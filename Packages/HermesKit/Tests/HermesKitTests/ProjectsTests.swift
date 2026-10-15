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

    @Test func abbreviatesHomeFolders() {
        #expect(ProjectPath.abbreviated("/Users/ada/Code/app") == "~/Code/app")
        #expect(ProjectPath.abbreviated("/home/ada/blog") == "~/blog")
        #expect(ProjectPath.abbreviated("/srv/data") == "/srv/data")
        #expect(ProjectPath.contains("/a/b", "/a/b/c"))
        #expect(!ProjectPath.contains("/a/b", "/a/bc"))
        #expect(ProjectPath.lastComponent("/a/b/") == "b")
    }
}
