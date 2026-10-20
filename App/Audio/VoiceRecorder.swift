@preconcurrency import AVFoundation
import Foundation
import HermesKit
import Observation
import os

/// Records a voice message (`docs/voice.md` §2): hold the microphone, or lock it to record
/// hands-free; pause into Review to listen back and fix the transcript.
///
/// - It holds the coordinator's recording role (`docs/voice.md` §7): a call takes the microphone
///   from it, and the recording pauses into Review.
/// - One input tap feeds the encoder (AAC, 24 kHz mono, about 32 kbps, in `.m4a`), the waveform
///   and the transcriber (`SpeechInput`).
/// - Each stretch of recording is its own file; pausing joins them, so Review and Send always
///   have one.
@MainActor
@Observable
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        /// The microphone and the speech model are coming up; the finger is already down.
        case preparing
        /// Holding the button: let go to send, slide left to cancel, up to lock.
        case holding
        /// Recording hands-free.
        case locked
        /// Paused: play back, scrub, fix the transcript, keep recording or send.
        case review
    }

    /// A finished voice message, ready to send.
    struct Recording {
        var file: URL
        var transcript: String
        var duration: TimeInterval
    }

    private(set) var phase: Phase = .idle
    /// Settled words, then the ones still being heard (drawn lighter).
    private(set) var finalized = ""
    private(set) var volatile = ""
    /// The transcript as fixed in Review; it's what's sent.
    var edited: String?
    /// Words from before Review, when recording carried on after it.
    private(set) var earlierWords = ""
    /// The person fixed the transcript in Review: it's theirs, never rewritten.
    @ObservationIgnored private var isEditedByHand = false
    /// The transcriber joined after recording had started, so it may have missed the first words.
    @ObservationIgnored private var missedWords = false
    @ObservationIgnored private var segmentStartedAt: ContinuousClock.Instant?
    /// The recording's levels so far, about 20 a second.
    private(set) var levels: [Float] = []
    /// Seconds recorded.
    private(set) var duration: TimeInterval = 0
    /// What went wrong, in a sentence; the recording stays.
    private(set) var failure: String?
    /// Review: what's playing back.
    let playback = ClipPlayer()

    /// The words as they stand: fixed in Review, else heard.
    var transcript: String {
        if let edited { return edited }
        return Self.joined(earlierWords, (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Settled words, for drawing: what's before the lighter ones.
    var settled: String {
        Self.joined(earlierWords, finalized.trimmingCharacters(in: .whitespaces))
    }

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .holding || phase == .locked }
    /// 30 seconds left.
    var isNearLimit: Bool { duration >= Self.warning }

    /// Up to 10 minutes; a banner at 9:30 (`docs/voice.md` §2).
    static let limit: TimeInterval = 600
    static let warning: TimeInterval = 570
    /// Shorter than this with no words is a slip, not a message.
    static let minimum: TimeInterval = 0.6

    /// Words to recognise: Bot names, projects, skills.
    @ObservationIgnored var contextualStrings: [String] = []
    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var input: SpeechInput?
    @ObservationIgnored private var writer: VoiceFileWriter?
    @ObservationIgnored private var segments: [URL] = []
    /// Seconds in the segments already closed.
    @ObservationIgnored private var closedDuration: TimeInterval = 0
    @ObservationIgnored private var listeners: Task<Void, Never>?
    @ObservationIgnored private var transcriber: Task<Void, Never>?
    /// Bumped by every stop, so a start still waiting gives up (AGENTS.md).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let id = UUID()

    nonisolated static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")
    /// The speech model, prepared once for the session's language.
    private static var prepared: (configuration: String, value: SpeechInput.Prepared)?

    // MARK: Recording

    /// Starts recording; `locked` starts hands-free (VoiceOver, the Mac's menu). Returns `false`
    /// when the microphone is off for Hermes.
    @discardableResult
    func start(locked: Bool = false) async -> Bool {
        guard phase == .idle else { return true }
        generation += 1
        let attempt = generation
        reset()
        isEditedByHand = false
        missedWords = false
        phase = .preparing
        guard await SpeechInput.requestMicrophone() else {
            if attempt == generation { phase = .idle }
            return false
        }
        guard attempt == generation else { return true }
        await record(attempt: attempt)
        guard attempt == generation, phase == .preparing else { return true }
        phase = locked ? .locked : .holding
        return true
    }

    /// Slid up onto the lock: recording carries on hands-free.
    func lock() {
        guard phase == .holding || phase == .preparing else { return }
        if phase == .holding { phase = .locked } else { lockWhenReady = true }
    }

    @ObservationIgnored private var lockWhenReady = false

    /// Pause opens Review: the recording so far is joined into one file to play back.
    func pause() async {
        guard isRecording || phase == .preparing else { return }
        generation += 1
        await closeSegment()
        await join()
        await recoverMissedWords()
        phase = .review
    }

    /// Review → keep recording, after what's there.
    func resume() async {
        guard phase == .review else { return }
        playback.stop()
        generation += 1
        let attempt = generation
        earlierWords = transcript
        edited = nil
        finalized = ""
        volatile = ""
        phase = .preparing
        await record(attempt: attempt)
        guard attempt == generation, phase == .preparing else { return }
        phase = .locked
    }

    /// Ends the recording. `nil` when it was too short to be a message (under 0.6 s with no words),
    /// or nothing was recorded.
    func finish() async -> Recording? {
        guard phase != .idle else { return nil }
        generation += 1
        playback.stop()
        await closeSegment()
        await join()
        await recoverMissedWords()
        let words = transcript
        let total = duration
        guard let file = segments.first, total >= Self.minimum || !words.isEmpty else {
            discard()
            return nil
        }
        segments = []
        phase = .idle
        return Recording(file: file, transcript: words, duration: total)
    }

    /// Deletes the recording.
    func cancel() {
        generation += 1
        playback.stop()
        let input = input
        let writer = writer
        let lease = lease
        self.input = nil
        self.writer = nil
        self.lease = nil
        listeners?.cancel()
        listeners = nil
        transcriber?.cancel()
        transcriber = nil
        Task {
            await input?.cancel()
            _ = await writer?.close()
            if let lease { await AudioCoordinator.shared.release(lease) }
        }
        discard()
    }

    /// The recording so far, for Review's player.
    var reviewFile: URL? { phase == .review ? segments.first : nil }

    #if DEBUG
    /// The design gallery: a recorder drawn in `phase` without a microphone.
    func stage(_ phase: Phase, settled: String, volatile: String = "", duration: TimeInterval, levels: [Float]) {
        self.phase = phase
        if phase == .review {
            edited = settled
        } else {
            finalized = settled
            self.volatile = volatile
        }
        self.duration = duration
        self.levels = levels
    }
    #endif

    /// Review: the person fixed a word.
    func editTranscript(_ text: String) {
        edited = text
        isEditedByHand = true
    }

    /// The transcriber missed the start: the whole recording, transcribed on the device, if that
    /// gives more words than were heard live.
    private func recoverMissedWords() async {
        guard missedWords, !isEditedByHand, let file = segments.first, !AudioGraph.isSimulated else { return }
        missedWords = false
        let configuration = SpeechInput.Configuration(model: .conversation, locale: TalkPreferences.language ?? .current, contextualStrings: contextualStrings)
        guard let words = try? await SpeechInput.transcribe(file: file, configuration: configuration),
              words.count > transcript.count else { return }
        edited = words
    }

    // MARK: Internals

    private func reset() {
        finalized = ""
        volatile = ""
        edited = nil
        levels = []
        duration = 0
        failure = nil
        segments = []
        closedDuration = 0
        earlierWords = ""
        lockWhenReady = false
    }

    private func discard() {
        for url in segments { try? FileManager.default.removeItem(at: url) }
        segments = []
        phase = .idle
        reset()
    }

    /// Opens a new segment: the recording role, the encoder and the transcriber on one tap. The
    /// recording starts at once; the transcriber joins as soon as its model is ready (the gateway
    /// transcribes what it missed when it heard nothing).
    private func record(attempt: Int) async {
        do {
            let lease = try await AudioCoordinator.shared.acquire(
                .recording, owner: "voice-message",
                options: AudioRoleOptions(highQualityBluetoothRecording: TalkPreferences.studioMic)
            )
            guard attempt == generation else {
                await AudioCoordinator.shared.release(lease)
                return
            }
            let url = VoiceMessageStore.segmentURL()
            let (levels, levelSink) = AsyncStream<VoiceFileWriter.Progress>.makeStream(bufferingPolicy: .bufferingNewest(32))
            let writer = VoiceFileWriter(url: url, progress: levelSink)
            writer.graph = lease.graph
            // Held before anything else is awaited, so a stop meanwhile closes them.
            self.lease = lease
            self.writer = writer
            segments.append(url)
            segmentStartedAt = .now
            writer.consumer = try lease.graph.addInputConsumer { buffer, _ in writer.append(buffer) }
            listeners = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for await progress in levels { await self?.handle(progress) }
                    }
                    group.addTask { [weak self] in
                        for await event in lease.events { await self?.handle(event) }
                    }
                }
            }
            if lockWhenReady {
                lockWhenReady = false
                phase = .locked
            }
            transcriber = Task { [weak self] in await self?.transcribe(on: lease, attempt: attempt) }
        } catch AudioCoordinatorError.busy {
            failure = String(localized: "The microphone is in a call.")
            phase = .idle
        } catch {
            Self.logger.error("voice message didn't start: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            failure = String(localized: "Couldn't start recording. Try again.")
            phase = .idle
        }
    }

    /// Starts the transcriber on the recording's microphone, once its model is ready.
    private func transcribe(on lease: AudioLease, attempt: Int) async {
        guard let speech = await prepareSpeech(), attempt == generation, self.lease === lease else { return }
        let input = SpeechInput(SpeechInput.Configuration(model: .conversation, locale: TalkPreferences.language ?? .current, contextualStrings: contextualStrings))
        do {
            let words = try await input.start(on: lease.graph, prepared: speech)
            guard attempt == generation, self.lease === lease else {
                await input.cancel()
                return
            }
            self.input = input
            if let segmentStartedAt, ContinuousClock.now - segmentStartedAt > .milliseconds(500) { missedWords = true }
            for await event in words {
                handle(event)
            }
        } catch {
            Self.logger.error("voice message transcriber didn't start: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    /// The transcriber, its model installed. `nil` when speech recognition can't run here: the
    /// recording still works, and the gateway transcribes it on Send.
    private func prepareSpeech() async -> SpeechInput.Prepared? {
        let configuration = Self.speechConfiguration
        let key = configuration.locale.identifier
        if let prepared = Self.prepared, prepared.configuration == key { return prepared.value }
        do {
            let value = try await SpeechInput.prepare(configuration) { _ in }
            Self.prepared = (key, value)
            return value
        } catch {
            Self.logger.error("voice message without on-device words: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static var speechConfiguration: SpeechInput.Configuration {
        SpeechInput.Configuration(model: .conversation, locale: TalkPreferences.language ?? .current, contextualStrings: [])
    }

    /// Gets the transcriber ready ahead of the first recording, if its model is already on the
    /// device (nothing is downloaded until the person records).
    static func prewarm() async {
        let configuration = speechConfiguration
        let key = configuration.locale.identifier
        guard prepared?.configuration != key, let value = await SpeechInput.prepareIfInstalled(configuration) else { return }
        prepared = (key, value)
    }

    /// Stops this stretch: the last words settle, the file is finished, the microphone goes back.
    private func closeSegment() async {
        // The transcriber never joined this stretch: its words are only in the file.
        if input == nil, writer != nil { missedWords = true }
        let input = input
        let writer = writer
        let lease = lease
        self.input = nil
        self.writer = nil
        self.lease = nil
        if let input {
            let words = await input.stop()
            if !words.isEmpty {
                finalized = words
                volatile = ""
            }
        }
        listeners?.cancel()
        listeners = nil
        transcriber?.cancel()
        transcriber = nil
        if let writer {
            closedDuration += await writer.close()
            duration = closedDuration
        }
        if let lease { await AudioCoordinator.shared.release(lease) }
        if edited == nil { edited = transcript }
        finalized = ""
        volatile = ""
        earlierWords = ""
    }

    /// One file from the segments recorded so far.
    private func join() async {
        guard segments.count > 1 else { return }
        let parts = segments
        let joined = VoiceMessageStore.segmentURL()
        do {
            try await VoiceFileWriter.join(parts, into: joined)
            for url in parts { try? FileManager.default.removeItem(at: url) }
            segments = [joined]
        } catch {
            Self.logger.error("couldn't join the recording: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func handle(_ progress: VoiceFileWriter.Progress) async {
        guard isRecording || phase == .preparing else { return }
        levels.append(contentsOf: progress.levels)
        duration = closedDuration + progress.seconds
        if duration >= Self.limit {
            // At 10:00 it pauses into Review.
            await pause()
        }
    }

    private func handle(_ event: SpeechInput.Event) {
        switch event {
        case .words(let final, let volatile):
            finalized = final
            self.volatile = volatile
        case .failed(let message):
            Self.logger.error("voice message transcriber stopped: \(message, privacy: .public)")
        case .level, .voice, .unavailable:
            break
        }
    }

    private func handle(_ event: AudioLeaseEvent) async {
        switch event {
        case .paused, .ended:
            // A call or an interruption took the microphone: keep what's there, in Review.
            guard isRecording else { return }
            await pause()
        default:
            break
        }
    }
}

/// Encodes the microphone to AAC as it arrives, off the audio thread, and reports levels and time.
nonisolated final class VoiceFileWriter: @unchecked Sendable {
    struct Progress: Sendable {
        var levels: [Float]
        var seconds: TimeInterval
    }

    private let url: URL
    private let queue = DispatchQueue(label: "co.caffeinatedcode.hermes.voice-writer", qos: .userInitiated)
    private let progress: AsyncStream<Progress>.Continuation
    /// Only touched on `queue`.
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var failed = false
    private var frames: AVAudioFramePosition = 0
    private var meter = LevelWindow()
    var consumer: UUID?
    weak var graph: AudioGraph?

    /// AAC mono at 24 kHz, about 32 kbps (`docs/voice.md` §2).
    static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    init(url: URL, progress: AsyncStream<Progress>.Continuation) {
        self.url = url
        self.progress = progress
    }

    /// From the input tap: copied, then encoded on the writer's queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { self.write(copy) }
    }

    /// Finishes the file. Returns its length in seconds.
    func close() async -> TimeInterval {
        if let consumer { graph?.removeInputConsumer(consumer) }
        consumer = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                let seconds = self.file.map { Double(self.frames) / $0.processingFormat.sampleRate } ?? 0
                self.file?.close()
                self.file = nil
                self.progress.finish()
                continuation.resume(returning: seconds)
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        do {
            if file == nil {
                let file = try AVAudioFile(forWriting: url, settings: Self.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                self.file = file
                converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
                meter = LevelWindow(window: Int(file.processingFormat.sampleRate / 20))
            }
            guard let file, let converter else { return }
            let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            guard output.frameLength > 0 else { return }
            try file.write(from: output)
            frames += AVAudioFramePosition(output.frameLength)
            let levels = meter.add(output)
            progress.yield(Progress(levels: levels, seconds: Double(frames) / file.processingFormat.sampleRate))
        } catch {
            failed = true
            VoiceRecorder.logger.error("voice message encoding failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let data = from.mData, let destination = to.mData else { continue }
            memcpy(destination, data, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// Joins recordings into one `.m4a`, in order.
    @concurrent static func join(_ parts: [URL], into url: URL) async throws {
        var output: AVAudioFile?
        for part in parts {
            let input = try AVAudioFile(forReading: part)
            if output == nil {
                output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            guard let output, let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { continue }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        output?.close()
    }
}

/// Levels per 50 ms of a stream of buffers.
nonisolated struct LevelWindow {
    var window = 1200
    private var sum: Float = 0
    private var count = 0

    init(window: Int = 1200) {
        self.window = max(1, window)
    }

    mutating func add(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        var levels: [Float] = []
        for index in 0..<Int(buffer.frameLength) {
            sum += samples[index] * samples[index]
            count += 1
            if count == window {
                levels.append(AudioLevel.normalised(rms: (sum / Float(count)).squareRoot()))
                sum = 0
                count = 0
            }
        }
        return levels
    }
}

/// Where voice messages live on this device: recordings, and messages fetched from the gateway to
/// play. A message's file is named `voice-<uuid>.m4a` everywhere, so one name finds it.
nonisolated enum VoiceMessageStore {
    static var directory: URL {
        let url = URL.cachesDirectory.appending(path: "VoiceMessages", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stretch of recording, until it's sent.
    static func segmentURL() -> URL {
        URL.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).m4a")
    }

    /// Where a message's audio is kept on this device.
    static func localURL(for path: String) -> URL {
        directory.appending(path: (path as NSString).lastPathComponent)
    }

    /// The audio for `path`, if this device has it.
    static func existing(_ path: String) -> URL? {
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = localURL(for: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps a recording under its message name.
    static func keep(_ recording: URL, as name: String) throws -> URL {
        let target = localURL(for: name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: recording, to: target)
        return target
    }
}
