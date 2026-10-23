import Foundation

/// What a turn did to files, one entry per file (`docs/chat.md` §2, `turnChanges`): every edit the
/// turn made to a file merged into one diff where the edits allow it, its lines added and removed,
/// and whether it was created, deleted, renamed or written whole. Read from the turn itself (each
/// edit's arguments, result and `inline_diff`), so it reads the same live and from history; Hermes
/// Desktop's "N files changed" card folds a turn's edits the same way (`changed-files.ts`).
public struct TurnChanges: Hashable, Sendable {
    public var files: [ChangedFile]

    public init(files: [ChangedFile]) {
        self.files = files
    }

    public var isEmpty: Bool { files.isEmpty }
    /// The files the turn left different.
    public var changedFiles: [ChangedFile] { files.filter(\.hasChange) }
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
    public var failedEdits: Int { files.reduce(0) { $0 + $1.failures.count } }

    /// "Changed 3 files"; "1 edit failed" when nothing changed but something was tried.
    public var title: String {
        let count = changedFiles.count
        switch count {
        case 0: return failedEdits == 1 ? String(localized: "1 edit failed")
            : failedEdits > 1 ? String(localized: "\(failedEdits) edits failed") : String(localized: "No net changes")
        case 1: return String(localized: "Changed 1 file")
        default: return String(localized: "Changed \(count) files")
        }
    }

    /// "Changed 3 files, 106 lines added, 1 removed", and the failures.
    public var spokenSummary: String {
        var parts = [title]
        if !changedFiles.isEmpty {
            parts.append(added == 1 ? String(localized: "1 line added") : String(localized: "\(added) lines added"))
            parts.append(String(localized: "\(removed) removed"))
            if failedEdits > 0 {
                parts.append(failedEdits == 1 ? String(localized: "1 edit failed") : String(localized: "\(failedEdits) edits failed"))
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The files' names for the row's small line, as many as `limit`, then "+2".
    public func names(limit: Int = 3) -> String {
        let shown = (changedFiles.isEmpty ? files : changedFiles)
        let names = shown.prefix(limit).map(\.name)
        let rest = shown.count - names.count
        return (names + (rest > 0 ? ["+\(rest)"] : [])).joined(separator: " · ")
    }

    public func file(_ path: String) -> ChangedFile? {
        files.first { $0.path == path }
    }
}

/// One file a turn edited: its net change, or each edit in order when they couldn't be combined.
public struct ChangedFile: Identifiable, Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        case modified, created, deleted
        case renamed(from: String)
        /// Written whole over a file whose text before isn't in the chat (`write_file` without a diff).
        case rewritten
    }

    public var path: String
    public var change: Change
    public var added = 0
    public var removed = 0
    /// Edits the turn made to it, failed ones included.
    public var edits = 0
    /// What each failed edit said (empty when it said nothing). A failed edit changed nothing.
    public var failures: [String] = []
    /// One combined diff; false: each edit's own diff, in order.
    public var isMerged = true
    /// Hermes sent part of a change only (it caps an `inline_diff` at 80 lines).
    public var isShortened = false
    public var isBinary = false
    /// Too big to draw here: its size in bytes.
    public var tooBig: Int?
    /// The diff to draw, at most `ChangedFile.rowLimit` rows.
    public var rows: [DiffRow] = []
    /// How many rows the whole diff has.
    public var totalRows = 0
    /// The folder to show beside the name, shortened against the turn's other files.
    public var folder = ""

    public var id: String { path }
    public var name: String { ProjectPath.lastComponent(path) }
    /// What to highlight it as: its extension, or its name for the files known by name.
    public var language: String? {
        let name = name.lowercased()
        if ["dockerfile", "makefile"].contains(name) { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }
    public var hasChange: Bool { change != .modified || added + removed > 0 }

    public static let rowLimit = 2_000
    /// What a file's diff may weigh before it's summarised: the File tab's own limit.
    public static let byteLimit = 512 * 1_024

    public init(path: String, change: Change = .modified) {
        self.path = path
        self.change = change
    }
}

/// A line of a file's diff as drawn: its numbers in the file before and after, or a break.
public struct DiffRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context, added, removed
        /// Unchanged lines left out; how many when the numbers say.
        case gap(skipped: Int?)
        /// Edits shown one by one: where the next begins, and why it changed nothing if it failed.
        case edit(number: Int, of: Int, failure: String?)
    }

