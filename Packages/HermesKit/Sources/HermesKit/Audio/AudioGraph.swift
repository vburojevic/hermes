@preconcurrency import AVFAudio
import Foundation
import os

/// The app's one `AVAudioEngine` (`docs/voice.md` §4.2, §7), owned by the coordinator.
///
/// - The microphone has a single tap, shared by everyone who listens: a voice message feeds its
///   encoder, its waveform and its transcriber from the same buffers.
/// - Speech plays on player nodes in the same engine, so with voice processing on (Talk) the echo
///   canceller hears the Bot and removes it from the microphone.
/// - Nothing here is rebuilt between turns of a call; the coordinator reconfigures it only when
///   the role changes.
///
/// Calls are serialised by a lock; taps and render callbacks run on audio threads and never touch
/// actor state.
public final class AudioGraph: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var engine = AVAudioEngine()
    private var voiceProcessing = false
    private var usesInput = false
    private var tapInstalled = false
    private let consumers = OSAllocatedUnfairLock<[UUID: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void]>(initialState: [:])
    private var players: [UUID: AudioPlayerChain] = [:]
    private var sources: [AVAudioSourceNode] = []

    public init() {}

    #if DEBUG
    /// `-HERMES_VOICE_INPUT clip.caf@1.5,stop.caf@9`: spoken clips heard as if by the microphone,
    /// each at its second from when listening starts (simulators and UI tests have no microphone).
    nonisolated(unsafe) public static var simulatedInput: [(url: URL, at: TimeInterval)] = []
    private var simulated: SimulatedMicrophone?
    #endif

    // MARK: Configuration (the coordinator)

    /// Sets voice processing for the next role. The engine stops while it changes; players and
    /// the input tap are put back.
    func prepare(voiceProcessing: Bool, usesInput: Bool) throws {
        try lock.withLock {
            let hadInput = self.usesInput
            self.usesInput = usesInput
            if hadInput, !usesInput, players.isEmpty, consumers.withLock(\.isEmpty) {
                // From the microphone back to playback only: a fresh engine has no input unit.
                engine.stop()
                engine = AVAudioEngine()
                self.voiceProcessing = false
                tapInstalled = false
            }
            guard voiceProcessing != self.voiceProcessing else { return }
            #if DEBUG
            if Self.isSimulated {
                // The simulated microphone never touches the real input (a Mac build started from
                // a shell can't ask for it).
                self.voiceProcessing = voiceProcessing
                return
            }
            #endif
            let wasRunning = engine.isRunning
            engine.stop()
            removeTap()
            try engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
            self.voiceProcessing = voiceProcessing
            if voiceProcessing {
                // Other apps' audio is lowered, not silenced, while you talk.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .mid)
            }
            // The I/O formats changed: connect the mixer to the new output format.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            if !consumers.withLock(\.isEmpty) { try installTap() }
            if wasRunning || !players.isEmpty { try startLocked() }
        }
    }

    /// Stops everything (the session is being released).
    func stop() {
        lock.withLock {
            engine.stop()
        }
    }

    /// The engine stopped for a hardware change (AirPods connected, a new sample rate): start it
    /// again, with the tap on the new input format.
    func restartAfterConfigurationChange() {
        lock.withLock {
            removeTap()
            if !consumers.withLock(\.isEmpty), usesInput, !Self.isSimulated { try? installTap() }
            if !players.isEmpty || tapInstalled { try? startLocked() }
        }
    }

    /// The media server restarted: everything is gone, so start from a new engine. Holders of the
    /// audio are told (`engineRestarted`) and make their nodes again.
    func rebuild() {
        lock.withLock {
            engine.stop()
            engine = AVAudioEngine()
            voiceProcessing = false
            tapInstalled = false
            players.removeAll()
            sources.removeAll()
            consumers.withLock { $0.removeAll() }
        }
    }

    // MARK: The microphone

    #if DEBUG
    /// Debug: when the simulated microphone's timeline began (system uptime), so scripted words
    /// arrive when their clip is heard, whenever the transcriber joined.
    public var simulatedStart: TimeInterval? {
        lock.withLock { simulated?.start }
    }
    #endif

    /// Debug: spoken clips stand in for the microphone (`-HERMES_VOICE_INPUT`).
    public static var isSimulated: Bool {
        #if DEBUG
        !simulatedInput.isEmpty
        #else
        false
        #endif
    }

    /// The microphone's format, or `nil` when there's no input (no permission, a playback role).
    public var inputFormat: AVAudioFormat? {
        lock.withLock {
            guard usesInput else { return nil }
            #if DEBUG
            if !Self.simulatedInput.isEmpty { return SimulatedMicrophone.format }
            #endif
            let format = engine.inputNode.outputFormat(forBus: 0)
            return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
        }
    }

    /// Feeds every microphone buffer to `consumer` (on an audio thread) until the token is
    /// removed. Starts the engine.
    public func addInputConsumer(_ consumer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) throws -> UUID {
        try lock.withLock {
            guard usesInput else { throw AudioGraphError.noInput }
            let id = UUID()
            consumers.withLock { $0[id] = consumer }
            #if DEBUG
            if !Self.simulatedInput.isEmpty {
                if simulated == nil { simulated = SimulatedMicrophone(clips: Self.simulatedInput, consumers: consumers) }
                return id
            }
            #endif
            if !tapInstalled {
                do {
                    try installTap()
                } catch {
                    consumers.withLock { $0[id] = nil }
                    throw error
                }
            }
            try startLocked()
            return id
        }
    }

    public func removeInputConsumer(_ id: UUID) {
        lock.withLock {
            let empty = consumers.withLock {
                $0[id] = nil
                return $0.isEmpty
            }
            if empty {
                #if DEBUG
                simulated?.stop()
                simulated = nil
                #endif
                removeTap()
                if players.isEmpty { engine.stop() }
            }
        }
    }

    /// Voice processing only: told when the person talks while muted ("You're muted").
    public func setMutedSpeechListener(_ listener: (@Sendable (Bool) -> Void)?) {
        lock.withLock {
            guard voiceProcessing, !Self.isSimulated else { return }
            if let listener {
                _ = engine.inputNode.setMutedSpeechActivityEventListener { event in
                    listener(event == .started)
                }
            } else {
                _ = engine.inputNode.setMutedSpeechActivityEventListener(nil)
            }
        }
    }

    private func installTap() throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioGraphError.noInput }
        Self.installTap(on: node, format: format, consumers: consumers)
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Formed outside any actor: the tap block runs on an audio thread.
    private static func installTap(
        on node: AVAudioInputNode,
        format: AVAudioFormat,
        consumers: OSAllocatedUnfairLock<[UUID: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void]>
    ) {
        node.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: format) { buffer, time in
            let current = consumers.withLock { Array($0.values) }
            for consumer in current { consumer(buffer, time) }
        }
    }

    // MARK: Players

    /// A player for buffers in `format`, through a time-pitch unit (speed without the chipmunk
    /// voice) into the mixer.
    public func makePlayer(format: AVAudioFormat) throws -> AudioPlayerChain {
        try lock.withLock {
            let chain = AudioPlayerChain(format: format, graph: self)
            engine.attach(chain.player)
            engine.attach(chain.pitch)
            // The time-pitch unit doesn't resample: same format in and out, and the mixer
            // converts to the output's rate.
            engine.connect(chain.player, to: chain.pitch, format: format)
            engine.connect(chain.pitch, to: engine.mainMixerNode, format: format)
            players[chain.id] = chain
            try startLocked()
            return chain
        }
    }

    /// A node that renders its own audio (Realtime's playout), into the mixer at `format`.
    public func attachSource(_ node: AVAudioSourceNode, format: AVAudioFormat) throws {
        try lock.withLock {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sources.append(node)
            try startLocked()
        }
    }

    public func detachSource(_ node: AVAudioSourceNode) {
        lock.withLock {
            guard let index = sources.firstIndex(where: { $0 === node }) else { return }
            sources.remove(at: index)
            engine.detach(node)
            if players.isEmpty, sources.isEmpty, !tapInstalled { engine.stop() }
        }
    }

    public func removePlayer(_ chain: AudioPlayerChain) {
        lock.withLock {
            guard players.removeValue(forKey: chain.id) != nil else { return }
            chain.player.stop()
            engine.detach(chain.player)
            engine.detach(chain.pitch)
            if players.isEmpty, sources.isEmpty, !tapInstalled { engine.stop() }
        }
    }

    func startPlayer(_ chain: AudioPlayerChain) throws {
        try lock.withLock {
            guard players[chain.id] != nil else { return }
            try startLocked()
            chain.player.play()
        }
    }

    public var isRunning: Bool { lock.withLock { engine.isRunning } }

    private func startLocked() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }
}

