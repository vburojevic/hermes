import Foundation
import HermesKit
@testable import HermesPush
import Testing

/// The app icon and Dock badge equal the true count on every path that moves it: unread, unmuted,
/// listed chats, Bots and group chats plus open requests (`docs/notifications.md` §2 Badge).
@Suite("Badge")
struct BadgeTests {
    private let gateway = PushNotice.Gateway(id: "inst_home", name: "Studio Mac")
    /// Open counts older than six hours don't count, so the story happens in the last few minutes.
    private let sent = Date.now.addingTimeInterval(-600)
    private let suite = "badge-\(UUID().uuidString)"
    private let home = UUID()

    private func shared() -> PushShared {
        let shared = PushShared(suiteName: suite)
        shared.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        shared.recordCountable(CountableChats(ids: ["chat_a", "chat_b", "chat_c", "chat_ops"], bots: ["ops"], rooms: ["room_crew"]),
                               gateway: home)
        return shared
    }

    private func notice(_ kind: PushNotice.Kind, _ session: String? = nil, room: String? = nil, profile: String? = nil,
                        open: Int? = nil, at offset: TimeInterval = 0, read: ReadMarks? = nil, sessions: [String] = []) -> PushNotice {
        var notice = PushNotice(kind: kind, id: "\(kind)-\(session ?? room ?? "")", thread: session ?? room.map { "room:\($0)" } ?? "",
                                sessionID: session, gateway: gateway, open: open, sessions: sessions, read: read)
        notice.roomID = room
        notice.profile = profile
        notice.sentAt = at(offset)
        return notice
    }

    private func at(_ offset: TimeInterval) -> Date {
        sent.addingTimeInterval(offset)
    }

    private func chat(_ key: String, at offset: TimeInterval = 0) -> UnreadChat {
        UnreadChat(key: key, ids: [key], since: at(offset))
    }

    /// The drift the person saw: the phone left the app with two unread chats, one was read on the
    /// Mac and the plugin's badge-only push set the icon right (1). A withdrawal then woke the app,
    /// which set the badge from its own list, still holding the chat read on the Mac: 2 again, and
    /// the plugin, believing the icon showed its count, never set it right. The withdrawal carries
    /// the latest reads (plugin 1.4.6); followed first, the badge stays true.
    @Test func aBackgroundPushDoesntPutAChatReadElsewhereBack() {
        let shared = shared()
        shared.recordOpen(1, gateway: "inst_home", at: at(0))
        shared.recordUnread([chat("chat_a"), chat("chat_b")], gateway: home)
        #expect(shared.badge == 3)
        let withdraw = notice(.withdraw, open: 0, at: 20, read: ReadMarks(chats: ["chat_a": at(10)]))

        // What build 2610260307 did with a withdrawal: the open count, and nothing else.
        let before = PushShared(suiteName: "badge-before-\(UUID().uuidString)")
        before.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        before.recordUnread([chat("chat_a"), chat("chat_b")], gateway: home)
        before.recordOpen(withdraw.open ?? 0, gateway: "inst_home", at: at(20))
        #expect(before.badge == 2, "the drift: the chat read on the Mac is back on the icon")

        let marks = shared.noteBackground(withdraw, gateway: home, at: at(20))
        #expect(marks.chats.keys.sorted() == ["chat_a"])
        #expect(shared.badge == 1)
        #expect(shared.unread(gateway: home).map(\.key) == ["chat_b"])
        // And a count from the app's own marks, when they haven't caught up yet, doesn't bring it back.
        shared.recordUnread([chat("chat_a"), chat("chat_b")], gateway: home)
        #expect(shared.badge == 1)
    }

