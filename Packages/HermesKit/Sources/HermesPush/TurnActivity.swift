import Foundation

/// A long turn on the Lock Screen and in the Dynamic Island (`docs/notifications.md` §4).
public struct TurnActivityState: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        case working, needsYou, done
    }

    public struct Progress: Codable, Sendable, Hashable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    public var phase: Phase
    /// The latest step ("Listing snapshots older than 30 days").
    public var step: String?
    public var startedAt: Date?
    public var title: String?
    public var progress: Progress?
    /// Needs you: the command waiting for an OK, or the question.
    public var command: String?
    public var question: String?
    public var requestID: String?
    public var expiresAt: Date?
    /// Done: the result line, and whether it succeeded.
    public var result: String?
    public var ok: Bool?
    public var endedAt: Date?
    public var gateway: String?
    /// How the app answers the approval it's waiting on.
    public var answer: PushNotice.Answer?

    public init(
        phase: Phase, step: String? = nil, startedAt: Date? = nil, title: String? = nil, progress: Progress? = nil,
        command: String? = nil, question: String? = nil, requestID: String? = nil, expiresAt: Date? = nil,
        result: String? = nil, ok: Bool? = nil, gateway: String? = nil
    ) {
        self.phase = phase
        self.step = step
        self.startedAt = startedAt
        self.title = title
        self.progress = progress
        self.command = command
        self.question = question
        self.requestID = requestID
        self.expiresAt = expiresAt
        self.result = result
        self.ok = ok
        self.gateway = gateway
    }

    enum CodingKeys: String, CodingKey {
        case phase, step, title, progress, command, question, result, ok, gateway
        case answer
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case requestID = "request_id"
        case expiresAt = "expires_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date? {
            try c.decodeIfPresent(Double.self, forKey: key).map { Date(timeIntervalSince1970: $0) }
        }
        phase = (try? c.decodeIfPresent(Phase.self, forKey: .phase)) ?? .working
        step = try c.decodeIfPresent(String.self, forKey: .step)
        startedAt = try date(.startedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        progress = try? c.decodeIfPresent(Progress.self, forKey: .progress)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        expiresAt = try date(.expiresAt)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        endedAt = try date(.endedAt)
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        answer = try? c.decodeIfPresent(PushNotice.Answer.self, forKey: .answer)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(progress, forKey: .progress)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(question, forKey: .question)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(ok, forKey: .ok)
        try c.encodeIfPresent(endedAt?.timeIntervalSince1970, forKey: .endedAt)
        try c.encodeIfPresent(gateway, forKey: .gateway)
        try c.encodeIfPresent(answer, forKey: .answer)
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// One activity per gateway; the newest running turn wins.
public struct TurnActivityAttributes: ActivityAttributes {
    /// What the plugin pushes (`notices.activity_request`): only the phase in the clear, the rest
    /// sealed for this device. Updates the app makes itself carry `local` instead.
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: TurnActivityState.Phase
        public var sealed: PushEnvelope?
        public var local: TurnActivityState?

        public init(phase: TurnActivityState.Phase, sealed: PushEnvelope? = nil, local: TurnActivityState? = nil) {
            self.phase = phase
            self.sealed = sealed
            self.local = local
        }

        public init(_ state: TurnActivityState) {
            self.init(phase: state.phase, local: state)
        }

        /// The readable state: local, or opened with the device key.
        public func state(key: PushDeviceKey?) -> TurnActivityState {
            if let local { return local }
            if let sealed, let key, let opened = try? key.open(TurnActivityState.self, from: sealed) { return opened }
            return TurnActivityState(phase: phase)
        }
    }

    /// The app's id for the gateway.
    public var gatewayID: UUID
    public var gatewayName: String
    /// The chat's stored session id.
    public var sessionID: String
    public var chatTitle: String
    /// The Bot, in a Bot Chat.
    public var bot: String?

    public init(gatewayID: UUID, gatewayName: String, sessionID: String, chatTitle: String, bot: String? = nil) {
        self.gatewayID = gatewayID
        self.gatewayName = gatewayName
        self.sessionID = sessionID
        self.chatTitle = chatTitle
        self.bot = bot
    }
}
#endif
