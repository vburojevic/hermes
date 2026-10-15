import Foundation

// Checkpoints (`docs/checkpoints.md`): Hermes saves a chat's folder before it edits files, so a
// turn's changes can be reviewed and put back. The gateway's `rollback.*` calls
// (`tui_gateway/methods_tools.py`, `tools/checkpoint_manager.py`).

/// One saved state of the chat's folder (`rollback.list`). Hashes change when Hermes prunes old
/// checkpoints, so list again before acting on one.
public struct Checkpoint: Identifiable, Hashable, Sendable {
    /// Why Hermes saved it: the commit message, never the turn's text.
    public enum Kind: Hashable, Sendable {
        /// `before write_file`, `before patch`.
        case beforeEdit(tool: String)
        /// `before terminal: rm -rf build` (a command that looked destructive).
        case beforeCommand(String)
        /// `pre-rollback snapshot (restoring to 1a2b3c4d)`: the files just before a restore, so
        /// the restore itself can be undone.
        case beforeRestore(to: String)
        case other(String)
    }

    public var hash: String
    public var date: Date?
    public var message: String

    public var id: String { hash }

    public init(hash: String, date: Date?, message: String) {
        self.hash = hash
        self.date = date
        self.message = message
    }

    init?(json: JSONValue) {
        guard let hash = json["hash"]?.stringValue, !hash.isEmpty else { return nil }
        self.init(hash: hash, date: HermesDate.fromISO(json["timestamp"]?.stringValue), message: json["message"]?.stringValue ?? "")
    }

    public var kind: Kind {
        // Hermes may add " [nested git repos not captured: …]".
        let text = message.components(separatedBy: " [nested git repos").first ?? message
        if text.hasPrefix("pre-rollback snapshot"), let open = text.range(of: "restoring to ") {
            return .beforeRestore(to: String(text[open.upperBound...].prefix { $0.isHexDigit }))
        }
        if text.hasPrefix("before terminal: ") {
            return .beforeCommand(String(text.dropFirst("before terminal: ".count)))
        }
        if text.hasPrefix("before ") {
            return .beforeEdit(tool: String(text.dropFirst("before ".count)))
        }
        return .other(text)
    }
}

/// `rollback.list`: whether checkpoints are on for this chat, and its folder's checkpoints,
/// newest first.
public struct CheckpointList: Hashable, Sendable {
    public var enabled: Bool
    public var checkpoints: [Checkpoint]

    public init(enabled: Bool, checkpoints: [Checkpoint]) {
        self.enabled = enabled
        self.checkpoints = checkpoints
    }

    init(json: JSONValue) {
        enabled = json["enabled"]?.boolValue ?? false
        checkpoints = json["checkpoints"].items.compactMap(Checkpoint.init(json:))
    }
}

/// One file that differs between a checkpoint and the files now.
public struct CheckpointFileChange: Identifiable, Hashable, Sendable {
    public enum Change: Hashable, Sendable {
        case modified
        /// Not in the checkpoint: Hermes (or someone) created it after.
        case created
        /// In the checkpoint, gone now.
        case deleted
        case renamed(from: String)
    }

    /// Relative to the folder. With `pathIsExact` false it is git's shortened form (`.../Sync/X.swift`).
    public var path: String
    public var added: Int
    public var removed: Int
    public var change: Change
    public var isBinary: Bool
    /// The file's part of the diff, when it came back within the gateway's 4000 characters.
    public var diff: String?
    /// Its diff stopped at the limit.
    public var isPartial: Bool
    /// The full path is known, so this file can be restored on its own.
    public var pathIsExact: Bool

    public var id: String { path }

    public var fileName: String { (path as NSString).lastPathComponent }

    public init(path: String, added: Int, removed: Int, change: Change = .modified, isBinary: Bool = false,
                diff: String? = nil, isPartial: Bool = false, pathIsExact: Bool = true) {
        self.path = path
        self.added = added
        self.removed = removed
        self.change = change
        self.isBinary = isBinary
        self.diff = diff
        self.isPartial = isPartial
        self.pathIsExact = pathIsExact
    }
}

