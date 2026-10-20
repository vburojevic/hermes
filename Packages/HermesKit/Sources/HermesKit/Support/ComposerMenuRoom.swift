import Foundation

/// How tall a menu that grows up from the composer may be (the "/" and "@" menus, `docs/composer.md`
/// §1): its own cap, or less where the composer sits so high (the keyboard up, a short window) that
/// it would pass under the top bar. Taller content scrolls inside it; it never goes over the bar,
/// even where that leaves it a sliver (landscape with the keyboard up).
public enum ComposerMenuRoom {
    /// The menu's own cap, with room to spare.
    public static let cap: CGFloat = 440
    /// Clear room kept under the top bar.
    public static let margin: CGFloat = 8

    /// - Parameters:
    ///   - ceiling: the top bar's bottom edge, in the window's coordinates (`nil` until measured).
    ///   - panelTop: the composer panel's top edge, in the same coordinates.
    ///   - spacing: the gap between the menu and the panel.
    public static func height(ceiling: CGFloat?, panelTop: CGFloat?, spacing: CGFloat) -> CGFloat {
        guard let ceiling, let panelTop else { return cap }
        let room = (panelTop - spacing - margin - ceiling).rounded(.down)
        return min(cap, max(0, room))
    }
}
