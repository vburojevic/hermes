import Foundation

// The gateway's audio routes (`docs/voice.md` §10), all on the backend (`hermes serve`,
// `hermes_cli/web_routers/audio.py`): the API server has none. Scoped to a Bot with `?profile=`.

/// `GET /api/audio/voice-live/status`: whether Realtime (GPT-Live) can run.
public struct VoiceLiveStatus: Sendable, Equatable {
    /// `chained` (Hermes Voice) or `gpt-live`.
    public var mode: String
    public var available: Bool
    /// Why it isn't available ("no OpenAI API key (…)").
    public var reason: String?
    public var model: String?
    public var voice: String?

    public init(mode: String, available: Bool, reason: String? = nil, model: String? = nil, voice: String? = nil) {
        self.mode = mode
        self.available = available
        self.reason = reason
        self.model = model
        self.voice = voice
    }

    init(json: JSONValue) {
        mode = json["mode"]?.stringValue ?? "chained"
        available = json["available"]?.boolValue ?? false
        reason = json["reason"]?.stringValue
        model = json["model"]?.stringValue
        voice = json["voice"]?.stringValue
    }

    /// The gateway is set up for Realtime and can run it.
    public var isRealtime: Bool { mode == "gpt-live" && available }
}

/// `GET /api/audio/voice-config`: whether the device may talk to the speech providers directly.
/// The keys it carries live in memory for one call: they're never stored, shown or logged, and
/// `description` leaves them out (`docs/voice.md` §6, §8).
public struct VoiceConfig: Sendable, CustomStringConvertible {
    public struct Side: Sendable {
        /// `direct` or `relay`.
        public var mode: String
        /// Why it relays ("no credentials", "local provider").
        public var reason: String?
        /// How to call the provider: `openai-speech`, `elevenlabs-tts`, `openai-multipart`…
        public var wire: String?
        public var provider: String?
        public var baseURL: URL?
        public var model: String?
        public var voice: String?
        public var speed: Double?
        public var streaming: Bool
        fileprivate var key: RedactedKey?

        init(json: JSONValue?) {
            mode = json?["mode"]?.stringValue ?? "relay"
            reason = json?["reason"]?.stringValue
            wire = json?["wire"]?.stringValue
            provider = json?["provider"]?.stringValue
            baseURL = json?["base_url"]?.stringValue.flatMap(URL.init(string:))
            model = json?["model"]?.stringValue
            voice = json?["voice"]?.stringValue
            speed = json?["speed"]?.doubleValue
            streaming = json?["streaming"]?.boolValue ?? false
            key = json?["api_key"]?.stringValue.map(RedactedKey.init)
        }

        public var isDirect: Bool { mode == "direct" && key != nil && baseURL != nil }

        /// The provider key, for the one request that needs it.
        public func withKey<T>(_ body: (String) throws -> T) rethrows -> T? {
            guard let key else { return nil }
            return try body(key.value)
        }
    }

    public var stt: Side
    public var tts: Side

    init(json: JSONValue) {
        stt = Side(json: json["stt"])
        tts = Side(json: json["tts"])
    }

    public var description: String {
        "VoiceConfig(stt: \(stt.mode) \(stt.provider ?? "-"), tts: \(tts.mode) \(tts.provider ?? "-"))"
    }
}

/// A provider key that prints, dumps and reflects as "<redacted>".
struct RedactedKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// One ElevenLabs voice (`GET /api/audio/elevenlabs/voices`).
public struct ElevenLabsVoice: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// "Name (category)".
    public var label: String
}

extension BackendClient {
    private static func profileItems(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    public func voiceLiveStatus(profile: String?) async throws -> VoiceLiveStatus {
        VoiceLiveStatus(json: try await rest("api/audio/voice-live/status", query: Self.profileItems(profile)))
    }

    public func voiceConfig(profile: String?) async throws -> VoiceConfig {
        VoiceConfig(json: try await rest("api/audio/voice-config", query: Self.profileItems(profile)))
    }

    /// Starts a Realtime session: the gateway calls OpenAI with its own key and hands back the
    /// SDP answer. `history` is the recent chat as GPT-Live items.
    public func voiceLiveSession(offer: String, history: [JSONValue], profile: String?) async throws -> String {
        let body: JSONValue = .object(["sdp": .string(offer), "history": .array(history)])
        let json = try await rest("api/audio/voice-live/session", method: "POST", query: Self.profileItems(profile), body: body)
        guard let answer = json["transport"]?["sdp"]?.stringValue ?? json["sdp"]?.stringValue else {
            throw Failure.http(502, "Realtime didn't answer the call.")
        }
        return answer
    }

    /// The whole sentence as one audio file (`POST /api/audio/speak`), for providers or moments
    /// where streaming fell back.
    public func speak(_ text: String, profile: String?) async throws -> (data: Data, mimeType: String) {
        let json = try await rest("api/audio/speak", method: "POST", query: Self.profileItems(profile), body: .object(["text": .string(text)]))
        guard let url = json["data_url"]?.stringValue, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw Failure.http(500, "Invalid TTS response")
        }
        return (data, json["mime_type"]?.stringValue ?? "audio/mpeg")
    }

