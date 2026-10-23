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
    /// `hidden` for a send no chat shows (a widget's intent).
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

    /// The message as its bubble shows it (another Bot's message and a routine's delivery read
    /// as they do stored), or `nil` when there's nothing to show.
    public func userEntry(id: String) -> UserEntry? {
        guard !user.isEmpty, displayKind != "hidden", !CompactionSummary.matches(user) else { return nil }
        let entry = TranscriptBuilder.userEntry(id: id, message: SessionMessage(role: "user", content: .text(user), timestamp: startedAt))
        return entry.text.isEmpty && entry.fileNames.isEmpty ? nil : entry
    }

    /// The chat's rows already end with this message: Hermes without turn isolation stores it
    /// when it's sent. Its time says it's this turn's, not an earlier message with the same words.
    public func isStored(in items: [TranscriptItem]) -> Bool {
        guard let index = items.lastIndex(where: { if case .user = $0 { true } else { false } }),
              case .user(let stored) = items[index], let entry = userEntry(id: ""), stored.text == entry.text
        else { return false }
        if let startedAt, let at = stored.timestamp {
            return at >= startedAt.addingTimeInterval(-5)
        }
        return !items[(index + 1)...].contains { if case .assistant = $0 { true } else { false } }
    }
}
