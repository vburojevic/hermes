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
    /// Looks that find the turn partway, with nothing running, before it settles: nil when the backoff
    /// decides (the chat), 2 for the Bots list (`forBotsList`).
    public let partwaySettles: Int?
    /// Looks so far that found it partway.
    public private(set) var partwayLooks = 0

    public init(partwaySettles: Int? = nil) {
        self.partwaySettles = partwaySettles
    }

    /// The Bots list's looks at a Bot's own turn (`docs/bots-groups-skills.md` §1.2): two looks a second
    /// apart that both find nothing running and the rows partway settle it. Hermes stores a turn's rows
    /// before it says the session is idle, so a row that stops showing as working is right the moment
    /// nothing runs. The chat waits out the whole backoff, as its "Stopped" is a verdict on screen that
    /// a late store would contradict; a reply stored late here only moves the rows, and the row
    /// follows them.
    public static func forBotsList() -> TurnRecovery {
        TurnRecovery(partwaySettles: 2)
    }

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

    /// One look at a Bot's own turn whose stored rows stop mid-work, for a Bot whose chat isn't
    /// following it (`docs/bots-groups-skills.md` §1.2): the same verdict the chat reaches. `running`
    /// is whether Hermes runs the chat now (`session.active_list`, the flag `session.resume` answers
    /// the chat with), nil when it couldn't be asked; `stored` is the chat's last rows read again, nil
    /// when they couldn't be read. Rows that no longer stop mid-work in the person's own turn (the
    /// reply stored, another turn, too quiet to be running) take over.
    public static func look(running: Bool?, stored: [SessionMessage]?, now: Date = .now) -> Look {
        if running == true { return .running }
        guard let stored else { return .unreachable }
        guard TranscriptBuilder.endsOwnMidTurn(stored, now: now) else { return .stored }
        return running == false ? .partway : .unreachable
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
            if look == .partway {
                sawPartway = true
                partwayLooks += 1
                if let partwaySettles, partwayLooks >= partwaySettles { return .settle }
            }
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
