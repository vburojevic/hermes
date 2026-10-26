import Foundation

/// Why Hermes refused a message (4090 on `prompt.submit`, `data.reason`), in plain words, with
/// the one thing that helps (`docs/chat.md` §4d). Hermes names the reason; the words are its own
/// where they are already plain, and a reason the app doesn't know shows Hermes's own message,
/// never a guess.
///
/// The reasons (hermes-agent `hermes_cli/active_sessions.py`, `tui_gateway/methods_prompt.py`,
/// `tui_gateway/session_lifecycle.py`):
/// - `SESSION_NOT_OWNED`: another Hermes process holds the chat (the registry), or the gateway's
///   own queue has work in it that only the gateway can settle (the ledger).
/// - `SESSION_OWNER_BUSY`: the gateway runs a turn in the chat and couldn't queue this message
///   behind it. Nothing was sent; it goes when that turn ends.
/// - `SESSION_OWNER_UNCONFIRMED`: the gateway didn't confirm it in time. It may be queued there,
///   so it's never sent again by itself.
/// - `MAX_CONCURRENT_SESSIONS`: Hermes's chat limit, only when `max_concurrent_sessions` is set.
/// - `SESSION_COORDINATION_UNAVAILABLE`, or no reason: Hermes couldn't reserve the chat.
public struct SendRefusal: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Another Hermes process answers in this chat: a Bot's one-shot `hermes chat`, a
        /// routine, a terminal or another window.
        case chatHeld(ChatHold?)
        /// The gateway's queue holds work in this chat it couldn't confirm (`outcome-unknown`), or
        /// work no running gateway will finish. Only the gateway settles it.
        case gatewayWorkUnresolved
        /// The gateway runs a turn here and couldn't queue this message behind it. `imageRemoved`:
        /// Hermes dropped the photos staged for it (a photo can't join that queue).
        case ownerBusy(imageRemoved: Bool)
        /// The gateway didn't confirm the message in time: it may already be queued there.
        case ownerUnconfirmed
        /// Hermes runs as many chats at once as it's set to allow (`active` of `limit`).
        case atLimit(active: Int?, limit: Int?)
        /// Hermes couldn't tell who else uses the chat (its registry was unreadable).
        case coordinationUnavailable
        /// A reason this app doesn't know, or none.
        case other
    }

    /// What becomes of the message.
    public enum Action: Sendable, Equatable {
        /// It waits in Up Next and goes by itself once the chat is free.
        case waitsForChat
        /// Hermes may have it: the chat is checked before it could go again, and it's never
        /// retried by itself (`LostPrompt`).
        case checkTheChat
        /// It waits, held, for the person: only the gateway settles what blocks it.
        case settleOnGateway
        /// It comes back to the person with Hermes's words, to send again.
        case tryAgain
    }

    public let reason: Reason
    /// Hermes's own message, whole.
    public let message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    /// A 4090, or nil for any other refusal.
    public init?(_ error: GatewayRPCError) {
        guard error.code == 4090 else { return nil }
        self.init(reason: Self.reason(code: error.refusalReason, message: error.message), message: error.message)
    }

    static func reason(code: String?, message: String) -> Reason {
        switch code {
        case "SESSION_NOT_OWNED":
            // The ledger's refusal says where the work is; the registry's names the process.
            if message.contains("durable queue") { return .gatewayWorkUnresolved }
            return .chatHeld(ChatHold(refusal: message))
        case "SESSION_OWNER_BUSY":
            return .ownerBusy(imageRemoved: message.contains("image cannot join its queue"))
        case "SESSION_OWNER_UNCONFIRMED":
            return .ownerUnconfirmed
        case "MAX_CONCURRENT_SESSIONS":
            let counts = Self.limitCounts(in: message)
            return .atLimit(active: counts?.active, limit: counts?.limit)
        case "SESSION_COORDINATION_UNAVAILABLE":
            return .coordinationUnavailable
        default:
            return .other
        }
    }

    public var action: Action {
        switch reason {
        case .chatHeld, .ownerBusy, .atLimit: .waitsForChat
        case .ownerUnconfirmed: .checkTheChat
        case .gatewayWorkUnresolved: .settleOnGateway
        case .coordinationUnavailable, .other: .tryAgain
        }
    }

    /// What holds the chat while the message waits for it, when the refusal says: a chat another
    /// process holds is told from its stored rows instead (`ChatHold.holder`).
    public var holder: ChatHolder? {
        switch reason {
        case .ownerBusy: .gatewayTurn
        case .atLimit(let active, let limit): .chatLimit(active: active, limit: limit)
        case .gatewayWorkUnresolved: .elsewhere(line)
        default: nil
        }
    }

    /// Retry is offered only where a second copy can't run.
    public var offersRetry: Bool { action == .tryAgain }

    /// The line the person reads.
    public var line: String {
        switch reason {
        case .chatHeld:
            return "Another Hermes process is answering in this chat right now (another Bot's message, or a routine). Your message sends when it's done."
        case .gatewayWorkUnresolved:
            return "The gateway has unfinished work in this chat it couldn't confirm. Open the chat where the gateway runs (Hermes Desktop, or hermes chat --resume) to settle it. Nothing was sent."
        case .ownerBusy(let imageRemoved):
            return imageRemoved
                ? "The gateway is running a turn in this chat and can't queue a photo behind it. Your message sends, with its photo, when that turn ends."
                : "The gateway is running a turn in this chat. Your message sends when that turn ends."
        case .ownerUnconfirmed:
            return "The gateway is running a turn in this chat and didn't confirm your message in time. It may already be queued there: check the chat before sending it again."
        case .atLimit(let active, let limit):
            if let active, let limit {
                return "Hermes is running as many chats at once as it's set to allow (\(active) of \(limit)). Your message sends when one finishes."
            }
            return "Hermes is running as many chats at once as it's set to allow. Your message sends when one finishes."
        case .coordinationUnavailable, .other:
            return Self.firstLine(of: message) ?? "Hermes refused this message."
        }
    }

    /// "… the active session limit (3/3) …" → (3, 3).
    static func limitCounts(in message: String) -> (active: Int, limit: Int)? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = Self.counts.firstMatch(in: message, range: range),
              let active = Range(match.range(at: 1), in: message).flatMap({ Int(message[$0]) }),
              let limit = Range(match.range(at: 2), in: message).flatMap({ Int(message[$0]) }) else { return nil }
        return (active, limit)
    }

    private static let counts = try! NSRegularExpression(pattern: #"\((\d+)/(\d+)\)"#)

    /// Hermes puts the person's sentence first and details for logs after (`Details: …`).
    static func firstLine(of message: String) -> String? {
        message.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
