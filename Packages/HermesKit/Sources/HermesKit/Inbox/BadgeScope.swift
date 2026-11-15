import Foundation

/// What the app icon and Dock badge, and the list's unread counts (the chat list, the Chats and Bots
/// segments), take from the rows (`docs/notifications.md` §2 Badge, `docs/inbox.md` §5). Keys are
/// `UnreadStore`'s: a session's stable key, `bot:<profile>`, `group:<id>`.
public enum BadgeScope {
    /// An unread row counts unless it's on screen, muted, or a hidden Bot: a Bot folded under
    /// "Hidden · N" counts like a muted one, so the badge never shows news the person put away.
    /// Its own row still shows its news.
    public static func counts(_ key: String, isUnread: Bool, open: String?, isMuted: Bool, hiddenBots: Set<String>) -> Bool {
        isUnread && key != open && !isMuted && !isHiddenBot(key, hiddenBots)
    }

    /// What a row shows (`docs/inbox.md` §2): its badge, unless its chat is open. A chat backed out
    /// of on iPhone stays selected under the list but isn't open, so its news shows on its row.
    public static func rowBadge(_ badge: UnreadBadge, key: String, open: String?) -> UnreadBadge {
        key == open ? .none : badge
    }

    /// Whether a transcript reads what comes in (`docs/inbox.md` §4): only while its chat is the
    /// open one. Backed out of on iPhone it stays alive under the list, but nothing in it is seen.
    public static func readsAsShown(_ key: String?, open: String?) -> Bool {
        key != nil && key == open
    }

    /// A row of the Bots list (a Bot or a group chat), which the Bots segment counts; every other
    /// row is the Chats segment's.
    public static func isBotsRow(_ key: String) -> Bool {
        key.hasPrefix("bot:") || key.hasPrefix("group:")
    }

    public static func isHiddenBot(_ key: String, _ hiddenBots: Set<String>) -> Bool {
        key.hasPrefix("bot:") && hiddenBots.contains(String(key.dropFirst(4)))
    }

    /// Bot Chats by session id, leaving out hidden Bots': what the service extension and the push
    /// plugin may count (`CountableChats`, `presence away` with `listed`).
    public static func countedBotChats(_ botChats: [String: String], hiddenBots: Set<String>) -> [String: String] {
        botChats.filter { !hiddenBots.contains($0.value) }
    }
}
