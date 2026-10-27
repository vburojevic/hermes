import Foundation

/// What the main area shows.
public enum SidebarItem: Hashable, Sendable {
    /// A conversation, keyed by its stable key (survives compression).
    case session(String)
    case tasks
    case skills
    /// A Bot's Bot Chat, keyed by profile name.
    case bot(String)
    /// A hosted group chat, keyed by room id.
    case group(String)
    /// A project's home, keyed by project id (`docs/projects.md`).
    case project(String)
    /// A project's Board, keyed by project id (`docs/board.md`).
    case board(String)
    /// All Projects.
    case allProjects

    /// As a string for `SceneStorage`: what a window showed, restored when it opens again.
    public var storedValue: String {
        switch self {
        case .session(let key): "session:\(key)"
        case .tasks: "tasks"
        case .skills: "skills"
        case .bot(let name): "bot:\(name)"
        case .group(let id): "group:\(id)"
        case .project(let id): "project:\(id)"
        case .board(let id): "board:\(id)"
        case .allProjects: "allProjects"
        }
    }

    public init?(storedValue: String) {
        let parts = storedValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("session", let key?): self = .session(key)
        case ("tasks", _): self = .tasks
        case ("skills", _): self = .skills
        case ("bot", let name?): self = .bot(name)
        case ("group", let id?): self = .group(id)
        case ("project", let id?): self = .project(id)
        case ("board", let id?): self = .board(id)
        case ("allProjects", _): self = .allProjects
        default: return nil
        }
    }
}

/// The sidebar's two halves, like Hermes Desktop's Sessions and Bots modes.
public enum SidebarMode: String, Sendable {
    case chats, bots
}

/// The screen the main area shows for a selection (`docs/bots-groups-skills.md` §1.2): the one
/// place the sidebar's selection becomes a screen, so a selected row and the detail can't disagree.
public enum DetailRoute: Hashable, Sendable {
    /// Bots mode with nothing picked: every Bot as a tile.
    case botsHome
    /// A chat, a Bot Chat, or the new-chat draft: one screen, its conversation swapped.
    case chat
    case tasks
    case skills
    case group(String)
    case project(String)
    case board(String)
    case allProjects

    /// - Parameter hasBotMode: the gateway has a Hermes backend linked (a roster).
    public init(selection: SidebarItem?, mode: SidebarMode, hasBotMode: Bool) {
        switch selection {
        case nil: self = mode == .bots && hasBotMode ? .botsHome : .chat
        case .session, .bot: self = .chat
        case .tasks: self = .tasks
        case .skills: self = .skills
        case .group(let id): self = .group(id)
        case .project(let id): self = .project(id)
        case .board(let id): self = .board(id)
        case .allProjects: self = .allProjects
        }
    }
}

/// Makes the detail resolve its screen again when the selection doesn't change
/// (`docs/bots-groups-skills.md` §1.2). Setting a selection to the value it already has notifies
/// nothing, so a detail that missed a change (a window's selection restored while its first frame
/// was being built, which the Mac's detail column didn't always redraw for) kept the wrong screen
/// under a selected row, and clicking the row again did nothing. Each pass is a change the detail
/// reads: a pick of what is already selected, and a selection made as the window opened, once the
/// gateway has answered.
public struct DetailPass: Equatable, Sendable {
    /// Bumped for each pass; the detail reads it.
    public private(set) var count = 0
    /// What the window opened on (restored, or named by a launch flag), until it settles.
    private var opened: SidebarItem??

    public init() {}

    /// A pick in the sidebar. Returns whether the selection changes; a pick of what is already
    /// selected counts a pass instead.
    public mutating func pick(_ item: SidebarItem?, current: SidebarItem?) -> Bool {
        opened = nil
        guard item == current else { return true }
        count += 1
        return false
    }

    /// The window opens on `item`, possibly before its screen exists.
    public mutating func open(_ item: SidebarItem?) {
        opened = .some(item)
    }

    /// The gateway answered (or gave up): one more pass while the window still shows what it
    /// opened on. Only the first call after `open` counts.
    public mutating func settle(current: SidebarItem?) {
        guard let opened else { return }
        self.opened = nil
        if opened == current { count += 1 }
    }
}