    public var id: Int
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String

    public init(id: Int, kind: Kind, oldLine: Int? = nil, newLine: Int? = nil, text: String = "") {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

extension AssistantTurn {
    /// What the turn's changes are found by again: its fold key (its first call's id, the same
    /// live and stored), else its id.
    public var changesKey: String { foldKey ?? id }
}

/// A turn's changes with the key they belong to.
public struct KeyedTurnChanges: Hashable, Sendable {
    public var key: String
    public var changes: TurnChanges

    public init(key: String, changes: TurnChanges) {
        self.key = key
        self.changes = changes
    }
}

// MARK: - Building

extension TurnChanges {
    /// The turn's changes, worked out once per state of its edits (rows ask on every redraw).
    public static func of(_ turn: AssistantTurn) -> TurnChanges {
        var hasher = Hasher()
        var edits = 0
        for step in turn.steps {
            guard case .tool(let tool) = step, TurnFileEdits.edits(tool) else { continue }
            edits += 1
            hasher.combine(tool.id)
            hasher.combine(tool.status)
            hasher.combine(tool.diff?.utf8.count)
            hasher.combine(tool.output?.utf8.count)
            hasher.combine(tool.result?.utf8.count)
        }
        guard edits > 0 else { return TurnChanges(files: []) }
        let key = "\(turn.id)\u{0}\(hasher.finalize())" as NSString
        if let hit = TurnChangesCache.cache.object(forKey: key) { return hit.value }
        let changes = TurnChanges(steps: turn.steps)
        TurnChangesCache.cache.setObject(TurnChangesCache.Box(changes), forKey: key)
        return changes
    }

    public init(steps: [AssistantStep]) {
        var builder = TurnChangesBuilder()
        for step in steps {
            guard case .tool(let tool) = step, tool.status != .running, TurnFileEdits.edits(tool) else { continue }
            builder.add(tool)
        }
        self.init(files: builder.files())
    }
}

private enum TurnChangesCache {
    final class Box {
        let value: TurnChanges
        init(_ value: TurnChanges) { self.value = value }
    }

    nonisolated(unsafe) static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 60
        return cache
    }()
}

/// What one edit did to one file.
private enum Operation {
    case patch(UnifiedDiff.FilePatch, shortened: Bool)
    /// `write_file`: the whole new text, and Hermes's diff of it when sent (`shortened`: in part).
    case content(String, diff: UnifiedDiff.FilePatch?, shortened: Bool)
    /// `patch` in its replace mode, known only from its arguments.
    case replace(old: String, new: String, all: Bool)
}

/// A run of the file changed: lines `old` from `oldIndex` (0-based) in the file before the turn
/// became `new` from `newIndex` in the file now.
struct NetHunk: Hashable {
    var oldIndex: Int
    var old: [String]
    var newIndex: Int
    var new: [String]

    var newEnd: Int { newIndex + new.count }
}

private struct EditRecord {
    var hunks: [UnifiedDiff.Hunk]
    var failure: String?
}

private struct FileState {
    var path: String
    var renamedFrom: String?
    /// The whole file before the turn, when known ([] when the turn created it).
    var base: [String]?
    /// The whole file now, when known.
    var current: [String]?
    /// What changed, where the whole file isn't known.
    var net: [NetHunk] = []
    var exists = true
    var created = false
    var rewritten = false
    var merged = true
    var shortened = false
    var binary = false
    var bytes = 0
    var records: [EditRecord] = []
    var failures: [String] = []

    var touched: Bool { !records.isEmpty }
}

struct TurnChangesBuilder {
    private var states: [FileState] = []

    mutating func add(_ tool: ToolActivity) {
        let failure = Self.failure(tool)
        let operations = Self.operations(tool)
        for (path, operation) in operations {
            let index = state(for: path, operation: operation)
            if let failure {
                states[index].failures.append(failure)
                states[index].records.append(EditRecord(hunks: [], failure: failure))
            } else {
                apply(operation, to: index)
            }
        }
    }