public enum AudioGraphError: Error, Equatable {
    /// There's no microphone input (no permission, or the role doesn't record).
    case noInput
}

/// A player node and its time-pitch unit, with the level of what it's playing.
public final class AudioPlayerChain: @unchecked Sendable {
    public let id = UUID()
    public let format: AVAudioFormat
    let player = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    private weak var graph: AudioGraph?
    private let state = OSAllocatedUnfairLock(initialState: State())

    struct State {
        /// Frames scheduled since the last stop.
        var scheduledFrames: AVAudioFramePosition = 0
        /// Levels of what's scheduled, one per 1/30 s of the timeline, found again by play time.
        var meter = LevelAccumulator()
        /// Where the timeline starts in the file (after a seek), in seconds.
        var offset: TimeInterval = 0
    }

    init(format: AVAudioFormat, graph: AudioGraph) {
        self.format = format
        self.graph = graph
    }

    /// 0.5…2.0, pitch kept.
    public var rate: Float {
        get { pitch.rate }
        set { pitch.rate = max(0.5, min(2, newValue)) }
    }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public var isPlaying: Bool { player.isPlaying }

    /// Queues a buffer after what's queued; `completion` runs when it has played (or was dropped
    /// by a stop).
    public func schedule(_ buffer: AVAudioPCMBuffer, completion: (@Sendable () -> Void)? = nil) {
        let window = max(1, Int(format.sampleRate / 30))
        state.withLock {
            $0.scheduledFrames += AVAudioFramePosition(buffer.frameLength)
            $0.meter.add(buffer, window: window)
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion?() }
    }

