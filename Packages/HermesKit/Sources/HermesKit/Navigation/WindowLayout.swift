import Foundation

/// What a Mac window shows at its width (`docs/chat.md` §4): whether the sidebar sits beside the
/// chat or steps aside, and whether the Inspector opens beside the chat or over it.
///
/// Below 700 pt the sidebar collapses on its own and its button brings it back over the chat.
/// Past 700 pt it returns, unless the person hid it: a choice the person made is never undone by
/// a resize. Below 840 pt the Inspector opens over the chat rather than beside it.
public struct WindowLayout: Equatable, Sendable {
    /// Narrower than this, the sidebar steps aside.
    public static let sidebarCutoff = 700.0
    /// Narrower than this, the Inspector opens over the chat.
    public static let inspectorCutoff = 840.0
    /// Narrower than this, the Inspector beside the chat collapses the sidebar
    /// (`docs/inspector.md` §1).
    public static let inspectorHidesSidebarBelow = 1400.0

    /// The window's width; 0 until it's measured.
    public private(set) var width = 0.0
    /// The person hid the sidebar (its button or View > Hide Sidebar) while it was beside the chat.
    public private(set) var personHidSidebar = false
    /// The Inspector beside the chat collapsed the sidebar; closing it brings the sidebar back.
    public private(set) var inspectorHidSidebar = false
    /// A narrow window shows the sidebar over the chat.
    public private(set) var showsSidebarOver = false
    /// The Inspector is open, beside the chat or over it.
    public private(set) var inspectorIsOpen = false

    public init() {}

    /// Too narrow for the sidebar beside the chat. An unmeasured window counts as wide.
    public var isNarrow: Bool { width > 0 && width < Self.sidebarCutoff }

    /// The Inspector opens over the chat rather than beside it.
    public var inspectorOverlays: Bool { width > 0 && width < Self.inspectorCutoff }

    /// The sidebar sits beside the chat.
    public var docksSidebar: Bool { !isNarrow && !personHidSidebar && !inspectorHidSidebar }

    /// Whether the sidebar shows at all, beside the chat or over it: what View > Show/Hide Sidebar
    /// reads.
    public var showsSidebar: Bool { isNarrow ? showsSidebarOver : docksSidebar }

    /// The Inspector is beside the chat in a window under 1,400 pt, where it and the sidebar
    /// leave the chat too little room.
    private var inspectorCrowdsSidebar: Bool {
        inspectorIsOpen && !inspectorOverlays && width < Self.inspectorHidesSidebarBelow
    }

    /// The window was resized. Growing past the cutoff puts away the sidebar shown over the chat;
    /// whether it then docks is up to what the person chose. The Inspector coming beside the chat
    /// (from over it, or as the window narrows under 1,400 pt) collapses the sidebar as opening it
    /// there does; only that moment does, so a sidebar the person brought back stays.
    public mutating func resize(to newWidth: Double) {
        let crowded = inspectorCrowdsSidebar
        width = newWidth
        if !isNarrow { showsSidebarOver = false }
        if !crowded, inspectorCrowdsSidebar, docksSidebar { inspectorHidSidebar = true }
    }

    /// The sidebar button or ⌃⌘S: over the chat in a narrow window, beside it otherwise.
    public mutating func toggleSidebar() {
        if isNarrow {
            showsSidebarOver.toggle()
        } else if docksSidebar {
            personHidSidebar = true
        } else {
            personHidSidebar = false
            inspectorHidSidebar = false
        }
    }

    /// The split view reported the sidebar shown or hidden. In a wide window a change this type
    /// didn't ask for is the person's own (the system's sidebar button, dragging the divider shut).
    public mutating func sidebarChanged(shown: Bool) {
        guard !isNarrow, shown != docksSidebar else { return }
        if shown {
            personHidSidebar = false
            inspectorHidSidebar = false
        } else {
            personHidSidebar = true
        }
    }

    /// Picking a chat, clicking the chat or Esc puts the sidebar over the chat away.
    public mutating func closeSidebarOver() {
        showsSidebarOver = false
    }

    /// The Inspector opened or closed. Opening it beside the chat in a window under 1,400 pt
    /// collapses the sidebar; opening it over the chat puts away the sidebar over the chat, so one
    /// panel covers the chat at a time. Closing it brings back the sidebar it collapsed, and a
    /// resize in between never does: the sidebar docking in the same pass that the Inspector's
    /// column goes left the split view half drawn.
    public mutating func inspectorChanged(open: Bool) {
        inspectorIsOpen = open
        if open {
            if inspectorOverlays { showsSidebarOver = false }
            if inspectorCrowdsSidebar, docksSidebar { inspectorHidSidebar = true }
        } else {
            inspectorHidSidebar = false
        }
    }
}
