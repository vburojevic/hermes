import Foundation

/// Up Next, the app's own queue of messages that go as turns of their own (`docs/follow-ups.md`):
/// whether a message goes now or waits there, and why one is there (`docs/chat.md` §4c).
public enum UpNext {
    /// Whether a message sent as a turn of its own (Send, Send Again, Talk, Try Again, Send as
    /// Message) goes now. It waits behind a running turn, a chat Hermes refused because something
    /// else holds it, and messages already waiting their turn, so it never jumps the line. A queue
    /// Stop paused waits for the person's Send, so a new message doesn't wait behind it.
    public static func goesNow(turnRunning: Bool, waitsForChat: Bool, othersWaiting: Bool, queuePaused: Bool) -> Bool {
        if turnRunning || waitsForChat { return false }
        return !othersWaiting || queuePaused
    }
}

/// Why a message is in Up Next when it wasn't sent there, for its row (`docs/follow-ups.md`).
public enum UpNextNote: Sendable, Equatable {
    /// It couldn't go the way it was sent (a steer the turn couldn't take, Ask Aside or Run in
    /// Background with no live chat to do it): it goes as the next message instead.
    case sendsNextInstead
    /// Stop emptied the gateway's queue with the turn: it never ran, and waits for a Send.
    case clearedByStop
    /// Hermes refused it; it waits for what the refusal says (`SendRefusal.action`).
    case refused(SendRefusal)
}
