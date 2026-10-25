@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HermesKit
import os
import Speech

/// On-device speech to text from the coordinator's microphone (`docs/voice.md` §2, §4.2, §5).
///
/// - `SpeechTranscriber` where the device has it, else `DictationTranscriber` (dictation always
///   uses the latter, with punctuation and emoji); `AnalysisContext` carries Bot, project and
///   skill names so they're spelled right.
/// - One analyzer for as long as it runs: Talk ends a turn with `endTurn()` and keeps listening,
///   nothing is rebuilt between turns.
/// - The same microphone buffers give the level (about 20 a second) and 20 ms levels in dBFS
///   (`frames`), which Talk's ears (`TalkEars`) use before any words arrive.
/// - Talk's transcriber hears through a `NearGate`: while the Bot speaks, only sound near the
///   microphone reaches it, so the Bot's echo or a TV never makes it late with your words.
actor SpeechInput {
    enum Model: Sendable {
        /// Talk: `DictationTranscriber` reporting often, with each settled word's time and
        /// confidence (`docs/voice.md` §4.2).
        case conversation
        /// `DictationTranscriber` with punctuation and emoji: words into a field.
        case dictation
    }

    struct Configuration: Sendable {
        var model: Model = .conversation
        var locale: Locale = .current
        /// Words to recognise (Bot names, projects, skills): one or two words each, up to 100.
        var contextualStrings: [String] = []
    }

    enum Event: Sendable {
        /// Words since the last `endTurn()`: settled, then still being heard (they may change),
        /// with each settled word's time (system uptime) for Talk.
        case words(final: String, volatile: String, runs: [HeardWords.Run])
        /// 20 ms levels of the microphone in dBFS, the first starting at `start` (system uptime).
        case frames(start: TimeInterval, levels: [Float])
        /// The microphone's level, 0…1.
        case level(Float)
        /// The analyzer stopped with an error (shown, with Try Again).
        case failed(String)
        /// The gateway can't transcribe live (`GatewayTranscriber`): carry on with the device's.
        case unavailable(String)
    }

    /// The transcriber with its model installed, and the audio format it wants.
    struct Prepared: @unchecked Sendable {
        var modules: [any SpeechModule]
        var format: AVAudioFormat
        /// Debug: the simulated microphone's clips have their words written beside them, for
        /// simulators, which can't run the speech model.
        var scripted = false
    }

    enum Failure: LocalizedError {
        case unsupportedLanguage
        case modelUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: String(localized: "Speech recognition doesn't support this language on this device.")
            case .modelUnavailable: String(localized: "The speech model isn't available yet. Try again in a moment.")
            }
        }
    }

    private let configuration: Configuration
    private var analyzer: SpeechAnalyzer?
    private var modules: [any SpeechModule] = []
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var consumer: UUID?
    private weak var graph: AudioGraph?
    private var feed: InputFeed?
    private var reader: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var finalRuns: [HeardWords.Run] = []
    private var volatileRuns: [HeardWords.Run] = []
    /// Shared with the feed on the audio thread, which may not be made yet.
    private let gateThreshold = OSAllocatedUnfairLock<Float?>(initialState: nil)
    /// Seconds of audio the analyzer has been given, and what's been finalised through.
    private var finalizedThrough = CMTime.zero
    private var finalizationWaiters: [(CMTime, CheckedContinuation<Void, Never>)] = []

    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: Permissions and the model

    /// Microphone permission, asked in context (`docs/voice.md` §8). On-device transcription needs
    /// no speech-recognition permission.
    nonisolated static func requestMicrophone() async -> Bool {
        // The simulated microphone needs no permission (and a Mac build started from a shell
        // can't be given one).
        if AudioGraph.isSimulated { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated static var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// The modules for `configuration`, with their model installed. `progress` reports a download
    /// (0…1) when one is needed.
    /// The transcriber for `configuration`, its model installed and its format settled, before
    /// the session switches to recording (the format can't be worked out against a route with
    /// no input). `progress` reports a download (0…1) when one is needed.
    nonisolated static func prepare(_ configuration: Configuration, progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        let modules = try await modules(for: configuration, progress: progress)
        for attempt in 0..<4 {
            if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
                return Prepared(modules: modules, format: format)
            }
            // Spoken clips bring their own words: no need to wait for a model that isn't coming.
            if AudioGraph.isSimulated { break }
            // A model installed a moment ago can take a little while to report a format.
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
        #if DEBUG
        if !AudioGraph.simulatedInput.isEmpty {
            logger.info("no analyzer format here: the simulated microphone's clips bring their words")
            return Prepared(modules: [], format: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!, scripted: true)
        }
        #endif
        let status = await AssetInventory.status(forModules: modules)
        logger.error("no analyzer format: \(String(describing: modules.first.map { type(of: $0) }), privacy: .public) assets \(String(describing: status), privacy: .public)")
        throw Failure.modelUnavailable
    }

    /// The dictation languages on this device, and the ones it can download.
    nonisolated static func installedDictationLocales() async -> [Locale] {
        await DictationTranscriber.installedLocales
    }

    nonisolated static func supportedDictationLocales() async -> [Locale] {
        await DictationTranscriber.supportedLocales
    }

    /// Like `prepare`, but only when the model is already on the device: nothing is downloaded.
    nonisolated static func prepareIfInstalled(_ configuration: Configuration) async -> Prepared? {
        guard let modules = try? await modules(for: configuration, install: false, progress: { _ in }),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { return nil }
        return Prepared(modules: modules, format: format)
    }

    nonisolated private static func modules(for configuration: Configuration, install: Bool = true, progress: @escaping @Sendable (Double) -> Void) async throws -> [any SpeechModule] {
        let locale = await DictationTranscriber.supportedLocale(equivalentTo: configuration.locale) ?? Locale(identifier: "en-US")
        let transcriber: DictationTranscriber = switch configuration.model {
        case .conversation:
            // Talk: settled often, so a word said over the Bot comes back in about 0.35 s (the
            // general `SpeechTranscriber` reports every second, untimed), with each settled
            // word's time and confidence for `TalkEars` (`docs/voice.md` §4.2, §12).
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization],
                                 attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation, .emoji],
                                 reportingOptions: [.volatileResults], attributeOptions: [])
        }
        let modules: [any SpeechModule] = [transcriber]
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            guard install else { throw Failure.modelUnavailable }
            let watcher = ProgressWatcher(request.progress, report: progress)
            defer { watcher.stop() }
            try await request.downloadAndInstall()
        }
        return modules
    }

    /// The words of a whole recording, on the device: for a voice message whose transcriber
    /// joined after it had started (the model was still getting ready).
    nonisolated static func transcribe(file url: URL, configuration: Configuration) async throws -> String {
        let modules = try await modules(for: configuration, install: false, progress: { _ in })
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: modules)
        if !configuration.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(configuration.contextualStrings.prefix(100))
            try? await analyzer.setContext(context)
        }
        async let words = finalWords(of: modules.first)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func finalWords(of module: (any SpeechModule)?) async throws -> String {
        var words = ""
        if let transcriber = module as? DictationTranscriber {
            for try await result in transcriber.results where result.isFinal { words += String(result.text.characters) }
        }
        return words
    }

    // MARK: Running

    /// Starts listening on `graph`'s microphone. Events arrive until `stop()` or `cancel()`.
    func start(on graph: AudioGraph, prepared: Prepared) async throws -> AsyncStream<Event> {
        #if DEBUG
        if prepared.scripted { return try await startScripted(on: graph, format: prepared.format) }
        #endif
        let modules = prepared.modules
        let format = prepared.format
        let context = AnalysisContext()
        if !configuration.contextualStrings.isEmpty {
            context.contextualStrings[.general] = Array(configuration.contextualStrings.prefix(100))
        }
        let analyzer = SpeechAnalyzer(modules: modules, options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        try? await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (events, eventContinuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let feed = try await InputFeed.make(target: format, modules: modules, analyzer: inputContinuation, events: eventContinuation,
                                            gate: configuration.model == .conversation ? gateThreshold : nil)
        try await analyzer.start(inputSequence: inputs)

        self.analyzer = analyzer
        self.modules = modules
        self.inputContinuation = inputContinuation
        self.eventContinuation = eventContinuation
        self.feed = feed
        self.graph = graph
        finalized = ""
        volatile = ""
        finalRuns = []
        volatileRuns = []
        reader = Task { [weak self] in await self?.read(modules) }
        do {
            consumer = try graph.addInputConsumer { buffer, time in feed.process(buffer, time: time) }
        } catch {
            await cancel()
            throw error
        }
        return events
    }

    /// Ends a spoken turn without stopping: settles the words heard so far and hands them back;
    /// what's said next starts the next turn.
    func endTurn() async -> String {
        guard let feed else { return "" }
        if let analyzer {
            let through = feed.timeFed
            try? await analyzer.finalize(through: through)
            await waitForFinalization(through: through)
        }
        let words = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        finalized = ""
        volatile = ""
        finalRuns = []
        volatileRuns = []
        eventContinuation?.yield(.words(final: "", volatile: "", runs: []))
        return words
    }

    /// Talk: what the transcriber hears while the Bot speaks (`TalkEars.gateThreshold`).
    nonisolated func setGate(_ threshold: Float?) {
        gateThreshold.withLock { $0 = threshold }
    }

    /// Ends a turn whose words won't be used (heard over the Bot without stopping it).
    func dropTurn() async {
        _ = await endTurn()
    }

    /// Words heard since the last turn, without ending it.
    var heard: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops listening and waits for the last words.
    func stop() async -> String {
        detach()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await reader?.value
        } else {
            reader?.cancel()
        }
        let words = heard
        finish()
        return words
    }

    /// Stops at once, dropping what wasn't settled.
    func cancel() async {
        detach()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = analyzer
        reader?.cancel()
        finish()
        await analyzer?.cancelAndFinishNow()
    }

    #if DEBUG
    /// Voice activity and levels from the simulated microphone's audio; the words from the text
    /// beside each clip, appearing as the clip plays.
    private func startScripted(on graph: AudioGraph, format: AVAudioFormat) async throws -> AsyncStream<Event> {
        let (events, eventContinuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (_, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation.finish()
        let feed = try await InputFeed.make(target: format, modules: [], analyzer: inputContinuation, events: eventContinuation)
        self.eventContinuation = eventContinuation
        self.feed = feed
        self.graph = graph
        finalized = ""
        volatile = ""
        consumer = try graph.addInputConsumer { buffer, time in feed.process(buffer, time: time) }
        let clips = AudioGraph.simulatedInput
        reader = Task { [weak self] in
            for clip in clips.sorted(by: { $0.at < $1.at }) {
                guard let text = try? String(contentsOf: clip.url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8),
                      let file = try? AVAudioFile(forReading: clip.url) else { continue }
                let duration = Double(file.length) / file.processingFormat.sampleRate
                let words = text.split(separator: " ")
                let times = SimulatedClock.wordTimes(count: words.count, clipAt: clip.at, duration: duration)
                for (index, at) in times.enumerated() {
                    // Words arrive when their clip is heard: on the microphone's clock, which
                    // starts when listening does.
                    while true {
                        guard !Task.isCancelled else { return }
                        let wait = graph.simulatedClock?.wait(until: at, at: ProcessInfo.processInfo.systemUptime)
                        if wait == 0 { break }
                        // Not listening yet: look again shortly.
                        try? await Task.sleep(for: .seconds(wait ?? 0.05))
                    }
                    await self?.apply(text: AttributedString(words[...index].joined(separator: " ")), isFinal: false, finalizedThrough: .invalid)
                }
                await self?.apply(text: AttributedString(text + " "), isFinal: true, finalizedThrough: .invalid)
            }
        }
        return events
    }
    #endif

    #if DEBUG
    private var echoWords: Task<Void, Never>?

    /// Debug (`-HERMES_SPEAKER_ECHO`): the Bot's sentence heard back from the loudspeaker a word
    /// at a time as it's said, as a transcriber that its echo got past would hear it.
    func hearEcho(_ sentence: String) {
        guard AudioGraph.simulatedEcho != nil, analyzer == nil, feed != nil else { return }
        echoWords?.cancel()
        let words = sentence.split(separator: " ")
        echoWords = Task { [weak self] in
            var said = ""
            for word in words {
                // About as fast as the mock's voice and the device's say it.
                try? await Task.sleep(for: .seconds(Double(word.count + 1) * 0.065))
                guard !Task.isCancelled else { return }
                said += said.isEmpty ? String(word) : " " + word
                await self?.apply(text: AttributedString(said), isFinal: false, finalizedThrough: .invalid)
            }
            guard !Task.isCancelled else { return }
            await self?.apply(text: AttributedString(said + " "), isFinal: true, finalizedThrough: .invalid)
        }
    }

    /// The Bot was stopped: its echo stops too.
    func stopEcho() {
        echoWords?.cancel()
        echoWords = nil
    }
    #endif

    // MARK: Internals

    private func detach() {
        if let consumer { graph?.removeInputConsumer(consumer) }
        consumer = nil
    }

    private func finish() {
        eventContinuation?.finish()
        eventContinuation = nil
        analyzer = nil
        feed = nil
        reader = nil
        for (_, waiter) in finalizationWaiters { waiter.resume() }
        finalizationWaiters = []
    }

    private func read(_ modules: [any SpeechModule]) async {
        do {
            if let transcriber = modules.first as? DictationTranscriber {
                for try await result in transcriber.results {
                    apply(text: result.text, isFinal: result.isFinal, finalizedThrough: result.resultsFinalizationTime)
                }
            }
        } catch is CancellationError {
        } catch {
            let code = (error as NSError).code
            Self.logger.error("speech analysis failed: \((error as NSError).domain, privacy: .public) \(code)")
            eventContinuation?.yield(.failed(error.localizedDescription))
        }
    }

    private func apply(text attributed: AttributedString, isFinal: Bool, finalizedThrough time: CMTime) {
        let text = String(attributed.characters)
        let runs = runs(of: attributed)
        if isFinal {
            finalized += text
            volatile = ""
            finalRuns += runs
            volatileRuns = []
        } else {
            volatile = text
            volatileRuns = runs
        }
        if time.isValid, time > finalizedThrough { finalizedThrough = time }
        eventContinuation?.yield(.words(final: finalized, volatile: volatile, runs: finalRuns + volatileRuns))
        let ready = finalizationWaiters.filter { finalizedThrough >= $0.0 }
        finalizationWaiters.removeAll { finalizedThrough >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    /// Each run of words with its time on the microphone's clock and the transcriber's confidence,
    /// when it gives them (Talk's settled words).
    private func runs(of text: AttributedString) -> [HeardWords.Run] {
        guard let feed else { return [] }
        return text.runs.compactMap { run in
            guard let range = run.audioTimeRange, let start = feed.uptime(atAnalyzerTime: range.start.seconds),
                  let end = feed.uptime(atAnalyzerTime: range.end.seconds) else { return nil }
            return HeardWords.Run(text: String(text[run.range].characters), start: start, end: end, confidence: run.transcriptionConfidence)
        }
    }

    /// Waits until results finalised through `time` have arrived, at most 0.4 s (silence gives
    /// no result to wait for).
    private func waitForFinalization(through time: CMTime) async {
        guard finalizedThrough < time else { return }
        await withCheckedContinuation { continuation in
            finalizationWaiters.append((time, continuation))
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                await self?.releaseWaiters()
            }
        }
    }

    private func releaseWaiters() {
        for (_, waiter) in finalizationWaiters { waiter.resume() }
        finalizationWaiters = []
    }
}

/// Runs on the audio thread: converts microphone buffers to the analyzer's format and feeds
/// them in, and measures their levels on the way.
nonisolated final class InputFeed: @unchecked Sendable {
    private let target: AVAudioFormat
    private let analyzer: AsyncStream<AnalyzerInput>.Continuation
    private let events: AsyncStream<SpeechInput.Event>.Continuation
    private var converter: AVAudioConverter?
    private let modernConverter: AnyObject?
    private var lastLevel: TimeInterval = 0
    private let fed = OSAllocatedUnfairLock(initialState: CMTime.zero)
    /// Where the analyzer's timeline sits in system uptime, across gaps in the microphone, so its
    /// word times can be placed.
    private let clock: OSAllocatedUnfairLock<AnalyzerClock>
    /// Talk: the analyzer hears through a `NearGate`, whose threshold Talk's ears set.
    private let gateThreshold: OSAllocatedUnfairLock<Float?>?
    private var gate: NearGate?

    /// No analyzer to feed (the simulator's scripted words, the gateway's transcriber): levels only.
    private let scriptedOnly: Bool

    private init(target: AVAudioFormat, modernConverter: AnyObject?, analyzer: AsyncStream<AnalyzerInput>.Continuation,
                 events: AsyncStream<SpeechInput.Event>.Continuation, scriptedOnly: Bool, gate: OSAllocatedUnfairLock<Float?>?) {
        self.target = target
        self.modernConverter = modernConverter
        self.scriptedOnly = scriptedOnly
        self.analyzer = analyzer
        self.events = events
        gateThreshold = gate
        if gate != nil { self.gate = NearGate(sampleRate: target.sampleRate) }
        clock = OSAllocatedUnfairLock(initialState: AnalyzerClock(delay: gate == nil ? 0 : NearGate.delay))
    }

    static func make(target: AVAudioFormat, modules: [any SpeechModule], analyzer: AsyncStream<AnalyzerInput>.Continuation,
                     events: AsyncStream<SpeechInput.Event>.Continuation, gate: OSAllocatedUnfairLock<Float?>? = nil) async throws -> InputFeed {
        var modern: AnyObject?
        if #available(iOS 27, macOS 27, *), !modules.isEmpty, gate == nil {
            // 27 converts for the analyzer itself, keeping its timeline exact. A gated feed
            // converts itself, as it changes the samples on the way.
            modern = try? await AnalyzerInputConverter.converter(compatibleWith: modules)
        }
        return InputFeed(target: target, modernConverter: modern, analyzer: analyzer, events: events, scriptedOnly: modules.isEmpty, gate: gate)
    }

    /// How much audio the analyzer has had, on its own timeline.
    var timeFed: CMTime { fed.withLock { $0 } }

    /// A time on the analyzer's timeline as system uptime: when it was said.
    func uptime(atAnalyzerTime seconds: Double) -> TimeInterval? {
        clock.withLock { $0.uptime(atAnalyzerTime: seconds) }
    }

    func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let start = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
        measure(buffer, start: start)
        guard !scriptedOnly else { return }
        let fed = timeFed.seconds
        clock.withLock { $0.buffer(at: start, fed: fed) }
        if #available(iOS 27, macOS 27, *), let modern = modernConverter as? AnalyzerInputConverter {
            guard let inputs = try? modern.convert(buffer, at: nil) else { return }
            for input in inputs { yield(input, frames: input.bufferDuration) }
            return
        }
        guard let output = convert(buffer) else { return }
        if gate != nil {
            gate?.threshold = gateThreshold?.withLock { $0 }
            let count = Int(output.frameLength)
            if let samples = output.floatChannelData?[0] {
                gate?.process(UnsafeMutableBufferPointer(start: samples, count: count))
            } else if let samples = output.int16ChannelData?[0] {
                gate?.process(UnsafeMutableBufferPointer(start: samples, count: count))
            }
        }
        yield(AnalyzerInput(buffer: output), frames: CMTime(value: CMTimeValue(output.frameLength), timescale: CMTimeScale(target.sampleRate)))
    }

    private func yield(_ input: AnalyzerInput, frames duration: CMTime) {
        fed.withLock { $0 = $0 + duration }
        analyzer.yield(input)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
            // Voice processing can hand over several channels: the first one is the voice.
            if buffer.format.channelCount > 1, target.channelCount == 1 { converter?.channelMap = [0] }
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// The meter's level about 20 times a second, and every 20 ms in dBFS for Talk's ears.
    private func measure(_ buffer: AVAudioPCMBuffer, start: TimeInterval) {
        let rate = buffer.format.sampleRate
        let window = max(1, Int(rate / 50))
        let decibels = AudioLevel.decibelWindows(of: buffer, size: window)
        guard !decibels.isEmpty else { return }
        events.yield(.frames(start: start, levels: decibels))
        for (index, level) in decibels.enumerated() {
            let at = start + Double(index * window) / rate
            if at - lastLevel >= 0.05 {
                lastLevel = at
                events.yield(.level(AudioLevel.normalised(decibels: level)))
            }
        }
    }
}

/// Reports a download's progress until stopped.
nonisolated private final class ProgressWatcher: @unchecked Sendable {
    private var observation: NSKeyValueObservation?

    init(_ progress: Progress, report: @escaping @Sendable (Double) -> Void) {
        report(progress.fractionCompleted)
        observation = progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}
