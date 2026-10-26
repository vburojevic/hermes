import Foundation

/// Up Next, the app's own queue of messages that go as turns of their own (`docs/follow-ups.md`):
/// whether a message goes now or waits there, and why one is there (`docs/chat.md` §4c).
public enum UpNext {
    /// Whether a message sent as a turn of its own (Send, Send Again, Talk, Try Again, Send as
    /// Message) goes now. It waits behind a running turn, a chat Hermes refused because something
    /// else holds it, and messages already waiting their turn, so it never jumps the line. A queue
    /// Stop paused waits for the person's Send, so a new message doesn't wait behind it.
    public static func goesNow(turnRunning: Bool, waitsForChat: Bool, othersWaiting: Bool, queuePaused: Bool) -> Bool {
        if turnRunning || waitsForChat { return false }
        return !othersWaiting || queuePaused
    }

    /// What Up Next waits on before it sends by itself.
    public struct Chat: Sendable, Equatable {
        /// A turn runs, finishes or is open here.
        public var turnHoldsChat: Bool
        /// The gateway or API server is there to send to.
        public var reachable: Bool
        /// Stop paused the queue: it waits for a Send.
        public var paused: Bool
        /// Hermes refused a message because something else holds the chat (`waitForChat`).
        public var waitsForChat: Bool
        /// The gateway is about to send what it holds as the next turn (a carried-over steer, its
        /// queue's head): that goes first.
        public var expectsGatewayTurn: Bool
        /// A message typed before the chat loaded goes first, once it has.
        public var sendsOnLoad: Bool
        /// The person has opened the chat since the app launched. A chat the app only loaded in
        /// the background (one kept from before a relaunch) sends nothing by itself: nothing goes
        /// out from a chat the person hasn't looked at. A turn's end here counts as looked at.
        public var opened: Bool

        public init(turnHoldsChat: Bool, reachable: Bool, paused: Bool = false, waitsForChat: Bool = false,
                    expectsGatewayTurn: Bool = false, sendsOnLoad: Bool = false, opened: Bool = true) {
            self.turnHoldsChat = turnHoldsChat
            self.reachable = reachable
            self.paused = paused
            self.waitsForChat = waitsForChat
            self.expectsGatewayTurn = expectsGatewayTurn
            self.sendsOnLoad = sendsOnLoad
            self.opened = opened
        }

        /// Nothing holds the chat: what waits in Up Next may go.
        public var isFree: Bool {
            opened && !turnHoldsChat && reachable && !paused && !waitsForChat && !expectsGatewayTurn && !sendsOnLoad
        }
    }

    /// The message Up Next sends by itself now, if any (`docs/follow-ups.md` §4): the first one that
    /// doesn't wait for a Send, once nothing holds the chat. The app asks whenever the chat becomes
    /// idle and reachable (a turn's end, a load after a relaunch, an idle reconnect, a turn recovered
    /// as idle, a hold that cleared), and sending it starts a turn, so one goes at a time, in order.
    /// Not sent and Maybe sent messages go only with the person's Send.
    public static func next<Item>(in queue: [Item], chat: Chat, isHeld: (Item) -> Bool) -> Item? {
        guard chat.isFree else { return nil }
        return queue.first { !isHeld($0) }
    }
}

/// Why a message is in Up Next when it wasn't sent there, for its row (`docs/follow-ups.md` §4).
public enum UpNextNote: Sendable, Equatable {
    /// It couldn't go the way it was sent (a steer the turn couldn't take, Ask Aside or Run in
    /// Background with no live chat to do it): it goes as the next message instead.
    case sendsNextInstead(SendsNextReason)
    /// Stop emptied the gateway's queue with the turn: it never ran, and waits for a Send.
    case clearedByStop
    /// Hermes refused it; it waits for what the refusal says (`SendRefusal.action`).
    case refused(SendRefusal)
    /// Kept from before a relaunch, or shown by the chat after a missed turn end: Hermes may
    /// already have it (in another form: mentions, files, skills), so it waits for the person.
    case mayHaveArrived

    /// Went as the next message instead of the way it was sent.
    public var sendsNext: Bool {
        if case .sendsNextInstead = self { true } else { false }
    }

    /// The row's second line, or nil when the tray already says it (a refusal the queue waits
    /// out is the tray's hold note).
    public func line(gateway: String) -> String? {
        switch self {
        case .sendsNextInstead(let reason):
            return reason.line(gateway: gateway)
        case .clearedByStop:
            return "Stop cleared it from \(gateway)'s queue before it ran"
        case .mayHaveArrived:
            return "Hermes may already have this. Check the chat before you send it."
        case .refused(let refusal):
            switch refusal.action {
            case .waitsForChat: return nil // the tray's hold note says it
            case .settleOnGateway: return "Not sent: only the gateway can settle this chat"
            case .checkTheChat, .tryAgain: return refusal.line
            }
        }
    }

    /// Kept with the queue on the device, so a held row still says why after a relaunch. A
    /// refusal isn't kept: the next send asks Hermes again.
    public var storedKey: String? {
        switch self {
        case .sendsNextInstead(let reason): "next.\(reason.rawValue)"
        case .clearedByStop: "cleared"
        case .mayHaveArrived: "maybe"
        case .refused: nil
        }
    }

    public init?(storedKey: String?) {
        switch storedKey {
        case "cleared": self = .clearedByStop
        case "maybe": self = .mayHaveArrived
        case let key? where key.hasPrefix("next."):
            guard let reason = SendsNextReason(rawValue: String(key.dropFirst(5))) else { return nil }
            self = .sendsNextInstead(reason)
        default: return nil
        }
    }
}

