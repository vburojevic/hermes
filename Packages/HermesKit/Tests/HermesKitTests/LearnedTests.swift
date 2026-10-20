import Foundation
import Testing
@testable import HermesKit

@Suite("What Hermes Learned")
struct LearnedTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_792_000_000) // a Thursday
    private func ago(days: Double) -> Double { now.timeIntervalSince1970 - days * 86_400 }

    private func graph() throws -> LearningGraph {
        try LearningGraph(json: json("""
        {"nodes": [
          {"id": "ios-testing", "label": "ios-testing", "kind": "skill", "timestamp": \(ago(days: 1)), "category": "ios", "useCount": 12, "state": "active", "createdBy": "agent", "pinned": false},
          {"id": "xcode-build", "label": "xcode-build", "kind": "skill", "timestamp": \(ago(days: 20)), "category": "ios", "useCount": 9, "state": "active", "createdBy": "agent", "pinned": true},
          {"id": "nas-backups", "label": "nas-backups", "kind": "skill", "timestamp": \(ago(days: 3)), "category": "home", "useCount": 2, "state": "stale", "createdBy": "learn", "pinned": false},
          {"id": "used-only", "label": "used-only", "kind": "skill", "timestamp": \(ago(days: 2)), "category": "home", "useCount": 1, "state": "active", "createdBy": null, "pinned": false},
          {"id": "memory:memory:0:abc", "label": "Snapshot tests run on iPhone 17 Pro", "kind": "memory", "memorySource": "memory", "timestamp": \(ago(days: 40)), "category": "memory", "useCount": 0, "state": "active", "createdBy": "memory", "pinned": false},
          {"id": "broken"}
        ],
        "edges": [{"source": "ios-testing", "target": "xcode-build"}, {"source": "memory:memory:0:abc", "target": "ios-testing"}, {"source": "ios-testing", "target": "gone"}],
        "clusters": [{"category": "ios", "count": 2}, {"category": "home", "count": 2}, {"category": "memory", "count": 1}],
        "stats": {}}
        """))
    }

    @Test func readsTheGraph() throws {
        let graph = try graph()
        #expect(graph.nodes.count == 5) // the node without a kind is dropped
        #expect(graph.edges.count == 2) // an edge to a missing node is dropped
        #expect(graph.skills.count == 4 && graph.memories.count == 1)
        #expect(graph.learnedSkills.map(\.id).sorted() == ["ios-testing", "nas-backups", "xcode-build"])
        #expect(graph.node("xcode-build")?.pinned == true)
        #expect(graph.node("nas-backups")?.state == .stale)
        #expect(graph.node("ios-testing")?.isWellUsed == true && graph.node("nas-backups")?.isWellUsed == false)
        #expect(graph.connections(of: "ios-testing").map(\.id) == ["xcode-build", "memory:memory:0:abc"])
        #expect(graph.skillCategories == ["ios", "home"])
        #expect(graph.mostUsed.first?.id == "ios-testing")
    }

    @Test func bucketsWeeksAndFindsNewSkills() throws {
        let graph = try graph()
        let weeks = graph.weeks(endingAt: now, limit: 12)
        #expect(weeks.count >= 6 && weeks.count <= 7) // 40 days back to this week
        let calendar = LearningGraph.weekCalendar
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let recent = [1.0, 2, 3].filter { Date(timeIntervalSince1970: ago(days: $0)) >= thisWeek }.count
        #expect(weeks.last!.skills == recent) // what fell in this week of the last three days
        #expect(weeks.last!.start == thisWeek)
        #expect(weeks.reduce(0) { $0 + $1.skills } == 4)
        #expect(weeks.reduce(0) { $0 + $1.memories } == 1)
        #expect(weeks.first!.memories == 1)
        // Only learned skills, newest first; the used-only one isn't "new".
        #expect(graph.newThisWeek(now: now).map(\.id) == ["ios-testing", "nas-backups"])
        #expect(graph.weeks(endingAt: now, limit: 3).count == 3)
    }

    @Test func readsCuratorStatusAndReports() throws {
        let status = CuratorStatus(json: try json(#"{"enabled": true, "paused": false, "interval_hours": 168, "last_run_at": "2026-10-11T03:15:53.123456", "min_idle_hours": 2, "stale_after_days": 30, "archive_after_days": 90}"#))
        #expect(status.isRunning && status.intervalHours == 168 && status.staleAfterDays == 30 && status.archiveAfterDays == 90)
        #expect(status.lastRunAt != nil)
        let report = CuratorReport(json: try json("""
        {"started_at": "2026-10-13T03:00:00", "consolidated": [
           {"name": "xcode-test-runner", "into": "ios-testing", "source": "absorbed_into", "reason": "overlapped"},
           {"name": "snapshot-tests", "into": "ios-testing", "reason": ""}],
         "pruned": [{"name": "docker-cleanup", "reason": ""}],
         "archived": ["xcode-test-runner", "snapshot-tests", "docker-cleanup", "old-thing"],
         "state_transitions": [{"name": "synology-dsm", "from": "active", "to": "stale"}],
         "auto_transitions": {"marked_stale": 4}}
        """))
        #expect(report.merges.count == 2)
        #expect(report.mergeGroups.count == 1 && report.mergeGroups[0].into == "ios-testing" && report.mergeGroups[0].names == ["xcode-test-runner", "snapshot-tests"])
        #expect(report.mergeGroups[0].reason == "overlapped")
        #expect(report.archived.map(\.name) == ["docker-cleanup", "old-thing"]) // merged ones aren't archives
        #expect(report.markedStale == ["synology-dsm"] && report.markedStaleCount == 4)
        #expect(report.changedSomething)
        #expect(!CuratorReport(json: try json(#"{"consolidated": [], "pruned": [], "archived": [], "auto_transitions": {"marked_stale": 0}}"#)).changedSomething)
        // Archived for being unused before the review: counted, not named.
        let auto = CuratorReport(json: try json(#"{"archived": [], "auto_transitions": {"marked_stale": 0, "archived": 3}}"#))
        #expect(auto.archived.isEmpty && auto.archivedCount == 3 && auto.changedSomething)
        #expect(report.archivedCount == 2)
    }

    @Test func readsCuratorReplies() {
        #expect(CuratorReply.outcome("curator: pinned 'ios-testing' (will bypass auto-transitions)", verb: "pin").ok)
        #expect(CuratorReply.outcome("\u{1B}[32mcurator: unpinned 'ios-testing'\u{1B}[0m\n", verb: "unpin").ok)
        let refused = CuratorReply.outcome("curator: 'git' is bundled or hub-installed — cannot pin (only agent-created skills participate in curation)", verb: "pin")
        #expect(!refused.ok && refused.message.hasPrefix("'git' is bundled"))
        #expect(CuratorReply.outcome("curator: restored to /Users/studio/.hermes/skills/ios/docker-cleanup", verb: "restore").ok)
        #expect(!CuratorReply.outcome("curator: skill 'nope' not found in archive", verb: "restore").ok)
        #expect(!CuratorReply.outcome("curator: destination already exists: /x", verb: "restore").ok)
        #expect(CuratorReply.archivedNames("docker-cleanup\nsnapshot-tests\n\nxcode-test-runner\n") == ["docker-cleanup", "snapshot-tests", "xcode-test-runner"])
        #expect(CuratorReply.archivedNames("curator: no archived skills").isEmpty)
        #expect(CuratorReply.archivedNames("Archived skills:\n  • docker-cleanup (92 days)\n").contains("docker-cleanup"))
    }

    @Test func layoutIsStableAndInsideTheSquare() throws {
        let graph = try graph()
        let first = LearningLayout.positions(for: graph, aspect: 1.5)
        let second = LearningLayout.positions(for: graph, aspect: 1.5)
        #expect(first == second)
        #expect(first.count == graph.nodes.count)
        for point in first.values {
            #expect(point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1)
        }
        // Linked skills sit closer than unlinked ones across clusters.
        func distance(_ a: String, _ b: String) -> Double {
            let p = first[a]!, q = first[b]!
            return ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
        }
        #expect(distance("ios-testing", "xcode-build") < distance("ios-testing", "nas-backups"))
        #expect(LearningLayout.positions(for: LearningGraph()).isEmpty)
    }

    @Test func findsSkillsHermesWrote() throws {
        var create = ToolActivity(id: "t1", name: "skill_manage", arguments: try json(#"{"action": "create", "name": "app-store-listing", "content": "---"}"#),
                                  result: #"{"success": true, "message": "Skill 'app-store-listing' created."}"#, status: .succeeded)
        #expect(create.createdSkills == ["app-store-listing"])
        create.result = #"{"success": true, "staged": true}"#
        #expect(create.createdSkills.isEmpty) // waiting for approval
        let patch = ToolActivity(id: "t2", name: "skill_manage", arguments: try json(#"{"action": "patch", "name": "ios-testing"}"#), result: "{}", status: .succeeded)
        #expect(patch.createdSkills.isEmpty)
        let batch = ToolActivity(id: "t3", name: "skill_manage",
                                 arguments: try json(#"{"operations": [{"action": "create", "name": "a"}, {"action": "edit", "name": "b"}, {"action": "create", "name": "c"}]}"#),
                                 result: #"{"success": true}"#, status: .succeeded)
        #expect(batch.createdSkills == ["a", "c"])
        let failed = ToolActivity(id: "t4", name: "skill_manage", arguments: try json(#"{"action": "create", "name": "x"}"#), result: "{}", status: .failed)
        #expect(failed.createdSkills.isEmpty)
        let turn = AssistantTurn(id: "turn", steps: [.tool(create), .tool(batch), .tool(batch)])
        #expect(turn.createdSkills == ["a", "c"])
    }

    @Test func creationDatesComeFromCuratorUsage() throws {
        let dates = CuratorReply.creationDates("""
        [
          {"name": "ios-testing", "created_at": "2026-09-18T10:00:00+00:00", "use_count": 12},
          {"name": "no-date"},
          {"name": "xcode-build", "created_at": "2026-10-10T08:00:00+00:00"}
        ]
        """)
        #expect(dates.count == 2)
        let graph = try graph().applyingCreationDates(dates)
        #expect(graph.node("ios-testing")?.created != nil)
        #expect(graph.node("ios-testing")?.learnedAt == dates["ios-testing"])
        #expect(graph.node("nas-backups")?.learnedAt == graph.node("nas-backups")?.date) // no creation date: its own
        #expect(CuratorReply.creationDates("curator: no skills found").isEmpty)
    }

    @Test func dataURLsDecode() {
        #expect(BackendClient.dataURLBytes("data:application/json;base64,eyJhIjoxfQ==") == Data(#"{"a":1}"#.utf8))
        #expect(BackendClient.dataURLBytes("nonsense") == nil)
    }
}