/// `rollback.diff`: what changed since a checkpoint (checkpoint on the minus side, now on the plus).
public struct CheckpointDiff: Hashable, Sendable {
    public var files: [CheckpointFileChange]
    public var added: Int
    public var removed: Int
    /// The diff came back shortened (`rollback.diff` caps it at 4000 characters); files past the
    /// cut have counts from the stat but no diff.
    public var isShortened: Bool

    /// What `rollback.diff` cuts the diff to.
    public static let diffLimit = 4000

    public init(files: [CheckpointFileChange], added: Int, removed: Int, isShortened: Bool) {
        self.files = files
        self.added = added
        self.removed = removed
        self.isShortened = isShortened
    }

    public init(stat: String, diff: String) {
        let shortened = diff.count >= Self.diffLimit
        var files = Self.sections(of: diff, shortened: shortened)
        let stats = Self.statLines(stat)
        // Files past the cut: from the stat (its +/− bars are scaled, so the split is approximate).
        for line in stats.files where !files.contains(where: { Self.samePath($0.path, line.path) }) {
            files.append(CheckpointFileChange(
                path: line.path, added: line.added, removed: line.removed, isBinary: line.isBinary,
                pathIsExact: !line.path.hasPrefix(".../")
            ))
        }
        // A shortened file's counts come from the stat when it has them.
        for index in files.indices where files[index].isPartial {
            if let line = stats.files.first(where: { Self.samePath(files[index].path, $0.path) }) {
                files[index].added = line.added
                files[index].removed = line.removed
            }
        }
        self.files = files
        added = stats.added ?? files.reduce(0) { $0 + $1.added }
        removed = stats.removed ?? files.reduce(0) { $0 + $1.removed }
        isShortened = shortened
    }

    // MARK: Parsing

    /// The unified diff, one section per `diff --git` header.
    static func sections(of diff: String, shortened: Bool) -> [CheckpointFileChange] {
        var result: [CheckpointFileChange] = []
        var lines: [Substring] = []
        func flush() {
            guard !lines.isEmpty else { return }
            if let file = section(lines) { result.append(file) }
            lines = []
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            lines.append(line)
        }
        flush()
        if shortened, !result.isEmpty { result[result.count - 1].isPartial = true }
        return result
    }

