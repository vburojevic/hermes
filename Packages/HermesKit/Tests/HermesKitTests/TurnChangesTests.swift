import Foundation
import Testing
@testable import HermesKit

@Suite("A turn's file changes")
struct TurnChangesTests {
    static func write(_ id: String, _ path: String, _ content: String, diff: String? = nil, status: ToolActivity.Status = .succeeded) -> AssistantStep {
        var tool = ToolActivity(id: id, name: "write_file", arguments: .object(["path": .string(path), "content": .string(content)]),
                                result: #"{"bytes_written": 10}"#, status: status)
        tool.diff = diff
        return .tool(tool)
    }

    /// A `patch` call as Hermes stores it: its arguments, and its result with the full diff.
    static func patch(_ id: String, _ path: String, old: String, new: String, diff: String?, error: String? = nil) -> AssistantStep {
        var result: [String: JSONValue] = ["success": .bool(error == nil)]
        if let diff { result["diff"] = .string(diff) }
        if let error { result["error"] = .string(error) }
        let text = String(decoding: try! JSONEncoder().encode(JSONValue.object(result)), as: UTF8.self)
        return .tool(ToolActivity(id: id, name: "patch",
                                  arguments: .object(["path": .string(path), "old_string": .string(old), "new_string": .string(new)]),
                                  result: text, status: error == nil ? .succeeded : .failed))
    }

    static let file = (1...30).map { "line \($0)" }

    /// difflib's diff of `old` → `new` for `path`, as the patch tool returns it.
    static func difflib(_ path: String, _ old: [String], _ new: [String]) -> String {
        let hunks = TurnChangesBuilder.hunks(old, new)
        var lines = ["--- a/\(path)", "+++ b/\(path)"]
        for hunk in hunks {
            let oldCount = hunk.oldLines.count, newCount = hunk.newLines.count
            lines.append("@@ -\(hunk.oldStart ?? 0),\(oldCount) +\(hunk.newStart ?? 0),\(newCount) @@")
            for line in hunk.lines {
                lines.append((line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func replacing(_ lines: [String], _ index: Int, with new: [String]) -> [String] {
        var lines = lines
        lines.replaceSubrange(index...index, with: new)
        return lines
    }

    // MARK: Grouping and merging

    /// The person's chat (2026-10-24): one file edited again and again, each edit its own card.
    /// Now it's one file, every edit merged into one diff with the file's numbers.
    @Test func editsToOneFileMergeIntoOneDiff() throws {
        let path = "/srv/app/scripts/testflight_reports.py"
        let v1 = Self.replacing(Self.file, 4, with: ["line 5", "import re"])
        let v2 = Self.replacing(v1, 21, with: ["changed 21", "added after 21"])
        let v3 = Self.replacing(v2, 5, with: ["import re, sys"])
        let turn = AssistantTurn(id: "t", steps: [
            Self.patch("a", path, old: "line 5", new: "line 5\nimport re", diff: Self.difflib("scripts/testflight_reports.py", Self.file, v1)),
            Self.patch("b", path, old: "line 21", new: "changed 21\nadded after 21", diff: Self.difflib("scripts/testflight_reports.py", v1, v2)),
            Self.patch("c", path, old: "import re", new: "import re, sys", diff: Self.difflib("scripts/testflight_reports.py", v2, v3)),
        ])
        let changes = TurnChanges(steps: turn.steps)
        #expect(changes.files.count == 1)
        let file = try #require(changes.files.first)
        #expect(file.path == path)
        #expect(file.edits == 3)
        #expect(file.isMerged)
        #expect(file.change == .modified)
        // Net: "import re, sys" added after line 5; line 21 changed and a line added after it.
        #expect(file.added == 3)
        #expect(file.removed == 1)
        #expect(!file.rows.contains { $0.text == "import re" })
        let added = try #require(file.rows.first { $0.text == "import re, sys" })
        #expect(added.newLine == 6 && added.oldLine == nil)
        let removed = try #require(file.rows.first { $0.kind == .removed })
        #expect(removed.text == "line 21" && removed.oldLine == 21)
        // The unchanged lines between the two places are a gap that says how many.
        #expect(file.rows.contains { $0.kind == .gap(skipped: 9) })
        #expect(changes.title == "Changed 1 file")
        #expect(changes.spokenSummary == "Changed 1 file, 3 lines added, 1 removed")
    }

    /// Edits whose diffs Hermes sent live (`inline_diff`, no result yet) merge the same way.
    @Test func inlineDiffsMergeLikeResults() throws {
        let v1 = Self.replacing(Self.file, 9, with: ["ten"])
        let v2 = Self.replacing(v1, 9, with: ["TEN"])
        var first = ToolActivity(id: "a", name: "patch", arguments: .object(["path": .string("/w/a.py")]), status: .succeeded)
        first.diff = Self.difflib("a.py", Self.file, v1)
        var second = ToolActivity(id: "b", name: "patch", arguments: .object(["path": .string("/w/a.py")]), status: .succeeded)
        second.diff = Self.difflib("a.py", v1, v2)
        let file = try #require(TurnChanges(steps: [.tool(first), .tool(second)]).files.first)
        #expect(file.isMerged)
        #expect(file.rows.filter { $0.kind == .removed }.map(\.text) == ["line 10"])
        #expect(file.rows.filter { $0.kind == .added }.map(\.text) == ["TEN"])
    }

    /// A file created in the turn, then patched: one new file with its final text.
    @Test func aNewFilePatchedLaterIsOneNewFile() throws {
        let created = "--- /dev/null\n+++ b/notes.md\n@@ -0,0 +1,3 @@\n+# Notes\n+\n+first"
        let changes = TurnChanges(steps: [
            Self.write("w", "/w/notes.md", "# Notes\n\nfirst\n", diff: created),
            Self.patch("p", "/w/notes.md", old: "first", new: "second", diff: nil),
        ])
        let file = try #require(changes.files.first)
        #expect(file.change == .created)
        #expect(file.isMerged)
        #expect(file.added == 3 && file.removed == 0)
        #expect(file.rows.map(\.text) == ["# Notes", "", "second"])
    }

    /// A whole-file write after an earlier one diffs against it; written twice whole, it's
    /// written whole once, its last text.
    @Test func aFileWrittenWholeTwiceIsItsLastText() throws {
        let first = (1...12).map { $0 == 3 ? "first draft" : "line \($0)" }.joined(separator: "\n")
        let second = (1...12).map { $0 == 3 ? "second draft" : "line \($0)" }.joined(separator: "\n")
        let file = try #require(TurnChanges(steps: [Self.write("a", "/tmp/brief.md", first), Self.write("b", "/tmp/brief.md", second)]).files.first)
        // Neither write came with a diff: what the file held before isn't in the chat.
        #expect(file.change == .rewritten)
        #expect(file.added == 12 && file.removed == 0)
        #expect(file.rows.contains { $0.text == "second draft" })
        #expect(!file.rows.contains { $0.text == "first draft" })
    }

    @Test func aDeletedFileShowsWhatWentWithIt() throws {
        let deletion = "--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two"
        var tool = ToolActivity(id: "d", name: "patch", arguments: .object(["mode": .string("patch"), "patch": .string("*** Begin Patch\n*** Delete File: old.txt\n*** End Patch")]),
                                result: #"{"success": true, "diff": "--- a/old.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-one\n-two", "files_deleted": ["old.txt"]}"#, status: .succeeded)
        tool.diff = deletion
        let file = try #require(TurnChanges(steps: [.tool(tool)]).files.first)
        #expect(file.change == .deleted)
        #expect(file.path == "old.txt")
        #expect(file.removed == 2 && file.added == 0)
    }

    /// A V4A patch that moves one file and edits another: two files, the move as a rename.
    @Test func aMultiFilePatchSplitsByFileAndKeepsTheRename() throws {
        let diff = "# Moved: src/a.py -> src/b.py\n--- a/src/c.py\n+++ b/src/c.py\n@@ -2,1 +2,1 @@\n-x = 1\n+x = 2"
        let result = String(decoding: try JSONEncoder().encode(JSONValue.object(["success": .bool(true), "diff": .string(diff)])), as: UTF8.self)
        let tool = ToolActivity(id: "v", name: "patch", arguments: .object(["mode": .string("patch")]), result: result, status: .succeeded)
        let changes = TurnChanges(steps: [.tool(tool)])
        #expect(changes.files.map(\.path) == ["src/b.py", "src/c.py"])
        #expect(changes.files[0].change == .renamed(from: "src/a.py"))
        #expect(changes.files[1].added == 1 && changes.files[1].removed == 1)
        #expect(changes.changedFiles.count == 2)
    }

    /// A failed edit changed nothing: it's counted and said, never drawn as a change.
    @Test func aFailedEditIsMarkedAndChangesNothing() throws {
        let v1 = Self.replacing(Self.file, 0, with: ["LINE 1"])
        let changes = TurnChanges(steps: [
            Self.patch("a", "/w/a.py", old: "line 1", new: "LINE 1", diff: Self.difflib("a.py", Self.file, v1)),
            Self.patch("b", "/w/a.py", old: "nope", new: "never", diff: nil, error: "Could not find a match for old_string in the file\nmore"),
            Self.patch("c", "/w/b.py", old: "nope", new: "never", diff: nil, error: "Could not find a match"),
        ])
        let a = try #require(changes.file("/w/a.py"))
        #expect(a.edits == 2)
        #expect(a.failures == ["Could not find a match for old_string in the file"])
        #expect(a.added == 1 && a.removed == 1)
        let b = try #require(changes.file("/w/b.py"))
        #expect(!b.hasChange && b.rows.isEmpty)
        #expect(changes.changedFiles.map(\.path) == ["/w/a.py"])
        #expect(changes.failedEdits == 2)
        #expect(changes.spokenSummary == "Changed 1 file, 1 line added, 1 removed, 2 edits failed")
        #expect(TurnChanges(steps: [Self.patch("c", "/w/b.py", old: "a", new: "b", diff: nil, error: "x")]).title == "1 edit failed")
    }

    /// An edit taken back later in the turn leaves no change.
    @Test func anEditRevertedLaterLeavesNoChange() throws {
        let v1 = Self.replacing(Self.file, 4, with: ["five"])
        let file = try #require(TurnChanges(steps: [
            Self.patch("a", "/w/a.py", old: "line 5", new: "five", diff: Self.difflib("a.py", Self.file, v1)),
            Self.patch("b", "/w/a.py", old: "five", new: "line 5", diff: Self.difflib("a.py", v1, Self.file)),
        ]).files.first)
        #expect(file.edits == 2)
        #expect(!file.hasChange)
        #expect(file.rows.isEmpty)
    }

    /// Edits that can't be put together (no numbers, the file's text unknown) show one by one.
    @Test func editsThatCannotMergeShowInOrder() throws {
        let file = try #require(TurnChanges(steps: [
            Self.patch("a", "/w/a.py", old: "one", new: "uno", diff: nil),
            Self.patch("b", "/w/a.py", old: "two", new: "dos", diff: nil),
        ]).files.first)
        #expect(!file.isMerged)
        #expect(file.rows.first?.kind == .edit(number: 1, of: 2, failure: nil))
        #expect(file.rows.contains { $0.kind == .edit(number: 2, of: 2, failure: nil) })
        #expect(file.added == 2 && file.removed == 2)
    }

    /// Hermes caps an `inline_diff` at 80 lines and says what it left out: the file says so too.
    @Test func aShortenedDiffIsMarked() throws {
        var tool = ToolActivity(id: "a", name: "patch", arguments: .object(["path": .string("/w/big.py")]), status: .succeeded)
        tool.diff = "--- a/big.py\n+++ b/big.py\n@@ -1,1 +1,1 @@\n-a\n+b\n… omitted 120 diff line(s)"
        let file = try #require(TurnChanges(steps: [.tool(tool)]).files.first)
        #expect(file.isShortened)
        #expect(file.added == 1)
    }

    /// A new file's `inline_diff` comes shortened past 80 lines; its text is still all there.
    @Test func aNewFileWithAShortenedDiffIsStillNew() throws {
        let content = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let diff = "--- a/r.py\n+++ b/r.py\n@@ -0,0 +1,100 @@\n" + (1...77).map { "+line \($0)" }.joined(separator: "\n")
            + "\n… omitted 23 diff line(s)"
        let file = try #require(TurnChanges(steps: [Self.write("w", "/w/r.py", content, diff: diff)]).files.first)
        #expect(file.change == .created)
        #expect(file.added == 100)
        #expect(file.isMerged)

        // Live, Hermes's events carry no arguments: the shortened diff is all there is, and the
        // file is still one new file, marked as sent in part.
        var live = ToolActivity(id: "w", name: "write_file", status: .succeeded)
        live.diff = diff
        let partial = try #require(TurnChanges(steps: [.tool(live)]).files.first)
        #expect(partial.path == "r.py")
        #expect(partial.change == .created)
        #expect(partial.isMerged && partial.isShortened)
        #expect(partial.added == 77)
    }

    @Test func binaryAndHugeFilesAreSummarised() throws {
        var binary = ToolActivity(id: "b", name: "patch", arguments: .object(["path": .string("/w/icon.png")]), status: .succeeded)
        binary.diff = "--- a/icon.png\n+++ b/icon.png\nBinary files a/icon.png and b/icon.png differ"
        let huge = String(repeating: "0123456789abcdef\n", count: 40_000)
        let changes = TurnChanges(steps: [.tool(binary), Self.write("h", "/w/data.csv", huge)])
        #expect(changes.files[0].isBinary && changes.files[0].rows.isEmpty)
        #expect(changes.files[1].tooBig == huge.utf8.count)
        #expect(changes.files[1].rows.isEmpty)
        #expect(changes.files[1].added == 40_000)
    }

    /// The same file named two ways (the tool's absolute path, the diff's relative one) is one file.
    @Test func oneFileNamedTwoWaysIsOneFile() {
        var write = ToolActivity(id: "w", name: "write_file", arguments: .object(["path": .string("/srv/app/a.py"), "content": .string("x\ny\n")]),
                                 status: .succeeded)
        write.diff = "--- a/a.py\n+++ b/a.py\n@@ -0,0 +1,2 @@\n+x\n+y"
        var skill = ToolActivity(id: "s", name: "skill_manage", status: .succeeded)
        skill.diff = "--- a/a.py\n+++ b/a.py\n@@ -2,1 +2,1 @@\n-y\n+z"
        let changes = TurnChanges(steps: [.tool(write), .tool(skill)])
        #expect(changes.files.map(\.path) == ["/srv/app/a.py"])
        #expect(changes.files.first?.rows.map(\.text) == ["x", "z"])
    }

    /// Running calls aren't counted until they finish; a turn without edits has no changes.
    @Test func runningAndOtherCallsAreLeftOut() {
        let running = Self.write("r", "/w/a.py", "x", status: .running)
        let read = AssistantStep.tool(ToolActivity(id: "x", name: "read_file", arguments: .object(["path": .string("/w/a.py")]), status: .succeeded))
        #expect(TurnChanges(steps: [running, read]).isEmpty)
        #expect(TurnChanges.of(AssistantTurn(id: "t", steps: [read])).isEmpty)
    }

    // MARK: Composing

    @Test func composingKeepsBothSidesNumbered() throws {
        // Line 3 replaced, then a line inserted at 10 of the new file.
        let first = UnifiedDiff.Hunk(oldStart: 3, newStart: 3, lines: [.init(.removed, "c"), .init(.added, "C"), .init(.added, "C2")])
        var net = try #require(TurnChangesBuilder.compose([], [first]))
        #expect(net == [NetHunk(oldIndex: 2, old: ["c"], newIndex: 2, new: ["C", "C2"])])
        let second = UnifiedDiff.Hunk(oldStart: 9, newStart: 10, lines: [.init(.added, "new")])
        net = try #require(TurnChangesBuilder.compose(net, [second]))
        #expect(net.last == NetHunk(oldIndex: 8, old: [], newIndex: 9, new: ["new"]))
        // An edit that disagrees with what the turn changed doesn't compose.
        let wrong = UnifiedDiff.Hunk(oldStart: 3, newStart: 3, lines: [.init(.removed, "c"), .init(.added, "x")])
        #expect(TurnChangesBuilder.compose(net, [wrong]) == nil)
    }

    // MARK: Paths

    @Test func foldersAreShortAndTellFilesApart() {
        let folders = ChangePath.folders([
            "/Users/sam/Code/app/Sources/Chat/Row.swift",
            "/Users/sam/Code/app/Sources/Chat/List.swift",
            "/Users/sam/Code/app/Tests/RowTests.swift",
        ])
        #expect(folders["/Users/sam/Code/app/Sources/Chat/Row.swift"] == "Sources/Chat")
        #expect(folders["/Users/sam/Code/app/Tests/RowTests.swift"] == "Tests")
        #expect(ChangePath.folders(["/Users/sam/Code/app/scripts/testflight_reports.py"]).values.first == "…/app/scripts")
        let same = ChangePath.folders(["/srv/app/a.py", "/srv/app/b.py"])
        #expect(same["/srv/app/a.py"] == "app")
        #expect(ChangePath.folders(["notes.md"])["notes.md"] == "")
        // A V4A patch's relative path beside full ones: each as short as it can be.
        let mixed = ChangePath.folders(["/srv/app/scripts/a.py", "/srv/app/docs/b.md", "scripts/old.py"])
        #expect(mixed == ["/srv/app/scripts/a.py": "scripts", "/srv/app/docs/b.md": "docs", "scripts/old.py": "scripts"])
    }

    @Test func theRowNamesAFewFiles() {
        let changes = TurnChanges(files: ["a.py", "b.py", "c.py", "d.py", "e.py"].map {
            var file = ChangedFile(path: "/w/" + $0)
            file.added = 1
            return file
        })
        #expect(changes.names() == "a.py · b.py · c.py · +2")
        #expect(changes.title == "Changed 5 files")
    }

    // MARK: Parsing

    @Test func parsesDifflibAndV4A() {
        let diff = UnifiedDiff.parse("--- a/x.py\n+++ b/x.py\n@@ -1 +1,2 @@\n-a\n+b\n+c\n--- a/y.py\n+++ /dev/null\n@@ -1,1 +0,0 @@\n--- not a header")
        #expect(diff.files.map(\.path) == ["x.py", "y.py"])
        #expect(diff.files[0].hunks.first?.oldStart == 1)
        #expect(diff.files[0].added == 2)
        #expect(diff.files[1].isDeletion)
        // A removed line that starts with "-- " isn't a header.
        #expect(diff.files[1].hunks.first?.lines.first?.text == "-- not a header")
        let v4a = UnifiedDiff.parseV4A("*** Begin Patch\n*** Add File: n.txt\n+hi\n*** Update File: o.txt\n*** Move to: p.txt\n@@ def x\n-a\n+b\n*** End Patch")
        #expect(v4a.files.map(\.path) == ["n.txt", "p.txt"])
        #expect(v4a.files[0].isCreation)
        #expect(v4a.files[1].oldPath == "o.txt")
    }
}
