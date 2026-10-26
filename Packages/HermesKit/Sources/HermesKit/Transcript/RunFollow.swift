import Foundation

/// What following a run over the API server does when its event stream ends before the run did
/// (`docs/chat.md` §2, over the API server). The run's status says what's true; the stream may be
/// gone for good: Hermes sweeps a run's events 300 s after the run was created whenever nothing is
/// listening, even while it runs, and its events after that are dropped (hermes-agent
/// `gateway/platforms/api_server_runs.py` `_sweep_orphaned_runs_once`, `_RUN_STREAM_TTL`). A phone
/// back from the background after that got 404 on the events again and again, and said
/// "Reconnecting…" with no steps until the run ended.
public enum RunFollow {
    /// What the app does next.
    public enum Step: Sendable, Equatable {
        /// The run ended: its status says how.
        case end
        /// Hermes no longer has the run (a restart, past the hour it keeps a status): the stored
        /// chat says how it ended (`TurnRecovery`).
        case recover
        /// Listen to the events again.
        case listen
        /// The events are gone and the run goes on: follow its status alone until it ends, saying
        /// so in the turn's live line (`line`), and the stored reply shows when it does.
        case watchStatus
    }

    /// The run's events answered 404 (`run_not_found`) while its status may still be there: the
    /// stream was swept.
    public static func eventsGone(after error: (any Error)?) -> Bool {
        if case .notFound? = error as? HermesError { return true }
        return false
    }

    /// - Parameters:
    ///   - eventsGone: the events answered 404 (`eventsGone(after:)`), now or earlier in this run.
    ///   - status: the run's status, read after the stream ended.
    public static func next(eventsGone: Bool, status: Result<RunStatus, any Error>) -> Step {
        switch status {
        case .success(let status):
            if status.isTerminal { return .end }
            return eventsGone ? .watchStatus : .listen
        case .failure(let error):
            if case .notFound? = error as? HermesError { return .recover }
            // Couldn't ask (offline, a timeout): try again as before.
            return eventsGone ? .watchStatus : .listen
        }
    }

    /// How often the status is read once the events are gone.
    public static let statusInterval: TimeInterval = 4

    /// The turn's live line while only its status can be followed (`turnHeaderStepsLater`): it
    /// says it still runs, and why its steps don't show.
    public static var line: String {
        String(localized: "Still working · its steps show when it's done")
    }
}