/// Why a message goes as the next message instead of the way it was sent.
public enum SendsNextReason: String, Sendable, Equatable {
    /// The turn ended before Hermes read the steer (`rejected`), or it was stopped.
    case turnEnded
    /// The turn's agent was still being built (4010 "agent does not support steer").
    case turnStarting
    /// The turn waits on the person's approval (409 `run_not_accepting_steer` over the API
    /// server).
    case waitsOnApproval
    /// The API server hasn't started the run yet: it waits behind another turn (409
    /// `run_not_accepting_steer`).
    case runQueued
    /// The running turn couldn't take it, for a reason Hermes didn't give (409 while the turn
    /// still runs).
    case turnBusy
    /// The chat never came back while the steer waited for it.
    case notBack
    /// Ask Aside with no live chat to ask beside.
    case noAside
    /// Run in Background where nothing runs beside the chat (the API server).
    case noBackground

    func line(gateway: String) -> String {
        switch self {
        case .turnEnded: "Hermes finished before reading it, so it sends next"
        case .turnStarting: "Hermes was still starting the reply, so it sends next"
        case .waitsOnApproval: "Hermes is waiting for your approval, so it sends next"
        case .runQueued: "Hermes hasn't started this reply yet, so it sends next"
        case .turnBusy: "Hermes couldn't take it into this reply, so it sends next"
        case .notBack: "Couldn't reach \(gateway) in time, so it sends next"
        case .noAside: "Ask Aside needs a live chat, so it sends next"
        case .noBackground: "Run in Background isn't available here, so it sends next"
        }
    }

    /// Why a steer the turn couldn't take fell back, from what refused it first, then from the
    /// turn's state. Never "finished" for a turn that still runs, unless Hermes said it isn't
    /// running (`rejected`).
    /// - Parameters:
    ///   - error: what the steer failed with; nil when Hermes answered `rejected`, or it never went.
    ///   - turnRunning: the turn was still running here when the answer came.
    ///   - waitingForApproval: the turn was waiting on the person's approval.
    ///   - runQueued: the API server holds the run behind another turn (`runWaitsInQueue`).
    ///   - attached: the chat was attached (it had a live session or run to steer).
    public static func steer(error: (any Error)?, turnRunning: Bool, waitingForApproval: Bool, runQueued: Bool = false,
                             attached: Bool) -> SendsNextReason {
        if let rpc = error as? GatewayRPCError, rpc.code == 4010 { return .turnStarting }
        if case GatewaySocket.Failure.notConnected? = error { return .notBack }
        if case .server(409, _, _)? = error as? HermesError {
            // `run_not_accepting_steer` doesn't say why (hermes-agent `api_server_runs.py`).
            if waitingForApproval { return .waitsOnApproval }
            if runQueued { return .runQueued }
            return turnRunning ? .turnBusy : .turnEnded
        }
        if !turnRunning { return .turnEnded }
        if !attached { return .notBack }
        // Hermes answered `rejected`: its session isn't running, though this device hasn't heard the end yet.
        if error == nil { return .turnEnded }
        return waitingForApproval ? .waitsOnApproval : .turnBusy
    }
}

/// What the Up Next tray says it waits for, in its header (`docs/follow-ups.md` §4).
public enum UpNextWait: Sendable, Equatable {
    /// A queued message is being edited: just "Up next".
    case editing
    /// Something else holds the chat (another process, the gateway's turn, the chat limit): the
    /// tray says what, from `ChatHolder`.
    case chat
    /// The gateway's own queue holds the next message, behind its own turn.
    case gatewayTurn
    /// A turn runs here: "sends when this reply is done".
    case reply
    /// The gateway can't be reached: "sends when <gateway> is back".
    case gatewayAway
    /// Every message waits for the person's Send (Not sent, Maybe sent).
    case yourSend
    /// Nothing runs: Send with an empty field sends the first (after Stop, or a queue that didn't
    /// go by itself).
    case sendSendsFirst

    /// - Parameters:
    ///   - turnHoldsChat: a turn runs, finishes or stops here, or is open on the gateway.
    ///   - heldOnGateway: the gateway's own queue holds messages and nothing runs here.
    ///   - allHeld: every message in the app's queue waits for a Send.
    public static func of(isEditing: Bool, waitsForChat: Bool, turnHoldsChat: Bool, reachable: Bool,
                          heldOnGateway: Bool, allHeld: Bool) -> UpNextWait {
        if isEditing { return .editing }
        if waitsForChat { return .chat }
        if allHeld { return turnHoldsChat ? .yourSend : .sendSendsFirst }
        if !reachable { return .gatewayAway }
        if turnHoldsChat { return .reply }
        if heldOnGateway { return .gatewayTurn }
        return .sendSendsFirst
    }
}

/// What else a Stop ended, beyond the turn, for its receipt (`docs/follow-ups.md` §4). Hermes's
/// `session.interrupt` also ends the chat's running helpers and declines the approval the turn
/// waited on (hermes-agent `tui_gateway/session_lifecycle.py`); background processes keep running,
/// and what its queue held comes back in Up Next, which says so itself.
public enum StopReceipt {
    public static func line(helpersStopped: Int, approvalDeclined: Bool) -> String? {
        let helpers = helpersStopped == 1 ? "1 helper" : "\(helpersStopped) helpers"
        switch (helpersStopped > 0, approvalDeclined) {
        case (true, true): return "Stop also stopped \(helpers) and declined the approval Hermes was waiting on."
        case (true, false): return "Stop also stopped \(helpers)."
        case (false, true): return "Stop also declined the approval Hermes was waiting on."
        case (false, false): return nil
        }
    }
}
