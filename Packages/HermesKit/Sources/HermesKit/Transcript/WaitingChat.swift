import Foundation

/// A brand-new chat whose first message waits for the gateway (`docs/chat.md` §4): kept on the
/// device until Hermes has the message, so quitting the app loses nothing, and listed as a chat
/// meanwhile. The message itself is in the outbox, under `outboxKey`.
public struct WaitingChat: Codable, Sendable, Hashable, Identifiable {
    /// The chat's key on the device until Hermes makes it: its row, and its outbox before then.
    public let key: String
    /// The message's first line, for the row.
    public var title: String
    public var sentAt: Date
    /// The id the chat is asked for under over the API server, chosen here: Hermes refuses an id
    /// it has (409 `session_exists`), so asking again after a lost answer never makes a second chat.
    public let requestedID: String
    /// The chat Hermes made for it, once known.
    public private(set) var sessionID: String?
    /// The message went out to Hermes at least once (`prompt.submit`, or the run asked for): it may
    /// have it, so it's never sent again by itself.
    public private(set) var mayHaveArrived = false
    public var model: ModelSelection?
    public var effort: ReasoningEffort?
    /// The project it was started in (Run In), if any.
    public var projectID: String?

    public static let keyPrefix = "waiting-"

    public var id: String { key }

    public init(title: String, sentAt: Date = .now, model: ModelSelection? = nil, effort: ReasoningEffort? = nil,
                projectID: String? = nil, key: String = WaitingChat.keyPrefix + UUID().uuidString.lowercased(),
                requestedID: String? = nil) {
        self.key = key
        self.title = Self.line(title)
        self.sentAt = sentAt
        self.requestedID = requestedID ?? Self.newSessionID(at: sentAt)
        self.model = model
        self.effort = effort
        self.projectID = projectID
    }

    /// A key of a chat that only exists on this device.
    public static func isKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }

    /// An id shaped like the ones Hermes makes itself (`api_<seconds>_<8 hex>`).
    public static func newSessionID(at date: Date = .now) -> String {
        "api_\(Int(date.timeIntervalSince1970))_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))"
    }

    /// Hermes made the chat.
    public mutating func created(_ sessionID: String) {
        self.sessionID = sessionID
    }

    /// The message went out in `sessionID`'s chat.
    public mutating func left(in sessionID: String) {
        self.sessionID = sessionID
        mayHaveArrived = true
    }

    /// Where its message (and anything queued behind it) is kept: under the chat once Hermes made
    /// it, else under its own key.
    public var outboxKey: String { sessionID ?? key }

    /// What a relaunch does with it.
    public enum Resume: Equatable, Sendable {
        /// Nothing of the message reached Hermes: it goes again by itself, as a new chat. A chat
        /// made over the socket without a message isn't stored (Hermes stores it with its first
        /// prompt), and one made over the API server is asked for again under the same id.
        case send
        /// It went out: the chat Hermes made is asked whether it has it (`SubmitCheck`), and one
        /// that isn't there waits in Up Next for a Send, as in any chat.
        case lookFor(sessionID: String)
    }

    public var resume: Resume {
        if mayHaveArrived, let sessionID { return .lookFor(sessionID: sessionID) }
        return .send
    }

    /// As it goes again after a relaunch: a new chat, asking for the same API-server id.
    public var resent: WaitingChat {
        guard resume == .send else { return self }
        var next = self
        next.sessionID = nil
        return next
    }

    /// The key its row and chat go by: the chat's once Hermes made it, else its own.
    public var rowKey: String { sessionID ?? key }

    /// Its row in the chat list until the list has the chat itself.
    public var row: HermesSession {
        var row = HermesSession(id: rowKey, startedAt: sentAt, lastActive: sentAt, preview: title, messageCount: 1)
        row.title = title
        return row
    }

    /// The rows to show for `chats` above a list that has `listed` (stable keys): one per chat
    /// the list doesn't have yet, newest first.
    public static func rows(_ chats: [WaitingChat], listed: Set<String>) -> [HermesSession] {
        chats.filter { !listed.contains($0.rowKey) }.sorted { $0.sentAt > $1.sentAt }.map(\.row)
    }

    /// The chats still waiting once the gateway's list arrived: one whose message went out and
    /// whose chat Hermes now lists has arrived (Hermes stores a new chat with its first message).
    public static func remaining(_ chats: [WaitingChat], gatewayListed: Set<String>) -> [WaitingChat] {
        chats.filter { chat in
            guard chat.mayHaveArrived, let sessionID = chat.sessionID else { return true }
            return !gatewayListed.contains(sessionID)
        }
    }

    /// One line of the message, at most 60 characters, as Hermes's own preview.
    static func line(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
    }
}
