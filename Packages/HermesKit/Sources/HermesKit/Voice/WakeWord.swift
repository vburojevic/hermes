import Foundation

// "Hey Hermes" (`docs/voice.md` §4.6): the gateway's wake word over the backend socket
// (`wake.*`, Hermes's `tui_gateway/methods_voice.py`). The app streams 16 kHz int16 mono to it in
// 80 ms frames (`wake.feed`); `wake.detected` opens Talk. The engines run on the gateway's computer
// and cost nothing per use.

/// `wake.status {surface, client_capture}`: what the gateway's detector is doing.
public struct WakeState: Sendable, Equatable {
    /// An engine and the voice it needs (speech to text, text to speech) are there.
    public var available: Bool
    /// Hermes's sentence when it isn't.
    public var hint: String?
    /// `wake_word.enabled` in the gateway's config.
    public var enabled: Bool
    public var listening: Bool
    /// This connection runs the detector.
    public var ownedByCaller: Bool
    /// Who runs it ("gui", "tui"), when someone does.
    public var ownerSurface: String?
    /// `wake_word.surface` when it names one surface.
    public var configuredSurface: String?
    /// "client": the app streams the microphone; "local": the gateway's own microphone listens.
    public var capture: String?
    public var phrase: String?
    public var sampleRate: Int
    public var frameLength: Int

    public init(available: Bool = true, hint: String? = nil, enabled: Bool = true, listening: Bool = false, ownedByCaller: Bool = false,
                ownerSurface: String? = nil, configuredSurface: String? = nil, capture: String? = "client", phrase: String? = "hey hermes",
                sampleRate: Int = 16_000, frameLength: Int = 1_280) {
        self.available = available
        self.hint = hint
        self.enabled = enabled
        self.listening = listening
        self.ownedByCaller = ownedByCaller
        self.ownerSurface = ownerSurface
        self.configuredSurface = configuredSurface
        self.capture = capture
        self.phrase = phrase
        self.sampleRate = sampleRate
        self.frameLength = frameLength
    }

    public init(status json: JSONValue) {
        available = json["available"]?.boolValue ?? false
        hint = json["hint"]?.stringValue
        enabled = json["enabled"]?.boolValue ?? false
        listening = json["listening"]?.boolValue ?? false
        ownedByCaller = json["owned_by_caller"]?.boolValue ?? false
        ownerSurface = json["owner_surface"]?.stringValue
        configuredSurface = json["configured_surface"]?.stringValue
        capture = json["capture"]?.stringValue
        phrase = json["phrase"]?.stringValue
        sampleRate = json["sample_rate"]?.intValue ?? 16_000
        frameLength = json["frame_length"]?.intValue ?? 1_280
    }

    /// Someone else's detector holds the gateway's (one per machine).
    public var heldElsewhere: Bool { listening && !ownedByCaller }

    /// `wake_word.surface` keeps it to another surface ("tui").
    public var keptForOtherSurface: Bool {
        guard let configuredSurface, !configuredSurface.isEmpty else { return false }
        return !["auto", "gui", "desktop"].contains(configuredSurface)
    }
}

/// `wake.start {surface: "gui", client_capture: true, persist}`'s answer. Refusals aren't errors.
public struct WakeStart: Sendable, Equatable {
    public enum Refusal: Sendable, Equatable {
        /// No engine or no voice on the gateway, with Hermes's hint.
        case unavailable(String?)
        /// `wake_word.enabled` is off (only without `persist`).
        case disabled
        /// `wake_word.surface` names another surface.
        case otherSurface
        /// Another connection runs the detector.
        case owned(String?)
        case other(String)
    }

    public var started: Bool
    public var refusal: Refusal?
    public var capture: String?
    public var phrase: String?
    public var sampleRate: Int
    public var frameLength: Int

    public init(json: JSONValue) {
        started = json["started"]?.boolValue ?? false
        capture = json["capture"]?.stringValue
        phrase = json["phrase"]?.stringValue
        sampleRate = json["sample_rate"]?.intValue ?? 16_000
        frameLength = json["frame_length"]?.intValue ?? 1_280
        guard !started else {
            refusal = nil
            return
        }
        switch json["reason"]?.stringValue {
        case "unavailable": refusal = .unavailable(json["hint"]?.stringValue)
        case "disabled": refusal = .disabled
        case "disabled_for_surface": refusal = .otherSurface
        case "owned": refusal = .owned(json["owner_surface"]?.stringValue)
        case let reason: refusal = .other(reason ?? "not started")
        }
    }

    /// The gateway's own microphone listens: the app sends nothing.
    public var listensLocally: Bool { capture == "local" }
}

/// `wake.detected`: who was called, and whether to start a new chat.
public struct WakeDetection: Sendable, Equatable {
    public var phrase: String
    /// The Bot the phrase names (only some engines tell), else the gateway's own.
    public var profile: String?
    public var startNewSession: Bool

    public init(phrase: String, profile: String? = nil, startNewSession: Bool = true) {
        self.phrase = phrase
        self.profile = profile
        self.startNewSession = startNewSession
    }

    /// From the event's `payload`.
    public init?(payload json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        phrase = json["phrase"]?.stringValue ?? "hey hermes"
        profile = json["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        startNewSession = json["start_new_session"]?.boolValue ?? true
    }
}

/// The microphone's 16 kHz int16 cut into the engine's frames for `wake.feed`, four at a time
/// (320 ms, as Hermes Desktop sends them), far under Hermes's 64,000 bytes a call.
public struct WakeFrames: Sendable {
    public let frameBytes: Int
    public let framesPerCall: Int
    private var pending = Data()

    public init(frameLength: Int = 1_280, framesPerCall: Int = 4) {
        frameBytes = max(2, frameLength * 2)
        self.framesPerCall = max(1, framesPerCall)
    }

    /// What's ready to send: whole batches, oldest first. The rest waits for more audio.
    public mutating func append(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        let batchBytes = frameBytes * framesPerCall
        var batches: [Data] = []
        while pending.count >= batchBytes {
            batches.append(Data(pending.prefix(batchBytes)))
            pending.removeFirst(batchBytes)
        }
        return batches
    }

    public mutating func reset() {
        pending = Data()
    }
}
