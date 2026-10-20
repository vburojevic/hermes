@preconcurrency import AVFoundation
import Foundation
import HermesKit
import os
import Speech

/// What Talk hears words with: the device (`SpeechInput`) or the gateway (`GatewayTranscriber`).
protocol TalkTranscriber: Actor {
    /// Settles the turn's words and hands them back; what's said next starts the next turn.
    func endTurn() async -> String
    /// Ends a turn whose words won't be used (heard over the Bot without stopping it).
    func dropTurn() async
    /// Stops at once, dropping what wasn't settled.
    func cancel() async
}

extension SpeechInput: TalkTranscriber {}

/// Talk's words from the gateway (`docs/voice.md` §4.2, Transcribe on: The gateway). The device
/// still hears when the person speaks and decides when a turn ends; each turn streams to
/// `transcribe-stream` from half a second before they started, one socket per turn, as Hermes
/// wants it.
///
/// - A turn the gateway couldn't finish live goes to `POST /api/audio/transcribe` whole, as Hermes
///   Desktop does.
/// - When the gateway can't transcribe live at all ("no live STT for the configured provider"),
///   or two turns in a row fail, `unavailable` tells Talk to carry on with the device's.
actor GatewayTranscriber: TalkTranscriber {
    static let sampleRate = 16_000
    /// Kept from before the person starts, so the first word isn't clipped: half a second.
    private static let preroll = sampleRate
    /// A turn's audio kept for the whole-turn fallback: a minute at most.
    private static let turnLimit = sampleRate * 2 * 60
    /// How long to wait for the gateway's final words after the turn ends.
    private static let finalWait: Duration = .seconds(10)
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    private enum Turn {
        case idle
        /// Connecting: audio waits in `pending`.
        case opening
        case open(TranscribeStream)
        /// The socket couldn't open or broke: the turn goes whole at its end.
        case broken(String)
    }

    private let backend: BackendClient
    private let profile: String?
    private var graph: AudioGraph?
    private var consumer: UUID?
    private var events: AsyncStream<SpeechInput.Event>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var turn = Turn.idle
    private var reader: Task<Void, Never>?
    /// The last half second while no turn is open.
    private var recent = Data()
    /// Audio for a socket still connecting.
    private var pending = Data()
    private var turnAudio = Data()
    private var outcome: TranscribeStream.Event?
    private var waiter: CheckedContinuation<Void, Never>?
    /// Which wait a timeout belongs to: a late one never ends the next turn's.
    private var waits = 0
    private var failures = 0
    private var gaveUp = false

    init(backend: BackendClient, profile: String?) {
        self.backend = backend
        self.profile = profile
    }

    /// Starts listening on `graph`'s microphone: level and voice activity from the device, words
    /// from the gateway.
    func start(on graph: AudioGraph) async throws -> AsyncStream<SpeechInput.Event> {
        let (activity, activityContinuation) = AsyncStream<SpeechInput.Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (events, eventContinuation) = AsyncStream<SpeechInput.Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (_, analyzer) = AsyncStream<AnalyzerInput>.makeStream()
        analyzer.finish()
        // No analyzer to feed: the feed only measures level and voice activity.
        let feed = try await InputFeed.make(target: PCM16Converter.format, modules: [], analyzer: analyzer, events: activityContinuation)
        let (audio, audioContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let converter = PCM16Converter()
        self.events = eventContinuation
        self.graph = graph
        consumer = try graph.addInputConsumer { buffer, time in
            feed.process(buffer, time: time)
            if let pcm = converter.convert(buffer) { audioContinuation.yield(pcm) }
        }
        tasks = [
            Task { [weak self] in
                for await event in activity { await self?.handle(event) }
            },
            Task { [weak self] in
                for await pcm in audio { await self?.take(pcm) }
            },
        ]
        return events
    }

    func endTurn() async -> String {
        var words = ""
        switch turn {
        case .idle:
            break
        case .opening, .broken:
            words = await wholeTurn(failure: nil)
        case .open(let stream):
            try? await stream.finish()
            if outcome == nil { await waitForOutcome() }
            switch outcome {
            case .final(let text)?:
                failures = 0
                words = text
            case .failed(let message)?:
                words = await wholeTurn(failure: message)
            case .partial?, nil:
                words = await wholeTurn(failure: String(localized: "The gateway didn't finish the words in time."))
            }
        }
        closeTurn()
        events?.yield(.words(final: "", volatile: ""))
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dropTurn() async {
        closeTurn()
        events?.yield(.words(final: "", volatile: ""))
    }

    func cancel() async {
        if let consumer { graph?.removeInputConsumer(consumer) }
        consumer = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        closeTurn()
        events?.finish()
        events = nil
    }

    // MARK: Internals

    private func handle(_ event: SpeechInput.Event) {
        events?.yield(event)
        if case .voice(.started) = event, case .idle = turn, !gaveUp {
            // Connecting mustn't hold up the voice activity endpointing waits for.
            turn = .opening
            turnAudio = recent
            pending = recent
            recent = Data()
            outcome = nil
            Task { await connect() }
        }
    }

    private func take(_ pcm: Data) async {
        switch turn {
        case .idle:
            recent.append(pcm)
            if recent.count > Self.preroll { recent.removeFirst(recent.count - Self.preroll) }
        case .opening:
            pending.append(pcm)
            keep(pcm)
        case .open(let stream):
            keep(pcm)
            do {
                try await stream.send(pcm)
            } catch {
                broke(error)
            }
        case .broken:
            keep(pcm)
        }
    }

    private func keep(_ pcm: Data) {
        guard turnAudio.count < Self.turnLimit else { return }
        turnAudio.append(pcm)
    }

    private func connect() async {
        do {
            let stream = try await backend.transcribeStream(profile: profile)
            guard case .opening = turn else {
                await stream.cancel()
                return
            }
            try await stream.start(sampleRate: Self.sampleRate)
            read(stream)
            // What arrived while connecting goes first; more may arrive while it's sent.
            while !pending.isEmpty {
                let chunk = pending
                pending = Data()
                try await stream.send(chunk)
            }
            guard case .opening = turn else {
                await stream.cancel()
                return
            }
            turn = .open(stream)
        } catch {
            guard case .opening = turn else { return }
            broke(error)
        }
    }

    private func broke(_ error: any Error) {
        Self.logger.error("live transcription broke: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        if case .open(let stream) = turn { Task { await stream.cancel() } }
        pending = Data()
        turn = .broken(String(localized: "The connection to the gateway dropped."))
    }

    private func read(_ stream: TranscribeStream) {
        reader?.cancel()
        reader = Task { [weak self] in
            do {
                for try await event in stream.events() {
                    await self?.received(event, from: stream)
                }
            } catch {}
            await self?.closed(stream)
        }
    }

    private func received(_ event: TranscribeStream.Event, from stream: TranscribeStream) async {
        guard isCurrent(stream) else { return }
        switch event {
        case .partial(let text):
            events?.yield(.words(final: "", volatile: text))
        case .final, .failed:
            outcome = event
            if case .failed(let message) = event, Self.isUnavailable(message) {
                giveUp(message)
            }
            releaseWaiter()
        }
    }

    private func closed(_ stream: TranscribeStream) {
        guard isCurrent(stream), outcome == nil else { return }
        outcome = .failed(String(localized: "The gateway closed the connection."))
        releaseWaiter()
    }

    private func isCurrent(_ stream: TranscribeStream) -> Bool {
        if case .open(let current) = turn { return current === stream }
        if case .opening = turn { return true }
        return false
    }

    private func waitForOutcome() async {
        waits += 1
        let wait = waits
        await withCheckedContinuation { continuation in
            waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: Self.finalWait)
                await self?.timedOut(wait)
            }
        }
    }

    private func timedOut(_ wait: Int) {
        guard wait == waits else { return }
        releaseWaiter()
    }

    private func releaseWaiter() {
        waiter?.resume()
        waiter = nil
    }

    /// The turn's audio as one file, when the live words didn't come.
    private func wholeTurn(failure: String?) async -> String {
        let reason = failure ?? {
            if case .broken(let why) = turn { return why }
            return String(localized: "The gateway didn't answer.")
        }()
        // Less than a third of a second is a cough, not a turn.
        guard turnAudio.count > Self.sampleRate * 2 / 3 else { return "" }
        do {
            let words = try await backend.transcribe(WAVFile.make(pcm: turnAudio, sampleRate: Self.sampleRate), mimeType: "audio/wav", profile: profile)
            failures = 0
            return words
        } catch {
            Self.logger.error("whole-turn transcription failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            failures += 1
            if failures >= 2 { giveUp(reason) }
            return ""
        }
    }

    private func giveUp(_ reason: String) {
        guard !gaveUp else { return }
        gaveUp = true
        events?.yield(.unavailable(reason))
    }

    private func closeTurn() {
        if case .open(let stream) = turn { Task { await stream.cancel() } }
        reader?.cancel()
        reader = nil
        turn = .idle
        pending = Data()
        turnAudio = Data()
        outcome = nil
        releaseWaiter()
    }

    /// Hermes's words for a gateway that can't transcribe live at all (a provider without
    /// streaming, a missing key, `stt.streaming` off).
    static func isUnavailable(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("no live STT")
    }
}

/// Runs on the audio thread: the microphone's buffers as 16 kHz little-endian int16 mono.
nonisolated final class PCM16Converter: @unchecked Sendable {
    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(GatewayTranscriber.sampleRate), channels: 1, interleaved: true)!
    }
    private var converter: AVAudioConverter?

    private let target = PCM16Converter.format

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
            // Voice processing can hand over several channels: the first one is the voice.
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate).rounded(.up)) + 16
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
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}
