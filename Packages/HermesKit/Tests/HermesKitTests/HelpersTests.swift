import Foundation
import Testing
@testable import HermesKit

private func payload(_ text: String) -> JSONValue {
    JSONValue.parse(text) ?? .null
}

@Suite("Helpers")
struct HelpersTests {
    /// A helper's typing and Passwords steps never show what Hermes previewed (`docs/web.md` §4.1).
    @Test func typingStepsShowNoPreview() throws {
        var tracker = HelperTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        tracker.delegationStarted(callID: "call_1")
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-bbbb", "goal": "Sign in", "task_index": 0, "task_count": 1, "delegation_id": "deleg_1"}
        """), now: t0)
        tracker.apply(type: "subagent.tool", payload: payload("""
        {"subagent_id": "sa-0-bbbb", "task_index": 0, "task_count": 1, "tool_name": "browser_type", "tool_preview": "sam@example.com"}
        """), now: t0.addingTimeInterval(1))
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-0-bbbb", "task_index": 0, "task_count": 1, "status": "completed",
         "output_tail": [{"tool": "browser_vault", "preview": "github.com sam-k", "is_error": false}]}
        """), now: t0.addingTimeInterval(2))
        let helper = try #require(tracker.orderedTeams.first?.topLevel.first)
        #expect(helper.recentTools.allSatisfy { $0.preview.isEmpty })
        #expect(helper.outputTail.allSatisfy { $0.preview.isEmpty })
    }

    /// A background delegation as Hermes sends it: the call returns, then events on the parent.
    @Test func buildsATeamFromEvents() throws {
        var tracker = HelperTracker()
        let t0 = Date(timeIntervalSince1970: 1_000)
        tracker.delegationStarted(callID: "call_1")
        // Workers can start before the call returns.
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-1-aaaa", "goal": "Summarise the release notes", "task_index": 1, "task_count": 4, "depth": 0,
         "delegation_id": "deleg_1", "model": "claude-haiku-4.5", "tool_count": 0, "text": "Summarise the release notes"}
        """), now: t0)
        tracker.delegationReturned(callID: "call_1", result: .string("""
        {"status": "dispatched", "mode": "background", "count": 4, "delegation_id": "deleg_1",
         "goals": ["Audit targets", "Summarise the release notes", "Run tests", "Draft checklist"],
         "subagent_ids": ["sa-0-bbbb", "sa-1-aaaa", "sa-2-cccc", "sa-3-dddd"]}
        """), sessionID: "rt1", now: t0)
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-bbbb", "goal": "Audit targets", "task_index": 0, "task_count": 4, "delegation_id": "deleg_1", "tool_count": 0}
        """), now: t0.addingTimeInterval(1))
        tracker.apply(type: "subagent.tool", payload: payload("""
        {"subagent_id": "sa-0-bbbb", "goal": "Audit targets", "task_index": 0, "task_count": 4, "tool_name": "terminal",
         "tool_preview": "rg -n \\"@MainActor\\" Sources/", "tool_count": 12}
        """), now: t0.addingTimeInterval(2))
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-1-aaaa", "goal": "Summarise the release notes", "task_index": 1, "task_count": 4, "status": "completed",
         "summary": "Three changes matter.", "duration_seconds": 58, "input_tokens": 8000, "output_tokens": 1000,
         "files_written": ["notes/swift-6.4.md"], "output_tail": [{"tool": "web_extract", "preview": "swift.org", "is_error": false}]}
        """), now: t0.addingTimeInterval(58))
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-2-cccc", "goal": "Run tests", "task_index": 2, "task_count": 4, "delegation_id": "deleg_1"}
        """), now: t0)
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-2-cccc", "goal": "Run tests", "task_index": 2, "task_count": 4, "status": "timeout",
         "text": "Timed out after 600s", "duration_seconds": 600}
        """), now: t0.addingTimeInterval(600))

        let team = try #require(tracker.team(forCall: "call_1"))
        #expect(team.id == "deleg_1")
        #expect(tracker.orderedTeams.count == 1)
        #expect(team.topLevel.map(\.taskIndex) == [0, 1, 2, 3])
        #expect(team.total == 4)
        let audit = try #require(team.helpers["sa-0-bbbb"])
        #expect(audit.status == .running)
        #expect(audit.toolCount == 12)
        #expect(audit.currentTool == "terminal")
        #expect(audit.recentTools.last?.preview.contains("@MainActor") == true)
        #expect(team.helpers["sa-1-aaaa"]?.status == .completed)
        #expect(team.helpers["sa-1-aaaa"]?.filesWritten == ["notes/swift-6.4.md"])
        #expect(team.helpers["sa-1-aaaa"]?.totalTokens == 9000)
        #expect(team.helpers["sa-2-cccc"]?.status == .timeout)
        #expect(team.helpers["sa-2-cccc"]?.failureText == "Timed out after 600s")
        // Listed by the call but never started: waiting for a slot.
        #expect(team.helpers["sa-3-dddd"]?.status == .queued)
        #expect(team.runningCount == 1)
        #expect(team.waitingCount == 1)
        #expect(team.doneCount == 2)
        #expect(team.failedCount == 1)
        #expect(team.isLive)
    }

    @Test func mapsEveryStatus() {
        #expect(HelperStatus(wire: "queued") == .queued)
        #expect(HelperStatus(wire: "running") == .running)
        #expect(HelperStatus(wire: "completed") == .completed)
        #expect(HelperStatus(wire: "failed") == .failed)
        #expect(HelperStatus(wire: "error") == .error)
        #expect(HelperStatus(wire: "timeout") == .timeout)
        #expect(HelperStatus(wire: "interrupted") == .interrupted)
        #expect(HelperStatus(wire: "stalled") == .timeout)
        #expect(HelperStatus.allCases.filter(\.isFinished).count == 5)
        #expect(HelperStatus.timeout.isFailure && !HelperStatus.interrupted.isFailure)
    }

    @Test func nestsHelpersUnderTheirLead() throws {
        var tracker = HelperTracker()
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-lead", "goal": "Audit every folder", "task_index": 0, "task_count": 2, "depth": 0, "delegation_id": "deleg_top"}
        """))
        for index in 0..<3 {
            tracker.apply(type: "subagent.start", payload: payload("""
            {"subagent_id": "sa-\(index)-kid\(index)", "goal": "Folder \(index)", "task_index": \(index), "task_count": 3, "depth": 1,
             "parent_id": "sa-0-lead", "delegation_id": "deleg_nested"}
            """))
        }
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-1-kid1", "goal": "Folder 1", "task_index": 1, "task_count": 3, "depth": 1, "parent_id": "sa-0-lead", "status": "completed"}
        """))
        // Grandchildren join their lead's team, not a team of their own.
        #expect(tracker.orderedTeams.count == 1)
        let team = try #require(tracker.team(id: "deleg_top"))
        #expect(team.topLevel.map(\.id) == ["sa-0-lead"])
        let kids = team.children(of: "sa-0-lead")
        #expect(kids.map { team.number(of: $0) } == ["1.1", "1.2", "1.3"])
        #expect(kids[1].status == .completed)
        #expect(team.number(of: team.topLevel[0]) == "1")
        // "Team · 5 helpers" counts everyone: the delegation's two and the lead's three.
        #expect(team.total == 2)
        #expect(team.everyone == 5)
    }

    @Test func reconcilesWithTheLiveList() throws {
        var tracker = HelperTracker()
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-x", "goal": "A", "task_index": 0, "task_count": 2, "delegation_id": "deleg_r"}
        """), sessionID: "rt")
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-1-y", "goal": "B", "task_index": 1, "task_count": 2, "delegation_id": "deleg_r"}
        """), sessionID: "rt")
        // Back after a while: only A is still live; B finished unseen; a failed delegation is reported.
        tracker.reconcile(list: payload("""
        {"subagents": [{"subagent_id": "sa-0-x", "parent_id": null, "depth": 0, "goal": "A", "delegation_id": "deleg_r",
                        "model": "m", "started_at": 1000.0, "status": "running", "tool_count": 7, "last_tool": "grep", "accepting_steer": false}],
         "delegations": [{"delegation_id": "deleg_r", "task_index": 1, "status": "timeout", "goal": "B", "error": "child exceeded 600 s"}]}
        """), sessionID: "rt")
        let team = try #require(tracker.team(id: "deleg_r"))
        #expect(team.helpers["sa-0-x"]?.status == .running)
        #expect(team.helpers["sa-0-x"]?.toolCount == 7)
        #expect(team.helpers["sa-0-x"]?.acceptingSteer == false)
        #expect(team.helpers["sa-1-y"]?.status == .timeout)
        #expect(team.helpers["sa-1-y"]?.failureText == "child exceeded 600 s")
    }

    @Test func helperUnlistedOnResumeFinishedUnseen() throws {
        var tracker = HelperTracker()
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-z", "goal": "Z", "task_index": 0, "task_count": 1, "delegation_id": "deleg_z"}
        """), sessionID: "rt")
        tracker.reconcile(list: payload(#"{"subagents": [], "delegations": []}"#), sessionID: "rt")
        let helper = try #require(tracker.helper("sa-0-z"))
        #expect(helper.status.isFinished)
        #expect(helper.endedUnseen)
        #expect(tracker.team(id: "deleg_z")?.isFinished == true)
    }

    @Test func readsAMissedSteerFromTheSummary() {
        var helper = Helper(id: "sa-0-q", goal: "Q")
        helper.summary = "Done the audit.\n\n[steer did not land — the subagent finished before it could be delivered: Skip the Widgets target]"
        #expect(helper.missedSteerText == "Skip the Widgets target")
        #expect(helper.cleanSummary == "Done the audit.")
        helper.summary = "Plain summary"
        #expect(helper.missedSteerText == nil)
    }

    @Test func savedTreesRoundTrip() throws {
        var tracker = HelperTracker()
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-a", "goal": "Lead", "task_index": 0, "task_count": 1, "delegation_id": "deleg_s", "model": "opus"}
        """))
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-b", "goal": "Kid", "task_index": 0, "task_count": 1, "depth": 1, "parent_id": "sa-0-a"}
        """))
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-0-b", "goal": "Kid", "task_index": 0, "status": "failed", "text": "Boom", "duration_seconds": 3}
        """))
        tracker.apply(type: "subagent.complete", payload: payload("""
        {"subagent_id": "sa-0-a", "goal": "Lead", "task_index": 0, "status": "completed", "summary": "All good", "duration_seconds": 9,
         "files_written": ["a.swift"]}
        """))
        let team = try #require(tracker.team(id: "deleg_s"))
        let rows = team.helpers.values.map(SpawnTree.row(for:))
        let file = JSONValue.object(["session_id": .string("s1"), "started_at": .number(1000), "finished_at": .number(1009), "subagents": .array(rows)])
        let loaded = SpawnTree.team(from: file, id: "deleg_s", path: "/x.json")
        #expect(loaded.topLevel.map(\.goal) == ["Lead"])
        #expect(loaded.children(of: "sa-0-a").first?.status == .failed)
        #expect(loaded.children(of: "sa-0-a").first?.failureText == "Boom")
        #expect(loaded.helpers["sa-0-a"]?.summary == "All good")
        #expect(loaded.helpers["sa-0-a"]?.filesWritten == ["a.swift"])
        #expect(loaded.isFinished)
        #expect(loaded.savedPath == "/x.json")
        // The TUI's field names.
        if case .object(let row) = SpawnTree.row(for: try #require(team.helpers["sa-0-b"])) {
            #expect(Set(["id", "goal", "status", "depth", "parentId", "index", "taskCount", "toolCount", "tools", "notes", "thinking"]).isSubset(of: row.keys))
        } else {
            Issue.record("row isn't an object")
        }
    }

    @Test func clientSendsTheSessionAndNoProfile() async throws {
        actor Calls { var list: [(String, [String: JSONValue])] = []; func add(_ m: String, _ p: [String: JSONValue]) { list.append((m, p)) } }
        let calls = Calls()
        let client = HelpersClient { method, params in
            await calls.add(method, params)
            switch method {
            case "subagent.steer": return .object(["status": .string("rejected")])
            case "subagent.interrupt": return .object(["found": .bool(false)])
            case "delegation.status": return payload(#"{"active": [{}, {}], "paused": true, "max_spawn_depth": 2, "max_concurrent_children": 10}"#)
            default: return .object([:])
            }
        }
        #expect(try await client.steer(sessionID: "rt", helperID: "sa-0-a", text: "Skip it") == .rejected)
        #expect(try await client.interrupt(sessionID: "rt", helperID: "sa-0-a") == false)
        let status = try await client.status()
        #expect(status.paused && status.maxSpawnDepth == 2 && status.activeCount == 2)
        _ = try await client.setPaused(true)
        let list = await calls.list
        #expect(list[0].1["session_id"] == .string("rt"))
        #expect(list[0].1["subagent_id"] == .string("sa-0-a"))
        #expect(list.allSatisfy { $0.1["profile"] == nil })
        #expect(list[3].0 == "delegation.pause" && list[3].1["paused"] == .bool(true))
    }

    /// A helper waits on a running sibling: with none of its team listed it isn't waiting any more.
    @Test func waitingHelperWithNoListedSiblingFinished() throws {
        var tracker = HelperTracker()
        tracker.delegationReturned(callID: "call_w", result: .string("""
        {"status": "dispatched", "delegation_id": "deleg_w", "goals": ["A", "B"], "subagent_ids": ["sa-0-a", "sa-1-b"]}
        """), sessionID: "rt")
        tracker.apply(type: "subagent.start", payload: payload("""
        {"subagent_id": "sa-0-a", "goal": "A", "task_index": 0, "task_count": 2, "delegation_id": "deleg_w"}
        """), sessionID: "rt")
        // A runs, so B still waits for its slot.
        tracker.reconcile(list: payload(#"{"subagents": [{"subagent_id": "sa-0-a", "goal": "A", "status": "running", "depth": 0}], "delegations": []}"#), sessionID: "rt")
        #expect(tracker.helper("sa-1-b")?.status == .queued)
        // Later nothing is listed: both ran out of sight.
        tracker.reconcile(list: payload(#"{"subagents": [], "delegations": []}"#), sessionID: "rt")
        #expect(tracker.helper("sa-0-a")?.endedUnseen == true)
        #expect(tracker.helper("sa-1-b")?.status == .completed)
        #expect(tracker.team(id: "deleg_w")?.isFinished == true)
    }

    /// `subagent.tail` text as tools/delegation_live_log.py writes it.
    @Test func parsesTheLiveTranscript() {
        let text = """
        === Hermes subagent live transcript ===
        delegation: deleg_1   task: 0
        goal: Audit the app targets
        started: 2026-10-15 09:41:00
        (append-only; streams while the subagent runs — tail -f me)
        ========================================
        09:41:00 user     | kickoff: Audit the app targets
        09:41:00 start    | Audit the app targets
        09:41:02 assistant| I'll find every target's concurrency setting first.
        09:41:03 tool     | -> read_file(Hermes.xcodeproj/project.pbxproj)
        09:41:03 result   | read_file ok 0.2s: 2,410 lines
        09:41:05 think    | Three targets look minimal.
        09:41:09 result   | terminal ERROR 600.0s: child exceeded 600 s
        09:41:10 final    | status=timeout duration=600s
        """
        let lines = HelperTranscript.parse(text)
        #expect(lines == [
            .text("I'll find every target's concurrency setting first."),
            .tool(name: "read_file", arguments: "Hermes.xcodeproj/project.pbxproj"),
            .result(name: "read_file", text: "2,410 lines", isError: false),
            .thinking("Three targets look minimal."),
            .result(name: "terminal", text: "child exceeded 600 s", isError: true),
        ])
        // Cut to its last 16 KB, the first line may be partial: it goes.
        #expect(HelperTranscript.parse("ead_file ok\n09:41:02 assistant| Hi", truncated: true) == [.text("Hi")])
    }

    /// A chat reopened after its run: `subagent.list` may name a failure before the saved tree loads;
    /// the tree then fills in the team instead of being skipped.
    @Test func savedTreeReplacesATeamKnownFromItsFailures() throws {
        var tracker = HelperTracker()
        tracker.reconcile(list: payload("""
        {"subagents": [], "delegations": [{"delegation_id": "deleg_p", "task_index": 2, "status": "timeout", "goal": "Run tests", "error": "Timed out after 600s"}]}
        """), sessionID: "rt")
        #expect(tracker.team(id: "deleg_p")?.isPartial == true)
        #expect(tracker.team(id: "deleg_p")?.helpers.count == 1)
        var tree = HelperTeam(id: "deleg_p")
        for index in 0..<4 {
            tree.upsert(Helper(id: "sa-\(index)-x", goal: "Goal \(index)", taskIndex: index, status: index == 2 ? .timeout : .completed))
        }
        tracker.load(tree: tree)
        let team = try #require(tracker.team(id: "deleg_p"))
        #expect(!team.isPartial)
        #expect(team.helpers.count == 4)
        #expect(team.failedCount == 1)
        #expect(tracker.helper("sa-2-x")?.status == .timeout)
    }
}
