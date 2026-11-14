import Foundation
@testable import HermesKit
import Testing

/// The numbers the sidebar shows for group chats and their Bots (`docs/inbox.md` §1, §5).
@Suite("Sidebar counts")
struct SidebarCountsTests {
    /// A room's log as Hermes serves it (`read_events`): events after `since_seq`, oldest first,
    /// `limit` at most, and a refusal for a seq ahead of the log.
    final class FakeLog: @unchecked Sendable {
        var events: [RoomEvent]
        var asked: [Int] = []

        init(_ events: [RoomEvent]) { self.events = events }

        var latest: Int { events.last?.seq ?? 0 }

        func read(_ since: Int, _ limit: Int) throws -> RoomLogPage {
            asked.append(since)
            if since > latest { throw CancellationError() }
            let page = Array(events.filter { $0.seq > since }.prefix(limit))
            let cursor = page.last?.seq ?? since
            return RoomLogPage(events: page, cursor: cursor, hasMore: cursor < latest)
        }
    }

    static func event(_ seq: Int, _ kind: String, _ text: String = "") -> RoomEvent {
        RoomEvent(seq: seq, kind: kind, actorKind: kind == "message.user" ? "user" : "member",
                  actorID: kind == "message.member" ? "writer" : nil,
                  payload: .object(["text": .string(text), "member_id": .string("writer")]), createdAt: nil)
    }

    /// A room whose log has run long: `filler` settled events, then the person's question and
    /// four replies.
    static func longRoom(filler: Int) -> FakeLog {
        var events = (1...filler).map { event($0, "room.activity") }
        events.append(event(filler + 1, "message.user", "What changed since the last build?"))
        for n in 2...5 { events.append(event(filler + n, "message.member", "Reply \(n - 1)")) }
        return FakeLog(events)
    }

    /// What the person saw: Release log, 199 events in, got four replies and showed no badge.
    /// The count read the first 200 events of the log and never reached them.
    @Test func aLongRoomsNewMessagesAllCount() async throws {
        let log = Self.longRoom(filler: 199)
        let found = try await RoomTranscript.countUnread(after: 199, latest: log.latest) { try log.read($0, $1) }
        #expect(found.count == 4)
    }

    /// News past one of Hermes' pages is read page by page, to the end of the log.
    @Test func newsLongerThanAPageIsCountedWhole() async throws {
        var events = [Self.event(1, "message.user", "Go")]
        events += (2...1201).map { Self.event($0, "message.member", "Line \($0)") }
        let log = FakeLog(events)
        let found = try await RoomTranscript.countUnread(after: 1, latest: log.latest) { try log.read($0, $1) }
        #expect(found.count == 1200)
        #expect(log.asked == [0, 500, 1000])
    }

    /// A long log isn't read from its start: only from shortly before where the person read to.
    @Test func theCountStartsNearTheReadPoint() async throws {
        let log = Self.longRoom(filler: 2000)
        let found = try await RoomTranscript.countUnread(after: 2000, latest: log.latest) { try log.read($0, $1) }
        #expect(found.count == 4)
        #expect(log.asked.first == 2000 - RoomTranscript.quoteLookback)
    }

    /// A reply quoting what the person wrote before the read point still mentions them.
    @Test func aQuoteOfAnEarlierMessageIsStillAMention() async throws {
        var events = (1...300).map { Self.event($0, "room.activity") }
        events[149] = Self.event(150, "message.user", "Ship the dark mode pass")
        events.append(Self.event(301, "message.member", "> Ship the dark mode pass\nDone."))
        let log = FakeLog(events)
        let found = try await RoomTranscript.countUnread(after: 300, latest: log.latest) { try log.read($0, $1) }
        #expect(found.count == 1)
        #expect(found.mention?.seq == 301)
    }

    /// A read point past the log (a room Hermes started over) never asks for a seq it refuses.
    @Test func aReadPointPastTheLogIsNeverAskedFor() async throws {
        let log = Self.longRoom(filler: 10)
        let found = try await RoomTranscript.countUnread(after: 900, latest: log.latest) { try log.read($0, $1) }
        #expect(found.count == 0)
        #expect(log.asked.allSatisfy { $0 <= log.latest })
    }

    /// A page that doesn't move on ends the count instead of asking for it again.
    @Test func aPageThatDoesntMoveOnEndsTheCount() async throws {
        var asked = 0
        let found = try await RoomTranscript.countUnread(after: 0, latest: 50) { since, _ in
            asked += 1
            return RoomLogPage(events: [], cursor: since, hasMore: true)
        }
        #expect(found.count == 0)
        #expect(asked == 1)
    }

    /// Hermes' page decodes with its cursor and whether more follows.
    @Test func aLogPageDecodes() throws {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"events":[{"seq":201,"kind":"message.member","actor":{"kind":"member","id":"writer"},"payload":{"text":"Hi"}}],
         "cursor":201,"latest_seq":204,"has_more":true}
        """.utf8))
        let page = try #require(RoomLogPage.parse(json))
        #expect(page.events.map(\.seq) == [201])
        #expect(page.cursor == 201)
        #expect(page.hasMore)
    }

    /// The segments split the rows one way: Bots and group chats on the Bots side, the rest Chats.
    @Test func eachRowCountsOnOneSegment() {
        #expect(BadgeScope.isBotsRow("bot:writer"))
        #expect(BadgeScope.isBotsRow("group:release-log"))
        #expect(!BadgeScope.isBotsRow("chat_a"))
        #expect(!BadgeScope.isBotsRow("botany_chat"))
    }
}
