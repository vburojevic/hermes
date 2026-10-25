import Foundation
import HermesKit
import Observation

/// Where a new chat runs (Run In): a project's primary folder, one of its worktrees, a new
/// worktree, or the gateway's default folder (no project).
struct ChatPlacement: Equatable {
    var projectID: String?
    /// The folder `session.create` gets; `nil` lets the gateway pick its default.
    var cwd: String?
    /// The branch the chat runs on, when known (shown on iPad and Mac).
    var branch: String?
    /// Make a worktree on a new branch for this chat when it starts.
    var newWorktree = false

    static let noProject = ChatPlacement()
}

/// One gateway's projects (`docs/projects.md`): the tree from `projects.tree`, the projects
/// themselves (including archived ones), and what the app derives from them. Refreshed on
/// `projects.changed` and `sessions.changed`. Every call runs in this gateway's profile.
@MainActor
@Observable
final class ProjectsModel {
    @ObservationIgnored private weak var workspace: BotWorkspace?

    /// The gateway answered `projects.tree`; an older Hermes or an API-server-only gateway has no
    /// projects, and the app shows none.
    private(set) var isAvailable = false
    private(set) var hasLoaded = false
    private(set) var tree = ProjectTree()
    /// Every project, archived ones too, by id.
    private(set) var projects: [String: HermesProject] = [:]
    /// Lanes with their chats, per project (`projects.project_sessions`).
    private(set) var details: [String: ProjectNode] = [:]
    /// What Hermes knows about a folder, by path (`nil` value: nothing).
    private(set) var facts: [String: ProjectFacts?] = [:]
    /// The branch a folder's checkout is on, by path.
    private(set) var branches: [String: String] = [:]
    private(set) var discovered: [DiscoveredRepo] = []
    /// Chats Hermes is running now, by stored session id.
    private(set) var running: Set<String> = []
    /// The gateway's default folder (for "No Project").
    private(set) var defaultFolder: String?
    private(set) var lastError: String?

