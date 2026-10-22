import Foundation
import Testing
@testable import HermesKit

/// Word times after a gap in the microphone (`docs/voice.md` §4.2): a phone call or AirPods
/// connecting must not move the person's words into the past.
@Suite("Analyzer clock: words keep their times across gaps in the microphone")
struct AnalyzerClockTests {
    @Test func withoutGapsTheTimelineIsTheMicrophones() {
        var clock = AnalyzerClock()
        #expect(clock.uptime(atAnalyzerTime: 1) == nil)
        // 100 ms buffers from uptime 500, a little jitter.
        for index in 0..<50 { clock.buffer(at: 500 + Double(index) * 0.1 + (index % 3 == 1 ? 0.01 : 0), fed: Double(index) * 0.1) }
        #expect(abs((clock.uptime(atAnalyzerTime: 3.2) ?? 0) - 503.2) < 0.001)
    }

    @Test func aPhoneCallMovesLaterWordsByItsLengthAndLeavesEarlierOnes() {
        var clock = AnalyzerClock()
        for index in 0..<30 { clock.buffer(at: 100 + Double(index) * 0.1, fed: Double(index) * 0.1) }
        // Two minutes on the phone: the next buffer starts at 223 s, after 3 s fed.
        for index in 0..<20 { clock.buffer(at: 223 + Double(index) * 0.1, fed: 3 + Double(index) * 0.1) }
        // A word said a second after the call, 4 s into the analyzer's timeline.
        #expect(abs((clock.uptime(atAnalyzerTime: 4) ?? 0) - 224) < 0.001)
        // A word from before the call keeps its time.
        #expect(abs((clock.uptime(atAnalyzerTime: 2) ?? 0) - 102) < 0.001)
    }

    @Test func theGatesLookaheadIsTakenOff() {
        var clock = AnalyzerClock(delay: NearGate.delay)
        clock.buffer(at: 10, fed: 0)
        #expect(abs((clock.uptime(atAnalyzerTime: 1) ?? 0) - 10.9) < 0.001)
    }
}
