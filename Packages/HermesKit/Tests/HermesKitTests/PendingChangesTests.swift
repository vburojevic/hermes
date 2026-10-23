import Foundation
import Testing
@testable import HermesKit

/// A change shows at once and settles in place (`docs/chat.md` §4a).
@Suite("Changes on their way to the gateway")
struct PendingChangesTests {
    struct Row: Identifiable, Sendable, Equatable {
        var id: String
        var on: Bool = false
    }

    let gateway = [Row(id: "a"), Row(id: "b"), Row(id: "c")]

    @Test func anUpdateShowsAtOnceAndARefusalPutsItBack() {
        var pending = PendingChanges<Row>()
        let token = pending.begin(.update(Row(id: "b", on: true)), for: "b")
        #expect(pending.applied(to: gateway)[1].on)
        #expect(pending.isPending("b"))
        // Refused: the gateway's row shows again.
        let settled = pending.settle(token, for: "b")
        #expect(settled)
        #expect(pending.applied(to: gateway) == gateway)
        #expect(pending.isEmpty)
    }

    @Test func aReadFromBeforeTheChangeDoesntUndoIt() {
        var pending = PendingChanges<Row>()
        pending.begin(.update(Row(id: "a", on: true)), for: "a")
        pending.begin(.remove, for: "c")
        // A list read the gateway answered before it had either change.
        let stale = [Row(id: "a"), Row(id: "b"), Row(id: "c")]
        #expect(pending.applied(to: stale) == [Row(id: "a", on: true), Row(id: "b")])
    }

    @Test func onlyTheNewestChangeSettlesAnItem() {
        var pending = PendingChanges<Row>()
        let pause = pending.begin(.update(Row(id: "a", on: true)), for: "a")
        let resume = pending.begin(.update(Row(id: "a", on: false)), for: "a")
        // The first answer lands after the second tap: the second still shows.
        let stale = pending.settle(pause, for: "a")
        #expect(!stale)
        #expect(pending.isNewest(resume, for: "a"))
        #expect(pending.applied(to: [Row(id: "a", on: true)]) == [Row(id: "a", on: false)])
        let newest = pending.settle(resume, for: "a")
        #expect(newest)
        #expect(pending.isEmpty)
    }

    @Test func newItemsFollowTheGatewaysInTheOrderTheyWereMade() {
        var pending = PendingChanges<Row>()
        let first = pending.begin(.insert(Row(id: "new-1")), for: "new-1")
        pending.begin(.insert(Row(id: "new-2")), for: "new-2")
        #expect(pending.applied(to: gateway).map(\.id) == ["a", "b", "c", "new-1", "new-2"])
        // Made: the gateway's row (under its own id) replaces the one shown.
        pending.settle(first, for: "new-1")
        #expect(pending.applied(to: gateway + [Row(id: "x")]).map(\.id) == ["a", "b", "c", "x", "new-2"])
    }

    @Test func aChangeCanBeReadWithoutAList() {
        var pending = PendingChanges<Row>()
        pending.begin(.update(Row(id: "tool", on: true)), for: "tool")
        pending.begin(.remove, for: "gone")
        #expect(pending.item(for: "tool")?.on == true)
        #expect(pending.item(for: "gone") == nil)
        #expect(pending.item(for: "other") == nil)
    }

    @Test func aRemovalRefusedBringsTheRowBackWhereItWas() {
        var pending = PendingChanges<Row>()
        let token = pending.begin(.remove, for: "b")
        #expect(pending.applied(to: gateway).map(\.id) == ["a", "c"])
        pending.settle(token, for: "b")
        #expect(pending.applied(to: gateway).map(\.id) == ["a", "b", "c"])
    }

    @Test func aRefusalSaysWhatWasPutBack() {
        let note = RefusedChange("Couldn't pause “Backups”", error: HermesError.server(status: 400, code: nil, message: "Job is running."))
        #expect(note.title == "Couldn't pause “Backups”")
        #expect(note.message == "Job is running. It's back as it was.")
        let kept = RefusedChange("Couldn't run “Backups”", error: HermesError.server(status: 404, code: nil, message: "Job not found"), undone: false)
        #expect(kept.message == "Job not found")
    }
}

@Suite("Tasks shown before the gateway answers")
struct ScheduledChangeTests {
    @Test func aNewTaskShowsWhatWasSent() {
        let job = CronJob(making: NewCronJob(name: "Backups", schedule: "every day at 07:30", prompt: "Check the backups"), id: "new-1")
        #expect(job.name == "Backups")
        #expect(job.scheduleDisplay == "every day at 07:30")
        #expect(!job.isPaused && !job.hasFailed && job.nextRunAt == nil)
    }

    @Test func pausingShowsPausedAndLeavesTheNextRunToTheGateway() throws {
        let data = Data(#"{"id":"j1","name":"Backups","enabled":true,"state":"scheduled","next_run_at":"2026-10-13T07:30:00+02:00","paused_reason":null}"#.utf8)
        let job = try JSONDecoder().decode(CronJob.self, from: data)
        let paused = job.paused(true)
        #expect(paused.isPaused && paused.nextRunAt == nil)
        let resumed = paused.paused(false)
        #expect(!resumed.isPaused && resumed.state == "scheduled")
    }
}
