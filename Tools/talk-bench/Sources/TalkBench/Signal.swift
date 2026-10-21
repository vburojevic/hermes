import AVFoundation
import Foundation

/// Mono 16 kHz audio as floats, and the few things the bench does to it.
struct Signal {
    static let rate = 16_000.0
    var samples: [Float]

    init(samples: [Float]) { self.samples = samples }

    init(silence seconds: Double) {
        samples = [Float](repeating: 0, count: Int(seconds * Self.rate))
    }

    /// A clip from `make-clips.sh`, as 16 kHz mono floats.
    init(contentsOf url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let capacity = AVAudioFrameCount(Double(source.frameLength) * Self.rate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var given = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return source
        }
        samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    var duration: Double { Double(samples.count) / Self.rate }

    /// RMS of the voiced part (frames within 30 dB of the loudest), in dBFS.
    var activeLevel: Float {
        let levels = frameLevels()
        guard let loudest = levels.max() else { return -120 }
        let active = levels.filter { $0 > loudest - 30 }.map { pow(10, $0 / 10) }
        return 10 * log10(active.reduce(0, +) / Float(max(1, active.count)))
    }

    /// Where the sound starts and ends (the first and last 10 ms within 35 dB of the loudest).
    var activeSpan: (start: Double, end: Double) {
        let window = Int(Self.rate / 100)
        var levels: [Float] = []
        for start in stride(from: 0, to: samples.count, by: window) {
            levels.append(Self.level(samples[start..<min(samples.count, start + window)]))
        }
        guard let loudest = levels.max() else { return (0, 0) }
        let first = levels.firstIndex { $0 > loudest - 35 } ?? 0
        let last = levels.lastIndex { $0 > loudest - 35 } ?? 0
        return (Double(first) / 100, Double(last + 1) / 100)
    }

    /// 20 ms RMS levels in dBFS, as the app measures its microphone.
    func frameLevels() -> [Float] {
        let window = Int(Self.rate / 50)
        return stride(from: 0, to: samples.count, by: window).map { Self.level(samples[$0..<min(samples.count, $0 + window)]) }
    }

    static func level(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return -120 }
        let power = slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)
        return 10 * log10(max(power, 1e-12))
    }

    /// Scaled so its voiced part is at `decibels`.
    func scaled(to decibels: Float) -> Signal {
        let gain = pow(10, (decibels - activeLevel) / 20)
        return Signal(samples: samples.map { $0 * gain })
    }

    func gained(_ decibels: Float) -> Signal {
        let gain = pow(10, decibels / 20)
        return Signal(samples: samples.map { $0 * gain })
    }

    /// Adds `other` starting at `seconds`, growing as needed.
    mutating func mix(_ other: Signal, at seconds: Double) {
        let offset = Int(seconds * Self.rate)
        if samples.count < offset + other.samples.count {
            samples += [Float](repeating: 0, count: offset + other.samples.count - samples.count)
        }
        for (index, sample) in other.samples.enumerated() { samples[offset + index] += sample }
    }

    /// The same sound repeated (or cut) to `seconds`.
    func looped(to seconds: Double) -> Signal {
        let count = Int(seconds * Self.rate)
        guard !samples.isEmpty else { return Signal(silence: seconds) }
        return Signal(samples: (0..<count).map { samples[$0 % samples.count] })
    }

    /// A one-pole low pass.
    func lowPassed(_ hertz: Double) -> Signal {
        let alpha = Float(1 - exp(-2 * .pi * hertz / Self.rate))
        var state: Float = 0
        return Signal(samples: samples.map { state += alpha * ($0 - state); return state })
    }

    func highPassed(_ hertz: Double) -> Signal {
        let low = lowPassed(hertz)
        return Signal(samples: zip(samples, low.samples).map { $0 - $1 })
    }

    /// A small room: a few feedback delays, mixed wet, so speech sounds far away.
    func reverberant(_ wet: Float = 0.6) -> Signal {
        var out = samples
        for (delay, feedback) in [(0.029, 0.55), (0.037, 0.5), (0.041, 0.48), (0.053, 0.45)] as [(Double, Float)] {
            let lag = Int(delay * Self.rate)
            var line = samples
            for index in lag..<line.count { line[index] += line[index - lag] * feedback }
            for index in out.indices { out[index] += line[index] * wet / 4 }
        }
        return Signal(samples: out)
    }
}

/// Repeatable noise: every run of the bench hears the same room.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func noise() -> Float { Float.random(in: -1...1, using: &self) }
}
