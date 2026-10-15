import Foundation

/// The gateway's projects calls (`tui_gateway/methods_projects.py`, `methods_config.py`) and the
/// session calls that place a chat in a folder. Every call is scoped to one Hermes profile: the
/// projects database lives in that profile's home.
///
/// The gateway rejects parameters it doesn't know (error 4000), so only documented keys are sent.
public struct ProjectsClient: Sendable {
    /// Sends one request over whichever socket the caller has.
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    /// Error codes from `methods_projects.py`.
    public enum Code {
        public static let failed = 5061
        public static let notFound = 5062
        /// Bad input, including a primary folder that is already another project's.
        public static let invalid = 5063
    }

    let profile: String?
    let transport: Transport

    public init(profile: String?, transport: @escaping Transport) {
        self.profile = profile
        self.transport = transport
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params = params
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return try await transport(method, params)
    }

    private func project(from result: JSONValue) throws -> HermesProject {
        guard let project = HermesProject(json: result["project"]) else { throw GatewayRPCError(code: Code.notFound, message: "no such project") }
        return project
    }

    private static func projects(from result: JSONValue) -> (projects: [HermesProject], activeID: String?) {
        let rows: [HermesProject] = if case .array(let rows)? = result["projects"] { rows.compactMap(HermesProject.init(json:)) } else { [] }
        return (rows, result["active_id"]?.stringValue)
    }

    // MARK: Reading

    /// Projects → repos → lanes, with the newest `previewLimit` chats per project. Lanes come back
    /// without their chats; `projectSessions` fills them for one project.
    public func tree(previewLimit: Int = 3, sessionLimit: Int = 2000) async throws -> ProjectTree {
        ProjectTree(json: try await call("projects.tree", [
            "preview_limit": .number(Double(max(previewLimit, 1))),
            "session_limit": .number(Double(sessionLimit)),
        ]))
    }

    /// One project with every lane's chats. `nil` for a project with no chats yet that the tree
    /// only knows from disk.
    public func projectSessions(projectID: String, sessionLimit: Int = 5000) async throws -> ProjectNode? {
        let result = try await call("projects.project_sessions", [
            "project_id": .string(projectID),
            "session_limit": .number(Double(sessionLimit)),
        ])
        return result["project"].flatMap(ProjectNode.init(json:))
    }

    /// Every project including archived ones, oldest first, and the active one's id.
    public func list() async throws -> (projects: [HermesProject], activeID: String?) {
        Self.projects(from: try await call("projects.list"))
    }

    public func get(id: String) async throws -> HermesProject {
        try project(from: try await call("projects.get", ["id": .string(id)]))
    }

    /// Git folders Hermes has worked in, newest first. `scan` asks the gateway to walk its
    /// configured roots (a no-op unless the owner set some).
    public func discoverRepos(scan: Bool = false) async throws -> [DiscoveredRepo] {
        let result = try await call("projects.discover_repos", ["scan": .bool(scan)])
        guard case .array(let rows)? = result["repos"] else { return [] }
        return rows.compactMap(DiscoveredRepo.init(json:))
    }

    /// The project a folder is in, and its branch. Without a folder, the gateway's default
    /// folder. A folder that doesn't exist also resolves to the default folder.
    public func forCwd(_ cwd: String?) async throws -> ProjectLocation {
        var params: [String: JSONValue] = [:]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        let result = try await call("projects.for_cwd", params)
        return ProjectLocation(
            project: HermesProject(json: result["project"]),
            cwd: result["cwd"]?.stringValue ?? cwd ?? "",
            branch: result["branch"]?.stringValue ?? ""
        )
    }

    /// What Hermes knows about a folder; `nil` outside a recognisable workspace.
    public func facts(cwd: String) async throws -> ProjectFacts? {
        let result = try await call("project.facts", ["cwd": .string(cwd)])
        return ProjectFacts(json: result["facts"])
    }

    // MARK: Writing

    /// Creates a project. The primary folder goes first; `use` also makes it the active project.
    /// Fails with 5063 when the primary folder already belongs to a project.
    public func create(name: String, folders: [String], primaryPath: String?, icon: String?, color: String?, use: Bool) async throws -> HermesProject {
        var params: [String: JSONValue] = [
            "name": .string(name),
            "folders": .array(folders.map(JSONValue.string)),
            "use": .bool(use),
        ]
        if let primaryPath { params["primary_path"] = .string(primaryPath) }
        if let icon { params["icon"] = .string(icon) }
        if let color { params["color"] = .string(color) }
        return try project(from: try await call("projects.create", params))
    }

