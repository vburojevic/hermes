import Foundation
import Testing
@testable import HermesKit

/// Records what `ProjectsClient` sends and answers from a table.
private actor Recorder {
    var calls: [(method: String, params: [String: JSONValue])] = []
    var answers: [String: (([String: JSONValue]) -> JSONValue)] = [:]

    func set(_ method: String, _ answer: @escaping @Sendable ([String: JSONValue]) -> JSONValue) {
        answers[method] = answer
    }

    func handle(_ method: String, _ params: [String: JSONValue]) -> JSONValue {
        calls.append((method, params))
        return answers[method]?(params) ?? .object([:])
    }
}

private func client(_ recorder: Recorder, profile: String? = "coder") -> ProjectsClient {
    ProjectsClient(profile: profile) { method, params in await recorder.handle(method, params) }
}

@Suite("Projects")
struct ProjectsTests {
    // Shapes from tui_gateway/contracts/projects_pets.py and project_tree.py.
    static let projectJSON = """
    {"id": "p_4f2a9c1e", "slug": "hermes-app", "name": "Hermes App", "description": null,
     "icon": "chevron.left.forwardslash.chevron.right", "color": "ocean", "board_slug": null,
     "primary_path": "/Users/ada/Code/hermes-app", "archived": false, "created_at": 1790000000,
     "folders": [
       {"path": "/Users/ada/Code/hermes-app", "label": null, "is_primary": true, "added_at": 1790000000},
       {"path": "/Users/ada/.hermes/hermes-agent", "label": null, "is_primary": false, "added_at": 1790000001}
     ]}
    """

    static let treeJSON = """
    {"projects": [
      {"id": "__no_project__", "label": "Home", "path": null, "color": null, "icon": null, "isAuto": false, "isNoProject": true,
       "sessionCount": 1, "lastActive": 1790000500, "totalTokens": 0, "totalCostUsd": 0,
       "repos": [{"id": "__no_project__", "label": "Home", "path": null, "sessionCount": 1,
                  "groups": [{"id": "__no_project__::home", "label": "Home", "path": null, "isMain": false, "isKanban": false, "sessions": []}]}],
       "previewSessions": [], "sessionIds": ["s_home"]},
      {"id": "p_4f2a9c1e", "label": "Hermes App", "path": "/Users/ada/Code/hermes-app", "color": "ocean", "icon": "chevron.left.forwardslash.chevron.right",
       "isAuto": false, "isNoProject": false, "sessionCount": 4, "lastActive": 1790000900, "totalTokens": 0, "totalCostUsd": 0,
       "repos": [{"id": "/Users/ada/Code/hermes-app", "label": "hermes-app", "path": "/Users/ada/Code/hermes-app", "sessionCount": 4, "groups": [
         {"id": "/Users/ada/Code/hermes-app::branch::main", "label": "main", "path": "/Users/ada/Code/hermes-app", "isMain": true, "isKanban": false, "isGit": true,
          "sessions": [{"id": "s_new", "_lineage_root_id": "s_root", "title": "Fix the reconnect", "preview": "Fix it", "last_active": 1790000900,
                        "message_count": 4, "cwd": "/Users/ada/Code/hermes-app", "git_branch": "main", "source": "hermes_app", "archived": false}]},
         {"id": "/Users/ada/Code/hermes-app-worktrees/push", "label": "push", "path": "/Users/ada/Code/hermes-app-worktrees/push", "isMain": false, "isKanban": false,
          "sessions": [{"id": "s_push", "title": "Push plugin", "git_branch": "feature/push", "message_count": 2},
                       {"id": "s_push2", "title": "Relay", "git_branch": "feature/push", "message_count": 2}]},
         {"id": "/Users/ada/Code/hermes-app::kanban", "label": "kanban", "path": "/Users/ada/Code/hermes-app/.worktrees", "isMain": false, "isKanban": true,
          "sessions": [{"id": "s_task", "title": "Snapshots", "message_count": 2}]}
       ]}],
       "previewSessions": [], "sessionIds": ["s_new", "s_push", "s_push2", "s_task"]},
      {"id": "/Users/ada/Code/site", "label": "site", "path": "/Users/ada/Code/site", "color": null, "icon": null, "isAuto": true, "isNoProject": false,
       "sessionCount": 1, "lastActive": 1790000100, "repos": [], "previewSessions": [], "sessionIds": ["s_site"]}
    ], "active_id": "p_gone", "scoped_session_ids": ["s_home", "s_new", "s_push", "s_push2", "s_task", "s_site"]}
    """

