import Foundation

// Projects (workspaces): a named set of folders on the gateway, with a colour and a glyph
// (`tui_gateway/contracts/projects_pets.py`, `methods_projects.py`, `project_tree.py`).
//
// Ids are the gateway's and must stay byte-for-byte as received: the Hermes desktop app keys its
// pins, ordering and dismissal by them (`project_tree.py` docstring). Explicit projects are
// `p_<hex>`, auto projects and repos are the repo root path, the Home bucket is `__no_project__`,
// a main-checkout lane is `<repoRoot>::branch::<branch>`, a kanban lane `<repoRoot>::kanban`, and a
// linked worktree lane is the worktree path.

/// A project as `projects.list` / `projects.get` report it (`ProjectInfo`).
public struct HermesProject: Identifiable, Hashable, Sendable {
    public struct Folder: Hashable, Sendable {
        public var path: String
        public var label: String?
        public var isPrimary: Bool
        public var addedAt: Date?

        public init(path: String, label: String? = nil, isPrimary: Bool = false, addedAt: Date? = nil) {
            self.path = path
            self.label = label
            self.isPrimary = isPrimary
            self.addedAt = addedAt
        }

        init?(json: JSONValue) {
            guard let path = json["path"]?.stringValue, !path.isEmpty else { return nil }
            self.init(
                path: path,
                label: json["label"]?.stringValue,
                isPrimary: json["is_primary"]?.boolValue ?? false,
                addedAt: HermesDate.fromEpoch(json["added_at"]?.doubleValue)
            )
        }

        /// The folder's last path component, for rows ("hermes-app").
        public var name: String {
            if let label, !label.isEmpty { return label }
            return ProjectPath.lastComponent(path)
        }
    }

    public var id: String
    public var slug: String
    public var name: String
    public var description: String?
    /// The glyph: an SF Symbol name when this app wrote it; the desktop writes codicon names.
    public var icon: String?
    /// The colour: an accent name when this app wrote it; the desktop writes `hsl(…)` swatches.
    public var color: String?
    public var primaryPath: String?
    public var archived: Bool
    public var createdAt: Date?
    /// Primary first, then oldest first (the gateway's order).
    public var folders: [Folder]
    /// The kanban board bound to it (`hermes projects set-board`); the board's own `project_id`
    /// points back.
    public var boardSlug: String?

    public init(
        id: String, slug: String = "", name: String, description: String? = nil, icon: String? = nil, color: String? = nil,
        primaryPath: String? = nil, archived: Bool = false, createdAt: Date? = nil, folders: [Folder] = [], boardSlug: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.icon = icon
        self.color = color
        self.primaryPath = primaryPath
        self.archived = archived
        self.createdAt = createdAt
        self.folders = folders
        self.boardSlug = boardSlug
    }