    /// A failed edit changed nothing: its status, or a result that says so.
    static func failure(_ tool: ToolActivity) -> String? {
        let json = [tool.output, tool.result].lazy.compactMap { $0 }.compactMap { ToolDisplayCache.json($0) }.first
        let error = json?["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let error { return error.components(separatedBy: "\n").first ?? error }
        if json?["success"]?.boolValue == false || tool.status == .failed { return "" }
        return nil
    }

    /// The files an edit changed and how, from the best source it carries: the `patch` result's
    /// full `diff`, then `inline_diff` (capped by Hermes), then the arguments.
    private static func operations(_ tool: ToolActivity) -> [(String, Operation)] {
        let toolPath = tool.filePath
        func named(_ diff: UnifiedDiff, shortened: Bool) -> [(String, Operation)] {
            diff.files.compactMap { file in
                var file = file
                if file.oldPath == "", file.newPath == "" {
                    guard let toolPath else { return nil }
                    file.oldPath = toolPath
                    file.newPath = toolPath
                } else if let toolPath, file.oldPath == file.newPath, same(file.path, toolPath) {
                    // The diff names it from the working folder; the call, in full.
                    file.oldPath = toolPath
                    file.newPath = toolPath
                }
                return (file.path, .patch(file, shortened: shortened))
            }
        }
        let inline = tool.diff.flatMap { $0.isEmpty ? nil : UnifiedDiff.parse($0) }
        switch tool.name {
        case "write_file":
            guard let path = toolPath, let content = tool.arguments?["content"]?.stringValue else {
                return inline.map { named($0, shortened: $0.omittedLines > 0) } ?? []
            }
            return [(path, .content(content, diff: inline?.files.first, shortened: (inline?.omittedLines ?? 0) > 0))]
        case "patch":
            let json = [tool.output, tool.result].lazy.compactMap { $0 }.compactMap { ToolDisplayCache.json($0) }.first
            if let full = json?["diff"]?.stringValue, !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let parsed = named(UnifiedDiff.parse(full), shortened: false)
                if !parsed.isEmpty { return parsed }
            }
            if let inline, !inline.files.isEmpty {
                return named(inline, shortened: inline.omittedLines > 0)
            }
            if let v4a = tool.arguments?["patch"]?.stringValue {
                return named(UnifiedDiff.parseV4A(v4a), shortened: false)
            }
            guard let path = toolPath, let old = tool.arguments?["old_string"]?.stringValue,
                  let new = tool.arguments?["new_string"]?.stringValue else { return [] }
            return [(path, .replace(old: old, new: new, all: tool.arguments?["replace_all"]?.boolValue ?? false))]
        default:
            return inline.map { named($0, shortened: $0.omittedLines > 0) } ?? []
        }
    }

    /// Two names for one file: the same, or one ends with the other (a tool's absolute path and
    /// the diff's path relative to the working folder).
    static func same(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("/" + b) || b.hasSuffix("/" + a)
    }

    private mutating func state(for path: String, operation: Operation) -> Int {
        var name = path
        // A move goes on the file it moved from, under its new name.
        if case .patch(let file, _) = operation, let from = file.oldPath, let to = file.newPath, from != to {
            if let index = states.firstIndex(where: { Self.same($0.path, from) }) {
                if !states[index].created { states[index].renamedFrom = states[index].renamedFrom ?? states[index].path }
                states[index].path = to
                return index
            }
            var state = FileState(path: to)
            state.renamedFrom = from
            states.append(state)
            return states.count - 1
        }
        if let index = states.firstIndex(where: { Self.same($0.path, path) }) {
            // Keep the fuller name.
            if path.count > states[index].path.count { states[index].path = path }
            return index
        }
        if name.isEmpty { name = "file" }
        states.append(FileState(path: name))
        return states.count - 1
    }

