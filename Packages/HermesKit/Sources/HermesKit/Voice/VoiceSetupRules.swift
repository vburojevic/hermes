import Foundation

/// Talk, Listen and voice messages as setup statuses (`docs/voice.md` §6.1, `docs/setup.md`):
/// what each uses on this gateway or Bot, what it falls back to and why, and how to set it up.
public enum VoiceSetupRules {
    public static let talkDocs = URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode")!
    public static let speechDocs = URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/tts")!

    /// - Parameters:
    ///   - device: "iPhone", "iPad" or "Mac", for "this iPhone's voice".
    ///   - profile: a Bot's profile, or `nil` for the gateway's own (its ids get "@profile", its
    ///     commands `hermes -p profile`).
    public static func statuses(_ facts: VoiceFacts, device: String, profile: String? = nil) -> [SetupStatus] {
        var statuses = [talk(facts, device: device, profile: profile), listen(facts, device: device, profile: profile),
                        messages(facts, device: device, profile: profile)]
        // Only for someone who chose it: the device transcribes otherwise, and that needs nothing.
        if facts.wantsLiveTranscription { statuses.append(transcription(facts, device: device, profile: profile)) }
        // One detector per gateway: shown with the gateway's own voice, not each Bot's.
        if facts.wantsWake, profile == nil { statuses.append(wake(facts, device: device)) }
        return statuses
    }

    /// What every voice status id starts with.
    public static let prefix = "voice."

    public static func id(_ feature: String, profile: String?) -> String {
        profile.map { "\(prefix)\(feature)@\($0)" } ?? "\(prefix)\(feature)"
    }

    static func command(_ text: String, profile: String?) -> String {
        profile.map { "hermes -p \($0) \(text)" } ?? "hermes \(text)"
    }

    static func speechName(_ facts: VoiceFacts) -> String {
        let provider = VoiceProviders.speech(facts.speechProvider).title
        guard let voice = facts.speechVoice, !voice.isEmpty else { return provider }
        return "\(provider) · \(voice)"
    }

    /// Why the gateway can't speak, in a sentence's second half.
    static func speechProblem(_ facts: VoiceFacts) -> String? {
        if let key = facts.missingSpeechKey {
            return String(localized: "\(VoiceProviders.speech(facts.speechProvider).title) needs \(key) on the gateway")
        }
        return facts.lastSpeechFailure
    }

    static func speechSteps(_ facts: VoiceFacts, profile: String?) -> [SetupStep] {
        var steps: [SetupStep] = []
        if let key = facts.missingSpeechKey {
            steps.append(SetupStep(String(localized: "On the gateway's computer, add the key:"), command: command("config set \(key) <your key>", profile: profile)))
        }
        steps.append(SetupStep(String(localized: "Or use Edge, which needs no key:"), command: command("config set tts.provider edge", profile: profile)))
        return steps
    }

    static func talk(_ facts: VoiceFacts, device: String, profile: String?) -> SetupStatus {
        let id = id("talk", profile: profile)
        let title = String(localized: "Talk")
        let realtimeVoice = facts.realtimeVoice.capitalized
        if facts.realtimeAvailable {
            return SetupStatus(id: id, state: .ready, title: title, detail: String(localized: "Realtime · \(realtimeVoice)"))
        }
        let why = facts.realtimeReason.map { String(localized: "no Realtime here (\($0))") } ?? String(localized: "this gateway has no Realtime")
        var steps = [SetupStep(String(localized: "For Realtime, give the gateway an OpenAI key (Realtime is billed by OpenAI):"),
                               command: command("config set OPENAI_API_KEY <your key>", profile: profile))]
        if let problem = speechProblem(facts) {
            steps += speechSteps(facts, profile: profile)
            return SetupStatus(
                id: id, state: .limited, title: title,
                detail: String(localized: "Hermes Voice, in this \(device)'s voice"),
                fallback: String(localized: "Talk answers in this \(device)'s voice: \(problem), and \(why)."),
                fix: facts.missingSpeechKey == nil ? nil : SetupFix(title: String(localized: "Add Key…")),
                steps: steps, docs: talkDocs
            )
        }
        return SetupStatus(
            id: id, state: .limited, title: title,
            detail: String(localized: "Hermes Voice · \(speechName(facts))"),
            fallback: String(localized: "Talk uses Hermes Voice: \(why). It transcribes on this \(device) and answers in the gateway's voice."),
            fix: SetupFix(title: String(localized: "Add OpenAI Key…")),
            steps: steps, docs: talkDocs
        )
    }

    static func listen(_ facts: VoiceFacts, device: String, profile: String?) -> SetupStatus {
        let id = id("listen", profile: profile)
        let title = String(localized: "Listen")
        guard let problem = speechProblem(facts) else {
            return SetupStatus(id: id, state: .ready, title: title, detail: speechName(facts))
        }
        return SetupStatus(
            id: id, state: .limited, title: title,
            detail: String(localized: "In this \(device)'s voice"),
            fallback: String(localized: "Replies are read in this \(device)'s voice: \(problem)."),
            fix: SetupFix(title: facts.missingSpeechKey == nil ? String(localized: "Choose a Voice…") : String(localized: "Add Key…")),
            steps: speechSteps(facts, profile: profile), docs: speechDocs
        )
    }

