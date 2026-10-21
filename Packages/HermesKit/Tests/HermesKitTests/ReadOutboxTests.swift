import Foundation
@testable import HermesKit
import Testing

/// Reads that couldn't reach the gateway wait and go, forward only, and never mark what came after
/// them; a chat that keeps moving on screen is marked at most every 10 s (`docs/inbox.md` §4).
@Suite("Read outbox")
struct ReadOutboxTests {
    private let start = Date(timeIntervalSince1970: 1_792_560_000)

    @Test func aReadThatDidntLandWaitsAndGoesLater() {
        var outbox = ReadOutbox()
        outbox.queue("s1", through: start, now: start)
        #expect(outbox.due(now: start).map(\.key) == ["s1"])
        outbox.failed("s1", now: start)
        #expect(outbox.due(now: start.addingTimeInterval(4)).isEmpty)
        #expect(outbox.due(now: start.addingTimeInterval(5)).map(\.key) == ["s1"])
        outbox.failed("s1", now: start.addingTimeInterval(5))
        outbox.failed("s1", now: start.addingTimeInterval(20))
        #expect(outbox.entries["s1"]?.nextTry == start.addingTimeInterval(20 + 45))
        #expect(ReadOutbox.backoff(after: 10) == 300)
        outbox.sent("s1", through: start)
        #expect(outbox.isEmpty)
    }

    @Test func marksOnlyMoveForward() {
        var outbox = ReadOutbox()
        outbox.queue("bot:ops", through: start.addingTimeInterval(30))
        outbox.queue("bot:ops", through: start)  // an older read changes nothing
        #expect(outbox.entries["bot:ops"]?.through == start.addingTimeInterval(30))
        // An older read landing doesn't clear a newer one still waiting.
        outbox.sent("bot:ops", through: start)
        #expect(outbox.entries["bot:ops"] != nil)
        outbox.queue("bot:ops", through: start.addingTimeInterval(60))
        outbox.sent("bot:ops", through: start.addingTimeInterval(60))
        #expect(outbox.isEmpty)
    }

    /// Hermes stamps a mark "now": sending it after new messages came would mark them read unseen.
    @Test func aReadIsntSentOverNewsThatCameAfterIt() throws {
        var outbox = ReadOutbox()
        outbox.queue("s1", through: start)
        let entry = try #require(outbox.entries["s1"])
        #expect(ReadOutbox.isCurrent(entry, lastActive: start))
        #expect(ReadOutbox.isCurrent(entry, lastActive: start.addingTimeInterval(0.4)))
        #expect(!ReadOutbox.isCurrent(entry, lastActive: start.addingTimeInterval(30)))
        #expect(ReadOutbox.isCurrent(entry, lastActive: nil))
        let coded = try JSONDecoder().decode(ReadOutbox.self, from: JSONEncoder().encode(outbox))
        #expect(coded == outbox)
    }

    @Test func aChatThatKeepsMovingIsMarkedEveryTenSeconds() {
        var throttle = ReadThrottle()
        #expect(throttle.wait(for: "bot:sysadmin", now: start) == 0)
        throttle.sent("bot:sysadmin", at: start)
        #expect(throttle.wait(for: "bot:sysadmin", now: start.addingTimeInterval(3)) == 7)
        #expect(throttle.wait(for: "bot:sysadmin", now: start.addingTimeInterval(12)) == 0)
        #expect(throttle.wait(for: "bot:engineer", now: start.addingTimeInterval(3)) == 0)
    }
}
