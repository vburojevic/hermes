import Foundation
import Testing
@testable import HermesKit

/// Tasks reads its list through `LatestRead` (`docs/tasks.md` §1): when Tasks opens, again as the
/// gateway comes online, and on pull to refresh. The newest read's answer is the one that stands.
@MainActor
struct TasksLoadTests {
    /// A read that waits until the test lets it answer.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            opened = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    struct Offline: Error {}

    /// Lets a read started in another task get under way.
    func untilReading(_ reads: LatestRead<[String]>) async {
        var turns = 0
        while !reads.isReading, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
    }

    @Test func aReadAnswersWithItsValue() async throws {
        let reads = LatestRead<[String]>()
        let result = await reads.read { ["Morning briefing"] }
        #expect(try result?.get() == ["Morning briefing"])
        #expect(!reads.isReading)
    }

    @Test func aFailedReadAnswersWithItsError() async {
        let reads = LatestRead<[String]>()
        let result = await reads.read { throw Offline() }
        guard case .failure(let error)? = result else {
            Issue.record("Expected a failure, got \(String(describing: result))")
            return
        }
        #expect(error is Offline)
    }

    /// Tasks opened before the gateway connected: its read is still on its way when the gateway
    /// comes online and Tasks reads again. The older read gives way, and the newer one's list stands.
    @Test func aNewerReadReplacesTheOneOnItsWay() async throws {
        let reads = LatestRead<[String]>()
        let gate = Gate()
        let older = Task { @MainActor in
            await reads.read {
                await gate.wait()
                try Task.checkCancellation()
                throw Offline()
            }
        }
        await untilReading(reads)
        #expect(reads.isReading)
        let newer = await reads.read { ["Morning briefing", "Nightly backup check"] }
        gate.open()
        #expect(await older.value == nil)
        #expect(try newer?.get() == ["Morning briefing", "Nightly backup check"])
        #expect(!reads.isReading)
    }

    /// The older read ignores cancellation and answers last: its answer still doesn't stand.
    @Test func anOlderAnswerArrivingLastIsDropped() async throws {
        let reads = LatestRead<[String]>()
        let gate = Gate()
        let older = Task { @MainActor in
            await reads.read {
                await gate.wait()
                return []
            }
        }
        await untilReading(reads)
        let newer = await reads.read { ["Morning briefing"] }
        #expect(try newer?.get() == ["Morning briefing"])
        gate.open()
        #expect(await older.value == nil)
        #expect(!reads.isReading)
    }

    /// Tasks closed (or its trigger changed) mid-read: the read is cancelled and answers nothing,
    /// so no "Couldn't load tasks" for a read nobody waits for.
    @Test func aCancelledReadAnswersNothing() async {
        let reads = LatestRead<[String]>()
        let gate = Gate()
        let reading = Task { @MainActor in
            await reads.read {
                await gate.wait()
                try Task.checkCancellation()
                return ["Morning briefing"]
            }
        }
        await untilReading(reads)
        reading.cancel()
        gate.open()
        #expect(await reading.value == nil)
        #expect(!reads.isReading)
    }
}