    public init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let folders: [Folder] = if case .array(let rows)? = json["folders"] { rows.compactMap(Folder.init(json:)) } else { [] }
        self.init(
            id: id,
            slug: json["slug"]?.stringValue ?? "",
            name: json["name"]?.stringValue ?? id,
            description: json["description"]?.stringValue,
            icon: json["icon"]?.stringValue,
            color: json["color"]?.stringValue,
            primaryPath: json["primary_path"]?.stringValue ?? folders.first(where: \.isPrimary)?.path,
            archived: json["archived"]?.boolValue ?? false,
            createdAt: HermesDate.fromEpoch(json["created_at"]?.doubleValue),
            folders: folders,
            boardSlug: json["board_slug"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The primary folder, then the others.
    public var orderedFolders: [Folder] {
        folders.filter { $0.path == primaryPath } + folders.filter { $0.path != primaryPath }
    }
}

/// `projects.tree` and `projects.project_sessions`: projects → repos → lanes → chats.
public struct ProjectTree: Hashable, Sendable {
    public var nodes: [ProjectNode]
    /// The project new chats start in (`projects.set_active`). It can name a project that was
    /// since archived or deleted; check it against `nodes`.
    public var activeID: String?
    /// Every chat the tree placed, including the Home bucket and auto projects.
    public var scopedSessionIDs: Set<String>

    public init(nodes: [ProjectNode] = [], activeID: String? = nil, scopedSessionIDs: Set<String> = []) {
        self.nodes = nodes
        self.activeID = activeID
        self.scopedSessionIDs = scopedSessionIDs
    }

    public init(json: JSONValue) {
        let nodes: [ProjectNode] = if case .array(let rows)? = json["projects"] { rows.compactMap(ProjectNode.init(json:)) } else { [] }
        let scoped: [String] = if case .array(let ids)? = json["scoped_session_ids"] { ids.compactMap(\.stringValue) } else { [] }
        self.init(nodes: nodes, activeID: json["active_id"]?.stringValue, scopedSessionIDs: Set(scoped))
    }

    /// Projects someone made (not the Home bucket, auto-grouped repos or found folders).
    public var explicitProjects: [ProjectNode] {
        nodes.filter(\.isExplicit)
    }

    public func node(id: String) -> ProjectNode? {
        nodes.first { $0.id == id }
    }

    /// The chats that belong to a project someone made: the flat history leaves them out.
    public var explicitSessionIDs: Set<String> {
        Set(explicitProjects.flatMap(\.sessionIDs))
    }
}

/// One project in the tree.
public struct ProjectNode: Identifiable, Hashable, Sendable {
    public static let noProjectID = "__no_project__"

    public var id: String
    public var label: String
    /// The primary folder (explicit projects) or repo root (auto projects).
    public var path: String?
    public var color: String?
    public var icon: String?
    /// A git repo Hermes grouped by itself, not a project someone made.
    public var isAuto: Bool
    /// The Home bucket: chats outside any folder.
    public var isNoProject: Bool
    public var sessionCount: Int
    public var lastActive: Date?
    public var repos: [ProjectRepo]
    /// The newest few chats (`preview_limit`); empty from `projects.project_sessions`.
    public var previewSessions: [ProjectSessionRow]
    public var sessionIDs: [String]

    public init(
        id: String, label: String, path: String? = nil, color: String? = nil, icon: String? = nil, isAuto: Bool = false,
        isNoProject: Bool = false, sessionCount: Int = 0, lastActive: Date? = nil, repos: [ProjectRepo] = [],
        previewSessions: [ProjectSessionRow] = [], sessionIDs: [String] = []
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.color = color
        self.icon = icon
        self.isAuto = isAuto
        self.isNoProject = isNoProject
        self.sessionCount = sessionCount
        self.lastActive = lastActive
        self.repos = repos
        self.previewSessions = previewSessions
        self.sessionIDs = sessionIDs
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let repos: [ProjectRepo] = if case .array(let rows)? = json["repos"] { rows.compactMap(ProjectRepo.init(json:)) } else { [] }
        let previews: [ProjectSessionRow] = if case .array(let rows)? = json["previewSessions"] { rows.compactMap(ProjectSessionRow.init(json:)) } else { [] }
        let ids: [String] = if case .array(let rows)? = json["sessionIds"] { rows.compactMap(\.stringValue) } else { [] }
        self.init(
            id: id,
            label: json["label"]?.stringValue ?? id,
            path: json["path"]?.stringValue,
            color: json["color"]?.stringValue,
            icon: json["icon"]?.stringValue,
            isAuto: json["isAuto"]?.boolValue ?? false,
            isNoProject: json["isNoProject"]?.boolValue ?? (id == Self.noProjectID),
            sessionCount: json["sessionCount"]?.doubleValue.map { Int($0) } ?? ids.count,
            lastActive: HermesDate.fromEpoch(json["lastActive"]?.doubleValue),
            repos: repos,
            previewSessions: previews,
            sessionIDs: ids
        )
    }

    public var isExplicit: Bool { !isAuto && !isNoProject }

    /// Every lane across the project's folders, in the gateway's order (main checkout first,
    /// worktrees by recency, task worktrees last within each folder).
    public var lanes: [ProjectLane] {
        repos.flatMap(\.lanes)
    }

    /// Chats in each lane, once `projects.project_sessions` hydrated them.
    public var hydratedSessions: [ProjectSessionRow] {
        lanes.flatMap(\.sessions)
    }

    /// Branches and worktrees with chats (the header's "2 branches").
    public var branchCount: Int {
        lanes.filter { $0.kind != .tasks && !$0.sessions.isEmpty }.count
    }

    /// Chats in task (kanban) worktrees (the header's "3 tasks").
    public var taskCount: Int {
        lanes.filter { $0.kind == .tasks }.reduce(0) { $0 + $1.sessions.count }
    }
}

/// A folder of a project, with its lanes.
public struct ProjectRepo: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var path: String?
    public var lanes: [ProjectLane]
    public var sessionCount: Int

    public init(id: String, label: String, path: String? = nil, lanes: [ProjectLane] = [], sessionCount: Int = 0) {
        self.id = id
        self.label = label
        self.path = path
        self.lanes = lanes
        self.sessionCount = sessionCount
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let lanes: [ProjectLane] = if case .array(let rows)? = json["groups"] { rows.compactMap(ProjectLane.init(json:)) } else { [] }
        self.init(
            id: id,
            label: json["label"]?.stringValue ?? ProjectPath.lastComponent(id),
            path: json["path"]?.stringValue,
            lanes: lanes,
            sessionCount: json["sessionCount"]?.doubleValue.map { Int($0) } ?? lanes.reduce(0) { $0 + $1.sessions.count }
        )
    }
}

/// A lane: the main checkout on one branch, a linked worktree, or the task worktrees.
public struct ProjectLane: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case main, worktree, tasks
    }

    /// `<repoRoot>::branch::<branch>`, the worktree path, or `<repoRoot>::kanban`.
    public var id: String
    /// The branch (main checkout), the worktree's folder name, or "kanban".
    public var label: String
    public var path: String?
    public var isMain: Bool
    public var isKanban: Bool
    public var isGit: Bool
    /// Empty in `projects.tree`; filled by `projects.project_sessions`.
    public var sessions: [ProjectSessionRow]

    public init(id: String, label: String, path: String? = nil, isMain: Bool = false, isKanban: Bool = false, isGit: Bool = true, sessions: [ProjectSessionRow] = []) {
        self.id = id
        self.label = label
        self.path = path
        self.isMain = isMain
        self.isKanban = isKanban
        self.isGit = isGit
        self.sessions = sessions
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let sessions: [ProjectSessionRow] = if case .array(let rows)? = json["sessions"] { rows.compactMap(ProjectSessionRow.init(json:)) } else { [] }
        self.init(
            id: id,
            label: json["label"]?.stringValue ?? "main",
            path: json["path"]?.stringValue,
            isMain: json["isMain"]?.boolValue ?? false,
            isKanban: json["isKanban"]?.boolValue ?? false,
            isGit: json["isGit"]?.boolValue ?? true,
            sessions: sessions
        )
    }

    public var kind: Kind {
        if isKanban { return .tasks }
        return isMain ? .main : .worktree
    }

    /// The branch a main-checkout lane's chats recorded, from its id (`…::branch::<name>`).
    public var branch: String? {
        guard kind == .main else { return nil }
        if let range = id.range(of: "::branch::", options: .backwards) { return String(id[range.upperBound...]) }
        return label
    }
}

