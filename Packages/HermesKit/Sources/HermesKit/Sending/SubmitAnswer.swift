import Foundation

/// What Hermes did with a message, from `prompt.submit`'s answer (`docs/chat.md` §4c). Only this
/// says whether the message started a turn of its own: a chat can be busy with a turn the app
/// hasn't seen yet (a finished process's notice, a held message Hermes sends as a turn ends, another
/// device), and then Hermes queues the message, or steers or redirects that turn with it.
///
/// hermes-agent: `tui_gateway/methods_prompt.py` (`streaming`, `voice_stopped`, the owner's
/// `queued` + `forwarded`) and `session_auto_continue.py` `_handle_busy_submit` (`queued`,
/// `steered`, `redirected`).
public enum SubmitAnswer: Sendable, Equatable {
    /// The chat was idle: the message started its own turn.
    case started(userRowID: Int?)
    /// Hermes runs a turn in this chat: the message waits in Hermes's queue and goes as the next
    /// turn when that one ends.
    case queuedBehindTurn
    /// The gateway owns the chat (its own queue has work in it): the message waits in the
    /// gateway's queue, and only its turn's start and end reach this socket.
    case queuedOnGateway(admissionID: String?)
    /// Went into the running turn as a steer (a busy chat in `steer` mode).
    case steered
    /// Changed the running turn's course (a busy chat in `interrupt` mode).
    case redirected
    /// A stop phrase typed while voice mode was on: it ended the voice chat and nothing was sent.
    case voiceStopped

    public init(result: JSONValue?) {
        if result?["voice_stopped"]?.boolValue == true {
            self = .voiceStopped
            return
        }
        switch result?["status"]?.stringValue {
        case "queued":
            self = result?["forwarded"]?.boolValue == true
                ? .queuedOnGateway(admissionID: result?["admission_id"]?.stringValue)
                : .queuedBehindTurn
        case "steered":
            self = .steered
        case "redirected":
            self = .redirected
        default:
            // `streaming`, or an older Hermes that said nothing more: the turn is the message's.
            self = .started(userRowID: result?["user_row_id"]?.truncatedIntValue)
        }
    }

    /// The message started a turn of its own: the turn on screen answers it.
    public var startedItsTurn: Bool {
        if case .started = self { true } else { false }
    }

    /// The message waits in a queue (Hermes's or the gateway's), not yet a turn.
    public var isQueued: Bool {
        switch self {
        case .queuedBehindTurn, .queuedOnGateway: true
        default: false
        }
    }
}
