@preconcurrency import AVFoundation
import Foundation
import HermesKit
import Observation
import os
@preconcurrency import WebRTC

/// Talk's Realtime engine (`docs/voice.md` §4.1): WebRTC from the device to OpenAI's GPT-Live,
/// set up through the gateway (`POST /api/audio/voice-live/session`, which holds the key). GPT-Live
/// listens, talks and handles overlap itself; when the person asks for something it delegates
/// (`session.delegation.created`), the app runs that as a Hermes turn, and the turn's progress and
/// reply go back on the `oai-events` channel (`session.thinking.append`,
/// `session.commentary.append`), as Hermes Desktop does.
///
/// On iPhone and iPad its audio runs through the coordinator's engine (`GraphAudioDevice`), so
/// voice processing removes the Bot from the microphone and the face moves with the real output.
/// WebRTC's Mac SDK has no custom audio device: there it uses its own Core Audio module and echo
/// canceller, and the levels come from its statistics.
@MainActor
@Observable
final class RealtimeTalk: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case ended(String)
    }

    private(set) var state: State = .idle
    /// What GPT-Live heard, and what it's saying, from the transcript deltas.
    private(set) var heard = ""
    private(set) var saying = ""
    private(set) var isSpeaking = false
    #if os(iOS)
    var outputLevel: Float { device?.outputLevel ?? 0 }
    var inputLevel: Float { device?.inputLevel ?? 0 }
    @ObservationIgnored private var device: GraphAudioDevice?
    #else
    private(set) var outputLevel: Float = 0
    private(set) var inputLevel: Float = 0
    #endif

    /// The person asked for something: the delegation's id, what they said last and the recent
    /// spoken exchange (`voice_context`).
    var onDelegation: ((String, String, String) -> Void)?
    /// The session ended or failed (its reason).
    var onEnded: ((String) -> Void)?

    @ObservationIgnored private var factory: RTCPeerConnectionFactory?
    @ObservationIgnored private var connection: RTCPeerConnection?
    @ObservationIgnored private var channel: RTCDataChannel?
    @ObservationIgnored private var iceGathered: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var fragments: [(isUser: Bool, text: String, at: Date)] = []
    @ObservationIgnored private var eventNumber = 0
    @ObservationIgnored private var speakingSince: Date?
    @ObservationIgnored private var levelWatch: Task<Void, Never>?
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "talk")

    /// GPT-Live keeps appended text to this many characters a message.
    static let appendLimit = 1400

    // MARK: Starting and ending

    /// Connects: the offer goes to the gateway, the answer comes back, audio flows. `history` is
    /// the recent chat as GPT-Live items.
    func start(graph: AudioGraph, backend: BackendClient, profile: String?, history: [JSONValue]) async throws {
        guard state == .idle else { return }
        state = .connecting
        RTCInitializeSSL()
        #if os(iOS)
        let device = GraphAudioDevice(graph: graph)
        self.device = device
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
        #else
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        #endif
        self.factory = factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw Failure.couldNotConnect
        }
        self.connection = connection
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "microphone")
        connection.add(track, streamIds: ["talk"])
        // The channel goes in before the offer, so its m-line is negotiated.
        let channelConfiguration = RTCDataChannelConfiguration()
        let channel = connection.dataChannel(forLabel: "oai-events", configuration: channelConfiguration)
        channel?.delegate = self
        self.channel = channel

        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, any Error>) in
            connection.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) } else { continuation.resume(throwing: error ?? Failure.couldNotConnect) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await waitForIceGathering(connection)
        guard let sdp = connection.localDescription?.sdp else { throw Failure.couldNotConnect }
        let answer = try await backend.voiceLiveSession(offer: sdp, history: history, profile: profile)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        startLevelWatch()
    }

    /// Asks GPT-Live to close (`session.close`), then tears down.
    func close() {
        if !send(.object(["type": .string("session.close")])) { finish("close_requested") }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finish("close_requested")
        }
    }

    // MARK: The conversation

    /// Quiet progress for the voice ("Hermes is working: running a command. Not done yet.").
    func think(_ delegation: String?, _ text: String) {
        let content = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !content.isEmpty else { return }
        send(.object([
            "type": .string("session.thinking.append"), "delegation_id": delegation.map(JSONValue.string) ?? .null,
            "event_id": .string(nextEventID("think")), "content": .string(String(content.prefix(Self.appendLimit))),
        ]))
    }

    /// A result for the voice to say (it paraphrases).
    func speak(_ delegation: String, _ text: String) {
        for chunk in Self.chunks(text) {
            send(.object([
                "type": .string("session.commentary.append"), "delegation_id": .string(delegation),
                "event_id": .string(nextEventID("say")), "content": .string(chunk),
            ]))
        }
    }

    func setMuted(_ muted: Bool) {
        #if os(iOS)
        device?.isMuted = muted
        #endif
        send(.object(["type": .string(muted ? "session.input_audio.mute" : "session.input_audio.unmute"), "event_id": .string(nextEventID(muted ? "mute" : "unmute"))]))
    }

    /// The engine restarted: after a media services reset the playout node is made again.
    func engineRestarted() {
        #if os(iOS)
        device?.engineRestarted()
        #endif
    }

    /// Sentences, cut to the append limit.
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: ". ") {
            let piece = current.isEmpty ? sentence : current + ". " + sentence
            if piece.count > appendLimit, !current.isEmpty {
                chunks.append(current + ".")
                current = sentence
            } else {
                current = piece
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { chunks.append(String(current.prefix(appendLimit))) }
        return chunks
    }

    // MARK: Internals

    enum Failure: LocalizedError {
        case couldNotConnect

        var errorDescription: String? { String(localized: "Realtime couldn't connect.") }
    }

    private func nextEventID(_ prefix: String) -> String {
        eventNumber += 1
        return "\(prefix)_\(eventNumber)"
    }

    @discardableResult
    private func send(_ event: JSONValue) -> Bool {
        guard let channel, channel.readyState == .open, let data = try? JSONEncoder().encode(event) else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func waitForIceGathering(_ connection: RTCPeerConnection) async {
        guard connection.iceGatheringState != .complete else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            iceGathered = continuation
            Task { [weak self] in
                // Trickle is fine: the vendor answers with the candidates it has.
                try? await Task.sleep(for: .seconds(2))
                self?.resumeIceWait()
            }
        }
    }

    private func resumeIceWait() {
        iceGathered?.resume()
        iceGathered = nil
    }

    /// GPT-Live is speaking while its audio is loud, or was in the last 0.4 s.
    private func startLevelWatch() {
        levelWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                #if os(macOS)
                await self.readLevels()
                #endif
                let loud = self.outputLevel > 0.12
                if loud { self.speakingSince = .now }
                let speaking = self.speakingSince.map { Date.now.timeIntervalSince($0) < 0.4 } ?? false
                if speaking != self.isSpeaking { self.isSpeaking = speaking }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    #if os(macOS)
    /// The audio levels WebRTC reports (0…1 linear), as the meters show them.
    private func readLevels() async {
        guard let connection else { return }
        let report = await withCheckedContinuation { (continuation: CheckedContinuation<RTCStatisticsReport, Never>) in
            connection.statistics { continuation.resume(returning: $0) }
        }
        var output: Float = 0
        var input: Float = 0
        for stats in report.statistics.values {
            guard let level = (stats.values["audioLevel"] as? NSNumber)?.floatValue else { continue }
            if stats.type == "inbound-rtp" { output = level }
            if stats.type == "media-source" { input = level }
        }
        outputLevel = AudioLevel.normalised(rms: output)
        inputLevel = AudioLevel.normalised(rms: input)
    }
    #endif

    private func handle(_ text: String) {
        guard let event = JSONValue.parse(Data(text.utf8)), let type = event["type"]?.stringValue else { return }
        switch type {
        case "session.started":
            state = .live
        case "session.input_transcript.delta", "session.output_transcript.delta":
            let isUser = type == "session.input_transcript.delta"
            let delta = event["delta"]?.stringValue ?? ""
            fragments.append((isUser, delta, .now))
            if fragments.count > 2000 { fragments.removeFirst(500) }
            if isUser { heard += delta; saying = "" } else { saying += delta; heard = "" }
        case "session.delegation.created":
            guard let id = event["delegation"]?["id"]?.stringValue else { return }
            let (prompt, context) = delegationPrompt()
            heard = ""
            onDelegation?(id, prompt, context)
        case "error":
            let code = event["error"]?["code"]?.stringValue ?? ""
            // Late appends after our own close are expected.
            guard code != "context_injection_incomplete" else { return }
            Self.logger.error("realtime error \(code, privacy: .public)")
        case "session.closed":
            finish(event["reason"]?.stringValue ?? "closed")
        default:
            break
        }
    }

    /// What the person said last (the turn's text) and the spoken exchange of the last 5
    /// minutes, at most 80 fragments (Hermes Desktop's `delegationPrompt`).
    private func delegationPrompt() -> (String, String) {
        let recent = fragments.filter { Date.now.timeIntervalSince($0.at) < 300 }.suffix(80)
        var turns: [(isUser: Bool, text: String)] = []
        for fragment in recent {
            if let last = turns.last, last.isUser == fragment.isUser {
                turns[turns.count - 1].text += fragment.text
            } else {
                turns.append((fragment.isUser, fragment.text))
            }
        }
        let prompt = (turns.last(where: \.isUser)?.text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let context = VoiceTurn.context(turns)
        return (prompt.isEmpty ? String(context.suffix(400)) : prompt, context)
    }

    private func finish(_ reason: String) {
        guard state != .ended(reason), state != .idle || connection != nil else { return }
        levelWatch?.cancel()
        channel?.close()
        connection?.close()
        channel = nil
        connection = nil
        #if os(iOS)
        device?.shutDown()
        device = nil
        #endif
        factory = nil
        let wasLive = state == .live || state == .connecting
        state = .ended(reason)
        resumeIceWait()
        if wasLive { onEnded?(reason) }
    }
}

extension RealtimeTalk: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        guard newState == .failed || newState == .disconnected || newState == .closed else { return }
        Task { @MainActor in self.finish("connection_lost") }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in self.resumeIceWait() }
    }
}

extension RealtimeTalk: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .closed else { return }
        Task { @MainActor in self.finish("connection_lost") }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor in self.handle(text) }
    }
}
