import Foundation

/// Where the Board puts its columns and the open card (`docs/board.md` §2, §6).
public enum BoardLayout: Equatable, Sendable {
    /// iPhone: one column at a time; a card opens as a pushed page.
    case phone
    /// iPad portrait, and iPad at the accessibility sizes in either orientation: two columns
    /// across, paging sideways; a card opens as a large sheet.
    case pages
    /// iPad landscape and the Mac: columns side by side and the open card in an inspector.
    case inspector

    /// The narrowest a column gets, and the iPad landscape width.
    public static let minimumColumnWidth: Double = 255
    /// The Mac's columns keep this width at every text size and scroll sideways.
    public static let macColumnWidth: Double = 222
    /// The iPad landscape inspector needs this much window beside the columns.
    public static let inspectorMinimumWidth: Double = 900

    /// Picks the layout for a window. An iPad at the accessibility sizes keeps the portrait layout
    /// in landscape too, so a card keeps a readable width instead of squeezing beside the
    /// inspector.
    public static func choose(isMac: Bool, isCompact: Bool, width: Double, height: Double, isAccessibilitySize: Bool) -> BoardLayout {
        if isMac { return .inspector }
        if isCompact { return .phone }
        if isAccessibilitySize { return .pages }
        return width > height && width >= inspectorMinimumWidth ? .inspector : .pages
    }

    /// A column's width in a window `width` points wide: the Mac's and iPad landscape's are fixed;
    /// the portrait layout fits two across, max(255, (width − 52) / 2). Before the window is
    /// measured it's the narrowest.
    public func columnWidth(isMac: Bool, width: Double) -> Double {
        switch self {
        case .inspector:
            isMac ? Self.macColumnWidth : Self.minimumColumnWidth
        case .pages, .phone:
            width > 0 ? max(Self.minimumColumnWidth, (width - 52) / 2) : Self.minimumColumnWidth
        }
    }

    /// The Mac's inspector opens at its widest at the largest text size (`docs/board.md` §6).
    public static func inspectorIdealWidth(isAccessibilitySize: Bool) -> Double {
        isAccessibilitySize ? 460 : 380
    }
}

/// The fades at the Mac board's edges: a side fades only while more columns lie past it
/// (`docs/board.md` §2).
public struct BoardEdgeFades: Equatable, Sendable {
    public var leading: Bool
    public var trailing: Bool

    /// How wide each fade is.
    public static let width: Double = 64

    public init(leading: Bool, trailing: Bool) {
        self.leading = leading
        self.trailing = trailing
    }

    /// The fades for a strip `contentWidth` wide, scrolled to `offset` in a viewport
    /// `visibleWidth` wide. A point of slack keeps a fade from flickering at rest.
    public init(offset: Double, visibleWidth: Double, contentWidth: Double) {
        leading = offset > 1
        trailing = offset + visibleWidth < contentWidth - 1
    }
}

/// The notice over the board when the gateway refuses a move (`docs/board.md` §2, §6).
public enum BoardNotice {
    /// How long it stays: 6 s, or until it's dismissed while VoiceOver is running, so it's never
    /// taken away mid-sentence.
    public static func timeout(voiceOverRunning: Bool) -> Duration? {
        voiceOverRunning ? nil : .seconds(6)
    }
}
