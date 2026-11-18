import Foundation

/// Where sending leaves the chat (`docs/chat.md` §4, Scrolling).
public enum SendScroll: Equatable, Sendable {
    /// The page turns: the message glides up to just under the top bar, with blank room after it,
    /// and the reply fills in below it from its first line. Nothing follows the reply.
    case turnPage
    /// The chat stays at its end: the message lands at the bottom with the earlier messages above
    /// it, no blank room, and the reply grows from the bottom, followed while the reader stays
    /// at the end.
    case followEnd

    /// Settings → Chat → Keep chat at bottom when sending starts off: sending turns the page.
    public static let keepsAtBottomByDefault = false

    /// - Parameter keepsAtBottom: Settings → Chat → Keep chat at bottom when sending.
    /// - Parameter messageShown: a message of the person's is on screen for the page to turn to.
    ///   Without one (nothing pending to hold), the chat goes to its end either way.
    public static func onSend(keepsAtBottom: Bool, messageShown: Bool) -> SendScroll {
        messageShown && !keepsAtBottom ? .turnPage : .followEnd
    }
}
