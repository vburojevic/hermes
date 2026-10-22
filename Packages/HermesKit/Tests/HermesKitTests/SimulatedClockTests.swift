#if DEBUG
import Foundation
import Testing
@testable import HermesKit

/// The simulated microphone's clock (`-HERMES_VOICE_INPUT`, `docs/development.md`): clips and
/// their words count from when listening starts, however long the call took to get there.
@Suite("Simulated microphone: clips and words wait for listening")
struct SimulatedClockTests {
    private let rate = 48_000.0

    @Test func beforeListeningNothingOfTheClipsIsDue() {
        let clock = SimulatedClock(origin: 100)
        // The microphone plays (the room's quiet) from its first consumer…
        #expect(clock.samplesDue(at: 101, sampleRate: rate) == 48_000)
        // …but no clip sample and no word is due yet.
        #expect(clock.timelineIndex(ofSample: 48_000, sampleRate: rate) == nil)
        #expect(clock.wait(until: 2, at: 101) == nil)
    }

    @Test func aSlowEngineStartShiftsClipsAndWordsTogether() {
        var clock = SimulatedClock(origin: 100)
        // The call reaches Listening 12 s after the microphone's first consumer.
        clock.begin(at: 112)
        // The clip at 2 s is heard 2 s after listening started, and its words wait for it.
        let heardAt = 114.0
        let sample = clock.samplesDue(at: heardAt, sampleRate: rate)
        #expect(clock.timelineIndex(ofSample: sample, sampleRate: rate) == 2 * 48_000)
        #expect(clock.uptime(ofSample: sample, sampleRate: rate) == heardAt)
        #expect(clock.wait(until: 2, at: 112.5) == 1.5)
        // Before listening the microphone was quiet: those samples fall before the clips.
        #expect((clock.timelineIndex(ofSample: 48_000, sampleRate: rate) ?? 0) < 0)
    }

    @Test func listeningAgainKeepsTheFirstStart() {
        var clock = SimulatedClock(origin: 100)
        clock.begin(at: 103)
        clock.begin(at: 140)
        #expect(clock.start == 103)
        #expect(clock.wait(until: 12, at: 140) == 0)
    }

    @Test func listeningNeverStartsBeforeTheMicrophone() {
        var clock = SimulatedClock(origin: 100)
        clock.begin(at: 99)
        #expect(clock.start == 100)
    }

    @Test func aLateTimerCatchesUp() {
        let clock = SimulatedClock(origin: 100)
        // A timer that fires 300 ms late still owes all of it, not one 50 ms buffer.
        #expect(clock.samplesDue(at: 100.35, sampleRate: rate) == 16_800)
    }

    @Test func wordsSpreadOverTheirClip() {
        #expect(SimulatedClock.wordTimes(count: 4, clipAt: 2, duration: 2) == [2.5, 3, 3.5, 4])
        #expect(SimulatedClock.wordTimes(count: 0, clipAt: 2, duration: 2).isEmpty)
    }
}
#endif
