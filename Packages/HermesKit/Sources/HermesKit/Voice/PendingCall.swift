import Foundation

/// A call asked for from outside the app (Shortcuts, Control Center, Hey Hermes) that can't start
/// yet (`docs/voice.md` §4.4): what it calls, since when, and what it waits for.
///
/// It starts by itself only within `timeLimit`. A call that begins a minute or more after it was
/// asked for opens the microphone when nobody expects it, so once the limit passes the wait ends
/// for good and only Try Again (a new request) can start it.
public struct PendingCall: Equatable, Sendable, Identifiable {
    /// Long enough for Bot Mode to reconnect after a short drop (the socket retries within
    /// seconds, and its backoff tops out well under this), short enough that the person who asked
    /// is still holding the phone.
    public static let timeLimit: TimeInterval = 60

    public enum Callee: Equatable, Sendable {
        case hermes
        case bot(String)

        /// Hey Hermes and the intents name Hermes as no Bot.
        public init(botName: String?) {
            self = botName.map(Callee.bot) ?? .hermes
        }

        public var botName: String? {
            if case .bot(let name) = self { name } else { nil }
        }
    }

    /// What the app knows right now about where the call would go.
    public struct Facts: Equatable, Sendable {
        public enum BotMode: Equatable, Sendable {
            /// This gateway has no Bot Mode (no backend linked).
            case notSetUp
            /// Linked, but its socket isn't up yet (starting, reconnecting, unreachable).
            case connecting
            case connected
        }

        public var hasGateway: Bool
        public var botMode: BotMode
        /// For a Bot: whether the connected roster has it. `nil` while its Bots haven't loaded.
        public var hasBot: Bool?

        public init(hasGateway: Bool, botMode: BotMode, hasBot: Bool? = nil) {
            self.hasGateway = hasGateway
            self.botMode = botMode
            self.hasBot = hasBot
        }

        /// Before the app has looked (a cold launch from a Shortcut): wait rather than refuse.
        public static let unknown = Facts(hasGateway: true, botMode: .connecting)
    }

    public enum Reason: Equatable, Sendable {
        case noGateway
        /// A Bot was asked for on a gateway without Bot Mode.
        case botModeNotSetUp
        /// Bot Mode is connected and has no Bot with that name.
        case noSuchBot
    }

    public enum State: Equatable, Sendable {
        case waitingForBotMode
        case ready
        /// The limit passed before it could start. Never starts by itself after this.
        case timedOut
        case cantStart(Reason)

        /// Nothing more will happen without the person.
        public var isSettled: Bool {
            switch self {
            case .timedOut, .cantStart: true
            case .waitingForBotMode, .ready: false
            }
        }
    }

    public let id: UUID
    public let callee: Callee
    public let since: Date
    public private(set) var state: State

    public init(callee: Callee, since: Date, id: UUID = UUID()) {
        self.id = id
        self.callee = callee
        self.since = since
        self.state = .waitingForBotMode
    }

    public var deadline: Date { since.addingTimeInterval(Self.timeLimit) }

    /// Reads the facts at `now`. A settled call stays as it is: a Bot Mode that connects after the
    /// limit, or a roster that changes after a refusal, never starts it.
    public mutating func update(_ facts: Facts, now: Date) {
        guard !state.isSettled else { return }
        state = Self.state(callee, facts)
        // Also when the facts turn ready only now, read late (the app was suspended past it).
        if !state.isSettled, now >= deadline { state = .timedOut }
    }

    private static func state(_ callee: Callee, _ facts: Facts) -> State {
        guard facts.hasGateway else { return .cantStart(.noGateway) }
        switch (callee, facts.botMode) {
        case (.hermes, .notSetUp):
            // Talk with Hermes works without Bot Mode.
            return .ready
        case (.bot, .notSetUp):
            return .cantStart(.botModeNotSetUp)
        case (_, .connecting):
            return .waitingForBotMode
        case (.hermes, .connected):
            return .ready
        case (.bot, .connected):
            switch facts.hasBot {
            case nil: return .waitingForBotMode
            case true?: return .ready
            case false?: return .cantStart(.noSuchBot)
            }
        }
    }
}

/// The one call waiting to start. A new request replaces the old one (its limit starts again);
/// Cancel forgets it.
public struct PendingCallSlot: Equatable, Sendable {
    public private(set) var call: PendingCall?

    public init() {}

    public mutating func request(_ callee: PendingCall.Callee, now: Date, facts: PendingCall.Facts) -> PendingCall.Callee? {
        call = PendingCall(callee: callee, since: now)
        return update(facts, now: now)
    }

    /// Try Again: the same call, a new minute.
    public mutating func retry(now: Date, facts: PendingCall.Facts) -> PendingCall.Callee? {
        guard let call else { return nil }
        return request(call.callee, now: now, facts: facts)
    }

    public mutating func cancel() {
        call = nil
    }

    /// Reads the facts; answers the call to start, once, and lets it go. A call that can't start
    /// stays, settled, so the screen can say why.
    public mutating func update(_ facts: PendingCall.Facts, now: Date) -> PendingCall.Callee? {
        guard var current = call else { return nil }
        current.update(facts, now: now)
        if current.state == .ready {
            call = nil
            return current.callee
        }
        call = current
        return nil
    }
}