    static func messages(_ facts: VoiceFacts, device: String, profile: String?) -> SetupStatus {
        let id = id("messages", profile: profile)
        let title = String(localized: "Voice messages")
        let gateway = VoiceProviders.transcription(facts.transcriptionProvider).title
        guard let key = facts.missingTranscriptionKey else {
            return SetupStatus(id: id, state: .ready, title: title,
                               detail: String(localized: "On this \(device), with \(gateway) on the gateway as a backup"))
        }
        return SetupStatus(
            id: id, state: .limited, title: title,
            detail: String(localized: "Transcribed on this \(device)"),
            fallback: String(localized: "When this \(device) hears no words, the gateway can't transcribe either: \(gateway) needs \(key)."),
            fix: SetupFix(title: String(localized: "Add Key…")),
            steps: [
                SetupStep(String(localized: "On the gateway's computer, add the key:"), command: command("config set \(key) <your key>", profile: profile)),
                SetupStep(String(localized: "Or transcribe on the gateway itself:"), command: command("config set stt.provider local", profile: profile)),
            ],
            docs: speechDocs
        )
    }

    /// Transcribe on: The gateway (`transcribe-stream`): Talk's words from the gateway's provider
    /// as you speak, or the device's when it can't.
    static func transcription(_ facts: VoiceFacts, device: String, profile: String?) -> SetupStatus {
        let id = id("transcription", profile: profile)
        let title = String(localized: "Transcribe on the gateway")
        let provider = VoiceProviders.transcription(facts.transcriptionProvider)
        if facts.gatewayTranscribes {
            return SetupStatus(id: id, state: .ready, title: title, detail: String(localized: "\(provider.title), as you speak"))
        }
        let turnOn = SetupStep(String(localized: "Turn on live transcription:"), command: command("config set stt.streaming true", profile: profile))
        var steps: [SetupStep] = []
        var fix: SetupFix?
        let why: String
        if !VoiceProviders.liveTranscription.contains(facts.transcriptionProvider) {
            why = String(localized: "\(provider.title) can't transcribe as you speak")
            steps = [
                SetupStep(String(localized: "Use a provider that can: OpenAI, xAI or ElevenLabs (they're paid):"),
                          command: command("config set stt.provider openai", profile: profile)),
                SetupStep(String(localized: "Give it its key:"), command: command("config set OPENAI_API_KEY <your key>", profile: profile)),
                turnOn,
            ]
        } else if let key = facts.missingLiveTranscriptionKey {
            // Signed in to xAI Grok: voice messages transcribe on the gateway, a call can't.
            why = facts.transcriptionUsesSignIn
                ? String(localized: "the \(provider.title) sign-in doesn't cover transcribing as you speak, which needs \(key) on the gateway")
                : String(localized: "\(provider.title) needs \(key) on the gateway")
            fix = SetupFix(title: String(localized: "Add Key…"))
            steps = [SetupStep(String(localized: "On the gateway's computer, add the key:"), command: command("config set \(key) <your key>", profile: profile))]
            if !facts.liveTranscriptionOn { steps.append(turnOn) }
        } else if !facts.liveTranscriptionOn {
            why = String(localized: "live transcription is off on the gateway")
            fix = SetupFix(title: String(localized: "Turn On"))
            steps = [turnOn]
        } else if let failure = facts.lastTranscriptionFailure {
            why = failure
        } else {
            why = String(localized: "the gateway didn't say it can transcribe as you speak")
            steps = [.updateHermes, .restartGateway]
        }
        return SetupStatus(
            id: id, state: .limited, title: title,
            detail: String(localized: "On this \(device) instead"),
            fallback: String(localized: "Talk transcribes on this \(device): \(why)."),
            fix: fix, steps: steps, docs: talkDocs
        )
    }

    /// Hey Hermes (`wake.*`, `docs/voice.md` §4.6): whether the gateway listens for it from this
    /// device, and if not, why.
    static func wake(_ facts: VoiceFacts, device: String) -> SetupStatus {
        let id = id("wake", profile: nil)
        let title = String(localized: "Hey Hermes")
        let fallback = String(localized: "Start a call with Talk instead.")
        guard let state = facts.wake else {
            return .unknown(id: id, title: title, reason: String(localized: "The gateway didn't say whether it can listen for “Hey Hermes”. It may need a newer Hermes Agent."), docs: talkDocs)
        }
        guard state.available else {
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: state.hint ?? String(localized: "The gateway has no wake word engine, or no voice to answer with."),
                fallback: fallback, steps: [.updateHermes, .restartGateway], docs: talkDocs
            )
        }
        if state.keptForOtherSurface {
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "The gateway keeps it for \(state.configuredSurface ?? "another app") (wake_word.surface)."),
                fallback: fallback,
                steps: [SetupStep(String(localized: "Let any app use it:"), command: command("config set wake_word.surface auto", profile: nil))],
                docs: talkDocs
            )
        }
        if state.heldElsewhere {
            return SetupStatus(
                id: id, state: .limited, title: title,
                detail: String(localized: "Another device is listening for it"),
                fallback: String(localized: "The gateway listens for one device at a time: this \(device) takes over when that one stops.")
            )
        }
        if let pause = facts.wakePause {
            return SetupStatus(id: id, state: .limited, title: title, detail: pause, fallback: fallback)
        }
        guard state.enabled else {
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "It's off on the gateway (wake_word.enabled)."),
                fallback: fallback, fix: SetupFix(title: String(localized: "Turn On")),
                steps: [SetupStep(String(localized: "Or on the gateway's computer:"), command: command("config set wake_word.enabled true", profile: nil))],
                docs: talkDocs
            )
        }
        let detail = state.capture == "local"
            ? String(localized: "The gateway's own microphone listens for “Hey Hermes”")
            : String(localized: "Listening for “Hey Hermes”")
        return SetupStatus(id: id, state: .ready, title: title, detail: detail)
    }
}
