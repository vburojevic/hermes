import Foundation

/// What the app icon and Dock badge, and the list's unread counts (the drawer, the Chats and Bots
/// segments), take from the rows (`docs/notifications.md` §2 Badge, `docs/inbox.md` §5). Keys are
/// `UnreadStore`'s: a session's stable key, `bot:<profile>`, `group:<id>`.
public enum BadgeScope {
    /// An unread row counts unless it's on screen, muted, or a hidden Bot: a Bot folded under
    /// "Hidden · N" counts like a muted one, so the badge never shows news the person put away.
    /// Its own row still shows its news.
    public static func counts(_ key: String, isUnread: Bool, open: String?, isMuted: Bool, hiddenBots: Set<String>) -> Bool {
        isUnread && key != open && !isMuted && !isHiddenBot(key, hiddenBots)
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
