import AVFoundation
import Foundation
import HermesKit
import Observation
import os

/// A Bot's voice (`docs/voice.md` §6, `botVoicePicker`): it lives in the Bot's gateway profile,
/// read with `GET /api/config?profile=` and written with `PUT /api/config?profile=` (Hermes
/// deep-merges what's sent). Realtime's voice is `voice.gpt_live.voice`; replies and voice
/// messages use `tts.provider` with that provider's voice key, at `tts.speed`.
@MainActor
@Observable
final class BotVoiceModel {
    /// A text-to-speech provider Hermes has built in, and where its voice is kept.
    struct Provider: Identifiable, Hashable {
        let id: String
        let title: String
        /// The key under `tts.<id>` that names the voice; `nil` when it has none to pick.
        let voiceKey: String?
        /// Voices to pick from, bundled; empty means typed (or fetched, for ElevenLabs).
        let voices: [String]
    }

    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
        var detail: String?
    }

    /// Hermes's built-in providers (`tools/tts_tool.py`), `edge` its default.
    static let providers: [Provider] = [
        Provider(id: "edge", title: "Edge", voiceKey: "voice", voices: []),
        Provider(id: "openai", title: "OpenAI", voiceKey: "voice",
                 voices: ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"]),
        Provider(id: "elevenlabs", title: "ElevenLabs", voiceKey: "voice_id", voices: []),
        Provider(id: "gemini", title: "Gemini", voiceKey: "voice", voices: []),
        Provider(id: "xai", title: "xAI", voiceKey: "voice_id", voices: []),
        Provider(id: "minimax", title: "MiniMax", voiceKey: "voice_id", voices: []),
        Provider(id: "mistral", title: "Mistral", voiceKey: "voice_id", voices: []),
        Provider(id: "deepinfra", title: "DeepInfra", voiceKey: "voice", voices: []),
        Provider(id: "neutts", title: "NeuTTS", voiceKey: nil, voices: []),
        Provider(id: "kittentts", title: "KittenTTS", voiceKey: nil, voices: []),
        Provider(id: "piper", title: "Piper", voiceKey: nil, voices: []),
    ]

    /// Realtime's voices, hard-coded on the gateway too (`tools/voice_live.py`).
    static let realtimeVoices: [Voice] = [
        Voice(id: "marin", name: "Marin", detail: String(localized: "Warm and unhurried")),
        Voice(id: "cedar", name: "Cedar", detail: String(localized: "Low and steady")),
        Voice(id: "quartz", name: "Quartz", detail: String(localized: "Clear and bright")),
    ] + ["ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]
        .map { Voice(id: $0, name: $0.capitalized) }

    let profile: String?
    let title: String
    private let backend: BackendClient

    private(set) var isLoading = true
    private(set) var failure: String?
    private(set) var realtimeVoice = "marin"
    private(set) var providerID = "edge"
    /// The provider's voice: a name, or ElevenLabs' id.
    private(set) var voice: String?
    private(set) var speed: Double = 1
    private(set) var elevenLabsVoices: [Voice] = []
    /// Previews are made straight with the provider when the gateway hands out its voice
    /// (client-direct); otherwise there's nothing to preview with.
    private(set) var canPreview = false
    private(set) var previewing: String?
    @ObservationIgnored private var direct: VoiceConfig.Side?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    init(backend: BackendClient, profile: String?, title: String) {
        self.backend = backend
        self.profile = profile
        self.title = title
    }

    var provider: Provider {
        Self.providers.first { $0.id == providerID } ?? Provider(id: providerID, title: providerID, voiceKey: "voice", voices: [])
    }

    /// What's offered for the provider: its bundled list, ElevenLabs' own, else typed.
    var voices: [Voice] {
        if providerID == "elevenlabs" { return elevenLabsVoices }
        return provider.voices.map { Voice(id: $0, name: $0.capitalized) }
    }

    /// The voice's name, for the row.
    var voiceTitle: String {
        guard let voice, !voice.isEmpty else { return String(localized: "Default") }
        return voices.first { $0.id == voice }?.name ?? voice
    }

    var realtimeTitle: String {
        Self.realtimeVoices.first { $0.id == realtimeVoice }?.name ?? realtimeVoice.capitalized
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let config = try await backend.config(profile: profile)
            realtimeVoice = config["voice"]?["gpt_live"]?["voice"]?.stringValue ?? "marin"
            let tts = config["tts"]
            providerID = tts?["provider"]?.stringValue?.lowercased() ?? "edge"
            if let key = provider.voiceKey { voice = tts?[providerID]?[key]?.stringValue }
            speed = tts?["speed"]?.doubleValue ?? 1
            failure = nil
        } catch {
            failure = String(localized: "Couldn't read the voice from the gateway.")
            Self.logger.error("voice config: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
        if let config = try? await backend.voiceConfig(profile: profile) {
            direct = config.tts.isDirect ? config.tts : nil
            canPreview = direct != nil
        }
        if providerID == "elevenlabs" { await loadElevenLabs() }
    }

    private func loadElevenLabs() async {
        guard let result = try? await backend.elevenLabsVoices(profile: profile) else { return }
        elevenLabsVoices = result.voices.map { Voice(id: $0.id, name: $0.name, detail: $0.label) }
    }

    // MARK: Saving

    func setRealtimeVoice(_ id: String) async {
        let old = realtimeVoice
        realtimeVoice = id
        await save(.object(["voice": .object(["gpt_live": .object(["voice": .string(id)])])])) { self.realtimeVoice = old }
    }

    func setProvider(_ id: String) async {
        let old = (providerID, voice)
        providerID = id
        voice = nil
        await save(.object(["tts": .object(["provider": .string(id)])])) { (self.providerID, self.voice) = old }
        if id == "elevenlabs", elevenLabsVoices.isEmpty { await loadElevenLabs() }
        // The voice the profile already had for this provider, if any.
        if let key = provider.voiceKey, let config = try? await backend.config(profile: profile) {
            voice = config["tts"]?[id]?[key]?.stringValue
        }
    }

    func setVoice(_ id: String) async {
        guard let key = provider.voiceKey else { return }
        let old = voice
        voice = id
        await save(.object(["tts": .object([providerID: .object([key: .string(id)])])])) { self.voice = old }
    }

    func setSpeed(_ value: Double) async {
        let old = speed
        speed = value
        await save(.object(["tts": .object(["speed": .number(value)])])) { self.speed = old }
    }

    private func save(_ partial: JSONValue, undo: () -> Void) async {
        do {
            try await backend.updateConfig(partial, profile: profile)
            failure = nil
        } catch {
            undo()
            failure = String(localized: "Couldn't save the voice. Check the gateway and try again.")
        }
    }

    // MARK: Previews

    static let previewSentence = String(localized: "Hi, this is how I sound when I read your replies.")

    nonisolated private static let previewSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }()

    /// Says the preview sentence in `voice`, straight from the provider with the gateway's
    /// client-direct settings (the key is used for this one request and kept nowhere).
    func preview(_ voiceID: String, realtime: Bool) {
        if previewing == voiceID {
            stopPreview()
            return
        }
        stopPreview()
        guard let direct else { return }
        previewing = voiceID
        previewTask = Task {
            defer { if previewing == voiceID { previewing = nil } }
            do {
                let audio = try await Self.synthesise(Self.previewSentence, voice: voiceID, realtime: realtime, with: direct)
                guard !Task.isCancelled, previewing == voiceID else { return }
                let url = URL.temporaryDirectory.appending(path: "voice-preview-\(voiceID).\(audio.fileExtension)")
                try audio.data.write(to: url)
                await ClipPlayer.shared.play("preview:\(voiceID)", url: url, from: 0)
                while ClipPlayer.shared.isPlaying("preview:\(voiceID)"), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                Self.logger.error("voice preview: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                failure = String(localized: "Couldn't play the preview.")
            }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        if let previewing { ClipPlayer.shared.stop(ifPlaying: "preview:\(previewing)") }
        previewing = nil
    }

    /// One sentence from the provider the gateway named (`openai-speech` or `elevenlabs-tts`). A
    /// Realtime voice is previewed with OpenAI's speech model, which has the same voices.
    @concurrent static func synthesise(_ text: String, voice: String, realtime: Bool, with side: VoiceConfig.Side) async throws -> (data: Data, fileExtension: String) {
        guard let base = side.baseURL else { throw URLError(.badURL) }
        var request: URLRequest
        switch side.wire {
        case "elevenlabs-tts" where !realtime:
            request = URLRequest(url: base.appending(path: "text-to-speech/\(voice)"))
            side.withKey { request.setValue($0, forHTTPHeaderField: "xi-api-key") }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": side.model ?? "eleven_multilingual_v2"])
        case "openai-speech":
            request = URLRequest(url: base.appending(path: "audio/speech"))
            side.withKey { request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": realtime ? "gpt-4o-mini-tts" : (side.model ?? "gpt-4o-mini-tts"),
                "voice": voice, "input": text, "response_format": "wav",
            ])
        default:
            throw URLError(.unsupportedURL)
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A key never follows a redirect to another server (AGENTS.md).
        let (data, response) = try await previewSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return (data, type.contains("wav") ? "wav" : "mp3")
    }
}
