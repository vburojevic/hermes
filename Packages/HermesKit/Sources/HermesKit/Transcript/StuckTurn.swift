import Foundation

/// A turn flag that holds a chat with no turn to show for it (`docs/chat.md` §4b): the chat says a
/// turn is open on the gateway, or that one is finishing, while nothing streams. That happens
/// when the app never hears a turn end: one started elsewhere (a routine, another device, a turn
/// Hermes starts after a background process finishes) that ended while the socket was down, past
/// the moment Hermes lets a detached session go. After a short grace the gateway is asked, and
/// what it says settles it.
public enum StuckTurn {
    /// How long a flag may hold the chat with nothing streaming before the gateway is asked. A
    /// turn's ordinary end (its settle, reading its stored rows) takes a few seconds.
    public static let grace: Duration = .seconds(10)

    /// The flags hold the chat and no turn streams.
    public static func holds(isTurnOpen: Bool, isFinishing: Bool, isWorking: Bool) -> Bool {
        (isTurnOpen || isFinishing) && !isWorking
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing runs: the turn settles from the stored chat, and Up Next sends.
        case settle
        /// A turn still runs: the chat is attached to it (it streams on here), and messages wait
        /// in Up Next until it ends.
        case follow
        /// The gateway couldn't be asked: ask again after another grace.
        case askAgain
    }

    /// What the gateway's `running` (from `session.resume`) means for the held chat.
    public static func outcome(running: Bool?) -> Outcome {
        switch running {
        case false?: .settle
        case true?: .follow
        case nil: .askAgain
        }
    }
}