    private mutating func apply(_ operation: Operation, to index: Int) {
        var state = states[index]
        defer { states[index] = state }
        let fresh = !state.touched
        switch operation {
        case .content(let text, let diff, let shortened):
            state.bytes = max(state.bytes, text.utf8.count)
            if text.contains("\u{0}") { state.binary = true }
            let new = Self.lines(text)
            if let current = state.current, state.exists {
                state.records.append(EditRecord(hunks: Self.hunks(current, new), failure: nil))
            } else if let diff {
                state.records.append(EditRecord(hunks: diff.hunks, failure: nil))
                if fresh, diff.isCreation {
                    // A new file: its text is all there is, even when Hermes sent part of the diff.
                    state.base = []
                    state.created = true
                } else if shortened {
                    state.shortened = true
                    if fresh { state.rewritten = true } else if state.base == nil { state.merged = false }
                } else if !state.exists || !diff.hunks.allSatisfy(\.isNumbered) {
                    // Written again after the turn deleted it, or a diff that can't be placed.
                    if state.base == nil { state.merged = false }
                } else if state.merged, let net = Self.compose(state.net, diff.hunks) {
                    state.net = net
                } else {
                    state.merged = false
                }
            } else {
                state.records.append(EditRecord(hunks: [UnifiedDiff.Hunk(oldStart: 0, newStart: 1, lines: new.map { .init(.added, $0) })], failure: nil))
                if fresh {
                    state.rewritten = true
                } else if state.base == nil {
                    state.merged = false
                }
            }
            state.current = new
            state.exists = true

        case .patch(let file, let shortened):
            state.records.append(EditRecord(hunks: file.hunks, failure: nil))
            state.shortened = state.shortened || shortened
            state.bytes = max(state.bytes, file.hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.text.utf8.count + 1 } })
            if file.isBinary {
                state.binary = true
            } else if file.isMove, file.hunks.isEmpty {
                // Moved as it was: `state(for:)` renamed it.
            } else if file.isDeletion {
                if state.current == nil, state.net.isEmpty, state.base == nil, let hunk = file.hunks.first,
                   file.hunks.count == 1, hunk.newLines.isEmpty, (hunk.oldStart ?? 1) <= 1 {
                    // Hermes's deletion diff holds the whole file.
                    state.base = hunk.oldLines
                } else if state.current == nil, !state.created {
                    state.merged = false
                }
                state.current = []
                state.exists = false
            } else if file.isCreation, fresh || !state.exists {
                if fresh {
                    state.base = []
                    state.created = true
                } else if state.base == nil {
                    state.merged = false
                }
                state.current = file.hunks.flatMap(\.newLines)
                state.exists = true
            } else if !state.merged {
                // Shown one by one already.
            } else if shortened {
                // Part of a change can't be placed among the others.
                state.merged = false
            } else if let current = state.current {
                let numbered = file.hunks.allSatisfy(\.isNumbered)
                if let applied = numbered ? Self.applyNumbered(file.hunks, to: current) : Self.applyByContext(file.hunks, to: current) {
                    state.current = applied
                } else {
                    state.merged = false
                }
            } else if file.hunks.allSatisfy(\.isNumbered), let net = Self.compose(state.net, file.hunks) {
                state.net = net
            } else {
                state.merged = false
            }