    @Test func parsesProjectInfo() throws {
        let project = try #require(HermesProject(json: JSONValue.parse(Self.projectJSON)))
        #expect(project.id == "p_4f2a9c1e")
        #expect(project.icon == "chevron.left.forwardslash.chevron.right")
        #expect(project.primaryPath == "/Users/ada/Code/hermes-app")
        #expect(project.folders.count == 2)
        #expect(project.orderedFolders.first?.isPrimary == true)
        #expect(project.folders[1].name == "hermes-agent")
    }

    @Test func parsesTreeAndLanes() throws {
        let tree = ProjectTree(json: try #require(JSONValue.parse(Self.treeJSON)))
        // The flat history leaves out only chats in projects someone made, not Home or auto ones,
        // although `scoped_session_ids` lists them all.
        #expect(tree.explicitProjects.map(\.id) == ["p_4f2a9c1e"])
        #expect(tree.explicitSessionIDs == ["s_new", "s_push", "s_push2", "s_task"])
        #expect(tree.scopedSessionIDs.contains("s_home"))
        // An active id can outlive its project.
        #expect(tree.activeID == "p_gone")
        #expect(tree.node(id: "p_gone") == nil)

        let node = try #require(tree.node(id: "p_4f2a9c1e"))
        #expect(node.lanes.map(\.kind) == [.main, .worktree, .tasks])
        #expect(node.lanes[0].branch == "main")
        #expect(node.branchCount == 2)
        #expect(node.taskCount == 1)
        let row = try #require(node.lanes[0].sessions.first)
        #expect(row.stableID == "s_root")
        #expect(row.session.lineageRootID == "s_root")
        #expect(row.cwd == "/Users/ada/Code/hermes-app")
        // The Home lane leaves out isGit; the contract's default is true.
        #expect(tree.node(id: "__no_project__")?.lanes.first?.isGit == true)
        #expect(tree.node(id: "__no_project__")?.isNoProject == true)
    }

    @Test func parsesFacts() throws {
        let json = try #require(JSONValue.parse("""
        {"root": "/r", "manifests": ["pyproject.toml"], "packageManagers": ["uv"], "verifyCommands": ["pytest"], "contextFiles": ["AGENTS.md"]}
        """))
        let facts = try #require(ProjectFacts(json: json))
        #expect(facts.verifyCommands == ["pytest"])
        #expect(!facts.isEmpty)
        #expect(ProjectFacts(json: .null) == nil)
    }

    @Test func everyCallCarriesTheProfile() async throws {
        let recorder = Recorder()
        await recorder.set("projects.list") { _ in .object(["projects": .array([]), "active_id": .null]) }
        let projects = client(recorder)
        _ = try await projects.list()
        _ = try await projects.tree(previewLimit: 0)
        _ = try await projects.forCwd(nil)
        let calls = await recorder.calls
        #expect(calls.allSatisfy { $0.params["profile"] == .string("coder") })
        // preview_limit 0 would mean 3 on the gateway: never send it.
        #expect(calls[1].params["preview_limit"] == .number(1))
        // No cwd: the gateway's default folder. An empty one would mean the same, so it's left out.
        #expect(calls[2].params["cwd"] == nil)
    }

    @Test func defaultProfileSendsNoProfileKey() async throws {
        let recorder = Recorder()
        _ = try? await client(recorder, profile: nil).tree()
        #expect(await recorder.calls.first?.params["profile"] == nil)
    }

    @Test func createSendsTheDocumentedKeys() async throws {
        let recorder = Recorder()
        let reply = try #require(JSONValue.parse(Self.projectJSON))
        await recorder.set("projects.create") { _ in .object(["project": reply]) }
        let project = try await client(recorder).create(
            name: "Hermes App", folders: ["/Users/ada/Code/hermes-app"], primaryPath: "/Users/ada/Code/hermes-app",
            icon: "chevron.left.forwardslash.chevron.right", color: "ocean", use: true
        )
        #expect(project.name == "Hermes App")
        let params = try #require(await recorder.calls.first?.params)
        // The gateway rejects unknown keys (4000).
        #expect(Set(params.keys) == ["name", "folders", "primary_path", "icon", "color", "use", "profile"])
        #expect(params["use"] == .bool(true))
    }

    @Test func updateSendsOnlyWhatChanged() async throws {
        let recorder = Recorder()
        let reply = try #require(JSONValue.parse(Self.projectJSON))
        await recorder.set("projects.update") { _ in .object(["project": reply]) }
        _ = try await client(recorder).update(id: "p_4f2a9c1e", name: "Renamed")
        let params = try #require(await recorder.calls.first?.params)
        #expect(Set(params.keys) == ["id", "name", "profile"])
    }

    @Test func moveUsesTheStoredSessionKey() async throws {
        let recorder = Recorder()
        await recorder.set("session.workspace.move") { params in
            .object(["cwd": params["cwd"] ?? .null, "branch": .string("main"), "git_repo_root": .string("/r")])
        }
        let move = try await client(recorder).moveSession(sessionKey: "20261014_101010_abc", to: "/r")
        #expect(move.branch == "main")
        let params = try #require(await recorder.calls.first?.params)
        #expect(params["session_key"] == .string("20261014_101010_abc"))
        #expect(params["session_id"] == nil)
    }

    @Test func runningStatusesMatchTheDesktop() {
        #expect(ActiveSession(sessionKey: "a", status: "working").isRunning)
        #expect(ActiveSession(sessionKey: "a", status: "starting").isRunning)
        #expect(!ActiveSession(sessionKey: "a", status: "idle").isRunning)
    }

    @Test func fullFolderListingsAreAskedAgainByFirstLetter() async throws {
        let recorder = Recorder()
        await recorder.set("complete.path") { params in
            let word = params["word"]?.stringValue ?? ""
            if word == "~/" {
                // 30 entries, mostly dot-files: the cap hides the real folders.
                let items = (0..<29).map { JSONValue.object(["text": .string("~/.f\($0)"), "meta": .string("")]) }
                    + [.object(["text": .string("~/.Trash/"), "meta": .string("dir")])]
                return .object(["items": .array(items)])
            }
            if word == "~/c" { return .object(["items": .array([.object(["text": .string("~/Code/"), "meta": .string("dir")])])]) }
            if word == "~/d" { return .object(["items": .array([.object(["text": .string("~/Documents/"), "meta": .string("dir")]),
                                                                .object(["text": .string("~/data.txt"), "meta": .string("")])])]) }
            return .object(["items": .array([])])
        }
        let folders = try await client(recorder).folders(under: "~/")
        #expect(folders.contains("~/Documents/"))
        #expect(folders.contains("~/Code/"))
        #expect(!folders.contains("~/data.txt"))
        #expect(folders.contains("~/.Trash/"))
    }

    @Test func aProjectsTimeAndPlaceAreItsChatsNewestMessage() {
        let now = Date(timeIntervalSince1970: 1_760_600_000)
        func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }
        // dotfiles: last spoken in 32 days ago, a heartbeat 7 minutes ago. Blog: last spoken in 3 days
        // ago, compacted 25 minutes ago. Homelab: a reply 3 hours ago.
        let dotfiles = (rows: [RowTime.of(line: LastLine(speaker: .hermes, text: "Lazy now.", at: ago(32 * 86_400)), activity: ago(420), created: nil)],
                        activity: ago(420), id: "dotfiles")
        let blog = (rows: [RowTime.of(line: LastLine(speaker: .hermes, text: "Outline:", at: ago(3 * 86_400)), activity: ago(1500), created: nil),
                           RowTime.of(line: LastLine(speaker: .you, text: "RSS dates?", at: ago(6 * 86_400)), activity: ago(6 * 86_400), created: nil)],
                    activity: ago(1500), id: "blog")
        let homelab = (rows: [RowTime.of(line: LastLine(speaker: .hermes, text: "Upgraded.", at: ago(3 * 3600)), activity: ago(3 * 3600), created: nil)],
                       activity: ago(3 * 3600), id: "homelab")
        let times = Dictionary(uniqueKeysWithValues: [dotfiles, blog, homelab].map { project in
            (project.id, RowTime.ofProject(chats: project.rows, chatCount: project.rows.count, activity: project.activity, created: ago(60 * 86_400)))
        })
        // Neither the heartbeat nor the compaction moves its project.
        #expect(times["dotfiles"] == ago(32 * 86_400) && times["blog"] == ago(3 * 86_400))
        #expect(RowTime.ordered(["dotfiles", "blog", "homelab"], pinned: { _ in false }) { times[$0] ?? nil } == ["homelab", "blog", "dotfiles"])
        // A chat whose line isn't read yet stands at its activity, as a chat row does.
        #expect(RowTime.ofProject(chats: [RowTime.of(line: nil, activity: ago(420), created: nil)], chatCount: 1, activity: ago(420), created: nil) == ago(420))
        // No chats known yet: Hermes' activity stands in. No chats at all: when it was made.
        #expect(RowTime.ofProject(chats: [], chatCount: 4, activity: ago(420), created: ago(86_400)) == ago(420))
        #expect(RowTime.ofProject(chats: [], chatCount: 0, activity: nil, created: ago(86_400)) == ago(86_400))
    }

    // MARK: Archiving a chat from a project

    private func hermesApp() throws -> ProjectNode {
        let json = try #require(JSONValue.parse(Self.treeJSON))
        return try #require(ProjectTree(json: json).node(id: "p_4f2a9c1e"))
    }

    /// The project as the gateway reads it once a chat is archived: the row is gone, and a lane
    /// goes with its last chat.
    private func withoutChat(_ id: String, from node: ProjectNode) -> ProjectNode {
        var node = node
        for r in node.repos.indices {
            for l in node.repos[r].lanes.indices where node.repos[r].lanes[l].sessions.contains(where: { $0.id == id }) {
                node.repos[r].lanes[l].sessions.removeAll { $0.id == id }
                node.repos[r].sessionCount -= 1
            }
            node.repos[r].lanes.removeAll { $0.sessions.isEmpty }
        }
        node.sessionIDs.removeAll { $0 == id }
        node.sessionCount -= 1
        return node
    }

    @Test func anArchivedChatLeavesItsLaneAtOnce() throws {
        let node = try hermesApp()
        var changes = ProjectChatChanges()
        #expect(changes.archiving(key: "s_push", ids: ["s_push"], in: [node]) == "p_4f2a9c1e")

        let shown = changes.applied(to: node, hydrated: true)
        #expect(shown.lanes[1].sessions.map(\.id) == ["s_push2"])
        #expect(shown.sessionCount == 3 && shown.repos[0].sessionCount == 3)
        #expect(!shown.sessionIDs.contains("s_push"))
        // A compressed chat is found by its lineage root as well as its stored id.
        #expect(changes.archiving(key: "s_root", ids: ["s_new", "s_root"], in: [node]) == "p_4f2a9c1e")
        #expect(changes.applied(to: node, hydrated: true).lanes[0].sessions.isEmpty)
        // A chat no project has is left alone.
        #expect(changes.archiving(key: "s_elsewhere", ids: ["s_elsewhere"], in: [node]) == nil)
    }

    @Test func aReadFromBeforeTheArchiveLandedDoesNotBringTheRowBack() throws {
        let node = try hermesApp()
        let start = Date(timeIntervalSince1970: 1_790_001_000)
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_push", ids: ["s_push"], in: [node])
        // In flight: no read drops it, however late it started.
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(60))
        #expect(changes.change(for: "s_push") == .archived)

        changes.landed(.archived, key: "s_push", at: start)
        // A read that started before the archive landed still has the row: hidden.
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(-1))
        #expect(!changes.applied(to: node, hydrated: true).hydratedSessions.contains { $0.id == "s_push" })
        // A read of another project changes nothing here.
        changes.read(projectID: "p_other", startedAt: start.addingTimeInterval(1))
        #expect(changes.change(for: "s_push") == .archived)
        // One that started after it has the gateway's word for it: the change is done.
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(1))
        #expect(changes.isEmpty)
        // Counting the gateway's answer once: an absent row is not taken off again.
        let read = withoutChat("s_push", from: node)
        var again = ProjectChatChanges()
        again.archiving(key: "s_push", ids: ["s_push"], in: [node])
        #expect(again.applied(to: read, hydrated: true).sessionCount == 3)
    }

    @Test func undoPutsTheRowBackWhereItWas() throws {
        let node = try hermesApp()
        let start = Date(timeIntervalSince1970: 1_790_001_000)
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_push", ids: ["s_push"], in: [node])
        changes.landed(.archived, key: "s_push", at: start)
        // The read after the archive dropped the row; Undo brings it back before its call lands.
        let read = withoutChat("s_push", from: node)
        changes.restoring(key: "s_push")
        let shown = changes.applied(to: read, hydrated: true)
        #expect(shown.lanes[1].sessions.map(\.id) == ["s_push", "s_push2"])
        #expect(shown.sessionCount == 4 && shown.repos[0].sessionCount == 4)
        #expect(shown.sessionIDs.contains("s_push"))
        // A read that still has it, or the tree's lanes, which carry no chats, get no second copy.
        #expect(changes.applied(to: node, hydrated: true) == node)
        // The archive answering after Undo doesn't count as the unarchive.
        changes.landed(.archived, key: "s_push", at: start.addingTimeInterval(4))
        // In flight, a read can't drop the Undo; once the unarchive landed, a later read does.
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(5))
        #expect(changes.change(for: "s_push") == .restored)
        changes.landed(.restored, key: "s_push", at: start.addingTimeInterval(6))
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(7))
        #expect(changes.isEmpty)
    }

    @Test func undoWorksAfterAReadThatAlreadyHadTheArchive() throws {
        let node = try hermesApp()
        let start = Date(timeIntervalSince1970: 1_790_001_000)
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_push", ids: ["s_push"], in: [node])
        changes.landed(.archived, key: "s_push", at: start)
        // A read after the archive landed, while its Undo still shows, keeps it.
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(1), keeping: "s_push")
        #expect(changes.change(for: "s_push") == .archived)
        changes.restoring(key: "s_push")
        let shown = changes.applied(to: withoutChat("s_push", from: node), hydrated: true)
        #expect(shown.lanes[1].sessions.map(\.id) == ["s_push", "s_push2"])
        #expect(shown.sessionIDs.contains("s_push"))
        // Once the unarchive landed, a later read drops the Undo even with the toast still up.
        changes.landed(.restored, key: "s_push", at: start.addingTimeInterval(2))
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(3), keeping: "s_push")
        #expect(changes.isEmpty)
    }

    @Test func undoBringsBackALaneThatWentWithItsLastChat() throws {
        let node = try hermesApp()
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_task", ids: ["s_task"], in: [node])
        #expect(changes.applied(to: node, hydrated: true).taskCount == 0)
        let read = withoutChat("s_task", from: node)
        #expect(read.lanes.count == 2)
        changes.restoring(key: "s_task")
        let shown = changes.applied(to: read, hydrated: true)
        #expect(shown.lanes.map(\.kind) == [.main, .worktree, .tasks])
        #expect(shown.taskCount == 1 && shown.sessionCount == 4)
    }

    @Test func aFailedArchiveOrUnarchiveLeavesTheGatewaysAnswer() throws {
        let node = try hermesApp()
        let start = Date(timeIntervalSince1970: 1_790_001_000)
        var changes = ProjectChatChanges()
        // The archive failed: the row was never archived.
        changes.archiving(key: "s_push", ids: ["s_push"], in: [node])
        changes.forget(key: "s_push")
        #expect(changes.applied(to: node, hydrated: true) == node)
        // The unarchive failed after the archive landed: the chat stays archived until a read
        // after that says so.
        changes.archiving(key: "s_push", ids: ["s_push"], in: [node])
        changes.landed(.archived, key: "s_push", at: start)
        changes.restoring(key: "s_push")
        changes.archivedAgain(key: "s_push", at: start.addingTimeInterval(2))
        #expect(!changes.applied(to: node, hydrated: true).hydratedSessions.contains { $0.id == "s_push" })
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(1))
        #expect(changes.change(for: "s_push") == .archived)
        changes.read(projectID: "p_4f2a9c1e", startedAt: start.addingTimeInterval(3))
        #expect(changes.isEmpty)
    }

    @Test func theTreeLosesAnArchivedChatToo() throws {
        let tree = ProjectTree(json: try #require(JSONValue.parse(Self.treeJSON)))
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_task", ids: ["s_task"], in: tree.explicitProjects)
        let shown = changes.applied(to: tree)
        #expect(shown.explicitSessionIDs == ["s_new", "s_push", "s_push2"])
        #expect(shown.node(id: "p_4f2a9c1e")?.sessionCount == 3)
        #expect(shown.node(id: "__no_project__") == tree.node(id: "__no_project__"))
    }

    @Test func aChatBroughtBackWithUndoStaysInItsProject() throws {
        let tree = ProjectTree(json: try #require(JSONValue.parse(Self.treeJSON)))
        // A tree read while the chat was archived, which doesn't list it anywhere.
        let readWhileArchived = ProjectTree(json: try #require(JSONValue.parse(Self.treeJSON
            .replacingOccurrences(of: #"{"id": "s_push", "title": "Push plugin", "git_branch": "feature/push", "message_count": 2},"#, with: "")
            .replacingOccurrences(of: #""s_push", "#, with: ""))))
        #expect(readWhileArchived.projectIndex()["s_push"] == nil)
        var changes = ProjectChatChanges()
        changes.archiving(key: "s_push", ids: ["s_push"], in: tree.explicitProjects)
        #expect(changes.applied(to: tree).projectIndex()["s_push"] == nil)
        // Undo: the index built from what's shown keeps it out of the flat history again.
        changes.restoring(key: "s_push")
        let index = changes.applied(to: readWhileArchived).projectIndex()
        #expect(index["s_push"] == "p_4f2a9c1e")
        // Compressed chats are found by their lineage root too; Home and auto projects aren't scoped.
        #expect(index["s_new"] == "p_4f2a9c1e" && index["s_root"] == "p_4f2a9c1e")
        #expect(index["s_home"] == nil && index["s_site"] == nil)
    }

    @Test func abbreviatesHomeFolders() {
        #expect(ProjectPath.abbreviated("/Users/ada/Code/app") == "~/Code/app")
        #expect(ProjectPath.abbreviated("/home/ada/blog") == "~/blog")
        #expect(ProjectPath.abbreviated("/srv/data") == "/srv/data")
        #expect(ProjectPath.contains("/a/b", "/a/b/c"))
        #expect(!ProjectPath.contains("/a/b", "/a/bc"))
        #expect(ProjectPath.lastComponent("/a/b/") == "b")
    }
}
