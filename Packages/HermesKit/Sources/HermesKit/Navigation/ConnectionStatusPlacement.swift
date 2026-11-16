import Foundation

/// Where iPhone's chat list shows the connection status (`docs/design-to-swiftui.md` §6). The
/// system draws the navigation subtitle on one line and cuts it off at the accessibility text
/// sizes, so from AX1 up the status is the list's first row instead, where it wraps.
public enum ConnectionStatusPlacement: Equatable, Sendable {
    /// The subtitle under the large title.
    case subtitle
    /// The list's first row, above the Chats / Bots switch (or Tasks without Bot Mode).
    case row
    /// Neither: the row hides while a search has text in it, as the rows around it do.
    case hidden

    public init(isAccessibilitySize: Bool, isSearching: Bool) {
        if !isAccessibilitySize {
            self = .subtitle
        } else {
            self = isSearching ? .hidden : .row
        }
    }

    /// Whether the subtitle carries the status. At the accessibility sizes it stays empty, searching
    /// or not, so the status never shows cut off.
    public var showsSubtitle: Bool { self == .subtitle }

    /// Whether the list leads with the status row.
    public var showsRow: Bool { self == .row }
}
