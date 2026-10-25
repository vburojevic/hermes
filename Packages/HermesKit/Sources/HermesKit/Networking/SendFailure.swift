import Foundation

/// What a message's send that failed means for the message (`docs/chat.md` §4): whether it goes
/// again by itself, is looked for first, or goes back to the person. A busy or away Mac is never a
/// reason to give a message back: it waits for the gateway, visibly, and goes when it can.
public enum SendFailure: Equatable, Sendable {
    /// It never reached Hermes: no socket to send it on, or Hermes was retiring the process that
    /// took it. It waits for the gateway and goes again; nothing can run twice.
    case notSent
    /// Sent with a key Hermes dedupes on (`Idempotency-Key` on `POST /v1/runs`): the same request
    /// again is safe whatever became of the first, so it goes again after a pause.
    case sendAgain
    /// It went out and the answer was lost (the socket closed, or the answer was too late): Hermes
    /// may have it, so the stored chat is asked first (`SubmitCheck`). `prompt.submit` has no key
    /// Hermes dedupes on; sending it again could run it twice.
    case mayHaveArrived
    /// Hermes refused it: it goes back to the person, with why.
    case refused

    /// A `prompt.submit`, or a call on the socket on its way there (attaching the chat, a file).
    public static func overSocket(_ error: any Error) -> SendFailure {
        switch error {
        case GatewaySocket.Failure.notConnected:
            .notSent
        case let refusal as GatewayRPCError:
            // 5035: "backend is retiring; reconnect to continue", before it ran anything. The
            // gateway not confirming it in time (SESSION_OWNER_UNCONFIRMED) may still have queued it.
            if refusal.code == 5035 { .notSent }
            else if SendRefusal(refusal)?.action == .checkTheChat { .mayHaveArrived }
            else { .refused }
        case is CancellationError:
            .refused
        default:
            .mayHaveArrived
        }
    }

    /// A `POST /v1/runs` (with its `Idempotency-Key`) or the session it needs (under an id chosen
    /// here, `WaitingChat.requestedID`): a timeout, an unreachable gateway, a 5xx or a 429 goes
    /// again; any other answer is Hermes refusing it.
    public static func overHTTP(_ error: any Error) -> SendFailure {
        switch error {
        case is CancellationError:
            return .refused
        case let error as HermesError:
            switch error {
            // A setting on this device, or a certificate: the person fixes it, waiting won't.
            case .unreachable(_, .localNetworkDenied), .unreachable(_, .mobileDataOff), .unreachable(_, .wifiOff),
                 .unreachable(_, .tls), .unreachable(_, .insecure):
                return .refused
            case .unreachable, .rateLimited, .gatewayRestarting:
                return .sendAgain
            // The key went with another body: Hermes had the first send.
            case .server(409, "idempotency_key_conflict"?, _):
                return .mayHaveArrived
            case .server(let status, _, _) where status >= 500 || status == 429:
                return .sendAgain
            default:
                return .refused
            }
        case let error as URLError:
            return error.code == .cancelled ? .refused : .sendAgain
        default:
            return .refused
        }
    }

    /// How long to wait before the `attempt`th try (from 1): 1, 2, 4, 8, then every 15 s.
    public static func pause(before attempt: Int) -> Duration {
        .seconds(min(15, 1 << min(max(attempt - 1, 0), 4)))
    }
}
