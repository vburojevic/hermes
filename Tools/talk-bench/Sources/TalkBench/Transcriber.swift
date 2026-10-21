@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HermesKit
import Speech

/// The words heard so far in this turn, settled and still being heard, each run with its time in
/// the call. Like `SpeechInput`, a turn's end settles its words and starts the next from nothing.
actor Transcript {
    private var final: [HeardWords.Run] = []
    private var volatile: [HeardWords.Run] = []
    /// Results for audio before this belong to a turn already ended.
    private var settledThrough = -1.0
    private var waiter: (through: Double, continuation: CheckedContinuation<Void, Never>)?

    var heard: HeardWords {
        HeardWords(final: final.map(\.text).joined(), volatile: volatile.map(\.text).joined(), runs: final + volatile)
    }

    /// A result: `nil` when it's for a turn already ended.
    func take(_ runs: [HeardWords.Run], isFinal: Bool, rangeEnd: Double) -> HeardWords? {
        guard rangeEnd > settledThrough + 0.01 else { return nil }
        if isFinal {
            final += runs
            volatile.removeAll { $0.end <= rangeEnd + 0.01 }
            if let waiter, rangeEnd >= waiter.through - 0.05 {
                self.waiter = nil
                waiter.continuation.resume()
            }
        } else {
            volatile = runs
        }
        return heard
    }

    /// Waits for the words through `time` to settle (at most 0.4 s), hands them back and starts
    /// the next turn.
    func endTurn(through time: Double) async -> String {
        await withCheckedContinuation { continuation in
            waiter = (time, continuation)
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                self.timeOut()
            }
        }
        let words = heard.text
        final = []
        volatile = []
        settledThrough = time
        return words
    }

    private func timeOut() {
        waiter?.continuation.resume()
        waiter = nil
    }
}

enum TranscriberKind: String {
    case speech, dictation
}

/// The Mac's on-device transcriber, fed in real time, as the app feeds it its microphone.
final class Transcriber: @unchecked Sendable {
    let kind: TranscriberKind
    private let analyzer: SpeechAnalyzer
    private let module: any SpeechModule
    let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputs: AsyncStream<AnalyzerInput>

    static func modules(_ kind: TranscriberKind) async throws -> any SpeechModule {
        let locale = Locale(identifier: "en-US")
        switch kind {
        case .speech:
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                     attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        case .dictation:
            let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
            return DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
    }

    /// How far behind the call the transcriber's audio runs (the gate's lookahead).
    private let shift: Double

    init(kind: TranscriberKind, shift: Double = 0) async throws {
        self.kind = kind
        self.shift = shift
        module = try await Self.modules(kind)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "talk-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no transcriber on this Mac"])
        }
        self.format = format
        analyzer = SpeechAnalyzer(modules: [module], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
    }

    let transcript = Transcript()
    /// Seconds of audio fed.
    private(set) var fed = 0.0

    /// Every change to the transcript, as it arrives.
    func results(_ handle: @escaping @Sendable (HeardWords) async -> Void) -> Task<Void, Never> {
        let module = module
        let transcript = transcript
        let shift = shift
        return Task {
            func runs(of text: AttributedString) -> [HeardWords.Run] {
                text.runs.compactMap { run in
                    guard let range = run.audioTimeRange else { return nil }
                    return HeardWords.Run(text: String(text[run.range].characters), start: range.start.seconds - shift, end: range.end.seconds - shift,
                                          confidence: run.transcriptionConfidence)
                }
            }
            func take(_ text: AttributedString, isFinal: Bool, range: CMTimeRange) async {
                if let heard = await transcript.take(runs(of: text), isFinal: isFinal, rangeEnd: range.end.seconds) {
                    await handle(heard)
                }
            }
            do {
                if let speech = module as? SpeechTranscriber {
                    for try await result in speech.results { await take(result.text, isFinal: result.isFinal, range: result.range) }
                } else if let dictation = module as? DictationTranscriber {
                    for try await result in dictation.results { await take(result.text, isFinal: result.isFinal, range: result.range) }
                }
            } catch {}
        }
    }

    /// 20 ms of the call's microphone.
    func feed(_ samples: ArraySlice<Float>) {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let int16 = buffer.int16ChannelData?[0] {
            for (index, sample) in samples.enumerated() { int16[index] = Int16(max(-1, min(1, sample)) * 32767) }
        } else if let float = buffer.floatChannelData?[0] {
            for (index, sample) in samples.enumerated() { float[index] = sample }
        }
        input.yield(AnalyzerInput(buffer: buffer))
        fed += Double(samples.count) / format.sampleRate
    }

    /// Ends the turn as `SpeechInput.endTurn()` does: finalised through what's been fed.
    func endTurn() async -> String {
        let through = fed
        try? await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 16_000))
        return await transcript.endTurn(through: through)
    }

    func finish() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
    }
}
