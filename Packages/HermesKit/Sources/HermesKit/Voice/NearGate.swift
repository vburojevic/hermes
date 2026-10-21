import Foundation

/// What the transcriber hears while the Bot speaks (`docs/voice.md` §4.2): only sound near the
/// microphone, so the Bot's echo, a TV or a room of people talking never reach it.
///
/// A transcriber hearing the Bot's echo or a TV takes it for one long utterance and reports a
/// word said over it seconds late, or not at all; heard alone, "stop" comes back in about 0.35 s.
/// So while the gate is closed (`threshold` set) everything quieter than the threshold is
/// lowered by 40 dB, and it opens for sound above it with a little lookahead (the start of a
/// word is quieter than its middle) and holds open for a breath after.
///
/// The audio comes out `delay` late, always, so the transcriber's timeline never jumps.
/// Runs on the audio thread: no locks, no allocation after the first buffer.
public struct NearGate: Sendable {
    /// Lookahead: the output runs this far behind the input.
    public static let delay: TimeInterval = 0.1
    /// Open this long after the last near sound.
    public static let hangover: TimeInterval = 0.25
    private static let closedGain: Float = 0.01
    private static let window: TimeInterval = 0.01

    /// dBFS: sound above this opens the gate. `nil`: open, everything passes (the person's turn).
    public var threshold: Float?

    public let sampleRate: Double
    private var line: [Float]
    private var position = 0
    /// Input samples seen, and the gate's state in input samples.
    private var written = 0
    private var openUntil = Int.min
    private var gain: Float = 1
    private let delaySamples: Int
    private let windowSamples: Int
    private var windowSum: Float = 0
    private var windowCount = 0
    private let step: Float

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        delaySamples = max(1, Int(Self.delay * sampleRate))
        windowSamples = max(1, Int(Self.window * sampleRate))
        line = [Float](repeating: 0, count: delaySamples)
        // About 5 ms from shut to open, so nothing clicks.
        step = Float(1 / (0.005 * sampleRate))
    }

    /// Is the sample about to come out inside an open stretch?
    private var isOpen: Bool {
        threshold == nil || written - delaySamples < openUntil
    }

    /// Passes `samples` through: each comes out `delay` later, lowered while the gate is shut.
    public mutating func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        for index in samples.indices {
            let sample = samples[index]
            measure(sample)
            let target: Float = isOpen ? 1 : Self.closedGain
            if gain < target { gain = min(target, gain + step) } else if gain > target { gain = max(target, gain - step) }
            samples[index] = line[position] * gain
            line[position] = sample
            position = (position + 1) % delaySamples
            written += 1
        }
    }

    /// Int16 audio, the same way.
    public mutating func process(_ samples: UnsafeMutableBufferPointer<Int16>) {
        for index in samples.indices {
            let sample = Float(samples[index]) / 32768
            measure(sample)
            let target: Float = isOpen ? 1 : Self.closedGain
            if gain < target { gain = min(target, gain + step) } else if gain > target { gain = max(target, gain - step) }
            samples[index] = Int16(max(-32768, min(32767, line[position] * gain * 32768)))
            line[position] = sample
            position = (position + 1) % delaySamples
            written += 1
        }
    }

    private mutating func measure(_ sample: Float) {
        windowSum += sample * sample
        windowCount += 1
        guard windowCount >= windowSamples else { return }
        let level = 10 * log10(max(windowSum / Float(windowCount), 1e-12))
        windowSum = 0
        windowCount = 0
        guard let threshold, level >= threshold else { return }
        // Open now, which is the lookahead before this window in what comes out, until a breath
        // after it.
        openUntil = max(openUntil, written + Int(Self.hangover * sampleRate))
    }
}
