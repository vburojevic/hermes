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

    // MARK: What a task's detail shows

    func job(_ extra: String) throws -> CronJob {
        let json = #"{"id": "job_brief", "name": "Morning briefing", "prompt": "Brief me", "schedule_display": "0 7 * * *""# + extra + "}"
        return try JSONDecoder().decode(CronJob.self, from: Data(json.utf8))
    }

    /// The Model row shows only when the job names its model (`docs/tasks.md` §4).
    @Test func aJobNamesItsModelOrNone() throws {
        #expect(try job(#", "model": "anthropic/claude-sonnet-4.6""#).model == "anthropic/claude-sonnet-4.6")
        #expect(try job(#", "model": null"#).model == nil)
        #expect(try job(#", "model": "  ""#).model == nil)
        #expect(try job("").model == nil)
    }

    /// Hermes has no running state: a run under way is the job's `live_execution`, claimed or running.
    @Test func aLiveExecutionMeansARunIsUnderWay() throws {
        let running = try job(#", "live_execution": {"id": 7, "status": "running", "claimed_at": "2026-11-19T09:11:58+00:00", "started_at": "2026-11-19T09:12:00+00:00"}"#)
        #expect(running.isRunning)
        #expect(running.runningSince == HermesDate.fromISO("2026-11-19T09:12:00+00:00"))

        let claimed = try job(#", "live_execution": {"id": 7, "status": "claimed", "claimed_at": "2026-11-19T09:11:58+00:00", "started_at": null}"#)
        #expect(claimed.runningSince == HermesDate.fromISO("2026-11-19T09:11:58+00:00"))

        #expect(try !job(#", "live_execution": null"#).isRunning)
        #expect(try !job("").isRunning)
        #expect(try !job(#", "live_execution": {"status": "succeeded", "started_at": "2026-11-19T09:12:00+00:00"}"#).isRunning)
    }

    /// A recurring task counts a run when it finishes, a finite one when it starts
    /// (`claim_dispatch`): the run going on is counted once either way.
    @Test func theRunGoingOnIsCountedOnce() throws {
        let live = #", "live_execution": {"status": "running", "started_at": "2026-11-19T09:12:00+00:00"}"#
        #expect(try job(#", "repeat": {"times": null, "completed": 41}"# + live).runsCounted == 42)
        #expect(try job(#", "repeat": {"times": null, "completed": 41}"#).runsCounted == 41)
        #expect(try job(#", "repeat": {"times": 3, "completed": 1}"# + live).runsCounted == 1)
        #expect(try job(#", "repeat": {"times": 3, "completed": 1}"#).runsCounted == 1)
        #expect(try job(live).runsCounted == nil)
    }

    /// Run Now only marks the task due; "Starting…" ends once a read shows the run under way,
    /// finished between two reads, or not started (`docs/tasks.md` §1).
    @Test func runNowEndsWhenTheListShowsTheRun() throws {
        let before = try job(#", "repeat": {"times": null, "completed": 41}, "last_run_at": "2026-11-19T07:00:00+00:00", "last_status": "ok""#)
        #expect(!before.showsRun(askedOf: before))
        let due = try job(#", "repeat": {"times": null, "completed": 41}, "last_run_at": "2026-11-19T07:00:00+00:00", "last_status": "ok", "next_run_at": "2026-11-19T09:11:00+00:00""#)
        #expect(!due.showsRun(askedOf: before))

        let running = try job(#", "repeat": {"times": null, "completed": 41}, "last_run_at": "2026-11-19T07:00:00+00:00", "last_status": "ok", "live_execution": {"status": "claimed", "claimed_at": "2026-11-19T09:12:00+00:00"}"#)
        #expect(running.showsRun(askedOf: before))
        let ran = try job(#", "repeat": {"times": null, "completed": 42}, "last_run_at": "2026-11-19T09:12:00+00:00", "last_status": "ok""#)
        #expect(ran.showsRun(askedOf: before))
        let failed = try job(#", "repeat": {"times": null, "completed": 41}, "last_run_at": "2026-11-19T07:00:00+00:00", "last_status": "ok", "last_fire_error": {"detail": "No provider"}"#)
        #expect(failed.showsRun(askedOf: before))
    }

    /// The run under way leads the task's recent runs, whether or not the runs list has it yet.
    @Test func theLiveRunLeadsTheRecentRuns() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let finished = CronRun(sessionID: "cron_job_brief_1", startedAt: since - 86_400, endedAt: since - 86_376)
        let notClosed = CronRun(sessionID: "cron_job_brief_0", startedAt: since - 172_800)

        #expect(CronRun.withLiveRun([finished], runningSince: nil) == [finished])

        let added = CronRun.withLiveRun([finished, notClosed], runningSince: since)
        #expect(added.count == 3)
        #expect(added[0].isLive && added[0].startedAt == since && added[0].sessionID == nil)
        #expect(added.dropFirst().allSatisfy { !$0.isLive })

        let listed = CronRun(sessionID: "cron_job_brief_2", startedAt: since + 2)
        let moved = CronRun.withLiveRun([finished, listed], runningSince: since)
        #expect(moved.map(\.sessionID) == ["cron_job_brief_2", "cron_job_brief_1"])
        #expect(moved[0].isLive)
    }
}
