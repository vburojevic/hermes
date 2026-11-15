import Foundation

/// Whether a drag on a row is a sideways swipe (Reply on a message, scrubbing a voice clip),
/// decided as it starts. Anything else stays the list's or the chat's to scroll: a drag the rows
/// took whatever its direction stopped them scrolling (`docs/inbox.md` §4, §5).
public enum SidewaysSwipe {
    /// Which ways a swipe may go.
    public enum Direction: Sendable {
        case either
        /// Only toward the left (Reply on a message): a drag to the right from the screen's edge
        /// stays the system's back swipe.
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

    /// How far the finger has moved across since it touched down. A pan's translation starts
    /// again where the pan began, which leaves out the move that began it: 10 to 20 points of a
    /// finger's swipe, and a whole first sample where touches come further apart, so a row
    /// following it lagged the finger and a short swipe shut. The chat list's rows and a chat's
    /// Reply swipe count from touch-down.
    public static func travel(from touchDown: CGPoint, to location: CGPoint) -> CGFloat {
        location.x - touchDown.x
    }
}

/// A row's swipe actions from its trailing edge where the row isn't in a `List`, which has its
/// own (a project's lanes, `docs/projects.md` §2). Its numbers are the chat list's, measured on
/// iOS 27: round buttons 60 points wide with 10 between them and at the edge, the row following
/// the finger, a let-go past half of the buttons opening it, and a swipe past the full-swipe mark
/// doing the first action. A let-go decides by where the row is, never by how fast it moved: a
/// fast short flick there shuts, and a fast long one opens (`docs/inbox.md` §5).
///
/// Offsets are negative: how far the row has moved to the left. Buttons count from the edge, so
/// the first is the one a full swipe does.
public struct RowSwipe: Equatable, Sendable {
    /// What a let-go does.
    public enum Release: Equatable, Sendable {
        /// The row slides back.
        case close
        /// The row stays open on its buttons.
        case open
        /// The first action happens, then the row slides back.
        case full
    }

    /// Where a button sits: how far its trailing side is from the row's trailing edge, and how
    /// wide it is.
    public struct Slot: Equatable, Sendable {
        public let inset: CGFloat
        public let width: CGFloat
    }

    public static let buttonWidth: CGFloat = 60
    /// Between the buttons, and between them and the row's edges.
    public static let spacing: CGFloat = 10
    /// How much of the finger's travel past the full-swipe mark the row follows.
    static let resistance: CGFloat = 0.17
    /// How much of the row the full swipe needs, where that's more than its buttons do.
    static let fullSwipeShare: CGFloat = 0.52

    public let count: Int
    public let rowWidth: CGFloat

    public init(count: Int, rowWidth: CGFloat) {
        self.count = max(0, count)
        self.rowWidth = max(0, rowWidth)
    }

    /// How far the row moves to show every button: the buttons and the space around them.
    public var openWidth: CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * Self.buttonWidth + CGFloat(count + 1) * Self.spacing
    }

    /// Where the full swipe starts: a little over half the row, and on a narrow row once the
    /// first button has widened by its own width.
    public var fullSwipeDistance: CGFloat {
        max(openWidth + Self.buttonWidth, rowWidth * Self.fullSwipeShare)
    }

    /// Where the row sits for a drag of `translation` that began at `start` (0 shut, or
    /// `-openWidth` open). It never goes right of shut, and past the full-swipe mark it resists.
    public func offset(translation: CGFloat, from start: CGFloat) -> CGFloat {
        let raw = min(0, start + translation)
        let full = fullSwipeDistance
        guard count > 0, -raw > full else { return raw }
        return -(full + (-raw - full) * Self.resistance)
    }

    /// The row is past the full-swipe mark.
    public func isFull(_ offset: CGFloat) -> Bool {
        count > 0 && -offset >= fullSwipeDistance
    }

    /// What letting go here does.
    public func release(offset: CGFloat) -> Release {
        guard count > 0 else { return .close }
        if isFull(offset) { return .full }
        return -offset >= openWidth / 2 ? .open : .close
    }

    /// Button `index` shows once the row has nearly uncovered it. Past the full-swipe mark only
    /// the first does.
    public func shows(_ index: Int, at offset: CGFloat) -> Bool {
        guard index >= 0, index < count else { return false }
        if isFull(offset) { return index == 0 }
        let farSide = Self.spacing + CGFloat(index + 1) * Self.buttonWidth + CGFloat(index) * Self.spacing
        return -offset >= farSide - Self.spacing
    }

    /// Button `index`'s place. The buttons wait in their open places while the row uncovers
    /// them; past those the first widens and pushes the others along, and past the full-swipe
    /// mark it takes the whole space.
    public func slot(_ index: Int, at offset: CGFloat) -> Slot {
        let moved = max(0, -offset)
        let extra = max(0, moved - openWidth)
        if index == 0 {
            if isFull(offset) {
                return Slot(inset: Self.spacing, width: max(Self.buttonWidth, moved - 2 * Self.spacing))
            }
            return Slot(inset: Self.spacing, width: Self.buttonWidth + extra)
        }
        return Slot(inset: Self.spacing + CGFloat(index) * (Self.buttonWidth + Self.spacing) + extra, width: Self.buttonWidth)
    }

    /// How opaque button `index` is: past the open buttons the others fade, so the first one,
    /// the one a let-go there would do, stands out.
    public func opacity(_ index: Int, at offset: CGFloat) -> Double {
        let moved = -offset
        guard index > 0, moved > openWidth else { return 1 }
        let fade = min(1, (moved - openWidth) / Self.spacing)
        let progress = min(1, (moved - openWidth) / max(1, fullSwipeDistance - openWidth))
        return Double(1 - 0.5 * fade - 0.2 * progress)
    }
}
