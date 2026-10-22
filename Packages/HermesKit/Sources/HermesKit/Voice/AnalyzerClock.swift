import Foundation

/// Places the transcriber's word times on the clock Talk's ears use (system uptime,
/// `docs/voice.md` §4.2).
///
/// The analyzer's timeline is the audio it was fed, back to back. The microphone's isn't: a phone
/// call, Siri or the engine restarting for AirPods leaves a gap the analyzer never hears. Placed
/// from where the call started, every word said after it would land that much in the past, where
/// the ears find no voice and take the person's words for the room's. So each stretch of audio
/// keeps its own origin.
public struct AnalyzerClock: Sendable {
    /// A gap shorter than this is the audio thread's jitter, not a pause in the microphone.
    public static let smallestGap: TimeInterval = 0.25

    /// Each stretch: where it starts on the analyzer's timeline, and that timeline's origin
    /// (uptime) for it. The newest few; words come back within seconds.
    private var stretches: [(from: TimeInterval, origin: TimeInterval)] = []
    /// The audio that comes out this late (a `NearGate`'s lookahead).
    public let delay: TimeInterval

    public init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    /// A buffer that started at `start` (uptime) arrives, after `fed` seconds of audio have gone
    /// to the analyzer.
    public mutating func buffer(at start: TimeInterval, fed: TimeInterval) {
        guard let last = stretches.last else {
            stretches = [(fed, start - fed)]
            return
        }
        let gap = start - (last.origin + fed)
        guard gap >= Self.smallestGap else { return }
        stretches.append((fed, last.origin + gap))
        if stretches.count > 8 { stretches.removeFirst() }
    }

    /// When something the analyzer heard at `seconds` on its timeline was said.
    public func uptime(atAnalyzerTime seconds: TimeInterval) -> TimeInterval? {
        guard let stretch = stretches.last(where: { $0.from <= seconds }) ?? stretches.first else { return nil }
        return stretch.origin + seconds - delay
    }
}
