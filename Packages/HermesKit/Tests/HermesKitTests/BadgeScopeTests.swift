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

    /// What the person saw: on iPhone, a group chat they had opened and backed out of showed no
    /// count while its Bots talked on. Backed out of, it stays selected under the list but isn't
    /// open (no open key), so its row shows its news like every other row.
    @Test func aChatBackedOutOfShowsItsCount() {
        #expect(BadgeScope.rowBadge(.count(4), key: "group:crew", open: nil) == .count(4))
        #expect(BadgeScope.rowBadge(.count(2), key: "bot:ops", open: nil) == .count(2))
        #expect(BadgeScope.rowBadge(.dot, key: "chat_a", open: nil) == .dot)
        // Another chat open on iPad or the Mac leaves it alone too.
        #expect(BadgeScope.rowBadge(.count(4), key: "group:crew", open: "chat_a") == .count(4))
    }

    /// The open chat is read as it's shown, so its row never says it's new.
    @Test func theOpenChatsRowShowsNoBadge() {
        #expect(BadgeScope.rowBadge(.count(4), key: "group:crew", open: "group:crew") == .none)
        #expect(BadgeScope.rowBadge(.dot, key: "chat_a", open: "chat_a") == .none)
    }

    /// What the person saw: on iPhone, a reply that came after they went back to the list was read
    /// on arrival, so its chat's row never showed it. The transcript stays alive under the list;
    /// only the open chat's transcript reads.
    @Test func onlyTheOpenChatReadsWhatComesIn() {
        #expect(!BadgeScope.readsAsShown("chat_a", open: nil))
        #expect(!BadgeScope.readsAsShown("bot:ops", open: nil))
        #expect(!BadgeScope.readsAsShown("chat_a", open: "chat_b"))
        #expect(BadgeScope.readsAsShown("chat_a", open: "chat_a"))
        #expect(BadgeScope.readsAsShown("bot:ops", open: "bot:ops"))
        // The new-chat draft has no key and nothing to read.
        #expect(!BadgeScope.readsAsShown(nil, open: nil))
    }

    /// The extension and the plugin's away count never take a hidden Bot's chat: its replies are
    /// delivered as before, and count nowhere.
    @Test func aHiddenBotsChatIsntCountable() {
        let botChats = ["s_ops": "ops", "s_scout": "scout", "s_scout_root": "scout"]
        #expect(BadgeScope.countedBotChats(botChats, hiddenBots: ["scout"]) == ["s_ops": "ops"])
        #expect(BadgeScope.countedBotChats(botChats, hiddenBots: []) == botChats)
    }
}
