import Foundation

/// What became of a steer or a redirect, from Hermes's answer (`docs/follow-ups.md` §2,
/// `docs/chat.md` §4c). A steer only ever goes into the running turn; when that turn can't take it,
/// it goes as the next message instead, visibly, and it's never lost or sent twice.
///
/// hermes-agent: `tui_gateway/methods_session_interrupt.py` (`session.steer`, `session.redirect`)
/// and `gateway/platforms/api_server_runs.py` (`POST /v1/runs/{id}/steer`).
public enum SteerOutcome: Sendable, Equatable {
    /// Accepted: Hermes reads it after the step it's on (`queued` on the socket).
    case accepted
    /// The redirect changed the turn's course (`redirected`).
    case redirected
    /// Hermes holds it for the next turn itself (a redirect while the agent is built, or while
    /// the chat compacts).
    case heldByHermes
    /// The turn couldn't take it: it ended (`rejected`), its agent was still being built (4010),
    /// it waits on the person's approval, or a run is queued or stopping (409
    /// `run_not_accepting_steer`), or the socket never came back while it waited. It goes as the
    /// next message (Up Next) instead.
    case nextMessage
    /// The answer was lost: Hermes may have read it. It stays waiting, and the stored turn says
    /// whether it was read; it's never sent again by itself.
    case unknown

    /// `session.steer`'s answer, or the error it failed with.
    public static func steer(result: JSONValue?, error: (any Error)?) -> SteerOutcome {
        if let error { return failed(error) }
        switch FollowUpStatus(result: result) {
        case .queued?, .steered?: return .accepted
        case .redirected?: return .redirected
        case .rejected?, .streaming?: return .nextMessage
        case nil: return .unknown
        }
    }

    /// `session.redirect`'s answer: `queued` means Hermes holds it for the next turn.
    public static func redirect(result: JSONValue?, error: (any Error)?) -> SteerOutcome {
        if let error { return failed(error) }
        switch FollowUpStatus(result: result) {
        case .redirected?, .steered?: return .redirected
        case .queued?: return .heldByHermes
        case .rejected?, .streaming?: return .nextMessage
        case nil: return .unknown
        }
    }

    /// `POST /v1/runs/{id}/steer`: `{accepted: true}`, or 409 when the run can't take it.
    public static func apiServer(error: (any Error)?) -> SteerOutcome {
        guard let error else { return .accepted }
        // A refusal (409 `run_not_accepting_steer` or `steer_not_accepted`, 404 for a run gone)
        // never took it; a timeout or a 5xx may have.
        if case .server(let status, _, _)? = error as? HermesError, status < 500 { return .nextMessage }
        return .unknown
    }

    /// An RPC Hermes answered with a refusal never took it; a lost answer may have.
    static func failed(_ error: any Error) -> SteerOutcome {
        switch error {
        case is GatewayRPCError, GatewaySocket.Failure.notConnected, is CancellationError:
            .nextMessage
        default:
            .unknown
        }
    }
}