    /// Plays `file` from `start` seconds (a voice message), with its levels read as it's scheduled.
    public func schedule(file: AVAudioFile, from start: TimeInterval, completion: (@Sendable () -> Void)? = nil) {
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, start) * rate)
        guard startFrame < file.length else { return }
        state.withLock {
            $0.scheduledFrames = file.length - startFrame
            $0.meter = LevelAccumulator()
            $0.offset = Double(startFrame) / rate
        }
        // A gateway file can claim more than 2^32 frames: play what fits rather than stop the app (F38).
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(clamping: file.length - startFrame), at: nil,
                               completionCallbackType: .dataPlayedBack) { _ in completion?() }
    }

    public func play() throws {
        try graph?.startPlayer(self)
    }

    public func pause() {
        player.pause()
    }

    /// Stops and forgets everything queued.
    public func stop() {
        player.stop()
        state.withLock { $0 = State() }
    }

    /// Fades to silence over `duration` (barge-in: 80 ms), then stops.
    public func fadeOut(over duration: TimeInterval) async {
        let start = player.volume
        let steps = 8
        for step in 1...steps {
            player.volume = start * Float(steps - step) / Float(steps)
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
        }
        stop()
        player.volume = start
    }

    /// Seconds played since the timeline started (plus the seek offset).
    public var currentTime: TimeInterval {
        let offset = state.withLock(\.offset)
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return offset }
        return offset + Double(time.sampleTime) / time.sampleRate
    }

    /// The level of what's playing now, 0…1: what the Bot's face moves with.
    public var currentLevel: Float {
        guard player.isPlaying, let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        let index = Int(Double(time.sampleTime) / time.sampleRate * 30)
        return state.withLock { index >= 0 && index < $0.meter.levels.count ? $0.meter.levels[index] : 0 }
    }

    /// Seconds of audio queued and not yet played.
    public var queuedDuration: TimeInterval {
        let frames = state.withLock(\.scheduledFrames)
        let played: Double
        if let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) {
            played = Double(time.sampleTime)
        } else {
            played = 0
        }
        return max(0, (Double(frames) - played) / format.sampleRate)
    }

}

