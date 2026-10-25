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
        /// The provider sign-in that works in place of a key (`GET /api/providers/oauth` id):
        /// xAI's speech and transcription fall back to the xAI Grok sign-in
        /// (`resolve_xai_http_credentials`).
        public let signIn: String?

        public init(id: String, title: String, keys: [String], signIn: String? = nil) {
            self.id = id
            self.title = title
            self.keys = keys
            self.signIn = signIn
        }
    }

    /// The xAI Grok sign-in (`hermes model` → xAI Grok OAuth).
    public static let xaiSignIn = "xai-oauth"

    public static let speech: [Provider] = [
        Provider(id: "edge", title: "Edge", keys: []),
        Provider(id: "openai", title: "OpenAI", keys: ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"]),
        Provider(id: "elevenlabs", title: "ElevenLabs", keys: ["ELEVENLABS_API_KEY"]),
        Provider(id: "gemini", title: "Gemini", keys: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]),
        Provider(id: "xai", title: "xAI", keys: ["XAI_API_KEY"], signIn: xaiSignIn),
        // The China region's key counts too (`_resolve_minimax_tts_runtime`).
        Provider(id: "minimax", title: "MiniMax", keys: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY"]),
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
        Provider(id: "xai", title: "xAI", keys: ["XAI_API_KEY"], signIn: xaiSignIn),
        Provider(id: "elevenlabs", title: "ElevenLabs", keys: ["ELEVENLABS_API_KEY"]),
    ]

    /// Realtime (GPT-Live) uses `voice.gpt_live.api_key`, else OpenAI's key.
    public static let realtimeKeys = ["OPENAI_API_KEY"]

    /// The providers that transcribe as you speak (`transcribe-stream`; Hermes's
    /// `STREAMING_PROVIDERS`), with `stt.streaming: true`. All three are paid, and need a key of
    /// their own: never a sign-in (`transcription_streaming._builtin_session`: xAI is "API key
    /// only").
    public static let liveTranscription: Set<String> = ["openai", "xai", "elevenlabs"]

    /// Providers voice-config can hand out a key for that Hermes manages (OpenAI through a Nous
    /// subscription), which can't transcribe as you speak: their direct verdict proves only that
    /// the gateway transcribes whole recordings.
    static let managedDirect: Set<String> = ["openai"]

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
    /// Provider sign-ins the gateway has (`GET /api/providers/oauth`, `status.logged_in`), by id.
    public var signedIn: Set<String> = []
    /// What voice-config says the gateway does for speech and transcription (`tts`, `stt`).
    public var speechVerdict: VoiceVerdict?
    public var transcriptionVerdict: VoiceVerdict?
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

    /// The key the speech provider is missing, if it needs one and has nothing in its place: a
    /// key, the gateway handing out its settings (a direct verdict, which Hermes gives only with
    /// credentials, its own managed ones included) or a sign-in that works for it.
    public var missingSpeechKey: String? {
        missingKey(VoiceProviders.speech(speechProvider), verdict: speechVerdict)
    }

    /// The key transcribing a whole recording on the gateway is missing (voice messages).
    public var missingTranscriptionKey: String? {
        missingKey(VoiceProviders.transcription(transcriptionProvider), verdict: transcriptionVerdict)
    }

    /// The key transcribing as you speak is missing (Talk with Transcribe on: The gateway): a
    /// sign-in never does, and nor does a managed key.
    public var missingLiveTranscriptionKey: String? {
        let provider = VoiceProviders.transcription(transcriptionProvider)
        let verdict = transcriptionVerdict.flatMap { VoiceProviders.managedDirect.contains(provider.id) ? nil : $0 }
        return missingKey(VoiceProviders.Provider(id: provider.id, title: provider.title, keys: provider.keys), verdict: verdict)
    }

    /// The gateway works through a sign-in where the provider would otherwise want a key: xAI
    /// through xAI Grok, with no `XAI_API_KEY`.
    public var transcriptionUsesSignIn: Bool {
        missingTranscriptionKey == nil && missingLiveTranscriptionKey != nil
            && VoiceProviders.transcription(transcriptionProvider).signIn.map(signedIn.contains) == true
    }

    private func missingKey(_ provider: VoiceProviders.Provider, verdict: VoiceVerdict?) -> String? {
        let keys = provider.keys
        if keys.isEmpty || keys.contains(where: keysSet.contains) { return nil }
        if let verdict, verdict.isDirect, verdict.provider == nil || verdict.provider == provider.id { return nil }
        if let signIn = provider.signIn, signedIn.contains(signIn) { return nil }
        return keys.last
    }

    /// The gateway can speak replies: its provider has what it needs and hasn't just failed.
    public var gatewaySpeaks: Bool { missingSpeechKey == nil && lastSpeechFailure == nil }

    /// Talk's words come from the gateway: it says it can and hasn't just failed.
    public var gatewayTranscribes: Bool { liveTranscriptionAvailable && lastTranscriptionFailure == nil }
}

/// What voice-config says the gateway does for one side, with nothing secret in it: `direct`
/// (it hands out the provider's settings, so it has credentials) or `relay` (it speaks or
/// transcribes itself through `/api/audio/*`), and why.
public struct VoiceVerdict: Sendable, Equatable {
    public var mode: String
    public var provider: String?
    /// Why it relays ("no credentials", "xai oauth (server-managed) or no credentials").
    public var reason: String?

    public init(mode: String, provider: String? = nil, reason: String? = nil) {
        self.mode = mode
        self.provider = provider
        self.reason = reason
    }

    public var isDirect: Bool { mode == "direct" }
}
