#if DEBUG && os(iOS)
@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization
@preconcurrency import WebRTC

/// `-HERMES_REALTIME_LOOPBACK YES`: Realtime without OpenAI, for checking what GPT-Live would hear
/// (`docs/voice.md` §4.2). The call's WebRTC offer is answered by a second peer in the app instead
/// of the gateway. It "speaks" in bursts (a voiced tone, four seconds on, four off), so the call's
/// face, levels and gate run as with GPT-Live, and it logs how loud what it hears is each half
/// second, while speaking and not (category `talk`, "loopback heard"). With the simulated
/// microphone (`-HERMES_VOICE_INPUT`) a TV across the room should be 40 dB down while it speaks,
/// and a voice near the microphone come through.
@MainActor
final class RealtimeLoopback: NSObject {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "HERMES_REALTIME_LOOPBACK") }

    private let device = LoopbackAudioDevice()
    private var factory: RTCPeerConnectionFactory?
    private var connection: RTCPeerConnection?
    private var gathered: CheckedContinuation<Void, Never>?

    /// The answer to the call's offer, from the in-app peer.
    func answer(_ offer: String) async throws -> String {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
        self.factory = factory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw RealtimeTalk.Failure.couldNotConnect
        }
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // Its voice goes back on the call's audio line.
        let track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "loopback")
        if let transceiver = connection.transceivers.first(where: { $0.mediaType == .audio }) {
            transceiver.sender.track = track
            transceiver.setDirection(.sendRecv, error: nil)
        }
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, any Error>) in
            connection.answer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) } else { continuation.resume(throwing: error ?? RealtimeTalk.Failure.couldNotConnect) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        if connection.iceGatheringState != .complete {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gathered = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.iceDone()
                }
            }
        }
        RealtimeTalk.logger.info("loopback: answering the call in the app")
        return connection.localDescription?.sdp ?? answer.sdp
    }

    func close() {
        connection?.close()
        connection = nil
        factory = nil
        iceDone()
    }

    private func iceDone() {
        gathered?.resume()
        gathered = nil
    }
}

extension RealtimeLoopback: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in self.iceDone() }
    }
}

/// The loopback peer's audio: it records a voiced tone in bursts and plays nothing, measuring what
/// it's sent instead. One thread, 10 ms at a time, as a real device's IO would.
nonisolated private final class LoopbackAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    private static let rate: Double = 48_000
    private static let frames = 480
    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "talk")
    private let state = Mutex(State())

    private struct State {
        var delegate: (any RTCAudioDeviceDelegate)?
        var initialized = false
        var playoutInitialized = false
        var playing = false
        var recordingInitialized = false
        var recording = false
        var thread: Thread?
    }

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { state.withLock { $0.initialized } }
    var isPlayoutInitialized: Bool { state.withLock { $0.playoutInitialized } }
    var isPlaying: Bool { state.withLock { $0.playing } }
    var isRecordingInitialized: Bool { state.withLock { $0.recordingInitialized } }
    var isRecording: Bool { state.withLock { $0.recording } }

    func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
        state.withLock {
            $0.delegate = delegate
            $0.initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        state.withLock {
            $0.thread?.cancel()
            $0.thread = nil
            $0.delegate = nil
            $0.initialized = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        state.withLock { $0.playoutInitialized = true }
        return true
    }

    func startPlayout() -> Bool {
        state.withLock { $0.playing = true }
        startThread()
        return true
    }

    func stopPlayout() -> Bool {
        state.withLock { $0.playing = false }
        return true
    }

    func initializeRecording() -> Bool {
        state.withLock { $0.recordingInitialized = true }
        return true
    }

    func startRecording() -> Bool {
        state.withLock { $0.recording = true }
        startThread()
        return true
    }

    func stopRecording() -> Bool {
        state.withLock { $0.recording = false }
        return true
    }

    private func startThread() {
        state.withLock { state in
            guard state.thread == nil else { return }
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "loopback audio"
            thread.qualityOfService = .userInteractive
            state.thread = thread
            thread.start()
        }
    }

    private func run() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate, channels: 1, interleaved: true)!
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.frames)),
              let heard = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.frames)) else { return }
        out.frameLength = AVAudioFrameCount(Self.frames)
        heard.frameLength = AVAudioFrameCount(Self.frames)
        var sample = 0
        var phase = 0.0
        var sum = 0.0
        var count = 0
        let start = Date.now
        while !Thread.current.isCancelled {
            let tick = Date.now
            let (delegate, recording, playing) = state.withLock { ($0.delegate, $0.recording, $0.playing) }
            let elapsed = Double(sample) / Self.rate
            let speaking = elapsed.truncatingRemainder(dividingBy: 8) < 4
            if recording, let delegate, let samples = out.int16ChannelData?[0] {
                // Syllables of a voiced tone, about −12 dBFS, while "speaking".
                for index in 0..<Self.frames {
                    let time = Double(sample + index) / Self.rate
                    let envelope = speaking ? pow(sin(.pi * (time * 5).truncatingRemainder(dividingBy: 1)), 2) : 0
                    phase += 2 * .pi * 140 / Self.rate
                    samples[index] = Int16(0.35 * envelope * sin(phase) * 32767)
                }
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = Double(sample)
                timestamp.mFlags = .sampleTimeValid
                _ = delegate.deliverRecordedData(&flags, &timestamp, 1, UInt32(Self.frames), out.audioBufferList, nil, nil)
            }
            if playing, let delegate, let samples = heard.int16ChannelData?[0] {
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = Double(sample)
                timestamp.mFlags = .sampleTimeValid
                _ = delegate.getPlayoutData(&flags, &timestamp, 0, UInt32(Self.frames), heard.mutableAudioBufferList)
                for index in 0..<Self.frames {
                    let value = Double(samples[index]) / 32768
                    sum += value * value
                }
                count += Self.frames
                if count >= Int(Self.rate / 2) {
                    let level = 10 * log10(max(sum / Double(count), 1e-12))
                    Self.logger.info("loopback heard \(Int(level.rounded())) dB at \(String(format: "%.1f", Date.now.timeIntervalSince(start)), privacy: .public) s, \(speaking ? "speaking" : "quiet", privacy: .public)")
                    sum = 0
                    count = 0
                }
            }
            sample += Self.frames
            let wait = 0.01 - Date.now.timeIntervalSince(tick)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }
}
#endif