/// RMS levels per fixed window of a timeline that arrives in buffers of any length.
struct LevelAccumulator {
    private(set) var levels: [Float] = []
    private var sum: Float = 0
    private var count = 0

    mutating func add(_ buffer: AVAudioPCMBuffer, window: Int) {
        let frames = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<frames { add(sample: samples[index], window: window) }
        } else if let samples = buffer.int16ChannelData?[0] {
            for index in 0..<frames { add(sample: Float(samples[index]) / 32768, window: window) }
        }
    }

    mutating func add(sample: Float, window: Int) {
        sum += sample * sample
        count += 1
        if count >= window {
            levels.append(AudioLevel.normalised(rms: (sum / Float(count)).squareRoot()))
            sum = 0
            count = 0
        }
    }
}

/// Loudness of audio buffers, 0…1, as the meters and faces show it.
public enum AudioLevel {
    /// −50…0 dB mapped to 0…1.
    public static func normalised(rms: Float) -> Float {
        normalised(decibels: 20 * log10(max(rms, 0.000_01)))
    }

    public static func normalised(decibels: Float) -> Float {
        max(0, min(1, (decibels + 50) / 50))
    }

    /// RMS per `size` frames of the first channel in dBFS, down to −120: Talk's ears tell the
    /// quiet of a room from the quiet of a pause.
    public static func decibelWindows(of buffer: AVAudioPCMBuffer, size: Int) -> [Float] {
        powerWindows(of: buffer, size: size).map { 10 * log10(max($0, 1e-12)) }
    }

    /// RMS of the whole first channel.
    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        windows(of: buffer, size: Int(buffer.frameLength)).first ?? 0
    }

    /// RMS per `size` frames of the first channel, for float or int16 audio.
    public static func windows(of buffer: AVAudioPCMBuffer, size: Int) -> [Float] {
        powerWindows(of: buffer, size: size).map { normalised(rms: $0.squareRoot()) }
    }

    /// Mean power per `size` frames of the first channel.
    private static func powerWindows(of buffer: AVAudioPCMBuffer, size: Int) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0, size > 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(count / size + 1)
        var start = 0
        while start < count {
            let end = min(count, start + size)
            var sum: Float = 0
            if let samples = buffer.floatChannelData?[0] {
                for index in start..<end { sum += samples[index] * samples[index] }
            } else if let samples = buffer.int16ChannelData?[0] {
                for index in start..<end {
                    let value = Float(samples[index]) / 32768
                    sum += value * value
                }
            }
            result.append(sum / Float(end - start))
            start = end
        }
        return result
    }
}

#if DEBUG
/// Plays clips into the microphone's consumers in real time, 50 ms at a time, with silence
/// between them, as if someone were talking to the device.
final class SimulatedMicrophone: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    private let timer: any DispatchSourceTimer
    private var samples: [Float] = []
    private var position = 0
    /// When the clips' timeline began (system uptime).
    let start = ProcessInfo.processInfo.systemUptime

    init(clips: [(url: URL, at: TimeInterval)], consumers: OSAllocatedUnfairLock<[UUID: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void]>) {
        // One timeline: silence, then each clip at its time.
        var timeline: [Float] = []
        for clip in clips.sorted(by: { $0.at < $1.at }) {
            let offset = Int(clip.at * Self.format.sampleRate)
            if timeline.count < offset { timeline += [Float](repeating: 0, count: offset - timeline.count) }
            timeline += Self.read(clip.url)
        }
        samples = timeline
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "simulated-microphone"))
        let chunk = Int(Self.format.sampleRate / 20)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            buffer.frameLength = AVAudioFrameCount(chunk)
            let out = buffer.floatChannelData![0]
            for index in 0..<chunk {
                let sample = self.position < self.samples.count ? self.samples[self.position] : 0
                // A little room noise, so voice activity has a floor to stand on.
                out[index] = sample + Float.random(in: -0.0005...0.0005)
                self.position += 1
            }
            let time = AVAudioTime(hostTime: mach_absolute_time())
            for consumer in consumers.withLock({ Array($0.values) }) { consumer(buffer, time) }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
    }

    private static func read(_ url: URL) -> [Float] {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio").error("simulated microphone can't read \(url.lastPathComponent, privacy: .public)")
            return []
        }
        guard let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return [] }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var supplied = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
#endif
