import Foundation

/// The next turn's events while the app still finishes the last one (`docs/chat.md` §2). Hermes
/// starts the next turn the moment one ends: a steer the turn never read, or what its queue holds,
/// goes as a turn of its own right after the turn's idle notice (hermes-agent
/// `tui_gateway/prompt_turn.py` `_run_post_turn_followups`). The app is still reading the ended
/// turn's stored rows then, and the new turn's start and first steps went into the ended turn, so
/// the new one never showed live, and a steer it carried was marked missed while Hermes answered
/// it. Held here instead, they start the next turn, in order, once the last one has handed over.
public struct NextTurnHold<Item> {
    public private(set) var held: [Item] = []

    public init() {}

    /// Holding the next turn's events: whatever comes after its first one waits behind it.
    public var isHolding: Bool { !held.isEmpty }

    /// Whether `item` waits for the next turn (and is kept here). Once the turn on screen has ended
    /// (its end heard, or it's being finished), an event that means a turn is under way starts the
    /// next one; from then on everything after it waits too, so nothing is applied out of order.
    /// Anything else before that belongs to the turn that ended, or to no turn.
    /// - Parameters:
    ///   - startsTurn: the event means a turn is under way (its start, words, a step, a question).
    ///   - turnEnded: the turn on screen has ended and is being finished, or is gone while it is.
    public mutating func holds(_ item: Item, startsTurn: Bool, turnEnded: Bool) -> Bool {
        guard isHolding || (startsTurn && turnEnded) else { return false }
        held.append(item)
        return true
    }

    /// The held events, in the order they came, for the next turn; the hold is empty after.
    public mutating func release() -> [Item] {
        defer { held = [] }
        return held
    }
}

extension NextTurnHold: Sendable where Item: Sendable {}
