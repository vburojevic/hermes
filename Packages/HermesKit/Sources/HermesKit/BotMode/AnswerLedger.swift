import Foundation

/// Answers to Hermes's requests (approvals, questions) a chat gave, kept by the request's id until
/// Hermes is known to have them (`docs/quick-actions.md` §3).
///
/// Hermes doesn't acknowledge an answer: it resolves the request it names (`srq-…`) if it's still
/// open and drops it silently otherwise. An answer given with no socket to send it on, or written to
/// a socket that died before Hermes read it, would be lost, and the card came back on the next
/// attach as if never answered. So each answer stays here until the next attach says how it went:
/// - its request is still open (`open_requests`): the answer goes again, to that id only;
/// - it isn't, and the answer had gone out on a live socket: Hermes has it;
/// - it isn't, and the answer never went out: Hermes stopped waiting first (approvals time out
///   after 5 minutes), and the chat says so.
public struct AnswerLedger: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let result: JSONValue
        /// Written to a socket that was open at the time.
        public var sent = false
        /// On its way to the socket right now: an attach meanwhile neither sends it again nor says
        /// it expired (it may be the very answer that settled the request).
        public var isSending = true
        /// What the person was answering, for the note if it expired.
        public let summary: String
    }

    /// How an attach settled the answers kept.
    public struct Settlement: Sendable, Equatable {
        /// Still open on Hermes: send these again, each to its own id.
        public var resend: [Entry] = []
        /// Gone before an answer reached Hermes.
        public var expired: [Entry] = []
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// An answer the person gave, about to go out.
    public mutating func record(id: String, result: JSONValue, summary: String) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, result: result, summary: summary))
    }

    /// Answered already: an open request with this id is not shown again.
    public func holds(_ id: String) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Hermes withdrew the request (timed out, answered elsewhere, interrupted): nothing to send.
    public mutating func forget(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// A send (or resend) is over: `sent` when it went out on an open socket.
    public mutating func finishSending(_ id: String, sent: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isSending = false
        if sent { entries[index].sent = true }
    }

    /// The chat attached again and Hermes listed the requests still open (`openIDs`). Answers to
    /// open requests go again (and are kept until a later attach no longer lists them); answers
    /// that never went out, to requests no longer open, expired.
    public mutating func settle(openIDs: some Sequence<String>) -> Settlement {
        let open = Set(openIDs)
        var settlement = Settlement()
        var kept: [Entry] = []
        for var entry in entries {
            if open.contains(entry.id) {
                if !entry.isSending {
                    entry.isSending = true
                    settlement.resend.append(entry)
                }
                kept.append(entry)
            } else if !entry.sent, !entry.isSending {
                settlement.expired.append(entry)
            }
        }
        entries = kept
        return settlement
    }
}
