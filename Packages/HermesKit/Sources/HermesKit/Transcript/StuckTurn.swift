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

    /// What the gateway's `running` (from `session.resume`) means for the held chat. A turn whose end
    /// went unheard and whose stored rows are being read (`recovering`, `TurnRecovery`) isn't stuck:
    /// those reads are slow when Hermes is (a proxy's 502 is read again), and settling it here dropped
    /// the turn and its message, so the chat showed neither while its reads failed.
    public static func outcome(running: Bool?, recovering: Bool = false) -> Outcome {
        if recovering, running != true { return .askAgain }
        return switch running {
        case false?: .settle
        case true?: .follow
        case nil: .askAgain
        }
    }
}

/// A turn on screen that still works while the app hears nothing about it (`docs/chat.md` §4b):
/// its socket went quiet without closing (a phone that slept through the turn's end, a network
/// that drops a connection's traffic but not the connection), so no end ever comes, and the
/// header counted "Thinking…" with no end. A turn can be quiet for minutes on its own too (a long
/// tool call sends nothing between its start and its end), so quiet alone decides nothing: a turn
/// this quiet reads the stored chat, which Hermes writes before it says the session is idle, and
/// the stored chat decides. Whether a turn still runs is asked only when the socket itself hears
/// nothing, or once a minute, since asking attaches the chat again.
public enum QuietTurn {
    /// How long a working turn may go without an event before the app reads the stored chat.
    public static let quietAfter: TimeInterval = 30
    /// How often a quiet turn reads the stored chat again while it can't tell.
    public static let lookEvery: Duration = .seconds(15)
    /// How long one read may take before the look counts it as unanswered: a socket gone quiet
    /// never answers, and the next look tries again.
    public static let readTimeout: TimeInterval = 10
    /// How often a quiet turn on a socket that still hears its heartbeat asks whether it runs: a
    /// live socket would carry the turn's end, so the stored chat is the check that matters, and
    /// each ask attaches the chat again.
    public static let askRunningEvery: TimeInterval = 60

    /// Whether a working turn last heard from at `heardAt` is quiet enough to look.
    public static func isQuiet(heardAt: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(heardAt) >= quietAfter
    }

    /// Whether a look asks the gateway if the turn still runs. A socket that heard nothing lately
    /// may be gone half-open, and then its turn's end never comes: it asks every look. One that
    /// still hears its heartbeat asks once, then once every `askRunningEvery`.
    public static func asksRunning(socketHeard: Bool, lastAsked: Date?, now: Date = .now) -> Bool {
        guard socketHeard, let lastAsked else { return true }
        return now.timeIntervalSince(lastAsked) >= askRunningEvery
    }

    public enum Verdict: Equatable, Sendable {
        /// The turn may still run, or the app couldn't tell: it stays, and is looked at again.
        case keep
        /// The stored chat holds the turn whole: it ended unheard, and its stored rows take over.
        case settle
        /// Nothing runs and the stored chat doesn't hold the turn: its end went unheard, and its
        /// recovery finds out how it ended (`TurnRecovery`), never an endless timer.
        case recover
    }

    /// What one look at a quiet turn found. `stored` is the chat as Hermes stored it (nil when it
    /// couldn't be read), `after` the newest stored row from before the turn, and `running` whether
    /// Hermes says a turn runs there (nil when it couldn't be asked, as over a socket gone quiet).
    /// `heldAtSend` is the newest stored row the chat held when this device sent the turn: the
    /// turn's rows all come after it. `after` alone finds the message by its words, so a message
    /// sent again with the same words took the earlier one's reply for its own, and the unsent
    /// message vanished from the chat.
    public static func verdict(stored: [SessionMessage]?, after: Int?, running: Bool?, heldAtSend: Int? = nil) -> Verdict {
        let after = [after, heldAtSend].compactMap { $0 }.max()
        if let stored, TranscriptBuilder.holdsTurn(stored, after: after) { return .settle }
        return running == false ? .recover : .keep
    }
}