/// A chat in the tree (`_project_tree_row`). `id` is the stored session id.
public struct ProjectSessionRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var lineageRootID: String?
    public var title: String?
    public var preview: String?
    public var source: String?
    public var startedAt: Date?
    public var lastActive: Date?
    public var messageCount: Int
    public var model: String?
    public var cwd: String?
    public var gitBranch: String?
    public var archived: Bool

    public init(
        id: String, lineageRootID: String? = nil, title: String? = nil, preview: String? = nil, source: String? = nil,
        startedAt: Date? = nil, lastActive: Date? = nil, messageCount: Int = 0, model: String? = nil, cwd: String? = nil,
        gitBranch: String? = nil, archived: Bool = false
    ) {
        self.id = id
        self.lineageRootID = lineageRootID
        self.title = title
        self.preview = preview
        self.source = source
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.model = model
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.archived = archived
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(
            id: id,
            lineageRootID: json["_lineage_root_id"]?.stringValue,
            title: json["title"]?.stringValue,
            preview: json["preview"]?.stringValue,
            source: json["source"]?.stringValue,
            startedAt: HermesDate.fromEpoch(json["started_at"]?.doubleValue),
            lastActive: HermesDate.fromEpoch(json["last_active"]?.doubleValue),
            messageCount: json["message_count"]?.doubleValue.map { Int($0) } ?? 0,
            model: json["model"]?.stringValue,
            cwd: json["cwd"]?.stringValue,
            gitBranch: json["git_branch"]?.stringValue,
            archived: json["archived"]?.boolValue ?? false
        )
    }

    /// The same identity the chat history uses: the lineage root survives compression.
    public var stableID: String {
        if let lineageRootID, !lineageRootID.isEmpty { return lineageRootID }
        return id
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return String(preview.prefix(60)) }
        return String(localized: "New Chat")
    }

    /// A history row for this chat, so it opens like any other.
    public var session: HermesSession {
        var row = HermesSession(id: id)
        row.title = title
        row.preview = preview
        row.source = source
        row.startedAt = startedAt
        row.lastActive = lastActive
        row.messageCount = messageCount
        row.model = model
        row.lineageRootID = lineageRootID
        return row
    }
}

