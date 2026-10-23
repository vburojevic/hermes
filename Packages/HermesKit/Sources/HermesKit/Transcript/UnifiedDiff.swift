import Foundation

/// A unified diff read file by file, as Hermes's edit tools send them (`docs/chat.md` §2a): the
/// `patch` result's `diff` and `inline_diff` (difflib, `a/path` → `b/path`, numbered hunks), a
/// V4A patch's operations (`tools/patch_parser.py`: created and deleted files against
/// `/dev/null`, a move as `# Moved: a -> b`), and the app's own line diffs, whose hunks carry no
/// numbers.
public struct UnifiedDiff: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case context, added, removed }
        public var kind: Kind
        public var text: String

        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// One run of changes. `oldStart` and `newStart` are the header's 1-based numbers; nil for a
    /// hunk that came without them (it can't be placed in the file).
    public struct Hunk: Hashable, Sendable {
        public var oldStart: Int?
        public var newStart: Int?
        public var lines: [Line]

        public init(oldStart: Int? = nil, newStart: Int? = nil, lines: [Line] = []) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }

        public var oldLines: [String] { lines.filter { $0.kind != .added }.map(\.text) }
        public var newLines: [String] { lines.filter { $0.kind != .removed }.map(\.text) }
        public var isNumbered: Bool { oldStart != nil }

        /// Where the hunk's old side starts in the file, 0-based. A header's empty range names the
        /// line before it (`@@ -3,0 +4,2 @@` inserts after line 3).
        var oldIndex: Int? {
            guard let oldStart else { return nil }
            return oldLines.isEmpty ? oldStart : max(0, oldStart - 1)
        }
    }

    /// One file's part of the diff.
    public struct FilePatch: Hashable, Sendable {
        /// nil: the file didn't exist before (`/dev/null`).
        public var oldPath: String?
        /// nil: the file is gone after (`/dev/null`).
        public var newPath: String?
        public var hunks: [Hunk] = []
        public var isBinary = false
        /// A move with no change of content (`# Moved: a -> b`).
        public var isMove = false

        public init(oldPath: String?, newPath: String?, hunks: [Hunk] = []) {
            self.oldPath = oldPath
            self.newPath = newPath
            self.hunks = hunks
        }

        public var path: String { newPath ?? oldPath ?? "" }
        public var isCreation: Bool {
            if oldPath == nil { return true }
            // difflib names a file that didn't exist `a/path` too; its one hunk starts at -0,0.
            return hunks.count == 1 && hunks[0].oldStart == 0 && hunks[0].oldLines.isEmpty && !hunks[0].newLines.isEmpty
        }
        public var isDeletion: Bool { newPath == nil && oldPath != nil }
        public var added: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
        public var removed: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }
    }

    public var files: [FilePatch]
    /// Lines Hermes left out: it caps an `inline_diff` at 80 lines and says how many it omitted.
    public var omittedLines: Int

    public init(files: [FilePatch], omittedLines: Int = 0) {
        self.files = files
        self.omittedLines = omittedLines
    }

    /// `a/Sources/x.swift` → `Sources/x.swift`; `/dev/null` → nil.
    static func path(_ raw: Substring) -> String? {
        var path = raw.trimmingCharacters(in: .whitespaces)
        // A tab ends the name in git's and difflib's headers (a date may follow).
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        if path == "/dev/null" || path.isEmpty { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path
    }

    /// `@@ -12,5 +12,7 @@ func x()` → (12, 12); nil for a bare `@@` or `@@ hint @@`.
    static func header(_ line: String) -> (old: Int, new: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",").first ?? ""),
              let new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") else { return nil }
        return (old, new)
    }

    public static func parse(_ text: String) -> UnifiedDiff {
        let lines = text.components(separatedBy: "\n")
        var files: [FilePatch] = []
        var omitted = 0
        func current() -> Int {
            if files.isEmpty { files.append(FilePatch(oldPath: "", newPath: "")) }
            return files.count - 1
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            // A file's header; a removed line that happens to start "-- " has no "+++ " after it.
            if line.hasPrefix("--- "), index + 1 < lines.count, lines[index + 1].hasPrefix("+++ ") {
                files.append(FilePatch(oldPath: path(line.dropFirst(4)), newPath: path(lines[index + 1].dropFirst(4))))
                index += 1
                continue
            }
            if line.hasPrefix("@@") {
                let numbers = header(line)
                files[current()].hunks.append(Hunk(oldStart: numbers?.old, newStart: numbers?.new))
                continue
            }
            if line.hasPrefix("# Moved: "), let arrow = line.range(of: " -> ") {
                var move = FilePatch(oldPath: path(line[line.index(line.startIndex, offsetBy: 9)..<arrow.lowerBound]),
                                     newPath: path(line[arrow.upperBound...]))
                move.isMove = true
                files.append(move)
                continue
            }
            if line.hasPrefix("# Deleted: ") {
                files.append(FilePatch(oldPath: path(line.dropFirst(11)), newPath: nil))
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                files[current()].isBinary = true
                continue
            }
            if line.hasPrefix("… omitted ") || line.hasPrefix("... omitted ") {
                let words = line.split(separator: " ")
                omitted += words.count > 2 ? Int(words[2]) ?? 1 : 1
                continue
            }
            let kind: Line.Kind
            switch line.first {
            case "+": kind = .added
            case "-": kind = .removed
            case " ": kind = .context
            default: continue // "diff --git", "index", "\ No newline at end of file", blank lines
            }
            let file = current()
            if files[file].hunks.isEmpty { files[file].hunks.append(Hunk()) }
            files[file].hunks[files[file].hunks.count - 1].lines.append(Line(kind, String(line.dropFirst())))
        }
        // Lines before any header belong to a file with an empty path, for the caller to name.
        files.removeAll { $0.oldPath == "" && $0.newPath == "" && $0.hunks.allSatisfy(\.lines.isEmpty) && !$0.isBinary }
        return UnifiedDiff(files: files, omittedLines: omitted)
    }

    /// A V4A patch (`*** Begin Patch`, `*** Update File: p`, `*** Add File: p`, `*** Delete File: p`,
    /// `*** Move to: q`), as the `patch` tool takes it in its `patch` mode. Its hunks have no
    /// numbers: only context places them.
    public static func parseV4A(_ text: String) -> UnifiedDiff {
        var files: [FilePatch] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst(17)).trimmingCharacters(in: .whitespaces)
                files.append(FilePatch(oldPath: path, newPath: path))
            } else if line.hasPrefix("*** Add File: ") {
                files.append(FilePatch(oldPath: nil, newPath: String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("*** Delete File: ") {
                files.append(FilePatch(oldPath: String(line.dropFirst(17)).trimmingCharacters(in: .whitespaces), newPath: nil))
            } else if line.hasPrefix("*** Move to: "), !files.isEmpty {
                files[files.count - 1].newPath = String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("***") {
                continue
            } else if line.hasPrefix("@@"), !files.isEmpty {
                files[files.count - 1].hunks.append(Hunk())
            } else if let first = line.first, "+- ".contains(first), !files.isEmpty {
                let kind: Line.Kind = first == "+" ? .added : first == "-" ? .removed : .context
                if files[files.count - 1].hunks.isEmpty { files[files.count - 1].hunks.append(Hunk()) }
                let last = files.count - 1
                files[last].hunks[files[last].hunks.count - 1].lines.append(Line(kind, String(line.dropFirst())))
            }
        }
        for index in files.indices where files[index].oldPath != files[index].newPath && files[index].oldPath != nil
            && files[index].newPath != nil && files[index].hunks.isEmpty {
            files[index].isMove = true
        }
        return UnifiedDiff(files: files)
    }
}
