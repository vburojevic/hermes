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
    /// A chat opened from a project's home, on a compact width: it pushes over that home, so
    /// Back returns to the project (`docs/projects.md` §2).
    case projectChat(String)
    case allProjects

    /// - Parameters:
    ///   - hasBotMode: the gateway has a Hermes backend linked (a roster).
    ///   - parentProject: the project the selected chat was opened from
    ///     (`CompactNavigation.parentProject`), passed only on a compact width. Wider windows show
    ///     the chat in place of the project, as the sidebar is there to go back with.
    public init(selection: SidebarItem?, mode: SidebarMode, hasBotMode: Bool, parentProject: String? = nil) {
        switch selection {
        case nil where mode == .bots && hasBotMode: self = .botsHome
        case nil, .session: self = parentProject.map(DetailRoute.projectChat) ?? .chat
        case .bot: self = .chat
        case .tasks: self = .tasks
        case .skills: self = .skills
        case .group(let id): self = .group(id)
        case .project(let id): self = .project(id)
        case .board(let id): self = .board(id)
        case .allProjects: self = .allProjects
        }
    }

    /// What Back from this screen selects when it returns to another screen rather than the list:
    /// a project's chat and its Board go back to the project.
    public var backSelection: SidebarItem? {
        switch self {
        case .projectChat(let id), .board(let id): .project(id)
        default: nil
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

/// Where the selected screen shows on iPhone, and in an iPad window too narrow for a sidebar
/// (`docs/design-to-swiftui.md` §6): the chat list is the first screen, and the selected screen
/// opens on top of it, with the system's back button and swipe back. On a wider window both show
/// side by side and nothing here moves.
public struct CompactNavigation: Equatable, Sendable {
    /// Bumped each time the selected screen should come on screen; a compact window pushes it.
    public private(set) var pushes = 0
    /// Bumped each time the screen on show went away under the person (its chat deleted or
    /// archived, its Bot removed); a compact window goes back to the list rather than show a
    /// screen with nothing in it.
    public private(set) var pops = 0
    /// The selected screen is on screen. Always on a regular width; on a compact one only while
    /// it is pushed. A chat that was backed out of stays selected, but isn't open: it reads no
    /// replies and counts as unread again.
    public var showsDetail = true
    /// The project whose home the selected chat was opened from (`docs/projects.md` §2): a compact
    /// window pushes the chat over that home, so Back returns to the project and a second Back to
    /// the list. Nil for a chat opened any other way (the list, a notification, search, a link),
    /// which goes back to the list.
    public private(set) var parentProject: String?
    /// The project whose home is on screen under a collapsed split view that says the list is.
    /// Back from a screen pushed over the home (its chat, its Board) leaves the home on screen, but
    /// the split view reports that pop as going back to the list; asked to show the detail again,
    /// it popped the next screen pushed over the home as soon as it came. While this is set, the
    /// window leaves the split view's column as it is and counts the home as on show, until a
    /// screen is pushed anywhere but over that home.
    public private(set) var homeUnderList: String?

    public init() {}

    /// The selection changed. It keeps its place when switching Chats and Bots brings back the
    /// other mode's selection under its list, or when the screen on show only gets a new name (a
    /// draft filed under its chat once sent); a selection that clears (its chat deleted) leaves
    /// the window where it is too, and `dismiss()` says when it should go back.
    /// - Parameter project: the project home the chat (or a new chat's draft, `nil`) was opened
    ///   from. A chat that only gets a new name keeps the project it came from.
    public mutating func selectionChanged(to item: SidebarItem?, keepsPlace: Bool, fromProject project: String? = nil) {
        parentProject = switch item {
        case .session, nil: project ?? (keepsPlace && item != nil ? parentProject : nil)
        default: nil
        }
        guard item != nil, !keepsPlace else { return }
        pushes += 1
        if let home = homeUnderList, item != .board(home), parentProject != home { homeUnderList = nil }
    }

    /// A screen asked for by name: a row picked (even the selected one), New Chat, All Bots, a
    /// window opening on what it showed last.
    public mutating func show() {
        pushes += 1
        // A new chat started from the project's home opens over it.
        if let home = homeUnderList, parentProject != home { homeUnderList = nil }
    }

    /// A collapsed window went back from a chat or a Board to the project's home under it.
    public mutating func poppedToProject(_ projectID: String) {
        homeUnderList = projectID
    }

    /// The selected screen is gone: back to the list.
    public mutating func dismiss() {
        pops += 1
        homeUnderList = nil
    }
}
