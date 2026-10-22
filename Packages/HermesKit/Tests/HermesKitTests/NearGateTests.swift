import Foundation
import Testing
@testable import HermesKit

/// What the transcriber hears while the Bot speaks (`docs/voice.md` §4.2): near sound passes with
/// its soft start, everything else is 40 dB down, and the timeline never moves.
@Suite("Near gate: only the person reaches the transcriber while the Bot speaks")
struct NearGateTests {
    static let rate: Double = 16_000

    /// A tone at `level` dBFS (RMS) between `start` and `end` seconds, `quiet` elsewhere.
    static func signal(seconds: Double, level: Float, from start: Double, to end: Double, quiet: Float = -70) -> [Float] {
        (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            let db = time >= start && time < end ? level : quiet
            // A sine's RMS is its peak over √2.
            let peak = pow(10, db / 20) * Float(2).squareRoot()
            return peak * Float(sin(2 * .pi * 300 * time))
        }
    }

    static func run(_ input: [Float], threshold: Float?) -> [Float] {
        var gate = NearGate(sampleRate: rate)
        gate.threshold = threshold
        var samples = input
        samples.withUnsafeMutableBufferPointer { gate.process($0) }
        return samples
    }

    /// The level (dBFS) of what came out for the input between two times.
    static func level(_ output: [Float], from start: Double, to end: Double) -> Float {
        let delay = Int(NearGate.delay * rate)
        let slice = output[(Int(start * rate) + delay)..<(Int(end * rate) + delay)]
        let mean = slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)
        return 10 * log10(max(mean, 1e-12))
    }

    @Test func openItPassesEverythingExactlyOneDelayLate() {
        let input = Self.signal(seconds: 1, level: -30, from: 0.2, to: 0.6)
        let output = Self.run(input, threshold: nil)
        let delay = Int(NearGate.delay * Self.rate)
        #expect(output.prefix(delay).allSatisfy { $0 == 0 })
        for index in stride(from: 0, to: input.count - delay, by: 97) {
            #expect(abs(output[index + delay] - input[index]) < 1e-6)
        }
    }

    @Test func shutItLowersTheRoomByFortyDecibels() {
        // A TV across the room, under the threshold, the whole time.
        let input = Self.signal(seconds: 2, level: -40, from: 0, to: 2)
        let output = Self.run(input, threshold: -30)
        let heard = Self.level(output, from: 0.5, to: 1.8)
        #expect(abs(heard - -80) < 1.5)
    }

    @Test func aNearWordPassesWithItsSoftStartAndABreathAfter() {
        // The room at -45, the person at -20 from 1.0 to 1.5 s.
        let input = Self.signal(seconds: 3, level: -20, from: 1.0, to: 1.5, quiet: -45)
        let output = Self.run(input, threshold: -30)
        // The word itself, whole.
        #expect(abs(Self.level(output, from: 1.0, to: 1.5) - -20) < 0.5)
        // The lookahead: the 80 ms before it passes too (a word's soft start).
        #expect(Self.level(output, from: 0.92, to: 0.99) > -46)
        // The hangover: 200 ms after it still open, then shut.
        #expect(Self.level(output, from: 1.5, to: 1.7) > -46)
        #expect(Self.level(output, from: 2.0, to: 2.8) < -80)
        // And well before it, shut.
        #expect(Self.level(output, from: 0.2, to: 0.8) < -80)
    }

    @Test func oneLoudClickDoesNotOpenItForLong() {
        // A 10 ms knock at -15 in a quiet room: open for the knock and a breath, no more.
        let input = Self.signal(seconds: 2, level: -15, from: 1.0, to: 1.01, quiet: -45)
        let output = Self.run(input, threshold: -30)
        #expect(Self.level(output, from: 1.4, to: 1.9) < -80)
    }

    @Test func realtimesShorterLookaheadStillKeepsAWordsStart() {
        let input = Self.signal(seconds: 2, level: -20, from: 1.0, to: 1.4, quiet: -45)
        var gate = NearGate(sampleRate: Self.rate, lookahead: NearGate.realtimeLookahead)
        gate.threshold = -30
        var output = input
        output.withUnsafeMutableBufferPointer { gate.process($0) }
        let delay = Int(NearGate.realtimeLookahead * Self.rate)
        #expect(output.prefix(delay).allSatisfy { $0 == 0 })
        // The word, and the 30 ms before it, as they came in, 50 ms late.
        func level(_ start: Double, _ end: Double) -> Float {
            let slice = output[(Int(start * Self.rate) + delay)..<(Int(end * Self.rate) + delay)]
            return 10 * log10(max(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count), 1e-12))
        }
        #expect(abs(level(1.0, 1.4) - -20) < 0.5)
        #expect(level(0.97, 0.99) > -46)
        #expect(level(0.3, 0.8) < -80)
    }

    @Test func int16AudioIsGatedTheSameWay() {
        let floats = Self.signal(seconds: 2, level: -20, from: 1.0, to: 1.4, quiet: -45)
        var samples = floats.map { Int16(max(-32768, min(32767, $0 * 32768))) }
        var gate = NearGate(sampleRate: Self.rate)
        gate.threshold = -30
        samples.withUnsafeMutableBufferPointer { gate.process($0) }
        let output = samples.map { Float($0) / 32768 }
        #expect(abs(Self.level(output, from: 1.0, to: 1.4) - -20) < 0.5)
        #expect(Self.level(output, from: 0.2, to: 0.8) < -75)
    }

    @Test func openingAndShuttingNeverClicks() {
        let input = Self.signal(seconds: 2, level: -20, from: 1.0, to: 1.3, quiet: -45)
        let output = Self.run(input, threshold: -30)
        // The gain moves over about 5 ms: no sample jumps by more than the tone itself can.
        let largest = zip(output, output.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let tone = pow(10, Float(-20) / 20) * Float(2).squareRoot() * Float(2 * Double.pi * 300 / Self.rate)
        #expect(largest <= tone * 1.1)
    }
}