    private static func section(_ lines: [Substring]) -> CheckpointFileChange? {
        guard let header = lines.first, header.hasPrefix("diff --git ") else { return nil }
        var oldPath: String?
        var newPath: String?
        var change = CheckpointFileChange.Change.modified
        var renamedFrom: String?
        var isBinary = false
        var added = 0
        var removed = 0
        var inHunk = false
        for line in lines.dropFirst() {
            if !inHunk {
                if line.hasPrefix("new file mode") { change = .created }
                else if line.hasPrefix("deleted file mode") { change = .deleted }
                else if line.hasPrefix("rename from ") { renamedFrom = String(line.dropFirst("rename from ".count)) }
                else if line.hasPrefix("rename to ") { newPath = String(line.dropFirst("rename to ".count)) }
                else if line.hasPrefix("--- ") { oldPath = path(in: line.dropFirst(4)) }
                else if line.hasPrefix("+++ ") { newPath = path(in: line.dropFirst(4)) ?? newPath }
                else if line.hasPrefix("Binary files ") { isBinary = true }
                else if line.hasPrefix("@@") { inHunk = true }
                continue
            }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        if let renamedFrom, change == .modified { change = .renamed(from: renamedFrom) }
        // `diff --git a/x b/x`: the b side, split where " b/" starts the second half.
        let fromHeader: String? = {
            let rest = header.dropFirst("diff --git ".count)
            guard rest.hasPrefix("a/") else { return nil }
            let body = rest.dropFirst(2)
            let half = (body.count - 3) / 2
            if half > 0, body.count == half * 2 + 3 {
                let first = body.prefix(half)
                let second = body.suffix(half)
                if first == second { return String(first) }
            }
            return body.range(of: " b/").map { String(body[$0.upperBound...]) }
        }()
        guard let path = newPath ?? oldPath ?? fromHeader else { return nil }
        // The hunks, without git's header lines (`index`, `new file mode`, `---`, `+++`).
        let hunks = lines.drop { !$0.hasPrefix("@@") }
        return CheckpointFileChange(
            path: path, added: added, removed: removed, change: change, isBinary: isBinary,
            diff: hunks.isEmpty ? nil : hunks.joined(separator: "\n")
        )
    }

    /// `a/Sources/X.swift` → `Sources/X.swift`; `/dev/null` → nil.
    private static func path(in text: Substring) -> String? {
        var text = text
        if let tab = text.firstIndex(of: "\t") { text = text[..<tab] }
        if text == "/dev/null" { return nil }
        if text.hasPrefix("a/") || text.hasPrefix("b/") { return String(text.dropFirst(2)) }
        return String(text)
    }

    struct StatLine {
        var path: String
        var added: Int
        var removed: Int
        var isBinary: Bool
    }

    /// `git diff --stat`: ` Sources/X.swift | 12 +++++++---` lines, then
    /// ` 3 files changed, 41 insertions(+), 12 deletions(-)`.
    static func statLines(_ stat: String) -> (files: [StatLine], added: Int?, removed: Int?) {
        var files: [StatLine] = []
        var added: Int?
        var removed: Int?
        for raw in stat.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains(" changed"), line.first?.isNumber == true, !line.contains("|") {
                added = number(before: "insertion", in: line) ?? 0
                removed = number(before: "deletion", in: line) ?? 0
                continue
            }
            guard let bar = line.range(of: " | ", options: .backwards) else { continue }
            let path = line[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = line[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("Bin") {
                files.append(StatLine(path: renamedTarget(path), added: 0, removed: 0, isBinary: true))
                continue
            }
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard let total = parts.first.flatMap({ Int($0) }) else { continue }
            let graph = parts.count > 1 ? parts[1] : ""
            let plus = graph.filter { $0 == "+" }.count
            let minus = graph.filter { $0 == "-" }.count
            let lineAdded = plus + minus == 0 ? 0 : Int((Double(total) * Double(plus) / Double(plus + minus)).rounded())
            files.append(StatLine(path: renamedTarget(path), added: lineAdded, removed: total - lineAdded, isBinary: false))
        }
        return (files, added, removed)
    }

    /// `old.swift => new.swift` and `Sources/{A => B}/x.swift` name the new path.
    private static func renamedTarget(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"), open < close {
            let inside = path[path.index(after: open)..<close]
            let target = inside.components(separatedBy: " => ").last ?? ""
            let joined = String(path[..<open]) + target + String(path[path.index(after: close)...])
            return joined.replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }

    private static func number(before word: String, in line: String) -> Int? {
        guard let range = line.range(of: word) else { return nil }
        let head = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return head.split(separator: " ").last.flatMap { Int($0) }
    }

    /// The stat may shorten a long path to `.../tail`.
    static func samePath(_ full: String, _ stat: String) -> Bool {
        if full == stat { return true }
        guard stat.hasPrefix(".../") else { return false }
        return full.hasSuffix(String(stat.dropFirst(3)))
    }
}

/// What a restore did (`rollback.restore`). The list fields come only from gateways that restore
/// in safe mode; `hermes serve` overwrites the folder and sends none of them.
public struct CheckpointRestoreResult: Hashable, Sendable {
    public var success: Bool
    /// The first 8 characters of the hash it went back to.
    public var restoredTo: String?
    /// The restored checkpoint's own message.
    public var reason: String?
    public var directory: String?
    /// Set when one file was restored.
    public var file: String?
    public var restoredFiles: [String]
    /// Over the size limit, so never saved: left as they are.
    public var skippedOversize: [String]
    /// Changed by someone else after Hermes wrote them: left as they are.
    public var skippedUserEdits: [String]
    /// Files Hermes created that it couldn't delete.
    public var failedDeletes: [String]
    /// Messages the chat lost (only for a whole-folder restore).
    public var historyRemoved: Int?
    public var error: String?

    public init(success: Bool, restoredTo: String? = nil, reason: String? = nil, directory: String? = nil, file: String? = nil,
                restoredFiles: [String] = [], skippedOversize: [String] = [], skippedUserEdits: [String] = [],
                failedDeletes: [String] = [], historyRemoved: Int? = nil, error: String? = nil) {
        self.success = success
        self.restoredTo = restoredTo
        self.reason = reason
        self.directory = directory
        self.file = file
        self.restoredFiles = restoredFiles
        self.skippedOversize = skippedOversize
        self.skippedUserEdits = skippedUserEdits
        self.failedDeletes = failedDeletes
        self.historyRemoved = historyRemoved
        self.error = error
    }

    init(json: JSONValue) {
        func paths(_ key: String) -> [String] {
            json[key].items.compactMap { $0.stringValue ?? $0["path"]?.stringValue ?? $0["file"]?.stringValue }
        }
        self.init(
            success: json["success"]?.boolValue ?? false,
            restoredTo: json["restored_to"]?.stringValue,
            reason: json["reason"]?.stringValue,
            directory: json["directory"]?.stringValue,
            file: json["file"]?.stringValue,
            restoredFiles: paths("restored_files"),
            skippedOversize: paths("skipped_oversize"),
            skippedUserEdits: paths("skipped_user_edits"),
            failedDeletes: paths("failed_deletes"),
            historyRemoved: json["history_removed"]?.doubleValue.map { Int($0) },
            error: json["error"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// Why a checkpoint call didn't go through.
public enum CheckpointFailure: Error, Hashable, Sendable {
    /// A turn is running: a whole-folder restore waits for it (4009, or `session_busy` on
    /// gateways with session authority). One file can still be restored.
    case busy
    /// The gateway won't do it here and says why: a chat in a container
    /// (`_container_checkpoint_refusal`), a checkpoint that's gone.
    case refused(String)

    /// Sorts a gateway error. `nil` when it is neither (offline, a bug).
    public init?(error: any Error) {
        guard let rpc = error as? GatewayRPCError else { return nil }
        if rpc.code == 4009 || rpc.message == "session_busy" || rpc.message.hasPrefix("session busy") {
            self = .busy
        } else if [5020, 5021, 5022, 4014].contains(rpc.code) || (rpc.code == 4001 && rpc.message != "session not found") {
            self = .refused(Self.plain(rpc.message))
        } else {
            return nil
        }
    }

    /// The authority path's reasons are codes; the legacy path's are sentences.
    static func plain(_ message: String) -> String {
        switch message {
        case "invalid_checkpoint": String(localized: "That checkpoint is gone. Hermes may have pruned it.")
        case "unsupported_terminal_backend": String(localized: "Checkpoints aren't taken for chats that run in a container.")
        case "permission_denied", "profile_mismatch": String(localized: "This chat's checkpoints belong to another profile.")
        case "invalid_params": String(localized: "Hermes didn't accept that request.")
        default: message
        }
    }
}

/// The files a reply's tools wrote, for its undo bar: "3 files changed · +41 −12". From the
/// turn itself (each edit's diff), so it reads the same live and from history.
public struct TurnFileEdits: Hashable, Sendable {
    public var paths: [String]
    public var added: Int
    public var removed: Int

    public var isEmpty: Bool { paths.isEmpty }

    public init(turn: AssistantTurn) {
        var paths: [String] = []
        var added = 0
        var removed = 0
        for step in turn.steps {
            guard case .tool(let tool) = step, tool.status != .failed, Self.edits(tool) else { continue }
            let path = tool.filePath ?? tool.preview ?? tool.name
            if !paths.contains(path) { paths.append(path) }
            let counts = Self.counts(tool)
            added += counts.added
            removed += counts.removed
        }
        self.paths = paths
        self.added = added
        self.removed = removed
    }

    /// A call that wrote a file: Hermes saves the folder before these.
    static func edits(_ tool: ToolActivity) -> Bool {
        ["write_file", "patch"].contains(tool.name) || (tool.diff?.isEmpty == false)
    }

    /// Lines added and removed: the sent diff, else the edit's old and new text compared line by
    /// line (lines both share don't count).
    static func counts(_ tool: ToolActivity) -> (added: Int, removed: Int) {
        if let diff = tool.diff, !diff.isEmpty {
            var added = 0
            var removed = 0
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
            return (added, removed)
        }
        switch tool.name {
        case "patch":
            let old = tool.arguments?["old_string"]?.stringValue?.components(separatedBy: "\n") ?? []
            let new = tool.arguments?["new_string"]?.stringValue?.components(separatedBy: "\n") ?? []
            let difference = new.difference(from: old)
            return (difference.insertions.count, difference.removals.count)
        case "write_file":
            return (tool.arguments?["content"]?.stringValue?.components(separatedBy: "\n").count ?? 0, 0)
        default:
            return (0, 0)
        }
    }
}
