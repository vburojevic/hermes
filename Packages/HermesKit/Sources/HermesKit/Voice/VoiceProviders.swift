import Foundation

/// What Hermes's voice providers need (`docs/voice.md` §6.1), from its own source
/// (`tools/tts_tool*.py`, `tools/transcription_tools.py`): the key each one reads, so the app can
/// say which is missing without ever seeing a key.
public enum VoiceProviders {
    public struct Provider: Hashable, Sendable {
        public let id: String
        public let title: String
        /// The env keys any one of which the provider takes; empty when it needs none.
        public let keys: [String]
    }

    public static let speech: [Provider] = [
        Provider(id: "edge", title: "Edge", keys: []),
        Provider(id: "openai", title: "OpenAI", keys: ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"]),
        Provider(id: "elevenlabs", title: "ElevenLabs", keys: ["ELEVENLABS_API_KEY"]),
        Provider(id: "gemini", title: "Gemini", keys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]),
        Provider(id: "xai", title: "xAI", keys: ["XAI_API_KEY"]),
        Provider(id: "minimax", title: "MiniMax", keys: ["MINIMAX_API_KEY"]),
        Provider(id: "mistral", title: "Mistral", keys: ["MISTRAL_API_KEY"]),
        Provider(id: "deepinfra", title: "DeepInfra", keys: ["DEEPINFRA_API_KEY"]),
        Provider(id: "neutts", title: "NeuTTS", keys: []),
        Provider(id: "kittentts", title: "KittenTTS", keys: []),
        Provider(id: "piper", title: "Piper", keys: []),
    ]

    public static let transcription: [Provider] = [
        Provider(id: "local", title: "Whisper", keys: []),
        Provider(id: "local_command", title: String(localized: "A local command"), keys: []),
        Provider(id: "openai", title: "OpenAI", keys: ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"]),
        Provider(id: "groq", title: "Groq", keys: ["GROQ_API_KEY"]),
        Provider(id: "mistral", title: "Mistral", keys: ["MISTRAL_API_KEY"]),
        Provider(id: "xai", title: "xAI", keys: ["XAI_API_KEY"]),
        Provider(id: "elevenlabs", title: "ElevenLabs", keys: ["ELEVENLABS_API_KEY"]),
    ]

    /// Realtime (GPT-Live) uses `voice.gpt_live.api_key`, else OpenAI's key.
    public static let realtimeKeys = ["OPENAI_API_KEY"]

    /// The providers that transcribe as you speak (`transcribe-stream`; Hermes's
    /// `STREAMING_PROVIDERS`), with `stt.streaming: true`. All three are paid.
    public static let liveTranscription: Set<String> = ["openai", "xai", "elevenlabs"]

    public static func speech(_ id: String) -> Provider {
        speech.first { $0.id == id } ?? Provider(id: id, title: id, keys: [])
    }

    public static func transcription(_ id: String) -> Provider {
        transcription.first { $0.id == id } ?? Provider(id: id, title: id, keys: [])
    }
}

/// What a gateway profile has for voice, read from `/api/config`, `/api/env`, voice-config and
/// voice-live status. Nothing in it is secret: keys are only "set" or not.
public struct VoiceFacts: Sendable, Equatable {
    public var speechProvider: String
    public var speechVoice: String?
    public var transcriptionProvider: String
    public var realtimeVoice: String
    /// Env keys the profile has set (`/api/env` `is_set`).
    public var keysSet: Set<String>
    /// Realtime is offered, and if not, why (Hermes's own sentence).
    public var realtimeAvailable: Bool
    public var realtimeReason: String?
    /// The last time a reply couldn't be spoken in the gateway's voice, in a sentence.
    public var lastSpeechFailure: String?
    /// The person chose Transcribe on: The gateway for Talk (a setting on this device).
    public var wantsLiveTranscription: Bool
    /// `stt.streaming` in the profile's config.
    public var liveTranscriptionOn: Bool
    /// The gateway says it can transcribe as you speak (voice-config `stt.streaming`).
    public var liveTranscriptionAvailable: Bool
    /// The last time the gateway couldn't transcribe a call, in a sentence.
    public var lastTranscriptionFailure: String?
    /// The person turned Hey Hermes on (a setting on this device).
    public var wantsWake: Bool = false
    /// The gateway's wake word (`wake.status`), when it answered.
    public var wake: WakeState?
    /// Why this device isn't listening now ("Listens while this iPhone is charging…").
    public var wakePause: String?

    public init(speechProvider: String = "edge", speechVoice: String? = nil, transcriptionProvider: String = "local",
                realtimeVoice: String = "marin", keysSet: Set<String> = [], realtimeAvailable: Bool = false,
                realtimeReason: String? = nil, lastSpeechFailure: String? = nil, wantsLiveTranscription: Bool = false,
                liveTranscriptionOn: Bool = false, liveTranscriptionAvailable: Bool = false, lastTranscriptionFailure: String? = nil) {
        self.speechProvider = speechProvider
        self.speechVoice = speechVoice
        self.transcriptionProvider = transcriptionProvider
        self.realtimeVoice = realtimeVoice
        self.keysSet = keysSet
        self.realtimeAvailable = realtimeAvailable
        self.realtimeReason = realtimeReason
        self.lastSpeechFailure = lastSpeechFailure
        self.wantsLiveTranscription = wantsLiveTranscription
        self.liveTranscriptionOn = liveTranscriptionOn
        self.liveTranscriptionAvailable = liveTranscriptionAvailable
        self.lastTranscriptionFailure = lastTranscriptionFailure
    }

    /// The key the speech provider is missing, if it needs one and has none.
    public var missingSpeechKey: String? {
        let keys = VoiceProviders.speech(speechProvider).keys
        return keys.isEmpty || keys.contains(where: keysSet.contains) ? nil : keys.last
    }

    public var missingTranscriptionKey: String? {
        let keys = VoiceProviders.transcription(transcriptionProvider).keys
        return keys.isEmpty || keys.contains(where: keysSet.contains) ? nil : keys.last
    }

    /// The gateway can speak replies: its provider has what it needs and hasn't just failed.
    public var gatewaySpeaks: Bool { missingSpeechKey == nil && lastSpeechFailure == nil }

    /// Talk's words come from the gateway: it says it can and hasn't just failed.
    public var gatewayTranscribes: Bool { liveTranscriptionAvailable && lastTranscriptionFailure == nil }
}