/// `project.facts`: what Hermes learned about a folder.
public struct ProjectFacts: Hashable, Sendable {
    public var root: String?
    /// "Package.swift", "pyproject.toml", …
    public var manifests: [String]
    public var packageManagers: [String]
    /// The checks Hermes runs before calling something done.
    public var verifyCommands: [String]
    /// The context files Hermes reads first (AGENTS.md, …).
    public var contextFiles: [String]

    public init(root: String? = nil, manifests: [String] = [], packageManagers: [String] = [], verifyCommands: [String] = [], contextFiles: [String] = []) {
        self.root = root
        self.manifests = manifests
        self.packageManagers = packageManagers
        self.verifyCommands = verifyCommands
        self.contextFiles = contextFiles
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        func strings(_ key: String) -> [String] {
            if case .array(let rows)? = json[key] { return rows.compactMap(\.stringValue) }
            return []
        }
        self.init(
            root: json["root"]?.stringValue,
            manifests: strings("manifests"),
            packageManagers: strings("packageManagers"),
            verifyCommands: strings("verifyCommands"),
            contextFiles: strings("contextFiles")
        )
    }

    public var isEmpty: Bool {
        manifests.isEmpty && packageManagers.isEmpty && verifyCommands.isEmpty && contextFiles.isEmpty
    }
}

/// A git folder Hermes has worked in (`projects.discover_repos`).
public struct DiscoveredRepo: Identifiable, Hashable, Sendable {
    public var root: String
    public var label: String
    public var sessions: Int
    public var lastActive: Date?

    public var id: String { root }

    public init(root: String, label: String? = nil, sessions: Int = 0, lastActive: Date? = nil) {
        self.root = root
        self.label = label ?? ProjectPath.lastComponent(root)
        self.sessions = sessions
        self.lastActive = lastActive
    }

    init?(json: JSONValue) {
        guard let root = json["root"]?.stringValue, !root.isEmpty else { return nil }
        self.init(
            root: root,
            label: json["label"]?.stringValue,
            sessions: json["sessions"]?.doubleValue.map { Int($0) } ?? 0,
            lastActive: HermesDate.fromEpoch(json["last_active"]?.doubleValue)
        )
    }
}

/// `projects.for_cwd`: the project a folder is in, and its branch.
public struct ProjectLocation: Hashable, Sendable {
    public var project: HermesProject?
    public var cwd: String
    /// Empty outside git.
    public var branch: String
}

/// `session.workspace.move`: where the chat runs now.
public struct WorkspaceMove: Hashable, Sendable {
    public var cwd: String
    public var branch: String
    public var gitRepoRoot: String
}

/// A chat Hermes is running now (`session.active_list`).
public struct ActiveSession: Hashable, Sendable {
    /// The stored session id.
    public var sessionKey: String
    /// idle, starting, waiting, working, streaming or resuming.
    public var status: String

    public var isRunning: Bool {
        ["starting", "working", "streaming", "resuming"].contains(status)
    }
}

/// Path helpers for folders on the gateway (which may not be this device).
public enum ProjectPath {
    public static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// `/Users/ada/Code/app` → `~/Code/app` when the gateway's home is known or guessable.
    public static func abbreviated(_ path: String, home: String? = nil) -> String {
        if let home, !home.isEmpty, path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        // macOS and Linux home folders.
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        if path == "/root" || path.hasPrefix("/root/") { return "~" + path.dropFirst(5) }
        return path
    }

    /// Whether `path` is `folder` or inside it.
    public static func contains(_ folder: String, _ path: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }
}

/// A checkout of a repo on the gateway: the main one, or a linked worktree (`/api/git/worktrees`).
public struct GitWorktree: Identifiable, Hashable, Sendable {
    public var path: String
    public var branch: String?
    public var isMain: Bool

    public var id: String { path }

    public init(path: String, branch: String?, isMain: Bool) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
    }

    init?(json: JSONValue) {
        guard let path = json["path"]?.stringValue, !path.isEmpty else { return nil }
        self.init(path: path, branch: json["branch"]?.stringValue, isMain: json["isMain"]?.boolValue ?? false)
    }
}
