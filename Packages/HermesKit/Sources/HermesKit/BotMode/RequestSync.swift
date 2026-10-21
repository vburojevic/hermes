import Foundation

/// Which of the request cards a chat shows Hermes no longer waits on (`docs/quick-actions.md` §1).
///
/// Hermes tells the other clients nothing when one of them answers a request: it settles it and
/// stops listing it in `open_requests`, and an answer to it from anywhere else is dropped silently.
/// So another device's card stayed up, and could be answered again for nothing. A chat compares the
/// cards it shows with the ids Hermes still lists (on attaching, on coming back, and while a card is
/// up and the chat moves on) and takes down the ones that ended.
public enum RequestSync {
    public enum Ending: Sendable, Equatable {
        /// Settled while the card was still up here: another device answered it.
        case answeredElsewhere
        /// Past its deadline: Hermes stopped waiting.
        case timedOut
    }

    public struct Card: Sendable, Equatable {
        public let id: String
        public let deadline: Date?

        public init(id: String, deadline: Date? = nil) {
            self.id = id
            self.deadline = deadline
        }
    }

    /// The cards that ended, in the order shown. `answeredHere` are ids this device answered and
    /// is still sending (`AnswerLedger`): their cards are already gone, and Hermes may simply not
    /// have them yet.
    public static func ended(shown: [Card], open: Set<String>, answeredHere: Set<String> = [], now: Date = .now) -> [(id: String, ending: Ending)] {
        shown.compactMap { card in
            guard !open.contains(card.id), !answeredHere.contains(card.id) else { return nil }
            if let deadline = card.deadline, deadline <= now { return (card.id, .timedOut) }
            return (card.id, .answeredElsewhere)
        }
    }

    /// The ids in an `open_requests` list (`session.resume`, `session.activate`,
    /// `session.events.since`).
    public static func openIDs(_ value: JSONValue?) -> Set<String>? {
        guard case .array(let list)? = value else { return nil }
        return Set(list.compactMap { $0["id"]?.stringValue })
    }
}
