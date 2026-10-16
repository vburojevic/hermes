import Foundation
import Testing
@testable import HermesKit

@Suite("Board")
struct BoardTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The gateway's `GET /workflow` today (`kanban_workflow.DEFAULT_WORKFLOW.to_dict()`).
    private func defaultWorkflow() throws -> BoardWorkflow {
        BoardWorkflow(json: try json("""
        {"columns": [
          {"key": "triage", "label": "Triage", "icon": "◇", "drag_target": true},
          {"key": "todo", "label": "Todo", "icon": "◻", "drag_target": true},
          {"key": "scheduled", "label": "Scheduled", "icon": "⏱", "drag_target": false},
          {"key": "ready", "label": "Ready", "icon": "▶", "drag_target": true},
          {"key": "running", "label": "Running", "icon": "●", "drag_target": false},
          {"key": "blocked", "label": "Blocked", "icon": "⊘", "drag_target": true},
          {"key": "review", "label": "Review", "icon": "◎", "drag_target": false},
          {"key": "done", "label": "Done", "icon": "✓", "drag_target": true}],
         "manual": {
          "triage": ["ready", "todo"], "todo": ["ready", "scheduled", "triage"],
          "scheduled": ["ready", "todo", "triage"],
          "ready": ["blocked", "done", "review", "scheduled", "todo", "triage"],
          "running": ["blocked", "done", "ready", "review", "scheduled", "todo", "triage"],
          "blocked": ["done", "ready", "scheduled", "todo", "triage"],
          "review": ["done", "ready", "todo", "triage"], "done": ["ready", "todo", "triage"],
          "archived": ["ready", "todo", "triage"]},
         "archived": "archived"}
        """))
    }

    // MARK: Workflow

    @Test func columnsAndMovesComeFromTheWorkflow() throws {
        let workflow = try defaultWorkflow()
        #expect(workflow.columns.map(\.key) == ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"])
        #expect(workflow.column("todo")?.title == "To Do")
        // Ready first, then column order; never a column that isn't a drop target.
        #expect(workflow.moves(from: "running").map(\.key) == ["ready", "triage", "todo", "blocked", "done"])
        #expect(workflow.moves(from: "review").map(\.key) == ["ready", "triage", "todo", "done"])
        #expect(workflow.moves(from: "todo").map(\.key) == ["ready", "triage"])
        #expect(!workflow.allows(from: "ready", to: "running"))
        #expect(!workflow.allows(from: "done", to: "blocked"))
        #expect(workflow.restoreTargets.map(\.key) == ["ready", "triage", "todo"])
        #expect(workflow.moves(from: "unknown").isEmpty)
    }

    @Test func keyboardMovesSkipColumnsTheCardCantGoTo() throws {
        let workflow = try defaultWorkflow()
        #expect(workflow.nextMove(from: "todo", forward: true)?.key == "ready")
        #expect(workflow.nextMove(from: "ready", forward: true)?.key == "blocked")
        #expect(workflow.nextMove(from: "blocked", forward: true)?.key == "done")
        #expect(workflow.nextMove(from: "done", forward: true) == nil)
        #expect(workflow.nextMove(from: "done", forward: false)?.key == "ready")
        #expect(workflow.nextMove(from: "triage", forward: false) == nil)
    }

    @Test func anUnknownColumnKeepsTheGatewaysLabel() {
        #expect(BoardColumn(key: "qa", label: "QA").title == "QA")
    }

    // MARK: Board

    @Test func readsTheBoardAndItsCards() throws {
        let snapshot = BoardSnapshot(json: try json("""
        {"columns": [
          {"name": "ready", "tasks": [{"id": "t_00003fa2", "title": "Add Increase Contrast snapshot tests", "status": "ready",
            "assignee": "hermes", "priority": 0, "created_at": 1760000000, "comment_count": 0,
            "link_counts": {"parents": 0, "children": 0}, "progress": null}]},
          {"name": "running", "tasks": [{"id": "t_0000a91c", "title": "Fix the reconnect after sleep", "status": "running",
            "assignee": "hermes", "current_run_started_at": 1760000000, "last_heartbeat_at": 1760000300,
            "latest_summary": "Running swift test · 212 of 240 passed", "branch_name": "wt/t_a91c"}]},
          {"name": "done", "tasks": [{"id": "t_00005d02", "title": "Release 1.3", "status": "done", "completed_at": 1759990000,
            "progress": {"done": 2, "total": 5}, "link_counts": {"parents": 0, "children": 5}, "comment_count": 3}]}],
         "tenants": [], "assignees": ["ada", "hermes"], "latest_event_id": 412, "now": 1760000400}
        """))
        #expect(snapshot.latestEventID == 412)
        #expect(snapshot.assignees == ["ada", "hermes"])
        #expect(snapshot.cards(in: "ready").first?.shortID == "3fa2")
        let running = try #require(snapshot.card("t_0000a91c"))
        #expect(running.latestSummary == "Running swift test · 212 of 240 passed")
        #expect(running.branchName == "wt/t_a91c")
        let done = try #require(snapshot.card("t_00005d02"))
        #expect(done.progress?.done == 2 && done.progress?.total == 5)
        #expect(done.childCount == 5 && done.commentCount == 3)
    }

    @Test func movesACardBetweenColumnsInPlace() throws {
        var snapshot = BoardSnapshot(lanes: [
            BoardLane(key: "ready", cards: [BoardCard(id: "t_1", title: "One", column: "ready"), BoardCard(id: "t_2", title: "Two", column: "ready")]),
            BoardLane(key: "running", cards: []),
            BoardLane(key: "done", cards: [BoardCard(id: "t_0", title: "Zero", column: "done")]),
        ])
        snapshot.upsert(BoardCard(id: "t_1", title: "One", column: "running"))
        #expect(snapshot.cards(in: "ready").map(\.id) == ["t_2"])
        #expect(snapshot.cards(in: "running").map(\.id) == ["t_1"])
        // Done is newest first.
        snapshot.upsert(BoardCard(id: "t_2", title: "Two", column: "done"))
        #expect(snapshot.cards(in: "done").map(\.id) == ["t_2", "t_0"])
        // An edit stays where it is.
        snapshot.upsert(BoardCard(id: "t_0", title: "Zero, renamed", column: "done"))
        #expect(snapshot.cards(in: "done").map(\.title) == ["Two", "Zero, renamed"])
        // Archived isn't a column: the card leaves the board.
        snapshot.upsert(BoardCard(id: "t_1", title: "One", column: "archived"))
        #expect(snapshot.card("t_1") == nil)
        snapshot.remove("t_2")
        #expect(snapshot.cards(in: "done").map(\.id) == ["t_0"])
    }

    // MARK: Card states

    @Test func cardStatesFollowTheColumnAndItsFacts() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func card(_ column: String, _ change: (inout BoardCard) -> Void = { _ in }) -> BoardCard {
            var card = BoardCard(id: "t_1", title: "Card", column: column)
            change(&card)
            return card
        }
        let started = now.addingTimeInterval(-360)
        #expect(card("running") { $0.currentRunStartedAt = started; $0.lastHeartbeatAt = now.addingTimeInterval(-20) }.state(now: now) == .running(since: started))
        let quiet = now.addingTimeInterval(-540)
        #expect(card("running") { $0.currentRunStartedAt = started.addingTimeInterval(-600); $0.lastHeartbeatAt = quiet }.state(now: now) == .stale(since: quiet))
        #expect(card("blocked") { $0.blockKind = "needs_input" }.state(now: now) == .needsYou)
        #expect(card("blocked").state(now: now) == .needsYou)
        #expect(card("blocked") { $0.blockKind = "transient" }.state(now: now) == .blocked)
        #expect(card("blocked") { $0.consecutiveFailures = 3; $0.lastFailureError = "Build fails" }.state(now: now) == .gaveUp(tries: 3))
        #expect(card("todo") { $0.parentCount = 2 }.state(now: now) == .waiting(parents: 2))
        // The detail knows how many are still open, and whether the card was split.
        #expect(card("todo") { $0.parentCount = 3 }.state(now: now, extras: BoardCardExtras(openParents: 1)) == .waiting(parents: 1))
        #expect(card("todo") { $0.parentCount = 5 }.state(now: now, extras: BoardCardExtras(openParents: 3, split: BoardProgress(done: 2, total: 5))) == .parent(done: 2, total: 5))
        // The board's own `progress` counts cards waiting on this one: not sub-cards.
        #expect(card("ready") { $0.progress = (0, 1) }.state(now: now) == .idle)
        #expect(card("review").state(now: now) == .review)
        #expect(card("ready").state(now: now) == .idle)
    }

    // MARK: Detail

    @Test func readsADetailWithChecksQuestionAndFiles() throws {
        let detail = try #require(BoardCardDetail(json: try json("""
        {"task": {"id": "t_00003fa2", "title": "Add Increase Contrast snapshot tests", "status": "review", "assignee": "scout",
                  "latest_summary": "Added 46 snapshots; 2 colours fixed to reach 7:1.",
                  "last_failure_error": "PR acceptance failure: test (snapshots) failed"},
         "comments": [{"id": 1, "author": "dashboard", "body": "Looks close", "created_at": 1760000000},
                      {"id": 2, "author": "scout", "body": "Two snapshots differ on iPad.", "created_at": 1760000100}],
         "events": [
           {"id": 10, "task_id": "t_00003fa2", "run_id": 1, "kind": "blocked", "payload": {"reason": "Which category?", "kind": "needs_input"}, "created_at": 1759990000},
           {"id": 11, "task_id": "t_00003fa2", "run_id": 2, "kind": "pr_acceptance", "payload": {"ok": false, "classification": "failure",
             "pr_url": "https://github.com/caffeinated/hermes-app/pull/142", "head_sha": "4be1c9a0",
             "checks": [{"name": "build (iOS 27)", "classification": "success", "url": "https://github.com/x/1"},
                        {"name": "test (snapshots)", "classification": "failure"},
                        {"name": "lint", "classification": "pending"}]}, "created_at": 1760000050}],
         "attachments": [],
         "links": {"parents": ["t_p"], "children": ["t_c1", "t_c2"]},
         "link_tasks": [{"id": "t_p", "title": "Parent", "status": "done"}, {"id": "t_c1", "title": "Child one", "status": "done"},
                        {"id": "t_c2", "title": "Child two", "status": "running"}],
         "child_results": [{"id": "t_c1", "title": "Child one", "status": "done", "latest_summary": "Did it"}],
         "runs": [{"id": 1, "profile": "scout", "status": "blocked", "started_at": 1759980000, "ended_at": 1759990000},
                  {"id": 2, "profile": "scout", "status": "done", "outcome": "completed", "started_at": 1759995000, "ended_at": 1760000000,
                   "metadata": "{\\"changed_files\\": [\\"App/Theme.swift\\", \\"Tests/Snapshots.swift\\"]}"}]}
        """)))
        let checks = try #require(detail.checks)
        #expect(checks.prNumber == 142)
        #expect(!checks.ok)
        #expect(checks.failingCount == 1)
        #expect(checks.pendingCount == 1)
        #expect(checks.checks.first?.url?.absoluteString == "https://github.com/x/1")
        #expect(detail.question == "Which category?")
        #expect(detail.changedFiles.map(\.path) == ["App/Theme.swift", "Tests/Snapshots.swift"])
        #expect(detail.reviewerComment?.body == "Two snapshots differ on iPad.")
        #expect(detail.refusal?.contains("failed") == true)
        #expect(detail.parentCards.map(\.title) == ["Parent"])
        #expect(detail.childCards.first?.latestSummary == "Did it")
        let card = detail.boardCard
        #expect(card.commentCount == 2 && card.parentCount == 1 && card.childCount == 2)
        #expect(card.progress?.done == 1 && card.progress?.total == 2)
        #expect(detail.activeRun == nil)
        #expect(detail.extras.openParents == 0)
        #expect(detail.extras.split == nil)
        #expect(detail.extras.checks?.prNumber == 142)
    }

    @Test func aSplitCardWaitsOnItsNewCards() throws {
        // `decompose` links the split card under every new card; its progress is theirs.
        let detail = try #require(BoardCardDetail(json: try json("""
        {"task": {"id": "t_root", "title": "Release 1.3", "status": "todo"},
         "events": [{"id": 1, "kind": "decomposed", "payload": {}, "created_at": 1}],
         "links": {"parents": ["t_a", "t_b", "t_c"], "children": []},
         "link_tasks": [{"id": "t_a", "title": "A", "status": "done"}, {"id": "t_b", "title": "B", "status": "ready"},
                        {"id": "t_c", "title": "C", "status": "archived"}], "runs": []}
        """)))
        #expect(detail.extras.split == BoardProgress(done: 2, total: 3))
        #expect(detail.extras.openParents == 1)
        #expect(detail.card.state(extras: detail.extras) == .parent(done: 2, total: 3))
    }

    @Test func theQuestionFallsBackToTheSummary() throws {
        let detail = try #require(BoardCardDetail(json: try json(#"{"task": {"id": "t_1", "title": "x", "status": "blocked", "latest_summary": "Which one?"}, "events": [], "runs": []}"#)))
        #expect(detail.question == "Which one?")
    }

    // MARK: Events

    @Test func eventBatchesNameTheCardsTheyTouched() throws {
        let batch = try #require(BoardEventBatch(json: try json("""
        {"events": [
          {"id": 413, "task_id": "t_1", "run_id": 3, "kind": "heartbeat", "payload": null, "created_at": 1760000000},
          {"id": 414, "task_id": "t_2", "run_id": null, "kind": "status", "payload": {"status": "ready"}, "created_at": 1760000001},
          {"id": 415, "task_id": "t_2", "run_id": 4, "kind": "claimed", "payload": {}, "created_at": 1760000002},
          {"id": 416, "task_id": "t_3", "run_id": null, "kind": "commented", "payload": {"author": "ada", "len": 12}, "created_at": 1760000003}],
         "cursor": 416}
        """)))
        #expect(batch.cursor == 416)
        #expect(batch.touchedCards == ["t_2", "t_3"])
        #expect(batch.events.first?.isQuiet == true)
    }

    @Test func activityReadsInPlainWords() {
        func line(_ kind: String, _ payload: String? = nil) -> String? {
            let event = BoardEvent(id: 1, kind: kind, payload: payload.flatMap(JSONValue.parse))
            return BoardActivityLine.line(for: event, who: "Hermes") { BoardColumn(key: $0, label: $0).title }?.text
        }
        #expect(line("claimed") == "Hermes picked it up")
        #expect(line("review_requested") == "Asked for review")
        #expect(line("pr_acceptance", #"{"ok": true}"#) == "Checks passed")
        #expect(line("status", #"{"status": "todo"}"#) == "Moved to To Do")
        #expect(line("commented", #"{"author": "dashboard"}"#) == "You commented")
        #expect(line("gave_up", #"{"failures": 3}"#) == "Stopped after 3 tries")
        #expect(line("heartbeat") == nil)
        // Never the gateway's word.
        for kind in ["created", "edited", "claimed", "blocked", "completed", "archived", "reclaimed"] {
            #expect(line(kind)?.localizedCaseInsensitiveContains("task") != true)
        }
    }

    // MARK: New cards

    @Test func aNewCardSendsOnlyWhatWasChosen() throws {
        let plain = NewBoardCard(title: "  Write the App Store listing ", body: "")
        #expect(plain.json == .object(["title": .string("Write the App Store listing"), "priority": .number(0), "triage": .bool(false)]))
        let full = NewBoardCard(title: "Ship 1.3", body: "Archive and upload.", assignee: "ada", parents: ["t_1", "t_2"], triage: true, worksIn: .worktree, projectID: "p_1")
        #expect(full.json["assignee"]?.stringValue == "ada")
        #expect(full.json["workspace_kind"]?.stringValue == "worktree")
        #expect(full.json["project_id"]?.stringValue == "p_1")
        #expect(full.json["triage"]?.boolValue == true)
        #expect(full.json["parents"] == .array([.string("t_1"), .string("t_2")]))
    }

    @Test func changedFilesTakePathsOrObjects() throws {
        let run = try #require(BoardRun(json: try json(#"{"id": 3, "status": "done", "metadata": {"changed_files": ["A.swift", {"path": "B.swift", "additions": 312}, {"file": "C.swift", "added": 4, "removed": 4}, {"nope": 1}]}}"#)))
        #expect(run.changedFiles == [BoardChangedFile(path: "A.swift"), BoardChangedFile(path: "B.swift", added: 312), BoardChangedFile(path: "C.swift", added: 4, removed: 4)])
    }

    // MARK: From a chat

    @Test func aChatTurnListsTheCardsItAdded() throws {
        func step(_ args: String, _ reply: String, status: ToolActivity.Status = .succeeded) throws -> AssistantStep {
            .tool(ToolActivity(id: UUID().uuidString, name: "kanban_create", arguments: try json(args), result: reply, status: status))
        }
        let turn = AssistantTurn(id: "turn", steps: [
            try step(#"{"title": "Write the App Store listing", "assignee": "writer"}"#,
                     #"{"ok": true, "task_id": "t_8f31c4e8", "status": "ready", "project_id": "p_1", "gated": false}"#),
            try step(#"{"title": "Ship 1.3 to TestFlight", "assignee": "default", "parents": ["t_8f31c4e8", "t_2b6d8c3e"]}"#,
                     #"{"ok": true, "task_id": "t_7c1e0b19", "status": "todo", "project_id": "p_1", "gated": true, "gated_by": "t_8f31c4e8"}"#),
            try step(#"{"title": "Refused"}"#, #"{"ok": false, "error": "assignee is required"}"#),
            try step(#"{"title": "Failed"}"#, "boom", status: .failed),
            .tool(ToolActivity(id: "m", name: "memory", status: .succeeded)),
        ])
        let cards = turn.addedCards
        #expect(cards.map(\.title) == ["Write the App Store listing", "Ship 1.3 to TestFlight"])
        #expect(cards[0].column == "ready" && cards[0].assignee == "writer" && !cards[0].isWaiting)
        #expect(cards[1].isWaiting && cards[1].parentCount == 2 && cards[1].projectID == "p_1")
    }

    @Test func workerLogKeepsTheLastLines() {
        let log = BoardWorkerLog(exists: true, content: "one\n\ntwo\nthree\n  \nfour\n", truncated: false)
        #expect(log.lastLines(3) == ["two", "three", "four"])
    }
}
