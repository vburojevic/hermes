import Foundation
@testable import HermesPush
import Testing

/// Read chats leave no notifications behind, and the badge counts what's still unread
/// (`docs/notifications.md` §2 Reading, Badge).
@Suite("Read notices")
struct ReadNoticesTests {
    private let gateway = PushNotice.Gateway(id: "inst_1", name: "Studio Mac")
    private let sent = Date(timeIntervalSince1970: 1_792_300_000)

    private func reply(_ session: String, profile: String? = nil, at date: Date? = nil) -> PushNotice {
        var notice = PushNotice(kind: .reply, id: "reply-\(session)", thread: session, sessionID: session, gateway: gateway)
        notice.profile = profile
        notice.sentAt = date ?? sent
        return notice
    }

    private func message(room: String, at date: Date? = nil) -> PushNotice {
        var notice = PushNotice(kind: .message, id: "msg-\(room)", thread: "room:\(room)", gateway: gateway)
        notice.roomID = room
        notice.sentAt = date ?? sent
        return notice
    }

    // MARK: The wire

    /// The plugin's `read` push and the `read` list every notice carries.
    @Test func readsDecodeAsThePluginSendsThem() throws {
        // Each chat with when it was read: an earlier read doesn't clear news that came after it.
        let push = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"read","read":{"chats":[["20261021_a",1792299000],["20261021_ops",1792300009.5]],"rooms":[["room_1",1792300001]]},"gateway":{"id":"inst_1","name":"Studio Mac"},"open":1,"sent_at":1792300010.25}
        """#.utf8))
        #expect(push.kind == .read && push.open == 1)
        let marks = ReadMarks(push)
        #expect(marks.chats["20261021_a"] == Date(timeIntervalSince1970: 1_792_299_000))
        #expect(marks.chats["20261021_ops"] == Date(timeIntervalSince1970: 1_792_300_009.5))
        #expect(marks.rooms["room_1"] == Date(timeIntervalSince1970: 1_792_300_001))
        // Plain lists count as read when the push was sent.
        let plain = try JSONDecoder().decode(PushNotice.self, from: Data(#"{"kind":"read","id":"","sessions":["s1"],"rooms":["r1"],"sent_at":1792300010}"#.utf8))
        #expect(ReadMarks(plain) == ReadMarks(chats: ["s1": Date(timeIntervalSince1970: 1_792_300_010)], rooms: ["r1": Date(timeIntervalSince1970: 1_792_300_010)]))

        let notice = try JSONDecoder().decode(PushNotice.self, from: Data(#"""
        {"v":1,"kind":"reply","id":"r1","title":"Ops","body":"Done","session_id":"s1","read":{"chats":[["s0",1792299990.5],["s9",1792299000]],"rooms":[["room_2",1792299995]]}}
        """#.utf8))
        #expect(notice.read?.chats["s0"] == Date(timeIntervalSince1970: 1_792_299_990.5))
        #expect(notice.read?.rooms["room_2"] == Date(timeIntervalSince1970: 1_792_299_995))
        let again = try JSONDecoder().decode(PushNotice.self, from: JSONEncoder().encode(notice))
        #expect(again.read == notice.read)
        // A list this build can't read costs the cleanup, never the notice.
        let odd = try JSONDecoder().decode(PushNotice.self, from: Data(#"{"kind":"reply","id":"r2","read":{"chats":"soon"}}"#.utf8))
        #expect(odd.id == "r2" && odd.read == nil)
    }

    // MARK: Which notifications a read clears

    @Test func onlyAChatsNewsIsClearedByReadingIt() {
        #expect(ReadNotices.chat(of: reply("s1"))?.ids == ["s1"])
        #expect(ReadNotices.chat(of: message(room: "room_1")) == .init(ids: [], room: "room_1"))
        // A Bot's reply is known by its Bot too.
        #expect(ReadNotices.chat(of: reply("s_ops", profile: "ops"))?.profile == "ops")
        // Requests wait for an answer; results and cards are settled on their own.
        for kind: PushNotice.Kind in [.approval, .question, .password, .widget, .task, .taskFailed, .cardNeedsYou, .tidied, .test] {
            var notice = reply("s1")
            notice.kind = kind
            #expect(ReadNotices.chat(of: notice) == nil, "\(kind)")
        }
    }

    @Test func aNoticeGoesOnlyWhenItsChatWasReadAfterItWasSent() {
        let marks = ReadMarks(chats: ["s1": sent.addingTimeInterval(5)], rooms: ["room_1": sent.addingTimeInterval(-60)])
        #expect(ReadNotices.isRead(reply("s1"), deliveredAt: sent, readAt: marks.readAt))
        // News after the read stays: that reply is new.
        #expect(!ReadNotices.isRead(reply("s1", at: sent.addingTimeInterval(30)), deliveredAt: sent, readAt: marks.readAt))
        #expect(!ReadNotices.isRead(reply("s2"), deliveredAt: sent, readAt: marks.readAt))
        #expect(!ReadNotices.isRead(message(room: "room_1"), deliveredAt: sent, readAt: marks.readAt))
        #expect(ReadNotices.isRead(message(room: "room_1", at: sent.addingTimeInterval(-90)), deliveredAt: sent, readAt: marks.readAt))
        // Without a send time, when it was delivered.
        var undated = reply("s1")
        undated.sentAt = nil
        #expect(ReadNotices.isRead(undated, deliveredAt: sent, readAt: marks.readAt))
        #expect(!ReadNotices.isRead(undated, deliveredAt: sent.addingTimeInterval(10), readAt: marks.readAt))
    }

    // MARK: The badge

    @Test func theBadgeCountsUnreadChatsUntilTheyreRead() {
        let shared = PushShared(suiteName: "read-notices-\(UUID().uuidString)")
        let home = UUID()
        shared.remember(installationID: "inst_1", appID: home, name: "Studio Mac")
        shared.recordOpen(1, gateway: "inst_1")
        #expect(shared.badgeMode == .unreadChats, "unread chats count by default")
        // The app's own count: a chat and a Bot.
        let chat = UnreadChat(key: "s1", ids: ["s1", "s1_root"], since: sent)
        let bot = UnreadChat(key: "bot:ops", ids: ["s_ops"], since: sent)
        #expect(shared.recordUnread([chat, bot], gateway: home))
        #expect(!shared.recordUnread([chat, bot], gateway: home), "the same list changes nothing")
        #expect(shared.badge == 3)

        // News for a chat the list already has (by its root, or the Bot by its profile) counts once.
        #expect(!shared.noteUnread(reply("s1_root"), gateway: home))
        #expect(!shared.noteUnread(reply("s_ops_2", profile: "ops"), gateway: home))
        #expect(shared.noteUnread(reply("s2"), gateway: home))
        #expect(shared.noteUnread(message(room: "room_1"), gateway: home))
        #expect(shared.badge == 5)

        // A muted chat's news is delivered quietly and doesn't count.
        shared.setMutes(["s3": .distantFuture], gateway: home)
        #expect(!shared.noteUnread(reply("s3"), gateway: home))
        // News that the same notice says was read already doesn't count either.
        var late = reply("s4")
        late.read = ReadMarks(chats: ["s4": sent.addingTimeInterval(1)])
        #expect(!shared.noteUnread(late, gateway: home))

        // Reads take chats off, but not ones that became unread after the read.
        #expect(shared.noteRead(ReadMarks(chats: ["s1": sent.addingTimeInterval(2), "s2": sent.addingTimeInterval(-5)]), gateway: home))
        #expect(shared.unread(gateway: home).map(\.key).sorted() == ["bot:ops", "group:room_1", "push:s2"])
        #expect(shared.noteRead(ReadMarks(rooms: ["room_1": sent]), gateway: home))
        #expect(!shared.noteRead(ReadMarks(chats: ["nobody": sent]), gateway: home))
        #expect(shared.badge == 3)

        // Needs You counts only the requests.
        shared.badgeMode = .needsYou
        #expect(shared.badge == 1)
        #expect(!shared.noteUnread(reply("s5"), gateway: home), "counted, but not in the badge")
        shared.forget(appID: home)
        #expect(shared.unread(gateway: home).isEmpty)
    }

    /// Each gateway's plugin sets the whole badge while the app is away: it adds what the others count.
    @Test func eachGatewayKnowsWhatTheOthersAddToTheBadge() {
        let shared = PushShared(suiteName: "read-notices-\(UUID().uuidString)")
        let home = UUID(), vps = UUID()
        shared.remember(installationID: "inst_home", appID: home, name: "Home")
        shared.remember(installationID: "inst_vps", appID: vps, name: "VPS")
        shared.recordOpen(1, gateway: "inst_home")
        shared.recordOpen(2, gateway: "inst_vps")
        shared.recordUnread([UnreadChat(key: "a", ids: ["a"], since: sent), UnreadChat(key: "b", ids: ["b"], since: sent)], gateway: home)
        shared.recordUnread([UnreadChat(key: "c", ids: ["c"], since: sent)], gateway: vps)
        #expect(shared.badge == 6)
        #expect(shared.badge(besides: home) == 3 && shared.badge(besides: vps) == 3)
        shared.badgeMode = .needsYou
        #expect(shared.badge(besides: home) == 2)
    }

    /// Woken by a `read` push, the app may count from marks that haven't caught up: a chat read
    /// elsewhere doesn't come back, but one with news since the read does.
    @Test func aCountFromStaleMarksDoesntBringReadChatsBack() {
        let shared = PushShared(suiteName: "read-notices-\(UUID().uuidString)")
        let home = UUID()
        shared.noteRead(ReadMarks(chats: ["s1": sent.addingTimeInterval(5)], rooms: ["room_1": sent]), gateway: home, at: sent)
        shared.recordUnread([UnreadChat(key: "s1", ids: ["s1"], since: sent),
                             UnreadChat(key: "group:room_1", room: "room_1", since: sent.addingTimeInterval(-30)),
                             UnreadChat(key: "s2", ids: ["s2"], since: sent)], gateway: home)
        #expect(shared.unread(gateway: home).map(\.key) == ["s2"])
        shared.recordUnread([UnreadChat(key: "s1", ids: ["s1"], since: sent.addingTimeInterval(60))], gateway: home)
        #expect(shared.unread(gateway: home).map(\.key) == ["s1"])
        // The extension's count follows the same reads.
        #expect(!shared.noteUnread(reply("s1", at: sent), gateway: home))
        // Reads older than six hours are forgotten.
        shared.noteRead(ReadMarks(chats: ["s9": sent.addingTimeInterval(7 * 3600)]), gateway: home, at: sent.addingTimeInterval(7 * 3600))
        #expect(shared.reads(gateway: home).chats.keys.sorted() == ["s9"])
    }
}
