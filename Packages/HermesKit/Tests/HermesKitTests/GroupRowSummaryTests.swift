import Foundation
@testable import HermesKit
import Testing

/// A group chat's row in the chat list and the sidebar: its newest message and that message's
/// time (`docs/inbox.md` §2, `docs/bots-groups-skills.md` §2), whether the room was opened this
/// launch or not.
@Suite("Group row summary")
struct GroupRowSummaryTests {
    /// A room's log as Hermes serves it (`groups.log`, `read_events`): the events after
    /// `since_seq`, oldest first, `limit` at most, and a refusal for a seq ahead of the log.
    final class Log: @unchecked Sendable {
        var events: [RoomEvent]
        var asked: [(since: Int, limit: Int)] = []

        init(_ events: [RoomEvent]) { self.events = events }

        var latest: Int { events.last?.seq ?? 0 }

        func read(_ since: Int, _ limit: Int) throws -> RoomLogPage {
            asked.append((since, limit))
            if since > latest { throw CancellationError() }
            let page = Array(events.filter { $0.seq > since }.prefix(min(limit, RoomTranscript.logPageLimit)))
            let cursor = page.last?.seq ?? since
            return RoomLogPage(events: page, cursor: cursor, hasMore: cursor < latest)
        }
    }

    static func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    static func event(_ seq: Int, _ kind: String, _ text: String = "", member: String? = nil, at: Double? = nil) -> RoomEvent {
        var payload: [String: JSONValue] = [:]
        if !text.isEmpty { payload["text"] = .string(text) }
        if let member { payload["member_id"] = .string(member) }
        let actor = kind == "message.user" ? "user" : kind == "message.member" ? "member" : "gateway"
        return RoomEvent(seq: seq, kind: kind, actorKind: actor, actorID: kind == "message.member" ? member : nil,
                         payload: .object(payload), createdAt: t(at ?? Double(seq)))
    }

    static let names = ["writer": "Writer", "ops": "Ops"]
    static func name(_ id: String) -> String { names[id] ?? id }

    // MARK: The newest message wins

    @Test func theNewestMessageIsTheLineAMembersOrYours() {
        var events = [
            Self.event(1, "message.user", "We ship on Friday. What do we still need?"),
            Self.event(2, "turn.started", member: "writer"),
            Self.event(3, "message.member", "Release notes are in.", member: "writer"),
        ]
        let member = RoomRowLine.newest(in: events)
        #expect(member == RoomRowLine(seq: 3, memberID: "writer", text: "Release notes are in.", at: Self.t(3)))
        #expect(member?.preview(memberName: Self.name) == "Writer: Release notes are in.")

        // The person writes again: their words are the line, with no name in front.
        events.append(Self.event(4, "message.user", "Thanks, **ship it**."))
        let yours = RoomRowLine.newest(in: events)
        #expect(yours?.memberID == nil && yours?.seq == 4 && yours?.at == Self.t(4))
        #expect(yours?.preview(memberName: Self.name) == "Thanks, ship it.")

        // Out of order in the page, the seq still decides.
        #expect(RoomRowLine.newest(in: events.reversed()) == yours)
        // A member Hermes names only as the actor.
        let bare = RoomEvent(seq: 5, kind: "message.member", actorKind: "member", actorID: "ops",
                             payload: .object(["text": .string("CDN is fine.")]), createdAt: Self.t(5))
        #expect(RoomRowLine.newest(in: events + [bare])?.preview(memberName: Self.name) == "Ops: CDN is fine.")
    }

    // MARK: Only messages move the time

    @Test func presenceRoundsSettlingAndRenamesDontMoveTheTime() {
        let events = [
            Self.event(1, "message.user", "Is the CDN healthy?", at: 10),
            Self.event(2, "message.member", "Checked 4 edges: all healthy.", member: "ops", at: 20),
            Self.event(3, "turn.settled", member: "ops", at: 30),
            Self.event(4, "room.activity", at: 40),
            Self.event(5, "member.unavailable", member: "writer", at: 50),
            Self.event(6, "round.started", at: 60),
            Self.event(7, "room.renamed", at: 70),
        ]
        let line = RoomRowLine.newest(in: events)
        #expect(line?.seq == 2 && line?.at == Self.t(20))
        // The room's `updated_at` stands at the rename; the row reads the message.
        #expect(RowTime.of(messageAt: line?.at, activity: Self.t(70), created: nil) == Self.t(20))
        // Nothing but bookkeeping since: no line, so what the row has stays.
        #expect(RoomRowLine.newest(in: Array(events.dropFirst(2))) == nil)
        #expect(RoomRowLine.newer(line, RoomRowLine.newest(in: Array(events.dropFirst(2)))) == line)
    }

