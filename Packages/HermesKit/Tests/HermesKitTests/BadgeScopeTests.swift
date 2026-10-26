import Foundation
@testable import HermesKit
import Testing

/// A hidden Bot counts like a muted one: never on the app icon or Dock badge, never in the Bots
/// count, and not for the service extension or the plugin either (`docs/notifications.md` §2 Badge).
@Suite("Badge scope")
struct BadgeScopeTests {
    /// What the person saw: an icon saying 1 with no unread chat in the list. A Bot folded under
    /// "Hidden · 1" had news; the badge counted it, though only its folded row showed it.
    @Test func aHiddenBotsNewsStaysOffTheBadge() {
        let hidden: Set<String> = ["scout"]
        let rows = ["bot:scout", "bot:ops", "chat_a", "group:crew"]
        let counted = rows.filter { BadgeScope.counts($0, isUnread: true, open: nil, isMuted: false, hiddenBots: hidden) }
        #expect(counted == ["bot:ops", "chat_a", "group:crew"])
        // Shown in the roster again, it counts at the next update.
        #expect(BadgeScope.counts("bot:scout", isUnread: true, open: nil, isMuted: false, hiddenBots: []))
    }

    /// The rest of the rule as it was: read, on screen or muted rows never count.
    @Test func readOpenAndMutedRowsDontCount() {
        #expect(!BadgeScope.counts("chat_a", isUnread: false, open: nil, isMuted: false, hiddenBots: []))
        #expect(!BadgeScope.counts("chat_a", isUnread: true, open: "chat_a", isMuted: false, hiddenBots: []))
        #expect(!BadgeScope.counts("bot:ops", isUnread: true, open: nil, isMuted: true, hiddenBots: []))
        // A chat whose session id happens to look like a hidden Bot's name is no Bot.
        #expect(BadgeScope.counts("scout", isUnread: true, open: nil, isMuted: false, hiddenBots: ["scout"]))
    }

    /// The extension and the plugin's away count never take a hidden Bot's chat: its replies are
    /// delivered as before, and count nowhere.
    @Test func aHiddenBotsChatIsntCountable() {
        let botChats = ["s_ops": "ops", "s_scout": "scout", "s_scout_root": "scout"]
        #expect(BadgeScope.countedBotChats(botChats, hiddenBots: ["scout"]) == ["s_ops": "ops"])
        #expect(BadgeScope.countedBotChats(botChats, hiddenBots: []) == botChats)
    }
}
