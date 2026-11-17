import Foundation

/// Which gateway each open window shows, which gateway was used last, and so which gateways keep
/// their connection (`docs/connecting-and-voice.md` §8, `docs/sessions-and-models.md` §1).
///
/// Each Mac window (each iPad scene) keeps its own gateway: switching in one leaves the others
/// alone. The last-used gateway is the one app-wide places use (Settings, Talk, the menu bar
/// extra, notifications): it follows the latest switch, and the window that last became active.
/// A window that has no gateway of its own yet shows the last-used one.
public struct WindowGateways: Equatable, Sendable {
    private struct Window: Equatable, Sendable {
        var gateway: UUID?
        var isVisible = true
        /// Still on the gateway it opened with: a restored gateway that arrives late may replace it.
        var isRestorable = true
    }

    private var windows: [UUID: Window] = [:]
    /// Open windows, least recently active first.
    private var recency: [UUID] = []
    public private(set) var lastUsed: UUID?
    /// An app-wide switch made while no window was open (a notification tapped at launch): the
    /// next window to open shows it, whatever it showed before.
    private var nextWindow: UUID?

    public init(lastUsed: UUID? = nil) {
        self.lastUsed = lastUsed
    }

    /// The window that was active last: an app-wide switch (a notification, a link) changes it.
    public var mostRecentWindow: UUID? { recency.last }

    /// The gateway a window shows: its own, or the last-used one. Nil for a window that isn't open.
    public func gateway(in window: UUID) -> UUID? {
        guard let entry = windows[window] else { return nil }
        return entry.gateway ?? lastUsed
    }

    public func isOpen(_ window: UUID) -> Bool { windows[window] != nil }

    public var windowCount: Int { windows.count }

    /// Every gateway an open, visible window shows keeps checking its connection, and so does the
    /// last-used one, whatever the windows show: the app-wide places (the menu bar extra, Talk)
    /// show its state even with every window minimized or closed.
    public var keptConnected: Set<UUID> {
        let shown = windows.values.filter(\.isVisible).compactMap { $0.gateway ?? lastUsed }
        return Set(shown + [lastUsed].compactMap(\.self))
    }

    /// A window opened: on the gateway it showed before (restored with the window), or nil to
    /// show the last-used one. Opening isn't using: it comes first when it becomes active.
    public mutating func open(_ window: UUID, showing gateway: UUID?) {
        if windows[window] == nil { recency.insert(window, at: 0) }
        windows[window] = Window(gateway: nextWindow ?? gateway, isRestorable: nextWindow == nil)
        nextWindow = nil
    }

    /// The gateway a window showed before arrived after it opened (a Mac window's saved state is
    /// restored after the window appears). It takes it unless it was switched since it opened; the
    /// window in front makes it the last used.
    public mutating func restore(_ gateway: UUID, in window: UUID) {
        guard windows[window]?.isRestorable == true else { return }
        windows[window]?.gateway = gateway
        if recency.last == window { lastUsed = gateway }
    }

    public mutating func close(_ window: UUID) {
        windows[window] = nil
        recency.removeAll { $0 == window }
    }

    /// A window was hidden (minimized, its scene in the background) or shown again.
    public mutating func setVisible(_ isVisible: Bool, window: UUID) {
        windows[window]?.isVisible = isVisible
    }

    /// The window became the active one: its gateway is now the last used.
    public mutating func activate(_ window: UUID) {
        guard let entry = windows[window] else { return }
        recency.removeAll { $0 == window }
        recency.append(window)
        if let gateway = entry.gateway { lastUsed = gateway }
    }

    /// The person switched this window to a gateway. With no such window open, the gateway
    /// becomes the last used and the next window to open shows it.
    public mutating func show(_ gateway: UUID, in window: UUID?) {
        lastUsed = gateway
        guard let window, windows[window] != nil else {
            nextWindow = gateway
            return
        }
        windows[window]?.gateway = gateway
        windows[window]?.isRestorable = false
        activate(window)
    }

    /// An app-wide switch: the most recently active window shows the gateway.
    public mutating func show(_ gateway: UUID) {
        show(gateway, in: mostRecentWindow)
    }

    /// A gateway was removed: windows on it, and the last-used gateway, go to `fallback`.
    public mutating func remove(gateway: UUID, fallback: UUID?) {
        for id in windows.keys where windows[id]?.gateway == gateway {
            windows[id]?.gateway = fallback
        }
        if lastUsed == gateway { lastUsed = fallback }
        if nextWindow == gateway { nextWindow = fallback }
    }

    /// The gateway a window restored with: the one it showed when it still exists, otherwise the
    /// last-used one.
    public static func restored(_ stored: UUID?, among gateways: some Collection<UUID>, lastUsed: UUID?) -> UUID? {
        if let stored, gateways.contains(stored) { return stored }
        return lastUsed
    }
}