    /// The plugin's background pushes as it sends them: a `sync` names chats to read now, not chats
    /// read, so only its `read` list takes chats off.
    @Test func aSyncsChatsArentReads() throws {
        let sync = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"sync","sessions":["chat_a"],"gateway":{"id":"inst_home","name":"Studio Mac"},"open":2,"sent_at":1792300020,"read":{"chats":[["chat_b",1792300015]],"rooms":[]}}
        """#.utf8))
        #expect(ReadMarks(carriedBy: sync) == ReadMarks(chats: ["chat_b": Date(timeIntervalSince1970: 1_792_300_015)]))
        let withdraw = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"withdraw","ids":["req-1"],"gateway":{"id":"inst_home","name":"Studio Mac"},"open":0,"sent_at":1792300020,"read":{"chats":[],"rooms":[["room_crew",1792300011]]}}
        """#.utf8))
        #expect(ReadMarks(carriedBy: withdraw) == ReadMarks(rooms: ["room_crew": Date(timeIntervalSince1970: 1_792_300_011)]))

        let shared = shared()
        shared.recordUnread([chat("chat_a"), chat("chat_b")], gateway: home)
        shared.noteBackground(notice(.sync, open: 2, at: 20, read: ReadMarks(chats: ["chat_b": at(15)]), sessions: ["chat_a"]),
                              gateway: home, at: at(20))
        #expect(shared.unread(gateway: home).map(\.key) == ["chat_a"])
        #expect(shared.badge == 3, "two open requests and chat_a")
        // A `read` push's own lists are reads, as before.
        let read = notice(.read, open: 0, at: 30, sessions: ["chat_a"])
        #expect(ReadMarks(carriedBy: read).chats.keys.sorted() == ["chat_a"])
        shared.noteBackground(read, gateway: home, at: at(30))
        #expect(shared.badge == 0)
        // An older plugin's withdrawal carries no reads: only its open count moves.
        #expect(shared.noteBackground(notice(.withdraw, open: 1, at: 40), gateway: home).isEmpty)
        #expect(shared.badge == 1)
    }

    /// Every path, one after another, on one gateway, with the badge after each step.
    @Test func theBadgeIsTrueOnEveryPath() {
        let shared = shared()
        // Launch: the app's counts from its list.
        shared.recordOpen(0, gateway: "inst_home", at: at(0))
        shared.recordUnread([chat("chat_a")], gateway: home)
        #expect(shared.badge == 1)
        // A reply arrives in the background (the extension): one more; a second reply in it, none.
        #expect(shared.noteUnread(notice(.reply, "chat_b", at: 10), gateway: home))
        #expect(!shared.noteUnread(notice(.reply, "chat_b", at: 11), gateway: home))
        #expect(shared.badge == 2)
        // A Bot's message in its own chat, and a Bot's message in a group chat: one each.
        #expect(shared.noteUnread(notice(.reply, "chat_ops_2", profile: "ops", at: 12), gateway: home))
        #expect(shared.noteUnread(notice(.message, room: "room_crew", at: 13), gateway: home))
        #expect(shared.badge == 4)
        // A routine's run, a Bot-to-Bot one-shot chat, a helper's session: never listed, never counted.
        #expect(!shared.noteUnread(notice(.reply, "20261026_routine_run", at: 14), gateway: home))
        #expect(!shared.noteUnread(notice(.reply, "20261026_oneshot", profile: "ghost", at: 15), gateway: home))
        #expect(shared.badge == 4)
        // A request opens: the notice's open count.
        shared.recordOpen(1, gateway: "inst_home", at: at(16))
        #expect(shared.badge == 5)
        // Read on another device: the next notice lists it.
        let next = notice(.reply, "chat_c", open: 1, at: 20, read: ReadMarks(chats: ["chat_a": at(18)]))
        #expect(shared.noteRead(next.read ?? ReadMarks(), gateway: home, at: at(20)))
        #expect(shared.noteUnread(next, gateway: home))
        #expect(shared.badge == 5)
        // Read on another device: a `read` push.
        shared.noteBackground(notice(.read, open: 1, at: 25, read: ReadMarks(chats: ["chat_b": at(24)])), gateway: home, at: at(25))
        #expect(shared.badge == 4)
        // The request answered on another device: the withdrawal's open count.
        shared.noteBackground(notice(.withdraw, open: 0, at: 30), gateway: home, at: at(30))
        #expect(shared.badge == 3)
        // An older open count can't undo a newer one.
        shared.recordOpen(1, gateway: "inst_home", at: at(29))
        #expect(shared.badge == 3)
        // A group chat read elsewhere (the plugin's reads are its only read mark).
        shared.noteBackground(notice(.read, open: 0, at: 35, read: ReadMarks(rooms: ["room_crew": at(34)])), gateway: home, at: at(35))
        #expect(shared.badge == 2)
        // Muted: it leaves the badge as the app counts again, and its news doesn't count.
        shared.setMutes(["chat_c": .distantFuture], gateway: home)
        shared.recordUnread([UnreadChat(key: "bot:ops", ids: ["chat_ops"], since: at(12))], gateway: home)
        #expect(shared.badge == 1)
        #expect(!shared.noteUnread(notice(.reply, "chat_c", at: 40), gateway: home))
        // Deleted or archived (the Bot hidden): it leaves the list the app shares, and the badge.
        shared.recordCountable(CountableChats(ids: ["chat_a", "chat_b", "chat_c"], bots: [], rooms: ["room_crew"]), gateway: home)
        #expect(shared.badge == 0)
        // Relaunch: the same App Group, the same count.
        shared.recordOpen(2, gateway: "inst_home", at: at(50))
        shared.recordUnread([chat("chat_a", at: 60)], gateway: home)
        #expect(shared.badge == 3)
        #expect(PushShared(suiteName: suite).badge == 3)
        // Needs You counts only the requests.
        shared.badgeMode = .needsYou
        #expect(shared.badge == 2)
    }

    /// Installed plugins only update when the app reinstalls them: against plugin 1.4.5 (no reads in
    /// withdrawals, syncs, `presence` or `status`), this build sets the badge exactly as the build
    /// before it did, from the same pushes, and counts nothing twice.
    @Test func anOlderPluginLeavesTheBadgeAsItWas() throws {
        let today = shared()
        let before = PushShared(suiteName: "badge-145-\(UUID().uuidString)")
        before.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        before.recordCountable(today.countable(gateway: home) ?? CountableChats(), gateway: home)
        // Plugin 1.4.5's pushes, as it sends them: no `read` in a withdrawal or a sync.
        let withdraw = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"withdraw","ids":["req-1"],"gateway":{"id":"inst_home","name":"Studio Mac"},"open":1,"sent_at":\#(at(30).timeIntervalSince1970)}
        """#.utf8))
        let sync = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"sync","sessions":["chat_a"],"gateway":{"id":"inst_home","name":"Studio Mac"},"open":1,"sent_at":\#(at(40).timeIntervalSince1970)}
        """#.utf8))
        let readPush = notice(.read, open: 1, at: 50, read: ReadMarks(chats: ["chat_b": at(45)]))
        for shared in [today, before] {
            shared.recordOpen(2, gateway: "inst_home", at: at(0))
            shared.recordUnread([chat("chat_a"), chat("chat_b")], gateway: home)
            #expect(shared.noteUnread(notice(.reply, "chat_c", at: 10), gateway: home))
            #expect(!shared.noteUnread(notice(.reply, "chat_c", at: 11), gateway: home), "never twice")
        }
        // This build follows each push; the build before recorded the open count, and a read push's reads.
        #expect(today.noteBackground(withdraw, gateway: home).isEmpty)
        #expect(today.noteBackground(sync, gateway: home).isEmpty)
        today.noteBackground(readPush, gateway: home)
        before.recordOpen(1, gateway: "inst_home", at: at(30))
        before.recordOpen(1, gateway: "inst_home", at: at(40))
        before.recordOpen(1, gateway: "inst_home", at: at(50))
        before.noteRead(ReadMarks(readPush), gateway: home)
        #expect(today.badge == before.badge)
        #expect(today.badge == 3, "one open request, chat_a and chat_c")
        #expect(today.unread(gateway: home).map(\.key) == before.unread(gateway: home).map(\.key))
    }

    /// The Mac registers nowhere, but its Dock counts the open requests too: an open count counts only
    /// for a gateway this device knows by its installation, so the Mac must remember it.
    @Test func openRequestsCountOnlyForAKnownGateway() {
        let shared = PushShared(suiteName: "badge-mac-\(UUID().uuidString)")
        shared.recordOpen(2, gateway: "inst_home")
        #expect(shared.badge == 0, "the Dock before: open requests never counted")
        shared.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        shared.recordOpen(2, gateway: "inst_home")
        #expect(shared.badge == 2)
        // A count older than six hours is forgotten.
        let stale = PushShared(suiteName: "badge-mac-\(UUID().uuidString)")
        stale.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        stale.recordOpen(3, gateway: "inst_home", at: .now.addingTimeInterval(-7 * 3600))
        #expect(stale.badge == 0)
    }

    /// What the other gateways add is counted as the badge counts: an entry the list doesn't show
    /// never takes anything off another gateway's share.
    @Test func whatTheOthersAddMatchesTheBadge() {
        let shared = PushShared(suiteName: "badge-others-\(UUID().uuidString)")
        let vps = UUID()
        shared.remember(installationID: "inst_home", appID: home, name: "Home")
        shared.remember(installationID: "inst_vps", appID: vps, name: "VPS")
        shared.recordCountable(CountableChats(ids: ["a"]), gateway: home)
        shared.recordCountable(CountableChats(ids: ["v"]), gateway: vps)
        shared.recordOpen(0, gateway: "inst_home")
        shared.recordOpen(1, gateway: "inst_vps")
        // Home's list: one chat it shows, and one only a notice added that it no longer shows.
        shared.recordUnread([UnreadChat(key: "a", ids: ["a"], since: sent),
                             UnreadChat(key: "push:gone", ids: ["gone"], since: sent)], gateway: home)
        shared.recordUnread([UnreadChat(key: "v", ids: ["v"], since: sent)], gateway: vps)
        #expect(shared.badge == 3)
        #expect(shared.badge(besides: home) == 2, "the VPS's request and chat")
        #expect(shared.badge(besides: vps) == 1)
    }

    /// A chat Hermes never marked (`last_read_at` empty) is read by Hermes' rule, and the Mac's list
    /// shows it so (`UnreadStore`). Its reply used to count on the sleeping iPhone from the notice:
    /// one on the icon, none on the Dock. The app names those chats with its list, and the extension
    /// counts their news only once a read on some device gives them Hermes' mark.
    @Test func aChatHermesNeverMarkedCountsTheSameEverywhere() {
        let shared = shared()
        shared.recordCountable(CountableChats(ids: ["chat_a", "chat_b"], unmarked: ["chat_b"]), gateway: home)
        shared.recordOpen(0, gateway: "inst_home", at: at(0))

        // Before: a list without unmarked chats counts every reply it shows.
        let before = PushShared(suiteName: "badge-unmarked-before-\(UUID().uuidString)")
        before.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        before.recordCountable(CountableChats(ids: ["chat_a", "chat_b"]), gateway: home)
        before.noteUnread(notice(.reply, "chat_b", at: 10), gateway: home)
        #expect(before.badge == 1, "the drift: the iPhone counted what the Mac didn't")

        #expect(!shared.noteUnread(notice(.reply, "chat_b", at: 10), gateway: home))
        #expect(shared.badge == 0)
        // A chat Hermes marked counts as before.
        shared.noteUnread(notice(.reply, "chat_a", at: 11), gateway: home)
        #expect(shared.badge == 1)

        // Read on the Mac, the chat has a mark, so its next reply is unread everywhere.
        shared.noteRead(ReadMarks(chats: ["chat_b": at(20)]), gateway: home, at: at(20))
        #expect(shared.countable(gateway: home)?.unmarked.isEmpty == true)
        shared.noteUnread(notice(.reply, "chat_b", at: 30), gateway: home)
        #expect(shared.badge == 2)
    }

    /// Installed plugins only update when the app reinstalls them: plugin 1.4.6 ignores `unmarked` and
    /// counts a never-marked chat's reply in its badge push. Against it the app names no unmarked
    /// chats, so the extension counts exactly as the build before did, the same count as the plugin's
    /// badge push, and nothing twice.
    @Test func anOlderPluginKeepsCountingUnmarkedChatsAsBefore() {
        #expect(!AppPushClient.namesUnmarked(pluginVersion: "1.4.6"))
        #expect(!AppPushClient.namesUnmarked(pluginVersion: nil), "a gateway not checked yet")
        #expect(AppPushClient.namesUnmarked(pluginVersion: "1.4.7"))
        #expect(AppPushClient.namesUnmarked(pluginVersion: "1.10.0"))

        let named: Set<String> = AppPushClient.namesUnmarked(pluginVersion: "1.4.6") ? ["chat_b"] : []
        let today = shared()
        today.recordCountable(CountableChats(ids: ["chat_a", "chat_b"], unmarked: named), gateway: home)
        let before = PushShared(suiteName: "badge-146-\(UUID().uuidString)")
        before.remember(installationID: "inst_home", appID: home, name: "Studio Mac")
        before.recordCountable(CountableChats(ids: ["chat_a", "chat_b"]), gateway: home)
        for shared in [today, before] {
            shared.recordOpen(1, gateway: "inst_home", at: at(0))
            #expect(shared.noteUnread(notice(.reply, "chat_b", at: 10), gateway: home))
            #expect(!shared.noteUnread(notice(.reply, "chat_b", at: 11), gateway: home), "never twice")
        }
        // Plugin 1.4.6's badge push: the open request and chat_b.
        #expect(today.badge == before.badge && today.badge == 2)
        #expect(today.unread(gateway: home).map(\.key) == before.unread(gateway: home).map(\.key))
    }

    /// What the person saw: an icon saying 1 with nothing unread in the list. A reply in a chat Hermes
    /// never marked had counted from its notice. Once this build names the chat, the next count the
    /// app records takes the icon to 0, and the chat's next reply leaves it there.
    @Test func aBadgeOfOneWithNothingUnreadGoesToZero() {
        let shared = shared()
        shared.recordOpen(0, gateway: "inst_home", at: at(0))
        // An older build's state: the extension counted the reply, the list shows nothing unread.
        shared.recordCountable(CountableChats(ids: ["chat_b"]), gateway: home)
        shared.noteUnread(notice(.reply, "chat_b", at: 10), gateway: home)
        #expect(shared.badge == 1, "the icon the person saw")

        // This build, woken or in front, records what its list counts, and names the unmarked chat.
        shared.recordCountable(CountableChats(ids: ["chat_b"], unmarked: ["chat_b"]), gateway: home)
        shared.recordUnread([], gateway: home)
        #expect(shared.badge == 0)
        #expect(!shared.noteUnread(notice(.reply, "chat_b", at: 20), gateway: home))
        #expect(shared.badge == 0)
    }

    /// The read can come with the reply: the notice's own read list marks the chat first.
    @Test func aReadInTheNoticeMarksTheChat() {
        let shared = shared()
        shared.recordCountable(CountableChats(ids: ["chat_b"], unmarked: ["chat_b"]), gateway: home)
        let reply = notice(.reply, "chat_b", at: 30, read: ReadMarks(chats: ["chat_b": at(20)]))
        if let read = reply.read { shared.noteRead(read, gateway: home, at: at(30)) }
        shared.noteUnread(reply, gateway: home)
        #expect(shared.badge == 1)
    }

    /// Bots and group chats keep their own read points, so `unmarked` never holds them back.
    @Test func unmarkedNeverHoldsBackABotOrARoom() {
        let countable = CountableChats(ids: ["chat_ops"], bots: ["ops"], rooms: ["room_crew"], unmarked: ["chat_ops"])
        #expect(!countable.isUnmarked(ReadNotices.Chat(ids: ["chat_ops"], profile: "ops")))
        #expect(!countable.isUnmarked(ReadNotices.Chat(ids: [], room: "room_crew")))
        #expect(countable.isUnmarked(ReadNotices.Chat(ids: ["chat_ops"])))
    }

    /// A list the app wrote before it named unmarked chats still opens.
    @Test func anOlderCountableListDecodes() throws {
        let old = try JSONDecoder().decode(CountableChats.self, from: Data(#"{"ids":["a"],"bots":[],"rooms":[]}"#.utf8))
        #expect(old == CountableChats(ids: ["a"]))
    }
}
