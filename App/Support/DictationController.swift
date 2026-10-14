@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

/// On-device speech to text for the composer (`docs/composer.md` §3): the words land in the
/// field as they're heard; nothing is sent until the person sends. `SpeechAnalyzer` with a
/// `DictationTranscriber` (iOS / macOS 26), fed from the microphone through `AVAudioEngine`.
@MainActor
@Observable
final class DictationController {
    enum Mode {
        /// Words for the composer; other audio ducks while the microphone is on.
        case dictation
        /// Voice mode: play and record at once, with echo cancellation so Hermes doesn't hear
        /// itself, and the audio session left active between utterances.
        case conversation
    }

    enum State: Equatable {
        case idle
        /// Asking for permission or fetching the speech model.
        case preparing
        case listening
        /// Microphone or speech recognition is off for Hermes.
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Recent input levels, 0…1, newest last: the live meter (about 20 a second).
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.meterBars)
    private(set) var startedAt: Date?
    /// Finished words so far.
    private(set) var finalized = ""
    /// Words still being heard; they may change.
    private(set) var volatile = ""

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespaces)
    }

    var isActive: Bool { state == .preparing || state == .listening }

    static let meterBars = 24

    let mode: Mode
    /// Voice mode: reply audio through the speaker rather than the earpiece.
    var prefersSpeaker = true {
        didSet {
            guard prefersSpeaker != oldValue, mode == .conversation else { return }
            try? configureAudioSession()
        }
    }
    /// When the words last changed: Voice mode sends after a pause.
    private(set) var lastHeard: Date?

    init(mode: Mode = .dictation) {
        self.mode = mode
    }

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // MARK: Start, finish, cancel

    func start() async {
        guard !isActive else { return }
        state = .preparing
        finalized = ""
        volatile = ""
        levels = Array(repeating: 0, count: Self.meterBars)
        guard await Self.requestPermissions() else {
            state = .denied
            return
        }
        do {
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw DictationError.noAudioFormat
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try configureAudioSession()
            let engine = AVAudioEngine()
            let tap = AudioTap(target: format, continuation: continuation) { [weak self] level in
                Task { @MainActor in self?.push(level) }
            }
            let node = engine.inputNode
            if mode == .conversation {
                // Echo cancellation: what Hermes says doesn't come back as the person's words.
                try? node.setVoiceProcessingEnabled(true)
            }
            Self.installTap(on: node, feeding: tap)
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: stream)

            self.engine = engine
            self.analyzer = analyzer
            self.input = continuation
            startedAt = .now
            state = .listening
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard let self else { return }
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        self.lastHeard = .now
                    }
                } catch {}
            }
        } catch {
            tearDown()
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and waits for the last words. Returns the whole transcript.
    @discardableResult
    func finish() async -> String {
        guard state == .listening else {
            tearDown()
            state = .idle
            return transcript
        }
        stopAudio()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let text = transcript
        tearDown()
        state = .idle
        return text
    }

    func cancel() {
        let analyzer = analyzer
        tearDown()
        state = .idle
        finalized = ""
        volatile = ""
        Task { await analyzer?.cancelAndFinishNow() }
    }

    // MARK: Internals

    private func push(_ level: Float) {
        guard state == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lastHeard = nil
        // Voice mode keeps the session for the reply; `endSession()` releases it.
        if mode == .dictation { endSession() }
    }

    /// Gives the audio back to other apps.
    func endSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func tearDown() {
        stopAudio()
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        startedAt = nil
    }

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .dictation:
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        case .conversation:
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: prefersSpeaker ? [.duckOthers, .defaultToSpeaker] : [.duckOthers])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { return false }
        return await speechAuthorization()
    }

    // The audio thread and the speech framework call these back off the main actor, so the
    // closures must not be main-actor isolated (Swift traps on the mismatch).

    nonisolated private static func speechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func installTap(on node: AVAudioInputNode, feeding tap: AudioTap) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            tap.process(buffer)
        }
    }

    enum DictationError: LocalizedError {
        case noAudioFormat

        var errorDescription: String? {
            String(localized: "Dictation isn't available on this device.")
        }
    }
}

/// Runs on the audio thread: converts microphone buffers to the analyzer's format, feeds them
/// in, and reports the input level.
nonisolated private final class AudioTap: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let report: @Sendable (Float) -> Void
    private var converter: AVAudioConverter?
    private var lastReport = Date.distantPast

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, report: @escaping @Sendable (Float) -> Void) {
        self.target = target
        self.continuation = continuation
        self.report = report
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        meter(buffer)
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    /// Root-mean-square power, mapped from -50…0 dB to 0…1, about 20 times a second.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        let now = Date.now
        guard now.timeIntervalSince(lastReport) >= 0.05, let samples = buffer.floatChannelData?[0] else { return }
        lastReport = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        report(max(0, min(1, (decibels + 50) / 50)))
    }
}