        case .replace(let old, let new, let all):
            let hunk = UnifiedDiff.Hunk(lines: Self.diffLines(Self.lines(old), Self.lines(new)))
            state.records.append(EditRecord(hunks: [hunk], failure: nil))
            guard state.merged else { break }
            guard let current = state.current, state.exists else {
                state.merged = false
                break
            }
            let text = current.joined(separator: "\n")
            if all, text.contains(old) {
                state.current = Self.lines(text.replacingOccurrences(of: old, with: new))
            } else if let range = text.range(of: old) {
                state.current = Self.lines(text.replacingCharacters(in: range, with: new))
            } else {
                // Hermes matches loosely (whitespace, indentation); the exact text isn't there.
                state.merged = false
            }
        }
        // Once the whole file is known, so is what it was before: what changed, taken back out.
        if state.merged, state.base == nil, !state.rewritten, let current = state.current, state.exists {
            if let base = Self.unapply(state.net, to: current) {
                state.base = base
            } else {
                state.merged = false
            }
        }
    }

    func files() -> [ChangedFile] {
        let folders = ChangePath.folders(states.map(\.path))
        return states.map { state in
            var file = ChangedFile(path: state.path)
            file.folder = folders[state.path] ?? ""
            file.edits = state.records.count
            file.failures = state.failures
            file.isShortened = state.shortened
            file.isBinary = state.binary
            if state.created, state.exists {
                file.change = .created
            } else if !state.exists, !state.created {
                file.change = .deleted
            } else if let from = state.renamedFrom, state.exists {
                file.change = .renamed(from: from)
            } else if state.rewritten, state.exists {
                file.change = .rewritten
            }
            guard state.records.contains(where: { $0.failure == nil }), !state.binary else { return file }
            if state.bytes > ChangedFile.byteLimit {
                file.tooBig = state.bytes
                let lines = state.records.flatMap(\.hunks).flatMap(\.lines)
                file.added = lines.count { $0.kind == .added }
                file.removed = lines.count { $0.kind == .removed }
                return file
            }
            var rows = RowBuilder()
            if state.merged {
                if state.created, !state.exists {
                    // Made and removed in the same turn: nothing to show.
                } else if let base = state.base, let current = state.current {
                    rows.add(Self.chunks(Self.diffLines(base, state.exists ? current : []), oldStart: 1, newStart: 1))
                } else if state.rewritten, let current = state.current {
                    rows.add([UnifiedDiff.Hunk(newStart: 1, lines: current.map { .init(.added, $0) })])
                } else {
                    for hunk in state.net.sorted(by: { $0.newIndex < $1.newIndex }) {
                        rows.add(Self.chunks(Self.diffLines(hunk.old, hunk.new), oldStart: hunk.oldIndex + 1, newStart: hunk.newIndex + 1))
                    }
                }
            } else {
                for (number, record) in state.records.enumerated() {
                    rows.separate(number: number + 1, of: state.records.count, failure: record.failure)
                    rows.add(record.hunks)
                }
            }
            file.added = rows.added
            file.removed = rows.removed
            file.totalRows = rows.rows.count
            file.rows = Array(rows.rows.prefix(ChangedFile.rowLimit))
            file.isMerged = state.merged
            return file
        }
    }

    // MARK: Text

    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        // A file's last newline ends its last line; it doesn't start another.
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    static func diffLines(_ old: [String], _ new: [String]) -> [UnifiedDiff.Line] {
        guard old != new else { return [] }
        return ToolActivity.lineDiff(old, new).map { prefixed in
            let text = String(prefixed.dropFirst())
            switch prefixed.first {
            case "+": return .init(.added, text)
            case "-": return .init(.removed, text)
            default: return .init(.context, text)
            }
        }
    }

    /// `old` to `new` as numbered hunks, three lines around each change.
    static func hunks(_ old: [String], _ new: [String]) -> [UnifiedDiff.Hunk] {
        chunks(diffLines(old, new), oldStart: 1, newStart: 1)
    }

    /// Diff lines whose first lines are `oldStart` and `newStart` as hunks, `context` unchanged
    /// lines around each change, numbered as a unified diff's headers number them.
    static func chunks(_ lines: [UnifiedDiff.Line], oldStart: Int, newStart: Int, context: Int = 3) -> [UnifiedDiff.Hunk] {
        var kept = Set<Int>()
        for index in lines.indices where lines[index].kind != .context {
            kept.formUnion(max(0, index - context)...min(lines.count - 1, index + context))
        }
        var hunks: [UnifiedDiff.Hunk] = []
        var old = oldStart
        var new = newStart
        var previous: Int?
        for index in lines.indices {
            if kept.contains(index) {
                if previous.map({ index != $0 + 1 }) ?? true {
                    hunks.append(UnifiedDiff.Hunk(oldStart: old, newStart: new))
                }
                hunks[hunks.count - 1].lines.append(lines[index])
                previous = index
            }
            if lines[index].kind != .added { old += 1 }
            if lines[index].kind != .removed { new += 1 }
        }
        // A side with no lines names the line before the hunk.
        return hunks.map { hunk in
            var hunk = hunk
            if hunk.oldLines.isEmpty { hunk.oldStart = (hunk.oldStart ?? 1) - 1 }
            if hunk.newLines.isEmpty { hunk.newStart = (hunk.newStart ?? 1) - 1 }
            return hunk
        }
    }

    /// The hunks applied where their numbers say, else where their old lines are found.
    static func applyNumbered(_ hunks: [UnifiedDiff.Hunk], to current: [String]) -> [String]? {
        var text = current
        for hunk in hunks.sorted(by: { ($0.oldIndex ?? 0) > ($1.oldIndex ?? 0) }) {
            let old = hunk.oldLines
            guard var at = hunk.oldIndex, at <= text.count else { return nil }
            if at + old.count > text.count || Array(text[at..<(at + old.count)]) != old {
                guard let found = find(old, in: text, from: 0) else { return nil }
                at = found
            }
            text.replaceSubrange(at..<(at + old.count), with: hunk.newLines)
        }
        return text
    }

    /// Hunks without numbers (a V4A patch), each placed by its old lines after the one before.
    static func applyByContext(_ hunks: [UnifiedDiff.Hunk], to current: [String]) -> [String]? {
        var text = current
        var from = 0
        for hunk in hunks {
            let old = hunk.oldLines
            guard let at = find(old, in: text, from: from) ?? find(old, in: text, from: 0) else { return nil }
            text.replaceSubrange(at..<(at + old.count), with: hunk.newLines)
            from = at + hunk.newLines.count
        }
        return text
    }

    static func find(_ needle: [String], in haystack: [String], from: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count, from <= haystack.count - needle.count else { return nil }
        for start in from...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }

    /// The file before the turn, from the file now and what changed.
    static func unapply(_ net: [NetHunk], to current: [String]) -> [String]? {
        var text = current
        for hunk in net.sorted(by: { $0.newIndex > $1.newIndex }) {
            guard hunk.newEnd <= text.count, Array(text[hunk.newIndex..<hunk.newEnd]) == hunk.new else { return nil }
            text.replaceSubrange(hunk.newIndex..<hunk.newEnd, with: hunk.old)
        }
        return text
    }

    /// The turn's changes so far (`net`, before the turn → now) followed by an edit's numbered
    /// hunks (now → next), as one set of changes before the turn → next. Hunks that meet are
    /// joined; nil when they disagree about the lines between them (an edit that doesn't follow
    /// from the ones before), and the file's edits then show one by one.
    static func compose(_ net: [NetHunk], _ hunks: [UnifiedDiff.Hunk]) -> [NetHunk]? {
        var net = net.sorted { $0.newIndex < $1.newIndex }
        var placed: [(start: Int, old: [String], new: [String])] = []
        for hunk in hunks {
            guard let start = hunk.oldIndex else { return nil }
            placed.append((start, hunk.oldLines, hunk.newLines))
        }
        // From the bottom up, so the ones above keep their numbers.
        for (start, old, new) in placed.sorted(by: { $0.start > $1.start }) {
            let end = start + old.count
            let delta = new.count - old.count
            let meeting = net.indices.filter { net[$0].newIndex <= end && start <= net[$0].newEnd }
            guard let first = meeting.first, let last = meeting.last else {
                let before = net.filter { $0.newEnd <= start }.reduce(0) { $0 + $1.new.count - $1.old.count }
                for index in net.indices where net[index].newIndex > end { net[index].newIndex += delta }
                if old != new { net.append(NetHunk(oldIndex: start - before, old: old, newIndex: start, new: new)) }
                net.sort { $0.newIndex < $1.newIndex }
                continue
            }
            let low = min(start, net[first].newIndex)
            let high = max(end, net[last].newEnd)
            var now = [String?](repeating: nil, count: high - low)
            for index in meeting {
                for (offset, line) in net[index].new.enumerated() { now[net[index].newIndex - low + offset] = line }
            }
            for (offset, line) in old.enumerated() {
                let position = start - low + offset
                if let known = now[position], known != line { return nil }
                now[position] = line
            }
            guard !now.contains(where: { $0 == nil }) else { return nil }
            let lines = now.map { $0 ?? "" }
            var before: [String] = []
            var position = low
            for index in meeting {
                before += lines[(position - low)..<(net[index].newIndex - low)]
                before += net[index].old
                position = net[index].newEnd
            }
            before += lines[(position - low)...]
            let after = Array(lines[..<(start - low)]) + new + Array(lines[(end - low)...])
            let oldIndex = net[first].oldIndex - (net[first].newIndex - low)
            net.remove(atOffsets: IndexSet(meeting))
            for index in net.indices where net[index].newIndex >= high { net[index].newIndex += delta }
            if before != after { net.append(NetHunk(oldIndex: oldIndex, old: before, newIndex: low, new: after)) }
            net.sort { $0.newIndex < $1.newIndex }
        }
        return net
    }
}

