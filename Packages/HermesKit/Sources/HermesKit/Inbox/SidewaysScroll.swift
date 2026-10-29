import Foundation

/// A sideways scroll on a message on the Mac: a trackpad's or a Magic Mouse's swipe, or a mouse
/// that scrolls sideways. A scroll to the left replies to it, as a swipe left does on iPhone; one
/// that starts up or down stays the chat's (`docs/inbox.md` §4). Fed one scroll event at a time.
public struct SidewaysScroll: Sendable {
    /// Where an event sits in its scroll.
    public enum Phase: Sendable {
        case began, changed, ended, cancelled
        /// The glide after the fingers lift. It never starts a swipe.
        case momentum
        /// A mouse wheel's step, which has no phases: a run of them ends when they stop (`idle()`).
        case step
    }

    public enum Action: Equatable, Sendable {
        /// Not the message's: the chat scrolls.
        case pass
        /// The message follows the scroll, this far across (negative is to the left).
        case follow(CGFloat)
        /// The scroll ended this far across.
        case release(CGFloat)
        /// The glide after a swipe the message took: nothing moves, and the chat, which never
        /// saw that scroll begin, doesn't either.
        case absorb
    }

    private enum State: Sendable {
        case idle, deciding, sideways, other
    }

    /// How far a scroll moves before it's decided: a trackpad's first events are a point or two.
    static let decidingDistance: CGFloat = 4

    private var state = State.idle
    private var translation = CGPoint.zero
    /// The last scroll was the message's, so its glide is too.
    private var glides = false

    public init() {}

    /// No scroll is under way, so the next one may start a swipe.
    public var isIdle: Bool { state == .idle }

    /// Moves `delta` points, in the direction the content moves (AppKit's `scrollingDelta`).
    public mutating func scroll(_ phase: Phase, delta: CGPoint) -> Action {
        switch phase {
        case .began:
            glides = false
            state = .deciding
            translation = delta
            return decide()
        case .changed, .step:
            if state == .idle {
                // A trackpad scroll that began somewhere else isn't this message's.
                guard phase == .step else { return .pass }
                glides = false
                state = .deciding
                translation = .zero
            }
            translation.x += delta.x
            translation.y += delta.y
            switch state {
            case .deciding: return decide()
            case .sideways: return .follow(translation.x)
            case .idle, .other: return .pass
            }
        case .ended, .cancelled:
            defer { reset() }
            guard state == .sideways else { return .pass }
            glides = true
            return .release(phase == .ended ? translation.x : 0)
        case .momentum:
            return glides ? .absorb : .pass
        }
    }

    /// A scroll began over something else. Its glide is that scroll's, never this message's.
    public mutating func beganElsewhere() {
        glides = false
    }

    /// A mouse wheel went quiet: its run of steps ends here.
    public mutating func idle() -> Action {
        defer { reset() }
        return state == .sideways ? .release(translation.x) : .pass
    }

    private mutating func decide() -> Action {
        guard abs(translation.x) + abs(translation.y) >= Self.decidingDistance else { return .pass }
        let sideways = SidewaysSwipe.begins(velocity: .zero, translation: translation, direction: .left)
        state = sideways ? .sideways : .other
        return sideways ? .follow(translation.x) : .pass
    }

    private mutating func reset() {
        state = .idle
        translation = .zero
    }
}