    /// Projects pinned to the sidebar, in pin order (kept on this device, like the desktop's).
    private(set) var pinnedIDs: [String]
    /// Expanded Mac disclosure rows, by project id.
    var expandedIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(expandedIDs), forKey: key("expanded")) }
    }
    /// The lane the project home scrolls to (a Mac lane row was clicked).
    var focusLane: String?

    /// Sheets.
    var editing: ProjectEditorTarget?
    var movingSession: HermesSession?
    var runInConversation: ConversationModel?
    /// Add Folder… from the project menu.
    var addingFolder: String?
    /// Delete Project… waiting for its confirmation.
    var deleting: String?

    /// Chats this device just started in a project, before the tree has caught up.
    @ObservationIgnored private var placedSessions: [String: String] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activeFetch: Task<[ActiveSession]?, Never>?
    @ObservationIgnored private var activeFetched: (at: Date, rows: [ActiveSession])?
    @ObservationIgnored private var sessionIndex: [String: String] = [:]

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        let defaults = UserDefaults.standard
        let base = "projects.\(workspace.id.uuidString).\(workspace.bot.profileName ?? "default")"
        pinnedIDs = defaults.stringArray(forKey: "\(base).pinned") ?? []
        expandedIDs = Set(defaults.stringArray(forKey: "\(base).expanded") ?? [])
    }

    private func key(_ name: String) -> String {
        "projects.\(workspace?.id.uuidString ?? "").\(workspace?.bot.profileName ?? "default").\(name)"
    }

    var client: ProjectsClient? {
        guard let roster = workspace?.roster, roster.isConnected else { return nil }
        return ProjectsClient(profile: workspace?.bot.profileName) { method, params in
            try await roster.request(method, params)
        }
    }

    // MARK: Reading

    /// Projects someone made, not archived, oldest first (the gateway's order).
    var activeProjects: [HermesProject] {
        tree.explicitProjects.compactMap { projects[$0.id] ?? Self.project(from: $0) }
    }

    var archivedProjects: [HermesProject] {
        projects.values.filter(\.archived).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The sidebar's projects: pinned ones first, then by their time (`rowTime`), at most five.
    var sidebarProjects: [ProjectNode] {
        let nodes = tree.explicitProjects
        let pinned = pinnedIDs.compactMap { id in nodes.first { $0.id == id } }
        let rest = byTime(nodes.filter { !pinnedIDs.contains($0.id) })
        return Array((pinned + rest).prefix(5))
    }

    /// All Projects: projects someone made, newest first by their time (`rowTime`).
    var projectsByActivity: [ProjectNode] {
        byTime(tree.explicitProjects)
    }

    private func byTime(_ nodes: [ProjectNode]) -> [ProjectNode] {
        RowTime.ordered(nodes, pinned: { _ in false }) { self.rowTime($0) }
    }

    /// A project's time and place (`RowTime.ofProject`, `docs/projects.md` §2): the newest row
    /// time of the chats the app has for it, not the tree's `lastActive`, which a heartbeat or a
    /// compaction in any of its chats moves.
    func rowTime(_ node: ProjectNode) -> Date? {
        guard let workspace else { return node.lastActive }
        var times = chats(in: node.id).map(workspace.rowTime)
        times += workspace.sessions.filter { projectID(forSession: $0) == node.id }.map(workspace.rowTime)
        return RowTime.ofProject(chats: times, chatCount: node.sessionCount, activity: node.lastActive,
                                 created: projects[node.id]?.createdAt)
    }

    /// The chats the app has for a project: its lanes' once they're loaded, and the tree's newest few.
    func chats(in projectID: String) -> [ProjectSessionRow] {
        (details[projectID]?.hydratedSessions ?? []) + (tree.node(id: projectID)?.previewSessions ?? [])
    }

    func node(_ id: String) -> ProjectNode? {
        details[id] ?? tree.node(id: id)
    }

    func project(_ id: String) -> HermesProject? {
        projects[id] ?? tree.node(id: id).map(Self.project(from:))
    }

    func appearance(_ id: String) -> ProjectAppearance {
        if let project = projects[id] { return ProjectAppearance(project) }
        if let node = tree.node(id: id) { return ProjectAppearance(node) }
        return ProjectAppearance(color: nil, icon: nil)
    }

    func isPinned(_ id: String) -> Bool {
        pinnedIDs.contains(id)
    }

    /// The project a chat belongs to (projects someone made only), by stored or stable id.
    func projectID(forSession session: HermesSession) -> String? {
        sessionIndex[session.id] ?? sessionIndex[session.stableID] ?? placedSessions[session.id] ?? placedSessions[session.stableID]
    }

    func projectID(forSessionID id: String) -> String? {
        sessionIndex[id] ?? placedSessions[id]
    }

    /// The branch lane a chat sits in, once its project's chats are known.
    func lane(forSessionID id: String) -> String? {
        guard let projectID = projectID(forSessionID: id) else { return nil }
        return chats(in: projectID).first { $0.id == id || $0.stableID == id || $0.lineageRootID == id }?.gitBranch
    }

    /// Whether the flat history leaves this chat out (it's in a project); Pinned keeps it.
    func isScoped(_ session: HermesSession) -> Bool {
        projectID(forSession: session) != nil
    }

    func isRunning(sessionID id: String) -> Bool {
        running.contains(id) || (workspace?.isWorking(sessionKey: id) ?? false)
    }

    /// Whether any chat in the project is running (the sidebar's working dot).
    func isWorking(_ projectID: String) -> Bool {
        guard let node = tree.node(id: projectID) else { return false }
        if node.sessionIDs.contains(where: isRunning(sessionID:)) { return true }
        return placedSessions.contains { $0.value == projectID && isRunning(sessionID: $0.key) }
    }

    /// The project new chats start in, if it still exists and isn't archived.
    var activeProjectID: String? {
        guard let id = tree.activeID, tree.explicitProjects.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Where a new chat starts: the active project's primary folder, else the gateway's default.
    var defaultPlacement: ChatPlacement {
        guard let id = activeProjectID else { return .noProject }
        return placement(in: id)
    }

    func placement(in projectID: String) -> ChatPlacement {
        let path = project(projectID)?.primaryPath ?? tree.node(id: projectID)?.path
        return ChatPlacement(projectID: projectID, cwd: path, branch: path.flatMap { branches[$0] })
    }

    func branch(of path: String?) -> String? {
        guard let path, let branch = branches[path], !branch.isEmpty else { return nil }
        return branch
    }

    /// Repos Hermes found that aren't in a project yet ("Found on Studio Mac").
    var suggestedRepos: [DiscoveredRepo] {
        // Archived projects keep their folders: those aren't new finds either.
        let folders = Set(projects.values.flatMap { $0.folders.map(\.path) })
        return discovered.filter { !folders.contains($0.root) }
    }

    /// The project a folder already belongs to, for "homelab · in Homelab".
    func owner(ofFolder path: String, excluding projectID: String? = nil) -> HermesProject? {
        projects.values.first { project in
            !project.archived && project.id != projectID && project.folders.contains { $0.path == path }
        }
    }

    // MARK: Refreshing

    /// The socket (re)connected: load everything.
    func connected() {
        scheduleRefresh(delay: 0)
        startPolling()
    }

    func disconnected() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// `projects.changed` / `sessions.changed`: the gateway's store moved under us.
    func changeEvent(_ type: String) {
        scheduleRefresh(delay: 0.25, includeProjects: type == "projects.changed")
    }

    /// The desktop re-pulls running chats every 30 s even with change events; turns that start
    /// and end on other clients don't otherwise show. Every 2 minutes while the Mac app is behind
    /// other apps.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Double = AppPresence.isInBack ? 120 : 30
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
                guard !Task.isCancelled, let self else { return }
                await self.refreshRunning()
            }
        }
    }

    func scheduleRefresh(delay: Double = 0.25, includeProjects: Bool = true) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.refresh(includeProjects: includeProjects)
        }
    }

    func refresh(includeProjects: Bool = true) async {
        guard let client else { return }
        let current = Array(projects.values)
        let needsList = includeProjects || current.isEmpty
        do {
            async let tree = client.tree()
            async let list = needsList ? client.list().projects : current
            let (freshTree, freshList) = try await (tree, list)
            apply(tree: freshTree, projects: freshList)
            isAvailable = true
            lastError = nil
        } catch let error as GatewayRPCError where error.code == -32601 {
            isAvailable = false
        } catch is CancellationError {
            return
        } catch {
            lastError = error.localizedDescription
        }
        hasLoaded = true
        await refreshRunning()
        for id in details.keys {
            await loadDetail(id)
        }
        if defaultFolder == nil, let location = try? await client.forCwd(nil) {
            defaultFolder = location.cwd
        }
        for project in activeProjects {
            if let path = project.primaryPath, branches[path] == nil { await loadBranch(path) }
        }
    }

    private func apply(tree fresh: ProjectTree, projects list: [HermesProject]) {
        var index: [String: String] = [:]
        for node in fresh.explicitProjects {
            for id in node.sessionIDs { index[id] = node.id }
        }
        // Rows that came back with their lineage root (compressed chats) are found either way.
        for node in fresh.explicitProjects {
            for row in node.previewSessions + node.hydratedSessions where row.stableID != row.id {
                index[row.stableID] = node.id
            }
        }
        for (id, project) in placedSessions where index[id] != nil || fresh.scopedSessionIDs.contains(id) {
            // The tree knows where it is now; keep the local placement only until then.
            if index[id] == project || fresh.scopedSessionIDs.contains(id) { placedSessions[id] = nil }
        }
        sessionIndex = index
        if fresh != tree {
            tree = fresh
            // Its projects' newest chats, for the projects' times.
            workspace?.unread.readStaleLines()
        }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if byID != projects { projects = byID }
        let known = Set(byID.keys)
        let pins = pinnedIDs.filter { known.contains($0) }
        if pins != pinnedIDs { setPins(pins) }
    }

    func refreshRunning() async {
        _ = await activeSessions()
    }

    /// `session.active_list`, shared. The chat list's live lines and the projects' running chats
    /// ask at the same moments (a change event, the polls), and one answer serves both: a request
    /// under way is joined, and an answer under 2 s old is reused. Each answer also updates
    /// `running`.
    func activeSessions() async -> [ActiveSession]? {
        if let activeFetched, Date.now.timeIntervalSince(activeFetched.at) < 2 { return activeFetched.rows }
        if let activeFetch { return await activeFetch.value }
        guard let client else { return nil }
        let fetch = Task { try? await client.activeSessions() }
        activeFetch = fetch
        let rows = await fetch.value
        activeFetch = nil
        guard let rows else { return nil }
        activeFetched = (.now, rows)
        let ids = Set(rows.filter(\.isRunning).map(\.sessionKey))
        if ids != running { running = ids }
        return rows
    }

    /// One project's lanes with their chats (the project home).
    func loadDetail(_ id: String) async {
        guard let client else { return }
        do {
            if let node = try await client.projectSessions(projectID: id) {
                for row in node.hydratedSessions where row.stableID != row.id {
                    sessionIndex[row.stableID] = id
                }
                if details[id] != node { details[id] = node }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadFacts(_ path: String) async {
        guard let client, facts[path] == nil else { return }
        let found = try? await client.facts(cwd: path)
        facts[path] = .some(found)
    }

    func loadBranch(_ path: String) async {
        guard let client, let location = try? await client.forCwd(path) else { return }
        branches[path] = location.branch
    }

    func loadDiscovered() async {
        guard let client, let repos = try? await client.discoverRepos() else { return }
        if repos != discovered { discovered = repos }
    }

    // MARK: Pins

    func setPinned(_ id: String, _ pinned: Bool) {
        var pins = pinnedIDs.filter { $0 != id }
        if pinned { pins.insert(id, at: 0) }
        setPins(pins)
    }

    private func setPins(_ pins: [String]) {
        pinnedIDs = pins
        UserDefaults.standard.set(pins, forKey: key("pinned"))
    }

    // MARK: Writing

    /// Creates a project; `use` also makes it the active one (New Project does, Add doesn't).
    func create(name: String, folders: [String], primary: String?, appearance: ProjectAppearance, use: Bool = true) async throws -> HermesProject {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        let project = try await client.create(
            name: name, folders: folders, primaryPath: primary, icon: appearance.glyph.rawValue, color: appearance.accent.rawValue, use: use
        )
        projects[project.id] = project
        WelcomeProgress.shared.mark(.meetBots)
        await refresh()
        return project
    }

    /// Saves the name and look, sending only what changed: another client may have stored values
    /// this app draws differently.
    func update(_ project: HermesProject, name: String, appearance: ProjectAppearance) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        let old = ProjectAppearance(project)
        let updated = try await client.update(
            id: project.id,
            name: name == project.name ? nil : name,
            icon: appearance.glyph == old.glyph && project.icon != nil ? nil : appearance.glyph.rawValue,
            color: appearance.accent == old.accent && project.color != nil ? nil : appearance.accent.rawValue
        )
        projects[updated.id] = updated
        scheduleRefresh(delay: 0)
    }

    func addFolder(_ path: String, to project: HermesProject) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        projects[project.id] = try await client.addFolder(id: project.id, path: path)
        scheduleRefresh(delay: 0)
    }

    func removeFolder(_ path: String, from project: HermesProject) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        projects[project.id] = try await client.removeFolder(id: project.id, path: path)
        scheduleRefresh(delay: 0)
    }

    func makePrimary(_ path: String, in project: HermesProject) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        projects[project.id] = try await client.setPrimary(id: project.id, path: path)
        scheduleRefresh(delay: 0)
    }

    func archive(_ id: String, restore: Bool = false) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        let list = try await client.archive(id: id, restore: restore)
        projects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !restore {
            setPinned(id, false)
            leaveProjectHome(id)
        }
        await refresh()
    }

    /// Deletes a project; its chats stay, back in the flat history.
    func delete(_ id: String) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        let list = try await client.delete(id: id)
        projects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        details[id] = nil
        setPinned(id, false)
        expandedIDs.remove(id)
        leaveProjectHome(id)
        await refresh()
    }

    private func leaveProjectHome(_ id: String) {
        if workspace?.selection == .project(id) { workspace?.selection = .allProjects }
    }

    /// Run In: new chats from anywhere start here (`projects.set_active`); `nil` is No Project.
    func setActive(_ id: String?) async {
        guard let client, tree.activeID != id else { return }
        tree.activeID = id
        _ = try? await client.setActive(id: id)
    }

    /// Moves a chat to a project's primary folder. Hermes moves its workspace; a running turn
    /// follows.
    func move(_ session: HermesSession, to projectID: String) async throws {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        guard let cwd = project(projectID)?.primaryPath else { throw GatewayRPCError(code: 4016, message: String(localized: "This project has no folder yet.")) }
        _ = try await client.moveSession(sessionKey: session.id, to: cwd)
        placedSessions[session.id] = projectID
        sessionIndex[session.id] = projectID
        await refresh(includeProjects: false)
        if details[projectID] != nil { await loadDetail(projectID) }
    }

    /// A chat this device started in a project: file it there until the tree says so itself.
    func placed(storedID: String, in projectID: String?) {
        guard let projectID else { return }
        placedSessions[storedID] = projectID
        scheduleRefresh(delay: 1.5, includeProjects: false)
    }

    /// The folder a new chat gets, making its worktree first when asked.
    func resolveFolder(for placement: ChatPlacement) async throws -> String? {
        guard placement.newWorktree, let repo = placement.cwd else { return placement.cwd }
        guard let roster = workspace?.roster else { throw GatewaySocket.Failure.notConnected }
        return try await roster.addGitWorktree(repo: repo).path
    }

    func worktrees(of repo: String) async -> [GitWorktree] {
        (try? await workspace?.roster?.gitWorktrees(repo: repo)) ?? []
    }

    func folders(under word: String) async throws -> [String] {
        guard let client else { throw GatewaySocket.Failure.notConnected }
        return try await client.folders(under: word)
    }

    // MARK: Helpers

    /// A project as far as the tree describes it, when `projects.list` hasn't answered yet.
    static func project(from node: ProjectNode) -> HermesProject {
        HermesProject(
            id: node.id, name: node.label, icon: node.icon, color: node.color, primaryPath: node.path,
            folders: node.repos.compactMap { repo in repo.path.map { HermesProject.Folder(path: $0, isPrimary: $0 == node.path) } }
        )
    }

    /// "~/Code/hermes-app", using the gateway's home when it's known.
    func displayPath(_ path: String?) -> String {
        guard let path else { return "" }
        return ProjectPath.abbreviated(path, home: gatewayHomeFolder)
    }

    /// The gateway's home folder, guessed from its default folder (usually home).
    var gatewayHomeFolder: String? {
        guard let folder = defaultFolder else { return nil }
        let parts = folder.split(separator: "/")
        if folder.hasPrefix("/Users/") || folder.hasPrefix("/home/"), parts.count >= 2 { return "/" + parts.prefix(2).joined(separator: "/") }
        return nil
    }
}

/// New Project or Edit Project.
enum ProjectEditorTarget: Identifiable, Equatable {
    case new(folder: String?)
    case edit(String)

    var id: String {
        switch self {
        case .new(let folder): "new:\(folder ?? "")"
        case .edit(let id): "edit:\(id)"
        }
    }
}

/// Where a live chat runs, from `session.info` (also inside `session.create` / `session.resume`).
struct LiveWorkspace: Equatable {
    var cwd: String
    var branch: String?
    /// Set for projects someone made only.
    var projectID: String?

    init?(info: JSONValue?) {
        guard let info, let cwd = info["cwd"]?.stringValue, !cwd.isEmpty else { return nil }
        self.cwd = cwd
        branch = info["branch"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        projectID = info["project"]?["id"]?.stringValue
    }
}
