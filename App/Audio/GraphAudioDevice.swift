#if os(iOS)
@preconcurrency import AVFoundation
import Foundation
import HermesKit
import Synchronization
@preconcurrency import WebRTC

/// WebRTC's audio, through the coordinator's engine instead of its own audio unit
/// (`docs/voice.md` §4.2): the microphone's shared tap feeds the call as 16-bit PCM, and WebRTC's
/// playout renders into a source node in the same voice-processing engine, so the echo canceller
/// hears GPT-Live and the face can follow its real level. Runs on audio threads.
///
/// While GPT-Live speaks, what it hears goes through a `NearGate` (`docs/voice.md` §4.2): its own
/// barge-in takes any voice for the person, so a TV or people across the room would cut it off.
/// The gate's threshold comes from Talk's ears on the main actor (`nearThreshold`), fed the
/// microphone's 20 ms levels (`onFrames`).
nonisolated final class GraphAudioDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    static let sampleRate: Double = 48_000
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    /// GPT-Live counts as speaking this long after its audio was last loud (between words).
    private static let speakingHangover: TimeInterval = 0.4
    private static let loudOutput: Float = 0.12

    private let graph: AudioGraph
    private let state = Mutex(State())
    private let gate = Mutex(NearGate(sampleRate: GraphAudioDevice.sampleRate, lookahead: NearGate.realtimeLookahead))
    /// What the audio threads read and write, without locks.
    private let live = Live()

    private final class Live: Sendable {
        let output = Atomic<UInt32>(0)
        let input = Atomic<UInt32>(0)
        let muted = Atomic<Bool>(false)
        let playing = Atomic<Bool>(false)
        /// The gate's threshold in dBFS; NaN while the ears don't know one.
        let near = Atomic<UInt32>(Float.nan.bitPattern)
        /// Host time until which GPT-Live counts as speaking.
        let speakingUntil = Atomic<UInt64>(0)
    }

    private struct State {
        var delegate: (any RTCAudioDeviceDelegate)?
        var deliver: RTCAudioDeviceDeliverRecordedDataBlock?
        var playout: RTCAudioDeviceGetPlayoutDataBlock?
        var source: AVAudioSourceNode?
        var consumer: UUID?
        var converter: AVAudioConverter?
        var initialized = false
        var playoutInitialized = false
        var playing = false
        var recordingInitialized = false
        var recording = false
        var onFrames: (@Sendable (TimeInterval, [Float]) -> Void)?
    }

    init(graph: AudioGraph) {
        self.graph = graph
    }

    /// The level of what GPT-Live says, 0…1.
    var outputLevel: Float { Float(bitPattern: live.output.load(ordering: .relaxed)) }
    /// The microphone's level, 0…1.
    var inputLevel: Float { Float(bitPattern: live.input.load(ordering: .relaxed)) }
    var isMuted: Bool {
        get { live.muted.load(ordering: .relaxed) }
        set { live.muted.store(newValue, ordering: .relaxed) }
    }
    /// The quietest sound that's the person while GPT-Live speaks (`TalkEars.nearThreshold`).
    var nearThreshold: Float? {
        get {
            let value = Float(bitPattern: live.near.load(ordering: .relaxed))
            return value.isNaN ? nil : value
        }
        set { live.near.store((newValue ?? .nan).bitPattern, ordering: .relaxed) }
    }

    /// The microphone's 20 ms levels in dBFS with when the first was heard (system uptime), for
    /// Talk's ears. Set before recording starts.
    func onFrames(_ handler: (@Sendable (TimeInterval, [Float]) -> Void)?) {
        state.withLock { $0.onFrames = handler }
    }

    func shutDown() {
        _ = stopRecording()
        _ = stopPlayout()
        _ = terminateDevice()
    }

    // MARK: RTCAudioDevice

    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
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
            $0.deliver = delegate.deliverRecordedData
            $0.playout = delegate.getPlayoutData
            $0.initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        state.withLock {
            $0.delegate = nil
            $0.deliver = nil
            $0.playout = nil
            $0.initialized = false
        }
        return true
    }

    /// A media services reset took the playout node and the microphone's tap with the old engine:
    /// make the node again (the tap comes back by itself).
    func engineRestarted() {
        guard let source = state.withLock({ $0.source }), !graph.contains(source) else { return }
        state.withLock { $0.source = nil }
        _ = initializePlayout()
    }

    func initializePlayout() -> Bool {
        let playout = state.withLock { $0.playout }
        guard let playout else { return false }
        let live = live
        let hangover = AVAudioTime.hostTime(forSeconds: Self.speakingHangover)
        // The render thread reads only atomics and the playout block.
        let node = AVAudioSourceNode(format: Self.format) { isSilence, timestamp, frameCount, outputData in
            guard live.playing.load(ordering: .relaxed) else {
                isSilence.pointee = true
                Self.silence(outputData)
                live.output.store(Float(0).bitPattern, ordering: .relaxed)
                return noErr
            }
            var flags = AudioUnitRenderActionFlags()
            let status = playout(&flags, timestamp, 0, frameCount, outputData)
            let level = Self.level(outputData, frames: Int(frameCount))
            live.output.store(level.bitPattern, ordering: .relaxed)
            if level > Self.loudOutput {
                let now = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : mach_absolute_time()
                live.speakingUntil.store(now + hangover, ordering: .relaxed)
            }
            return status
        }
        do {
            try graph.attachSource(node, format: Self.format)
        } catch {
            return false
        }
        state.withLock {
            $0.source = node
            $0.playoutInitialized = true
        }
        return true
    }

    func startPlayout() -> Bool {
        state.withLock { $0.playing = true }
        live.playing.store(true, ordering: .relaxed)
        return true
    }

    func stopPlayout() -> Bool {
        live.playing.store(false, ordering: .relaxed)
        let source = state.withLock { state -> AVAudioSourceNode? in
            state.playing = false
            state.playoutInitialized = false
            defer { state.source = nil }
            return state.source
        }
        if let source { graph.detachSource(source) }
        live.output.store(Float(0).bitPattern, ordering: .relaxed)
        return true
    }

    func initializeRecording() -> Bool {
        state.withLock { $0.recordingInitialized = true }
        return true
    }

    func startRecording() -> Bool {
        guard let id = try? graph.addInputConsumer({ [weak self] buffer, time in self?.record(buffer, at: time) }) else { return false }
        state.withLock {
            $0.consumer = id
            $0.recording = true
        }
        return true
    }

    func stopRecording() -> Bool {
        let id = state.withLock { state -> UUID? in
            state.recording = false
            defer { state.consumer = nil }
            return state.consumer
        }
        if let id { graph.removeInputConsumer(id) }
        live.input.store(Float(0).bitPattern, ordering: .relaxed)
        return true
    }

    // MARK: Audio threads

    /// One microphone buffer, as 48 kHz 16-bit mono, into WebRTC: gated while GPT-Live speaks.
    private func record(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        live.input.store(AudioLevel.level(of: buffer).bitPattern, ordering: .relaxed)
        let (deliver, converter, onFrames) = state.withLock { state -> (RTCAudioDeviceDeliverRecordedDataBlock?, AVAudioConverter?, (@Sendable (TimeInterval, [Float]) -> Void)?) in
            if state.converter == nil || state.converter?.inputFormat != buffer.format {
                state.converter = AVAudioConverter(from: buffer.format, to: Self.format)
                state.converter?.primeMethod = .none
                if buffer.format.channelCount > 1 { state.converter?.channelMap = [0] }
            }
            return (state.deliver, state.converter, state.onFrames)
        }
        let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        if let onFrames {
            onFrames(AVAudioTime.seconds(forHostTime: host), AudioLevel.decibelWindows(of: buffer, size: max(1, Int(buffer.format.sampleRate / 50))))
        }
        guard let deliver, let converter else { return }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate).rounded(.up)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
        var supplied = false
        let status = converter.convert(to: converted, error: nil) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0, let samples = converted.int16ChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        let speaking = host < live.speakingUntil.load(ordering: .relaxed)
        let near = nearThreshold
        gate.withLock { gate in
            gate.threshold = speaking ? near : nil
            gate.process(UnsafeMutableBufferPointer(start: samples, count: count))
        }
        if isMuted { samples.update(repeating: 0, count: count) }
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid
        _ = deliver(&flags, &timestamp, 1, converted.frameLength, converted.audioBufferList, nil, nil)
    }

    private static func silence(_ list: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    /// RMS of 16-bit samples, as the meters show it.
    private static func level(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) -> Float {
        guard let buffer = UnsafeMutableAudioBufferListPointer(list).first, let data = buffer.mData, frames > 0 else { return 0 }
        let samples = data.assumingMemoryBound(to: Int16.self)
        var sum: Float = 0
        for index in 0..<frames {
            let value = Float(samples[index]) / 32768
            sum += value * value
        }
        return AudioLevel.normalised(rms: (sum / Float(frames)).squareRoot())
    }
}
#endif
