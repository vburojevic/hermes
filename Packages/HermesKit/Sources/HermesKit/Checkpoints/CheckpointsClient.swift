import Foundation

/// The gateway's checkpoint calls for one chat (`rollback.*`, `methods_tools.py`), plus the two
/// session calls undo leans on. All take the chat's runtime session id; `rollback.*` ignore the
/// profile, so none is sent. Unknown parameters are rejected (4000).
public struct CheckpointsClient: Sendable {
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// Whether checkpoints are on for this chat, and its folder's checkpoints, newest first.
    public func list(sessionID: String) async throws -> CheckpointList {
        CheckpointList(json: try await transport("rollback.list", ["session_id": .string(sessionID)]))
    }

    /// What differs between a checkpoint and the files now. Refused (5022) with a reason for a
    /// chat in a container.
    public func diff(sessionID: String, hash: String) async throws -> CheckpointDiff {
        let result = try await transport("rollback.diff", ["session_id": .string(sessionID), "hash": .string(hash)])
        return CheckpointDiff(stat: result["stat"]?.stringValue ?? "", diff: result["diff"]?.stringValue ?? "")
    }

    /// Puts the folder back as it was at `hash`, and drops the chat's newest turn; refused while a
    /// turn runs. With `filePath`, only that file, the chat untouched, allowed mid-turn. Send the
    /// full hash: a short one made only of digits reads as a list position.
    public func restore(sessionID: String, hash: String, filePath: String? = nil) async throws -> CheckpointRestoreResult {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), "hash": .string(hash)]
        if let filePath { params["file_path"] = .string(filePath) }
        return CheckpointRestoreResult(json: try await transport("rollback.restore", params))
    }

    /// Drops the chat's newest user turn and everything after it (`session.undo`); the files stay.
    /// Returns how many messages went.
    @discardableResult
    public func dropLastTurn(sessionID: String) async throws -> Int {
        let result = try await transport("session.undo", ["session_id": .string(sessionID), "intent": .string("undo")])
        return result["removed"]?.truncatedIntValue ?? 0
    }

    /// Ends the chat's live session on the gateway (its history stays, resumable). A resumed
    /// session builds a new agent, which reads settings like `checkpoints.enabled` again.
    @discardableResult
    public func closeSession(sessionID: String) async throws -> Bool {
        let result = try await transport("session.close", ["session_id": .string(sessionID)])
        return result["closed"]?.boolValue ?? false
    }
}

/// Ties checkpoints to the turns they were taken in. Nothing on the gateway links them: a
/// checkpoint's message names the tool ("before patch"), never the turn. Hermes takes one just
/// before a turn's first file write (and may take more as it goes), so a checkpoint belongs to the
/// turn whose time span holds it, and the earliest one in a turn is the state before it.
public struct CheckpointMatcher: Sendable {
    /// One user message and the time until the next.
    public struct Span: Hashable, Sendable {
        public var userID: String
        public var text: String
        /// The reply's id, once there is one.
        public var turnID: String?
        public var start: Date
        public var end: Date?
    }

    public let spans: [Span]

    public init(items: [TranscriptItem]) {
        var spans: [Span] = []
        for item in items {
            switch item {
            case .user(let entry) where !entry.isSteer && entry.isFromPerson:
                guard let start = entry.timestamp else { continue }
                if !spans.isEmpty { spans[spans.count - 1].end = start }
                spans.append(Span(userID: entry.id, text: entry.text, turnID: nil, start: start, end: nil))
            case .assistant(let turn):
                if !spans.isEmpty, spans[spans.count - 1].turnID == nil { spans[spans.count - 1].turnID = turn.id }
            default:
                continue
            }
        }
        self.spans = spans
    }

    /// The span a checkpoint was taken in. Checkpoint times are whole seconds, so a span starts at
    /// the second its message was sent.
    public func span(of checkpoint: Checkpoint) -> Span? {
        guard let date = checkpoint.date else { return nil }
        if case .beforeRestore = checkpoint.kind { return nil }
        return spans.last { span in
            date >= span.start.addingTimeInterval(-span.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) &&
                (span.end.map { date < $0 } ?? true)
        }
    }

    /// The state before a reply: the earliest checkpoint taken during it.
    public func checkpoint(beforeTurn turnID: String, in checkpoints: [Checkpoint]) -> Checkpoint? {
        checkpoints
            .filter { span(of: $0)?.turnID == turnID }
            .min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// The turns restoring `checkpoint` takes out of the chat, oldest first: its own turn and every
    /// later one. One from elsewhere (another chat in the folder, or a restore's own snapshot) still
    /// costs the newest turn: the gateway always drops that one.
    public func turnsRemoved(restoring checkpoint: Checkpoint) -> [Span] {
        if let own = span(of: checkpoint), let index = spans.firstIndex(of: own) {
            return Array(spans[index...])
        }
        return spans.last.map { [$0] } ?? []
    }

    /// One row per turn for the timeline: the earliest checkpoint of each turn, plus every
    /// checkpoint that belongs to no turn here. Newest first.
    public func timeline(_ checkpoints: [Checkpoint]) -> [Checkpoint] {
        var seen: Set<String> = []
        let oldestFirst = checkpoints.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var rows: [Checkpoint] = []
        for checkpoint in oldestFirst {
            if let span = span(of: checkpoint) {
                guard !seen.contains(span.userID) else { continue }
                seen.insert(span.userID)
            }
            rows.append(checkpoint)
        }
        return rows.reversed()
    }
}