    /// The gateway's speech to text for a whole recording (`POST /api/audio/transcribe`): a
    /// voice message the device couldn't make out (`docs/voice.md` §2). "" when no speech was heard.
    public func transcribe(_ audio: Data, mimeType: String, profile: String?) async throws -> String {
        let json = try await rest("api/audio/transcribe", method: "POST", query: Self.profileItems(profile), body: .object([
            "data_url": .string("data:\(mimeType);base64,\(audio.base64EncodedString())"),
            "mime_type": .string(mimeType),
        ]))
        return json["transcript"]?.stringValue ?? ""
    }

    /// Keeps the gateway's speech engine warm while a call or a reply is open
    /// (`POST /api/audio/tts-lease`). Failures don't matter: speech still works, just slower.
    public func ttsLease(_ lease: String, active: Bool, profile: String?) async {
        _ = try? await rest("api/audio/tts-lease", method: "POST", query: Self.profileItems(profile),
                            body: .object(["lease": .string(lease), "active": .bool(active)]))
    }

    public func elevenLabsVoices(profile: String?) async throws -> (available: Bool, voices: [ElevenLabsVoice]) {
        let json = try await rest("api/audio/elevenlabs/voices", query: Self.profileItems(profile))
        guard case .array(let rows)? = json["voices"] else { return (json["available"]?.boolValue ?? false, []) }
        let voices = rows.compactMap { row -> ElevenLabsVoice? in
            guard let id = row["voice_id"]?.stringValue else { return nil }
            let name = row["name"]?.stringValue ?? id
            return ElevenLabsVoice(id: id, name: name, label: row["label"]?.stringValue ?? name)
        }
        return (json["available"]?.boolValue ?? !voices.isEmpty, voices)
    }

    /// Writes part of a Bot's config (`PUT /api/config?profile=`), deep-merged by the gateway:
    /// its voice (`tts.provider`, `tts.<provider>.voice`, `voice.gpt_live.voice`).
    public func updateConfig(_ partial: JSONValue, profile: String?) async throws {
        var body: [String: JSONValue] = ["config": partial]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await rest("api/config", method: "PUT", query: Self.profileItems(profile), body: .object(body))
    }

    /// A Bot's config (`GET /api/config?profile=`), for its current voice. Keys in it are never
    /// read by the app.
    public func config(profile: String?) async throws -> JSONValue {
        try await rest("api/config", query: Self.profileItems(profile))
    }

    /// One sentence in the Bot's voice, as it's synthesised (`WS /api/audio/speak-stream`).
    public func speakStream(_ text: String, profile: String?) async throws -> SpeakStream {
        let task = try await webSocket(path: "api/audio/speak-stream", query: Self.profileItems(profile))
        return SpeakStream(task: task, text: text)
    }

    /// One spoken turn transcribed by the gateway as it's said (`WS /api/audio/transcribe-stream`).
    public func transcribeStream(profile: String?) async throws -> TranscribeStream {
        let task = try await webSocket(path: "api/audio/transcribe-stream", query: Self.profileItems(profile))
        return TranscribeStream(task: task)
    }

    /// The URL and headers to play a gateway file (`GET /api/files/stream?path=`; Range works,
    /// no profile, header auth only).
    public func fileStreamRequest(path: String) -> URLRequest {
        var url = baseURL.appending(path: "api/files/stream")
        url.append(queryItems: [URLQueryItem(name: "path", value: path)])
        var request = URLRequest(url: url)
        for (name, value) in authorizationHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Downloads a gateway file for playing (voice messages and agent audio are small enough to
    /// keep: 10 minutes at 32 kbps is about 2.4 MB).
    public func downloadFile(path: String) async throws -> Data {
        let (data, _) = try await restData("api/files/stream", query: [URLQueryItem(name: "path", value: path)])
        return data
    }
}

/// `WS /api/audio/speak-stream` for one sentence: send `{text, done}`, then `start
/// {sample_rate}`, int16 little-endian mono PCM frames and `end` come back. `fallback` means the
/// provider couldn't stream: use `speak`. Barge-in sends `{stop}`.
public actor SpeakStream {
    public enum Event: Sendable, Equatable {
        case start(sampleRate: Double)
        /// Whole samples, little-endian int16 mono.
        case pcm(Data)
        case end
        case fallback
    }

    private let task: URLSessionWebSocketTask
    private let text: String
    private var stopped = false

    init(task: URLSessionWebSocketTask, text: String) {
        self.task = task
        self.text = text
    }

    /// Sends the sentence and yields what comes back until `end`, `fallback` or a close.
    public nonisolated func events() -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await self.run(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                work.cancel()
                if case .cancelled = reason { Task { await self.stop() } }
            }
        }
    }