    /// Changes the given fields only; the others stay as they are (another client may have
    /// written values this app doesn't draw).
    public func update(id: String, name: String? = nil, description: String? = nil, icon: String? = nil, color: String? = nil) async throws -> HermesProject {
        var params: [String: JSONValue] = ["id": .string(id)]
        if let name { params["name"] = .string(name) }
        if let description { params["description"] = .string(description) }
        if let icon { params["icon"] = .string(icon) }
        if let color { params["color"] = .string(color) }
        return try project(from: try await call("projects.update", params))
    }

    public func addFolder(id: String, path: String, isPrimary: Bool = false) async throws -> HermesProject {
        // An empty path would mean the gateway's own folder.
        guard !path.isEmpty else { throw GatewayRPCError(code: Code.invalid, message: "folder path required") }
        return try project(from: try await call("projects.add_folder", [
            "id": .string(id), "path": .string(path), "is_primary": .bool(isPrimary),
        ]))
    }

    public func removeFolder(id: String, path: String) async throws -> HermesProject {
        try project(from: try await call("projects.remove_folder", ["id": .string(id), "path": .string(path)]))
    }

    public func setPrimary(id: String, path: String) async throws -> HermesProject {
        try project(from: try await call("projects.set_primary", ["id": .string(id), "path": .string(path)]))
    }

    /// Archives (or restores) a project. Its chats stay where they are.
    @discardableResult
    public func archive(id: String, restore: Bool = false) async throws -> [HermesProject] {
        Self.projects(from: try await call("projects.archive", ["id": .string(id), "restore": .bool(restore)])).projects
    }

    /// Deletes a project. Its chats are kept; they go back to the flat history.
    @discardableResult
    public func delete(id: String) async throws -> [HermesProject] {
        Self.projects(from: try await call("projects.delete", ["id": .string(id)])).projects
    }

    /// Where new chats start from anywhere; `nil` clears it (No Project).
    @discardableResult
    public func setActive(id: String?) async throws -> String? {
        let result = try await call("projects.set_active", ["id": id.map(JSONValue.string) ?? .null])
        return result["active_id"]?.stringValue
    }

    // MARK: Chats

    /// Moves a chat's workspace to another folder. A running agent follows, even mid-turn.
    /// `sessionKey` is the stored session id.
    public func moveSession(sessionKey: String, to cwd: String) async throws -> WorkspaceMove {
        let result = try await call("session.workspace.move", ["session_key": .string(sessionKey), "cwd": .string(cwd)])
        return WorkspaceMove(
            cwd: result["cwd"]?.stringValue ?? cwd,
            branch: result["branch"]?.stringValue ?? "",
            gitRepoRoot: result["git_repo_root"]?.stringValue ?? ""
        )
    }

    /// Chats Hermes is running now, by stored session id.
    public func activeSessions() async throws -> [ActiveSession] {
        let result = try await call("session.active_list")
        guard case .array(let rows)? = result["sessions"] else { return [] }
        return rows.compactMap { row in
            guard let key = row["session_key"]?.stringValue ?? row["id"]?.stringValue else { return nil }
            return ActiveSession(sessionKey: key, status: row["status"]?.stringValue ?? "idle")
        }
    }

    /// Folders under `word` on the gateway (`complete.path`), for choosing another folder.
    /// `word` ends with `/` and starts with `~/` or `/`; results keep that form.
    ///
    /// `complete.path` stops at 30 entries, files and dot-entries included, so a busy folder (a
    /// home folder) would hide most of its folders. When a listing comes back full, the folder is
    /// asked again per first character (the gateway matches names by prefix) and merged.
    public func folders(under word: String) async throws -> [String] {
        let first = try await listing(word)
        guard first.total >= 30, word.hasSuffix("/") else { return first.folders }
        let starts = "abcdefghijklmnopqrstuvwxyz0123456789_".map(String.init)
        var found = Set(first.folders)
        try await withThrowingTaskGroup(of: [String].self) { group in
            for start in starts {
                group.addTask { try await self.listing(word + start).folders }
            }
            for try await folders in group { found.formUnion(folders) }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func listing(_ word: String) async throws -> (folders: [String], total: Int) {
        let result = try await call("complete.path", ["word": .string(word)])
        guard case .array(let items)? = result["items"] else { return ([], 0) }
        let folders = items.compactMap { item -> String? in
            guard item["meta"]?.stringValue == "dir" || item["kind"]?.stringValue == "dir", let text = item["text"]?.stringValue else { return nil }
            return text
        }
        return (folders, items.count)
    }
}