/// Hunks to rows: each line with its numbers, a gap between hunks (with how many lines it skips
/// when the numbers say), and where each edit begins when they're shown one by one.
private struct RowBuilder {
    var rows: [DiffRow] = []
    var added = 0
    var removed = 0
    /// The old file's next line number after the last hunk drawn.
    private var nextOld: Int?

    mutating func separate(number: Int, of count: Int, failure: String?) {
        rows.append(DiffRow(id: rows.count, kind: .edit(number: number, of: count, failure: failure)))
        nextOld = nil
    }

    mutating func add(_ hunks: [UnifiedDiff.Hunk]) {
        for hunk in hunks where !hunk.lines.isEmpty {
            var old = hunk.oldStart.map { hunk.oldLines.isEmpty ? $0 + 1 : $0 }
            var new = hunk.newStart.map { hunk.newLines.isEmpty ? $0 + 1 : $0 }
            if let last = rows.last {
                let startsEdit = if case .edit = last.kind { true } else { false }
                let skipped = old.flatMap { start in nextOld.map { start - $0 } }
                if !startsEdit, skipped != 0 {
                    rows.append(DiffRow(id: rows.count, kind: .gap(skipped: skipped.flatMap { $0 > 0 ? $0 : nil })))
                }
            }
            for line in hunk.lines {
                let kind: DiffRow.Kind = switch line.kind {
                case .added: .added
                case .removed: .removed
                case .context: .context
                }
                rows.append(DiffRow(id: rows.count, kind: kind, oldLine: line.kind == .added ? nil : old,
                                    newLine: line.kind == .removed ? nil : new, text: line.text))
                if line.kind == .added { added += 1 } else { old = old.map { $0 + 1 } }
                if line.kind == .removed { removed += 1 } else { new = new.map { $0 + 1 } }
            }
            nextOld = old
        }
    }
}

