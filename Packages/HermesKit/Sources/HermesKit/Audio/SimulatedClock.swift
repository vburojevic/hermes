import Foundation

#if DEBUG
/// Debug: the simulated microphone's one clock (`-HERMES_VOICE_INPUT`), shared by its clips and
/// their scripted words.
///
/// The microphone plays from when its first consumer joins (`origin`), but its clips count from
/// when listening starts (`start`): a call can take seconds more to get there (a slow audio engine
/// start on a busy Mac), and a clip played before it would go unheard. Until then the microphone
/// plays the room's quiet.
public struct SimulatedClock: Sendable, Equatable {
    /// When the microphone started playing (system uptime).
    public let origin: TimeInterval
    /// When listening started (system uptime), `nil` until it has.
    public private(set) var start: TimeInterval?

    public init(origin: TimeInterval) {
        self.origin = origin
    }

    /// Listening started at `now`. The first time counts: a call listening again after a reply
    /// carries on along the same clips.
    public mutating func begin(at now: TimeInterval) {
        guard start == nil else { return }
        start = max(now, origin)
    }

    /// How many samples the microphone should have played by `now`, so it keeps time however
    /// late its timer fires.
    public func samplesDue(at now: TimeInterval, sampleRate: Double) -> Int {
        max(0, Int(((now - origin) * sampleRate).rounded()))
    }

    /// When the microphone's `sample`th sample is heard (system uptime).
    public func uptime(ofSample sample: Int, sampleRate: Double) -> TimeInterval {
        origin + Double(sample) / sampleRate
    }

    /// Where the microphone's `sample`th sample falls on the clips' timeline (negative before
    /// listening started), or `nil` while it hasn't.
    public func timelineIndex(ofSample sample: Int, sampleRate: Double) -> Int? {
        guard let start else { return nil }
        return sample - Int(((start - origin) * sampleRate).rounded())
    }

    /// How long until `second` on the clips' timeline (0 once it's passed), or `nil` while
    /// listening hasn't started.
    public func wait(until second: TimeInterval, at now: TimeInterval) -> TimeInterval? {
        guard let start else { return nil }
        return max(0, start + second - now)
    }

    /// When each of a clip's words has been said, on the clips' timeline: spread evenly over the
    /// clip, the last at its end.
    public static func wordTimes(count: Int, clipAt at: TimeInterval, duration: TimeInterval) -> [TimeInterval] {
        guard count > 0 else { return [] }
        return (1...count).map { at + duration * Double($0) / Double(count) }
    }
}
#endif
