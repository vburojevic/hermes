import Foundation
import Testing
@testable import HermesKit

@Suite("Turn-taking: voice activity and endpointing")
struct TurnTakingTests {
    /// 20 ms frames: `quiet` then `loud` then `quiet` again, as (rms, time).
    private func frames(_ pattern: [(rms: Float, seconds: Double)], start: TimeInterval = 0) -> [(Float, TimeInterval)] {
        var result: [(Float, TimeInterval)] = []
        var time = start
        for part in pattern {
            let count = Int((part.seconds / 0.02).rounded())
            for _ in 0..<count {
                result.append((part.rms, time))
                time += 0.02
            }
        }
        return result
    }

    @Test func speechIsFoundAboveTheRoomAndEndsAfterAHangover() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        for (rms, time) in frames([(0.002, 1), (0.08, 0.5), (0.002, 0.5)]) {
            if let event = vad.process(rms: rms, at: time) { events.append(event) }
        }
        guard events.count == 2, case .started(let start) = events[0], case .ended(let end) = events[1] else {
            Issue.record("expected a start and an end, got \(events)")
            return
        }
        #expect(abs(start - 1.0) < 0.03)
        #expect(abs(end - 1.48) < 0.03)
    }

    @Test func aNoisyRoomRaisesTheThreshold() {
        var vad = VoiceActivityDetector()
        // A fan: steady noise for two seconds, never speech.
        var events = 0
        for (rms, time) in frames([(0.02, 3)]) where vad.process(rms: rms, at: time) != nil {
            events += 1
        }
        // At most the first moment, before the floor caught up.
        #expect(events <= 2)
        #expect(!vad.isSpeaking)
        #expect(vad.threshold > 0.03)
        // Talking over the fan is still speech.
        var started = false
        for (rms, time) in frames([(0.2, 0.3)], start: 3) where vad.process(rms: rms, at: time) != nil {
            started = true
        }
        #expect(started)
    }

    @Test func aTurnEndsAfterThePauseSetting() {
        var endpointer = Endpointer(pause: .short)
        endpointer.speechStarted(at: 0)
        endpointer.heard("check the NAS", at: 0.8)
        #expect(endpointer.deadline == nil)  // still talking
        endpointer.speechEnded(at: 1.0)
        #expect(endpointer.deadline == 1.6)
        #expect(!endpointer.isComplete(at: 1.5))
        #expect(endpointer.isComplete(at: 1.6))

        var normal = Endpointer(pause: .normal)
        normal.speechStarted(at: 0)
        normal.heard("check the NAS", at: 0.5)
        normal.speechEnded(at: 1.0)
        #expect(normal.deadline == 1.9)
        var long = Endpointer(pause: .long)
        long.heard("check the NAS", at: 1.0)
        #expect(long.deadline == 2.4)
    }

    @Test func anUnfinishedThoughtGetsLonger() {
        var endpointer = Endpointer(pause: .normal)
        endpointer.speechStarted(at: 0)
        endpointer.heard("check the NAS and", at: 0.9)
        endpointer.speechEnded(at: 1.0)
        #expect(endpointer.deadline == 1.0 + 0.9 + 0.4)
        #expect(Endpointer.soundsUnfinished("so um"))
        #expect(Endpointer.soundsUnfinished("Check the NAS, and"))
        #expect(!Endpointer.soundsUnfinished("Check the NAS."))
        #expect(!Endpointer.soundsUnfinished("Is it full?"))
        #expect(!Endpointer.soundsUnfinished("Check the NAS"))
    }

    @Test func wordsArrivingLateMoveTheDeadline() {
        var endpointer = Endpointer(pause: .short)
        endpointer.speechStarted(at: 0)
        endpointer.speechEnded(at: 1.0)
        #expect(endpointer.deadline == nil)  // a cough: no words, no turn
        endpointer.heard("check", at: 1.2)
        #expect(abs((endpointer.deadline ?? 0) - 1.8) < 0.0001)
        endpointer.heard("check the NAS", at: 1.4)
        #expect(abs((endpointer.deadline ?? 0) - 2.0) < 0.0001)
        endpointer.reset()
        #expect(endpointer.deadline == nil)
    }
}
