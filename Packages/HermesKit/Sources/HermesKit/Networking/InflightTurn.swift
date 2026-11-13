import Foundation

/// The turn a live session is running, as `session.resume` and `session.activate` report it
/// (`inflight`, `turn_started_at`). Hermes keeps the message from the moment it was sent, so
/// another device sees it before the stored chat has it: with `dashboard.turn_isolation` the
/// stored row lands only once the turn's own process starts.
public struct InflightTurn: Sendable, Equatable {
    /// The message the turn answers, as it was sent.
    public var user: String
    /// The reply so far (empty under turn isolation, where the turn streams from its own process).
    public var assistant: String
    /// `hidden` for a send no chat shows (a widget's intent, a heartbeat); `process_complete`,
    /// `internal_notification` and the like for a turn Hermes started by itself
    /// (`tui_gateway/session_history.py` `_start_inflight_turn`).
    public var displayKind: String?
    public var startedAt: Date?

    public init(user: String, assistant: String = "", displayKind: String? = nil, startedAt: Date? = nil) {
        self.user = user
        self.assistant = assistant
        self.displayKind = displayKind
        self.startedAt = startedAt
    }

    public init?(snapshot: JSONValue) {
        guard let inflight = snapshot["inflight"], case .object = inflight else { return nil }
        user = inflight["user"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        assistant = inflight["assistant"]?.stringValue ?? ""
        displayKind = inflight["display_kind"]?.stringValue
        startedAt = HermesDate.fromEpoch(snapshot["turn_started_at"]?.doubleValue)
    }

    /// The message as the chat shows it, read as the stored chat reads it
    /// (`TranscriptBuilder.reading`): the person's bubble, another Bot's message or a routine's or
    /// a script's delivery as theirs, a notice Hermes started the turn for by itself (a finished
    /// process, helpers' results) as its line, and nothing for a hidden send, a heartbeat,
    /// scaffolding or a compaction summary (`docs/chat.md` §2a).
    public func reading(id: String) -> TranscriptBuilder.UserRowReading {
        guard !user.isEmpty, !CompactionSummary.matches(user) else { return .nothing }
        let message = SessionMessage(role: "user", content: .text(user), timestamp: startedAt, displayKind: displayKind)
        let reading = TranscriptBuilder.reading(id: id, message: message)
        if case .message(let entry) = reading, entry.text.isEmpty, entry.fileNames.isEmpty, entry.skillNames.isEmpty {
            return .nothing
        }
        return reading
    }

    /// The message as its bubble shows it, or `nil` when it has none (`reading`).
    public func userEntry(id: String) -> UserEntry? {
        if case .message(let entry) = reading(id: id) { entry } else { nil }
    }

    /// The chat's rows already end with this message: Hermes without turn isolation stores it
    /// when it's sent. Its time says it's this turn's, not an earlier message with the same words.
    /// A notice is found as its stored line, folded into the finished work before it or not.
    public func isStored(in items: [TranscriptItem]) -> Bool {
        let index: Int
        let storedAt: Date?
        switch reading(id: "") {
        case .nothing:
            return false
        case .message(let entry):
            guard let found = items.lastIndex(where: { if case .user = $0 { true } else { false } }),
                  case .user(let stored) = items[found], stored.text == entry.text
            else { return false }
            (index, storedAt) = (found, stored.timestamp)
        case .notice(let notice):
            guard let found = items.lastIndex(where: { if case .notice = $0 { true } else { false } }),
                  case .notice(let stored) = items[found], Self.holds(stored, notice)
            else { return false }
            (index, storedAt) = (found, stored.timestamp)
        }
        if let startedAt, let storedAt {
            return storedAt >= startedAt.addingTimeInterval(-5)
        }
        return !items[(index + 1)...].contains { if case .assistant = $0 { true } else { false } }
    }

    /// The stored line is this notice: the same note, or a line of finished work that names all of
    /// it (by process id; the stored copy may know more, such as when each process started).
    private static func holds(_ stored: Notice, _ notice: Notice) -> Bool {
        guard stored.kind == notice.kind else { return false }
        guard !notice.work.isEmpty else { return stored.text == notice.text }
        return notice.work.allSatisfy { work in stored.work.contains { same($0, work) } }
    }

    private static func same(_ a: FinishedWork, _ b: FinishedWork) -> Bool {
        switch (a, b) {
        case (.process(let a), .process(let b)): a.id == b.id
        case (.helper(let a), .helper(let b)): a.goal == b.goal && a.status == b.status
        default: false
        }
    }
}
