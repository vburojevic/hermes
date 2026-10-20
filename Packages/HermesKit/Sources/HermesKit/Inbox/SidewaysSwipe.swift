import Foundation

/// Whether a drag on a row is a sideways swipe (the drawer's swipe actions, Reply on a message),
/// decided as it starts. Anything else stays the list's or the chat's to scroll: a drag the rows
/// took whatever its direction stopped them scrolling (`docs/inbox.md` §4, §5).
public enum SidewaysSwipe {
    /// Which ways a swipe may go.
    public enum Direction: Sendable {
        case either
        /// Only toward the left (Reply on a message): a drag to the right from the screen's edge
        /// stays the drawer's.
        case left
    }

    /// How much more across than up or down a swipe must start.
    static let slant: CGFloat = 1.3

    /// A drag that starts with this velocity and has moved this far. The velocity leads (a
    /// flick's first move is short); the distance counts ten times, so a slow drag decides too.
    public static func begins(velocity: CGPoint, translation: CGPoint, direction: Direction) -> Bool {
        let across = velocity.x + translation.x * 10
        let x = abs(velocity.x) + abs(translation.x) * 10
        let y = abs(velocity.y) + abs(translation.y) * 10
        guard x > y * slant else { return false }
        switch direction {
        case .either: return true
        case .left: return across < 0
        }
    }
}
