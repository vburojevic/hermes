@preconcurrency import AVFoundation
import Foundation
import HermesKit
import HermesMarkdown
import NaturalLanguage
import Observation
import os

/// Turns one sentence into audio. The Bot's gateway voice and the device's voice both do.
protocol SentenceVoice: Sendable {
    /// Audio for `text`, in order; the stream ends when the sentence has been synthesised.
    func audio(for text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, any Error>
}

/// The device's own voice (`docs/voice.md` §3: offline, or when the gateway can't speak):
/// `AVSpeechSynthesizer` rendered into buffers with `write(_:toBufferCallback:)`, so it plays on
/// the coordinator's engine (Talk's echo canceller hears it) instead of its own output.
nonisolated final class DeviceVoice: SentenceVoice, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let language: String?

    /// Instant: the voice is looked up on first use, off the main thread, because the list of
    /// voices can take seconds to come (a call froze on it).
    init(language: String?) {
        self.language = language
    }

    func audio(for text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, any Error> {
        let (stream, continuation) = AsyncThrowingStream<AVAudioPCMBuffer, any Error>.makeStream()
        let language = language
        let synthesizer = synthesizer
        let task = Task.detached(priority: .userInitiated) {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.bestVoice(for: language)
            utterance.prefersAssistiveTechnologySettings = true
            guard !Task.isCancelled else {
                continuation.finish()
                return
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // A zero-length buffer ends the utterance.
                    continuation.finish()
                    return
                }
                continuation.yield(pcm)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Voices found, by language: the lookup is slow, the answer doesn't change in a session.
    private static let found = OSAllocatedUnfairLock<[String: AVSpeechSynthesisVoice?]>(initialState: [:])

    /// The best installed voice for a language: Premium, then Enhanced, then the default; the
    /// person's region first. Slow the first time: never call it on the main thread.
    static func bestVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        let code = language ?? String(current.prefix(2))
        if let known = found.withLock({ $0[code] }) { return known }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let best = candidates.max { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue < rhs.quality.rawValue }
            return (lhs.language == current ? 1 : 0) < (rhs.language == current ? 1 : 0)
        }
        let voice = best ?? AVSpeechSynthesisVoice(language: current)
        found.withLock { $0[code] = voice }
        return voice
    }

    /// The language a reply is written in ("en", "hr"), for the device voice.
    static func language(of text: String) -> String? {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
}

/// Plays sentences one after another through a player on the coordinator's engine, fetching the
/// next ones while one plays (`docs/voice.md` §3, §4.2). It knows which sentence is playing (the
/// reply lights it up) and how loud it is (the Bot's face moves with it).
@MainActor
@Observable
final class SpokenPlayer {
    /// The sentence being heard, by its place in what was queued.
    var current: Int? { queue.current }
    private(set) var isSpeaking = false {
        didSet { if isSpeaking != oldValue { onSpeaking?(isSpeaking) } }
    }
    private(set) var isPaused = false
    /// The level of what's playing, 0…1, about 30 times a second while speaking.
    private(set) var level: Float = 0
    /// The sentences queued, read and to read.
    var queued: [SpokenSentence] { queue.sentences }
    /// Where reading is in them, and which sentence the voice is asked for next.
    private var queue = SpokenQueue()
    /// When the first audio of the current run started playing (for the latency overlay).
    private(set) var startedAt: Date?
    /// Lowered while Talk checks whether the person is talking over it (`TalkEars`).
    private(set) var isDucked = false

    var rate: Float = 1 {
        didSet { chain?.rate = rate }
    }

    /// Called when everything queued has played.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Called when a sentence starts playing.
    @ObservationIgnored var onSentence: ((Int) -> Void)?
    /// Called when sound starts or stops (barge-in listens only while it plays).
    @ObservationIgnored var onSpeaking: ((Bool) -> Void)?
    /// Called when the gateway's voice failed and the device's took over, with why
    /// (`docs/voice.md` §6.1: the setup says so until it works again).
    @ObservationIgnored var onFellBack: ((String) -> Void)?

    @ObservationIgnored private var voice: any SentenceVoice
    @ObservationIgnored private let fallback: (any SentenceVoice)?
    @ObservationIgnored private let graph: AudioGraph
    @ObservationIgnored private var chain: AudioPlayerChain?
    @ObservationIgnored private var fetching: Task<Void, Never>?
    @ObservationIgnored private var metering: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Stops under way: what's queued while one fades out is forgotten with the rest.
    @ObservationIgnored private var stopping = 0
    @ObservationIgnored private var inputDone = false
    @ObservationIgnored private let converter = PCMConverter()
    @ObservationIgnored private var ramp: Task<Void, Never>?
    /// About −14 dB: clearly yielding, still there if it was only the room.
    static let duckedVolume: Float = 0.2
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    init(graph: AudioGraph, voice: any SentenceVoice, fallback: (any SentenceVoice)? = nil) {
        self.graph = graph
        self.voice = voice
        self.fallback = fallback
    }

    /// Adds sentences to read after the ones queued.
    func enqueue(_ sentences: [SpokenSentence]) {
        // Words of a reply being talked over still come in during barge-in's fade: never read on.
        guard !sentences.isEmpty, stopping == 0 else { return }
        queue.append(sentences)
        inputDone = false
        pump()
    }

    /// Nothing more will be queued: finish when the last sentence has played.
    func finishInput() {
        inputDone = true
        finishIfDone()
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        chain?.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        try? chain?.play()
        isPaused = false
    }

    /// Lowers the voice at once while Talk listens for words (`TalkEars`), or brings it back.
    func duck(_ on: Bool) {
        guard on != isDucked else { return }
        isDucked = on
        ramp?.cancel()
        guard let chain else { return }
        let from = chain.volume
        let target: Float = on ? Self.duckedVolume : 1
        // Down in 60 ms, so it yields as you start; back up gently.
        let seconds = on ? 0.06 : 0.2
        ramp = Task {
            for step in 1...6 {
                guard !Task.isCancelled else { return }
                chain.volume = from + (target - from) * Float(step) / 6
                try? await Task.sleep(for: .seconds(seconds / 6))
            }
        }
    }

    /// What it's reading and the sentences either side: what its echo could carry.
    var textAround: String {
        guard !queued.isEmpty else { return "" }
        let middle = min(current ?? queued.count - 1, queued.count - 1)
        return queued[max(0, middle - 1)...min(queued.count - 1, middle + 1)].map(\.text).joined(separator: " ")
    }

    /// Stops and forgets what's queued. `fade` is barge-in's 80 ms fade.
    func stop(fade: Bool = false) async {
        stopping += 1
        defer { stopping -= 1 }
        generation += 1
        fetching?.cancel()
        fetching = nil
        metering?.cancel()
        metering = nil
        ramp?.cancel()
        ramp = nil
        if fade, let chain, chain.isPlaying {
            await chain.fadeOut(over: 0.08)
        } else {
            chain?.stop()
        }
        chain?.volume = 1
        isDucked = false
        queue.reset()
        _ = converter.flush()
        isSpeaking = false
        isPaused = false
        level = 0
        startedAt = nil
    }

    /// Lets the player go (the role ended).
    func tearDown() {
        generation += 1
        fetching?.cancel()
        metering?.cancel()
        if let chain { graph.removePlayer(chain) }
        chain = nil
        isSpeaking = false
        level = 0
    }

    /// The engine restarted (a route change, or a media services reset that took the player with
    /// it): what was scheduled is gone, so read on from the sentence that was playing.
    func engineRestarted() {
        if let chain, !graph.contains(chain) {
            self.chain = nil
            metering?.cancel()
            metering = nil
        }
        guard let current else { return }
        let remaining = Array(queued[current...])
        Task {
            await stop()
            enqueue(remaining)
        }
    }

    // MARK: Internals

    private func pump() {
        guard fetching == nil else { return }
        let generation = generation
        fetching = Task { [weak self] in
            // Fetch ahead of what's being heard, but not too far: a sentence ending pumps again.
            while let self, generation == self.generation, let index = self.queue.takeNextToFetch() {
                await self.fetch(index, generation: generation)
            }
            guard let self, generation == self.generation else { return }
            self.fetching = nil
            self.finishIfDone()
        }
    }

    private func fetch(_ index: Int, generation: Int) async {
        let text = queued[index].text
        // The first sentence plays as its audio arrives: that's the latency people hear.
        let streams = index == 0 || current == nil
        var buffers: [AVAudioPCMBuffer] = []
        do {
            for try await buffer in voice.audio(for: text) {
                guard generation == self.generation else { return }
                if streams {
                    schedule([buffer], sentence: index, last: false, generation: generation)
                } else {
                    buffers.append(buffer)
                }
            }
        } catch {
            let failure = error as NSError
            Self.logger.error("voice failed for a sentence: \(failure.domain, privacy: .public) \(failure.code)")
            // The gateway voice failed: this sentence and the rest use the device's voice.
            guard let fallback, generation == self.generation else { return }
            voice = fallback
            onFellBack?(Self.failureSentence(error))
            buffers = []
            do {
                for try await buffer in fallback.audio(for: text) { buffers.append(buffer) }
            } catch {}
        }
        guard generation == self.generation else { return }
        schedule(buffers, sentence: index, last: true, generation: generation)
    }

    /// Why the gateway's voice didn't speak, for the setup: the gateway's own words when it gave any.
    static func failureSentence(_ error: any Error) -> String {
        if case BackendClient.Failure.http(_, let message?) = error, !message.isEmpty {
            return String(localized: "the gateway's voice didn't answer (\(message))")
        }
        return String(localized: "the gateway's voice didn't answer")
    }

    private func schedule(_ buffers: [AVAudioPCMBuffer], sentence: Int, last: Bool, generation: Int) {
        var converted = buffers.compactMap { converter.convert($0, to: Self.format) }
        if last, let tail = converter.flush() { converted.append(tail) }
        guard let chain = ensureChain() else { return }
        if converted.isEmpty, last {
            // Nothing more to hear: a frame of silence marks where the sentence ends.
            let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 1)!
            silence.frameLength = 1
            converted = [silence]
        }
        for (offset, buffer) in converted.enumerated() {
            scheduleBuffer(buffer, chain: chain, sentence: sentence, last: last && offset == converted.count - 1, generation: generation)
        }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, chain: AudioPlayerChain, sentence: Int, last: Bool, generation: Int) {
        if current == nil { begin(sentence) }
        chain.schedule(buffer) { [weak self] in
            guard last else { return }
            Task { @MainActor in self?.sentenceEnded(sentence, generation: generation) }
        }
        if !chain.isPlaying, !isPaused {
            try? chain.play()
            if startedAt == nil { startedAt = .now }
            startMetering()
        }
        isSpeaking = true
    }

    private func begin(_ sentence: Int) {
        if queue.begin(sentence) { onSentence?(sentence) }
    }

    private func sentenceEnded(_ sentence: Int, generation: Int) {
        guard generation == self.generation, current == sentence else { return }
        if let next = queue.ended(sentence) {
            // The next one is already on its way (or queued in the player).
            onSentence?(next)
        } else {
            // Caught up: quiet until more is queued (Talk's reply still streaming, or its next
            // reply) or done.
            isSpeaking = false
            level = 0
            metering?.cancel()
            metering = nil
        }
        pump()
        finishIfDone()
    }

    private func finishIfDone() {
        guard inputDone, current == nil, fetching == nil, queue.isFetched else { return }
        isSpeaking = false
        level = 0
        metering?.cancel()
        metering = nil
        startedAt = nil
        let finished = onFinished
        inputDone = false
        finished?()
    }

    private func ensureChain() -> AudioPlayerChain? {
        if let chain { return chain }
        do {
            chain = try graph.makePlayer(format: Self.format)
        } catch {
            let failure = error as NSError
            Self.logger.error("no player: \(failure.domain, privacy: .public) \(failure.code)")
        }
        chain?.rate = rate
        return chain
    }

    private func startMetering() {
        guard metering == nil else { return }
        metering = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let chain = self.chain else { return }
                let level = chain.currentLevel
                if abs(level - self.level) > 0.01 { self.level = level }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

}

/// Converts synthesiser audio to the player's format, keeping resampling state across the
/// buffers of a sentence so there are no clicks between them.
nonisolated final class PCMConverter {
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || target != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
            if buffer.format.channelCount > 1, format.channelCount == 1 { converter?.channelMap = [0] }
            target = format
        }
        return run(input: buffer, endOfStream: false)
    }

    /// What the converter still holds at the end of a sentence.
    func flush() -> AVAudioPCMBuffer? {
        guard converter != nil else { return nil }
        let tail = run(input: nil, endOfStream: true)
        converter?.reset()
        return tail
    }

    private func run(input: AVAudioPCMBuffer?, endOfStream: Bool) -> AVAudioPCMBuffer? {
        guard let converter, let target else { return nil }
        let frames = Double(input?.frameLength ?? 512)
        let capacity = AVAudioFrameCount((frames * target.sampleRate / converter.inputFormat.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied || input == nil {
                status.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