// MARK: - Paths

/// Short names for the folders of a turn's files: what tells them apart, not the whole path.
public enum ChangePath {
    /// Each path's folder, home as `~`, without the folders every full path shares, and at most
    /// its last two folders (`…/Sources/Chat`). Files all in one folder show that folder's name.
    /// A path relative to the working folder (a V4A patch's) is already short.
    public static func folders(_ paths: [String]) -> [String: String] {
        let split = paths.map { path -> [String] in
            Array(ProjectPath.abbreviated(path).split(separator: "/").map(String.init).dropLast())
        }
        let full = zip(paths, split).filter { $0.0.hasPrefix("/") || $0.0.hasPrefix("~") }.map(\.1)
        var common = 0
        if paths.count > 1, let first = full.first {
            while common < first.count, full.allSatisfy({ $0.count > common && $0[common] == first[common] }) { common += 1 }
        }
        var result: [String: String] = [:]
        for (path, folders) in zip(paths, split) {
            let shared = path.hasPrefix("/") || path.hasPrefix("~") ? common : 0
            var rest = Array(folders.dropFirst(shared))
            if rest.isEmpty, shared > 0 { rest = [folders[shared - 1]] }
            result[path] = rest.count > 2 ? "…/" + rest.suffix(2).joined(separator: "/") : rest.joined(separator: "/")
        }
        return result
    }
}
