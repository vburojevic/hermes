import Foundation

/// A message whose `prompt.submit` answer never came (the socket closed first), known by where
/// and when it went in rather than by its words (`docs/chat.md` §2).
///
/// Absence proves nothing. Hermes can take a prompt late: while it builds a chat's agent it says
/// the chat is idle and stores nothing yet, and a starved Mac reads a dead socket's last frames
/// after the app has given up on it. Sending the message again then ran it twice. So only
/// evidence settles it, a turn Hermes took or a row it stored, and without any the message is
/// never sent again by itself. Words aren't compared: Hermes stores what it was sent, which isn't
/// always what the composer held (a mention's note, file references, a skill's expansion).
public struct LostPrompt: Sendable, Equatable {
    /// The newest stored message the chat had when it was sent.
    public let knownNewestID: Int?
    public let sentAt: Date

    /// How far apart the device's clock and the gateway's may be, for a turn's start.
    static let turnClockSkew: TimeInterval = 15
    /// For a stored row's time (Hermes stamps rows as it stores them, which can be later).
    static let rowClockSkew: TimeInterval = 120

    public init(knownNewestID: Int?, sentAt: Date) {
        self.knownNewestID = knownNewestID
        self.sentAt = sentAt
    }

    public enum Finding: Sendable, Equatable {
        /// Hermes runs a turn that started with or after the send: this message's.
        case taken
        /// A message from the person is stored after the newest row the chat had: this one.
        case stored
        /// Nothing yet, which proves nothing: Hermes may still take it.
        case nothingYet
    }

    /// What Hermes shows of the message: a running turn (`session.resume`'s `running` and
    /// `turn_started_at`), else the stored chat's rows (`nil` when they couldn't be read).
    public func finding(running: Bool, turnStartedAt: Date?, messages: [SessionMessage]?) -> Finding {
        if wasTaken(running: running, turnStartedAt: turnStartedAt) { return .taken }
        if let messages, wasStored(in: messages) { return .stored }
        return .nothingYet
    }

    /// A turn runs that started around or after the send. Running without a start time still
    /// counts: a turn Hermes started since is the only one this chat can have.
    public func wasTaken(running: Bool, turnStartedAt: Date?) -> Bool {
        guard running else { return false }
        guard let turnStartedAt else { return true }
        return turnStartedAt >= sentAt.addingTimeInterval(-Self.turnClockSkew)
    }

    /// A message from the person is stored after the newest row the chat had when this one was
    /// sent, from around then. Not a row Hermes adds itself (a hidden intent, a failed turn's
    /// notice, an internal notification).
    public func wasStored(in messages: [SessionMessage]) -> Bool {
        messages.contains { message in
            guard message.role == "user", !Self.notThePerson.contains(message.displayKind ?? "") else { return false }
            if let known = knownNewestID, let id = message.id, id <= known { return false }
            if let at = message.timestamp, at < sentAt.addingTimeInterval(-Self.rowClockSkew) { return false }
            return knownNewestID != nil || message.timestamp != nil
        }
    }

    private static let notThePerson: Set<String> = ["hidden", "failed_turn", "internal_notification"]
}
