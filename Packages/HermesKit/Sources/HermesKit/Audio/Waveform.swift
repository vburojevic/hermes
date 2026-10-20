@preconcurrency import AVFoundation
import Foundation

/// The bars a voice message or a listen strip draws (`blocks/audio.elyx`): levels 0…1, one per
/// bar, from a recording's live levels or read from a file.
public enum Waveform {
    /// `levels` squeezed or stretched to `count` bars. Each bar is the loudest level in its share
    /// of the timeline, so a short word still shows.
    public static func bars(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !levels.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { bar in
            let start = bar * levels.count / count
            let end = max(start + 1, (bar + 1) * levels.count / count)
            return levels[min(start, levels.count - 1)..<min(end, levels.count)].max() ?? 0
        }
    }

    /// Levels of `url`, about `perSecond` a second, and its length in seconds.
    public static func levels(of url: URL, perSecond: Double = 20) throws -> (levels: [Float], duration: TimeInterval) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let window = AVAudioFrameCount(min(max(1, format.sampleRate / perSecond), 1_000_000))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window * 16) else { return ([], 0) }
        var levels: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            var offset = 0
            while offset < Int(buffer.frameLength) {
                let end = min(Int(buffer.frameLength), offset + Int(window))
                var sum: Float = 0
                for index in offset..<end { sum += samples[index] * samples[index] }
                levels.append(AudioLevel.normalised(rms: (sum / Float(end - offset)).squareRoot()))
                offset = end
            }
        }
        return (levels, Double(file.length) / format.sampleRate)
    }

    /// "0:07", "1:23", "10:00".
    public static func time(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
