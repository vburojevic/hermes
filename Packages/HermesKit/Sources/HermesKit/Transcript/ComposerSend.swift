import Foundation

/// What the composer's Send does with what's in the field, from the chat's turn flags
/// (`docs/chat.md` §4b). The composer is never dead: whenever there's something to send, one of
/// these takes it, and the button says which. A turn that's open but can't take a note (it runs
/// elsewhere, it's finishing, it's stopping, or the app lost track of its end) queues the message
/// for when it ends, rather than greying Send out.
public enum ComposerSend: Equatable, Sendable {
    /// Nothing runs: a new turn.
    case send
    /// A live turn takes it now, the way the mode chip says (Steer by default).
    case steer
    /// A turn is open and can't take it: it waits in Up Next and goes when the turn ends.
    case queue
    /// The field is empty and nothing runs: Send sends the first message waiting in Up Next.
    case sendQueued
    /// A note to the helper the composer is writing to (`subagent.steer`), not to Hermes.
    case steerHelper

    /// What the chat looks like to Send.
    public struct State: Equatable, Sendable {
        /// Text, attachments, files or skills in the field.
        public var hasContent: Bool
        /// A message in Up Next that a Send may send (not held for one, not being edited).
        public var hasQueued: Bool
        /// A turn streams here (`live` and not finished).
        public var isWorking: Bool
        /// Stop was pressed and the turn hasn't ended yet.
        public var isStopping: Bool
        /// The turn ended and its stored rows are being read.
        public var isFinishing: Bool
        /// A turn is open on the gateway (ours, or one started elsewhere) and hasn't settled.
        public var isTurnOpen: Bool
        /// The composer writes to a helper that can still read notes.
        public var steersHelper: Bool
        /// The gateway or API server is there to send to now.
        public var isReachable: Bool

        public init(hasContent: Bool, hasQueued: Bool = false, isWorking: Bool = false, isStopping: Bool = false,
                    isFinishing: Bool = false, isTurnOpen: Bool = false, steersHelper: Bool = false, isReachable: Bool = true) {
            self.hasContent = hasContent
            self.hasQueued = hasQueued
            self.isWorking = isWorking
            self.isStopping = isStopping
            self.isFinishing = isFinishing
            self.isTurnOpen = isTurnOpen
            self.steersHelper = steersHelper
            self.isReachable = isReachable
        }

        /// A turn holds the chat: a new one can't start until it ends.
        public var isBusy: Bool { isWorking || isFinishing || isTurnOpen }
    }

    /// What Send does now, or `nil` when there's nothing for it (the trailing button is Stop or
    /// Talk then).
    public static func decide(_ state: State) -> ComposerSend? {
        guard state.hasContent else {
            // An empty field sends the first queued message, once nothing holds the chat. Up Next
            // drains by itself when the turn ends; the stuck-turn check makes sure it does.
            return state.hasQueued && !state.isBusy && state.isReachable ? .sendQueued : nil
        }
        if state.steersHelper { return .steerHelper }
        if state.isWorking, !state.isStopping { return .steer }
        return state.isBusy ? .queue : .send
    }
}
