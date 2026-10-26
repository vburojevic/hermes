import Foundation

/// How a turn whose end the app didn't hear finds out how it ended, by itself (`docs/chat.md` §2).
/// That happens in normal use: Hermes reaps a session 20 s after its last socket left, so a phone
/// away while its reply ended re-attaches to a new runtime that replays nothing; a run's status is
/// kept only for an hour, and not over a gateway restart; an app relaunched mid-reply finds the
/// stored rows stopping partway. Hermes stores a turn's rows before it says the session is idle,
/// so the stored chat says how the turn ended.
///
/// The app looks again on a backoff of about 30 s, within a minute of the unheard end however slow
/// the reads are (a frozen backend answers nothing for a minute at a time), and the turn keeps its
/// last state meanwhile: recovery is quiet. A turn still running is followed live; stored whole, its rows take over;
/// still partway once the looks are spent, it ended there, as Hermes stored it ("Stopped"). Only
/// when no look could read the chat, or Hermes says the chat is gone, does the turn say it lost
/// track, and why (`LostTurn`).
public struct TurnRecovery: Sendable, Equatable {
    /// The waits between looks: about 30 s in all after the first.
    public static let backoff: [TimeInterval] = [1, 2, 4, 8, 15]
    /// How long after the unheard end the app may keep looking, reads included: past it, what the
    /// looks found decides.
    public static let deadline: TimeInterval = 60

    /// How long a look that starts `elapsed` after the unheard end may take: what's left before the
    /// deadline, never less than a moment to try.
    public static func timeout(elapsed: TimeInterval) -> TimeInterval {
        max(2, deadline - elapsed)
    }

    /// What one look at Hermes found.
    public enum Look: Sendable, Equatable {
        /// The turn still runs: the chat attached to it again.
        case running
        /// The stored chat holds the turn whole.
        case stored
        /// The stored chat stops partway through the turn, and nothing runs.
        case partway
        /// The chat couldn't be read (offline, a timeout, the gateway down).
        case unreachable
        /// Hermes says the chat doesn't exist any more (a 404).
        case gone
    }

    /// What the app does next.
    public enum Step: Sendable, Equatable {
        /// Follow the turn live; it carries on in its place.
        case follow
        /// The stored rows take over.
        case handOver
        /// Look again this long from now.
        case wait(TimeInterval)
        /// It ended where Hermes stored it: settle it as stopped there (`AssistantTurn.endedPartway`).
        case settle
        /// Say the app lost track of it, and why, with Reload.
        case lost(LostTurn)
    }

    /// Looks taken so far.
    public private(set) var looks = 0
    /// A look read the chat stopping partway: the turn's end is known even if a later read fails.
    public private(set) var sawPartway = false

    public init() {}

    /// What a read of the stored chat that failed with `error` says: Hermes answering 404 for the chat
    /// (over the API server, `HermesError.notFound`; over the backend a Bot Chat is read from, a 404
    /// that isn't a route an older Hermes lacks) means it's gone; anything else, it couldn't be read.
    public static func look(after error: any Error) -> Look {
        if case .notFound? = error as? HermesError { return .gone }
        if case .http(404, let message)? = error as? BackendClient.Failure {
            return message.map(HermesVersionGap.isMissingRoute) == true ? .unreachable : .gone
        }
        return .unreachable
    }

    /// What a turn on screen does once its chat attached again after the socket dropped and Hermes
    /// says nothing runs there.
    public enum Reattached: Sendable, Equatable {
        /// The turn ended while the socket was down: it ends here, and the stored chat says how
        /// (`LiveTurn.settleUnheard`, then the looks above).
        case recover
        /// Hermes hasn't taken its prompt yet (it builds a chat's agent first): not over, so wait.
        case wait
        /// No turn on screen: what waited to be sent goes now.
        case idle
    }

    /// Attached again with nothing running. The replay (`session.events.since`) comes only from the
    /// same runtime: Hermes reaps a session 20 s after its last socket left, and the re-attach then
    /// gets a new runtime with a new event sequence, which replays nothing of the old one. Either
    /// way a turn on screen that heard no end by now never will, and asks the stored chat.
    public static func afterReattach(working: Bool, promptTaken: Bool) -> Reattached {
        guard working else { return .idle }
        return promptTaken ? .recover : .wait
    }

    /// - Parameter elapsed: time since the unheard end. Past `deadline` no more looks are taken, and a
    ///   wait never runs past it.
    public mutating func next(after look: Look, elapsed: TimeInterval = 0) -> Step {
        defer { looks += 1 }
        switch look {
        case .running: return .follow
        case .stored: return .handOver
        case .gone: return .lost(.gone)
        case .partway, .unreachable:
            if look == .partway { sawPartway = true }
            let left = Self.deadline - elapsed
            if looks < Self.backoff.count, left > 0 { return .wait(min(Self.backoff[looks], left)) }
            return sawPartway ? .settle : .lost(.unreachable)
        }
    }
}

/// Why the app couldn't find out by itself how a turn ended (`turnHeaderLost`, `docs/chat.md` §2).
/// The header says so in still words, with Reload beside them.
public enum LostTurn: String, Sendable, Equatable, CaseIterable {
    /// Every look failed to read the chat.
    case unreachable
    /// Hermes no longer has the chat.
    case gone

    public var line: String {
        switch self {
        case .unreachable: String(localized: "Couldn't reach the gateway to see how this reply ended.")
        case .gone: String(localized: "Hermes no longer has this reply.")
        }
    }

    /// The reason a failed turn's line gives, when it's one of these.
    public init?(line: String) {
        guard let reason = Self.allCases.first(where: { $0.line == line }) else { return nil }
        self = reason
    }
}