    /// Barge-in: the server stops synthesising, and the socket closes.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        try? await task.send(.string(#"{"stop":true}"#))
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func run(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation) async throws {
        task.resume()
        let request = JSONValue.object(["text": .string(text), "done": .bool(true)])
        try await task.send(.string(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)))
        var assembler = PCMAssembler()
        while !Task.isCancelled {
            let message = try await task.receive()
            switch message {
            case .data(let data):
                let samples = assembler.append(data)
                if !samples.isEmpty { continuation.yield(.pcm(samples)) }
            case .string(let string):
                guard let json = JSONValue.parse(Data(string.utf8)) else { continue }
                switch json["type"]?.stringValue {
                case "start":
                    continuation.yield(.start(sampleRate: json["sample_rate"]?.doubleValue ?? 24_000))
                case "end":
                    continuation.yield(.end)
                    task.cancel(with: .normalClosure, reason: nil)
                    return
                case "fallback":
                    continuation.yield(.fallback)
                    task.cancel(with: .normalClosure, reason: nil)
                    return
                default:
                    continue
                }
            @unknown default:
                continue
            }
        }
    }
}

/// `WS /api/audio/transcribe-stream` for one utterance (Hermes's `transcription_streaming`):
/// `{sample_rate}` first, then little-endian int16 mono PCM, then `{eos}`. `partial {text}` (all
/// heard so far) comes back as it's heard, `final {transcript}` after `eos`, or `error {message}`.
/// Closing early cancels it. The device decides when a turn ends: one socket per turn.
public actor TranscribeStream {
    public enum Event: Sendable, Equatable {
        case partial(String)
        case final(String)
        case failed(String)
    }

    private let task: URLSessionWebSocketTask
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    /// Opens the socket and tells the gateway the audio's rate (8–48 kHz).
    public func start(sampleRate: Int) async throws {
        task.resume()
        try await task.send(.string(#"{"sample_rate":\#(sampleRate)}"#))
    }

    public func send(_ pcm: Data) async throws {
        guard !closed, !pcm.isEmpty else { return }
        try await task.send(.data(pcm))
    }

    /// The turn is over: the gateway answers with `final`.
    public func finish() async throws {
        guard !closed else { return }
        try await task.send(.string(#"{"eos":true}"#))
    }

    /// Drops the turn: Hermes cancels when the socket closes.
    public func cancel() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// What comes back, until `final`, an error or a close.
    public nonisolated func events() -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    while !Task.isCancelled {
                        guard case .string(let string) = try await self.task.receive(),
                              let event = Self.event(string) else { continue }
                        continuation.yield(event)
                        if case .partial = event { continue }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// One message from the gateway, or `nil` for one the app doesn't use.
    public static func event(_ text: String) -> Event? {
        guard let json = JSONValue.parse(Data(text.utf8)) else { return nil }
        switch json["type"]?.stringValue {
        case "partial": return .partial(json["text"]?.stringValue ?? "")
        case "final": return .final(json["transcript"]?.stringValue ?? "")
        case "error": return .failed(json["message"]?.stringValue ?? "transcription failed")
        default: return nil
        }
    }
}

/// A WAV file of 16-bit mono PCM, for `POST /api/audio/transcribe` when the gateway couldn't
/// transcribe a turn live.
public enum WAVFile {
    public static func make(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// int16 PCM arrives in frames that aren't sample-aligned: an odd trailing byte is carried to
/// the next frame (as Hermes Desktop does).
public struct PCMAssembler: Sendable {
    private var carry: UInt8?

    public init() {}

    /// The whole samples now available.
    public mutating func append(_ data: Data) -> Data {
        var bytes = Data()
        bytes.reserveCapacity(data.count + 1)
        if let carry { bytes.append(carry) }
        bytes.append(data)
        if bytes.count % 2 == 1 {
            carry = bytes.removeLast()
        } else {
            carry = nil
        }
        return bytes
    }
}