    // MARK: A room never opened

    @Test func aRoomNeverOpenedStillGetsItsLine() async throws {
        // A long log: 2,000 events of bookkeeping, then the question and four replies.
        var events = (1...2000).map { Self.event($0, "room.activity") }
        events.append(Self.event(2001, "message.user", "What changed since the last build?"))
        for n in 2...5 { events.append(Self.event(2000 + n, "message.member", "Reply \(n - 1)", member: "writer")) }
        events.append(Self.event(2006, "turn.settled", member: "writer"))
        let log = Log(events)
        let line = try await RoomTranscript.lastLine(after: 0, latest: log.latest) { try log.read($0, $1) }
        #expect(line?.seq == 2005 && line?.preview(memberName: Self.name) == "Writer: Reply 4")
        // The tail is read, not the log from its start.
        #expect(log.asked.count == 1 && log.asked[0].since >= 2000 - RoomTranscript.logPageLimit)
    }

    @Test func aQuietTailIsReadFurtherBackUntilAMessage() async throws {
        var events = [Self.event(1, "message.user", "Plan the launch post")]
        events.append(Self.event(2, "message.member", "Draft is ready.", member: "writer"))
        events += (3...1500).map { Self.event($0, "room.activity") }
        let log = Log(events)
        let line = try await RoomTranscript.lastLine(after: 0, latest: log.latest) { try log.read($0, $1) }
        #expect(line?.seq == 2 && line?.text == "Draft is ready.")
        // Each read goes further back, and none reads past what's already been read.
        #expect(log.asked.count > 1)
        #expect(log.asked.allSatisfy { $0.limit <= RoomTranscript.logPageLimit })
    }

    @Test func aRoomWithNoMessagesHasNoLine() async throws {
        let log = Log((1...3).map { Self.event($0, "room.activity") })
        #expect(try await RoomTranscript.lastLine(after: 0, latest: log.latest) { try log.read($0, $1) } == nil)
        // Nothing new since the line the row has: nothing is read.
        let empty = Log([])
        #expect(try await RoomTranscript.lastLine(after: 5, latest: 5) { try empty.read($0, $1) } == nil)
        #expect(empty.asked.isEmpty)
    }

    @Test func onlyWhatCameAfterTheKnownLineIsRead() async throws {
        var events = (1...40).map { Self.event($0, $0 == 10 ? "message.member" : "room.activity", "Old line", member: "writer") }
        events.append(Self.event(41, "turn.started", member: "ops"))
        let log = Log(events)
        // The row already has seq 10; what came since is bookkeeping: no new line, nothing before 10 read.
        #expect(try await RoomTranscript.lastLine(after: 10, latest: log.latest) { try log.read($0, $1) } == nil)
        #expect(log.asked.allSatisfy { $0.since >= 10 })
    }

    // MARK: An open chat and the list agree

    @Test func anOpenChatsPollAndTheListsRefreshAgree() async throws {
        var events = [
            Self.event(1, "message.user", "We ship on Friday."),
            Self.event(2, "message.member", "On it.", member: "writer"),
            Self.event(3, "turn.settled", member: "writer"),
        ]
        let log = Log(events)
        // The chat reads from where it left off, page by page, and keeps the newest it saw.
        var polled: RoomRowLine?
        var lastSeq = 0
        func poll() {
            var more = true
            while more {
                let page = try! log.read(lastSeq, 200)
                polled = RoomRowLine.newer(polled, RoomRowLine.newest(in: page.events))
                lastSeq = page.cursor
                more = page.hasMore
            }
        }
        poll()
        let listed = try await RoomTranscript.lastLine(after: 0, latest: log.latest) { try log.read($0, $1) }
        #expect(polled == listed)

        // New messages arrive while the list shows: both land on the same line.
        events += [Self.event(4, "turn.started", member: "ops"), Self.event(5, "message.member", "CDN is fine.", member: "ops"), Self.event(6, "turn.settled", member: "ops")]
        log.events = events
        poll()
        let refreshed = try await RoomTranscript.lastLine(after: listed?.seq ?? 0, latest: log.latest) { try log.read($0, $1) }
        #expect(polled == refreshed && polled?.seq == 5)
        // Whichever lands first, the newer one stays.
        #expect(RoomRowLine.newer(listed, refreshed) == refreshed)
        #expect(RoomRowLine.newer(refreshed, listed) == refreshed)
        #expect(RoomRowLine.newer(nil, listed) == listed)
    }
}
