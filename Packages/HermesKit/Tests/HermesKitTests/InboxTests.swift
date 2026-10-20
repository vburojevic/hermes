import Foundation
import Testing
@testable import HermesKit
import HermesPush

@Suite("Inbox")
struct InboxTests {
    private static let base = Date(timeIntervalSince1970: 1_760_600_000)
    private static func t(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    private static func you(_ id: String, at seconds: Double) -> TranscriptItem {
        .user(UserEntry(id: id, text: "question", timestamp: t(seconds)))
    }

    private static func reply(_ id: String, from start: Double, to end: Double, answer: String = "Done.") -> TranscriptItem {
        .assistant(AssistantTurn(id: id, steps: [.narration(id: "\(id)-n0", text: "Looking…")], answer: answer, state: .complete, startedAt: t(start), finishedAt: t(end)))
    }

    private static func bot(_ id: String, _ name: String, at seconds: Double) -> TranscriptItem {
        .user(UserEntry(id: id, text: "Shipped it", timestamp: t(seconds), sender: AgentSender(name: name, handle: name.lowercased())))
    }

    // MARK: Read marks

    @Test func readMarkDecodesNullZeroAndTime() throws {
        func session(_ json: String) throws -> HermesSession {
            try JSONDecoder().decode(HermesSession.self, from: Data(json.utf8))
        }
        let untracked = try session(#"{"id": "a", "last_active": 1760600100, "last_read_at": null}"#)
        #expect(untracked.readMark == .untracked && !untracked.isUnreadOnGateway)
        let marked = try session(#"{"id": "b", "last_active": 1760600100, "last_read_at": 0}"#)
        #expect(marked.readMark == .markedUnread && marked.isUnreadOnGateway)
        let read = try session(#"{"id": "c", "last_active": 1760600100, "last_read_at": 1760600100.2}"#)
        #expect(read.readMark == .readUntil(Date(timeIntervalSince1970: 1760600100.2)) && !read.isUnreadOnGateway)
        let behind = try session(#"{"id": "d", "last_active": 1760600100, "last_read_at": 1760600000}"#)
        #expect(behind.isUnreadOnGateway)
        // A gateway that doesn't serve the field: no mark at all, so the device's own is used.
        let headless = try session(#"{"id": "e", "last_active": 1760600100}"#)
        #expect(headless.readMark == nil && !headless.isUnreadOnGateway)
    }

    @Test func halfASecondOfSlackForTheGatewaysClock() {
        #expect(!ReadMark.readUntil(Self.t(0)).isUnread(lastActive: Self.t(0.4)))
        #expect(ReadMark.readUntil(Self.t(0)).isUnread(lastActive: Self.t(0.6)))
        #expect(!ReadMark.readUntil(Self.t(0)).isUnread(lastActive: nil))
        #expect(ReadMark.markedUnread.readUntil == nil && ReadMark.untracked.readUntil == nil)
    }

    // MARK: Counting

    @Test func countsRepliesThatEndedATurnNotStepsOrYourMessages() {
        let items: [TranscriptItem] = [
            Self.you("m1", at: 0), Self.reply("tm2", from: 1, to: 5),
            Self.you("m3", at: 100), Self.reply("tm4", from: 101, to: 140),
            Self.you("m5", at: 200), Self.reply("tm6", from: 201, to: 260),
            .notice(Notice(id: "m7", kind: "model_switch", text: "Model changed")),
        ]
        #expect(UnreadCounter.count(items, after: Self.t(10)) == 2)
        #expect(UnreadCounter.count(items, after: Self.t(150)) == 1)
        #expect(UnreadCounter.count(items, after: Self.t(300)) == 0)
        // A reply that started before the mark but ended after it landed after it.
        #expect(UnreadCounter.count(items, after: Self.t(120)) == 2)
    }

    @Test func turnsWithoutAnAnswerOrStillRunningDontCount() {
        let empty = TranscriptItem.assistant(AssistantTurn(id: "t1", steps: [.narration(id: "n", text: "Checking")], answer: "", startedAt: Self.t(10), finishedAt: Self.t(20)))
        let running = TranscriptItem.assistant(AssistantTurn(id: "t2", answer: "Half", state: .streaming, startedAt: Self.t(30)))
        #expect(UnreadCounter.count([empty, running], after: Self.t(0)) == 0)
    }

    @Test func botMembersRoutinesAndCommandsCount() {
        var routine = UserEntry(id: "m4", text: "Digest", timestamp: Self.t(40))
        routine.routineName = "Daily digest"
        let items: [TranscriptItem] = [
            Self.bot("m1", "Ada", at: 10), Self.bot("m2", "Ops", at: 20), Self.you("m3", at: 30), .user(routine),
            .command(CommandEntry(id: "c1", name: "usage", argument: nil, outcome: .note("12k tokens"), timestamp: Self.t(50))),
            .command(CommandEntry(id: "c2", name: "compress", argument: nil, outcome: .running(nil), timestamp: Self.t(60))),
        ]
        #expect(UnreadCounter.count(items, after: Self.t(0)) == 4)
        #expect(UnreadCounter.count(items, after: Self.t(15)) == 3)
    }

    @Test func badgesCapAt99() {
        #expect(UnreadCounter.label(3) == "3" && UnreadCounter.label(99) == "99" && UnreadCounter.label(140) == "99+")
        #expect(UnreadBadge.count(120).label == "99+" && UnreadBadge.dot.label == nil && UnreadBadge.dot.isUnread && !UnreadBadge.none.isUnread)
    }

    // MARK: The New Messages line

    @Test func lineSitsAboveTheFirstNewTurn() throws {
        let items: [TranscriptItem] = [
            Self.you("m1", at: 0), Self.reply("tm2", from: 1, to: 5),
            Self.you("m3", at: 100), Self.reply("tm4", from: 101, to: 140),
            Self.you("m5", at: 200), Self.reply("tm6", from: 201, to: 260),
        ]
        // Read after your message went: the line goes above the reply.
        let marker = try #require(NewMessagesMarker.find(in: items, since: Self.t(100.5), seenThrough: nil))
        #expect(marker == NewMessagesMarker(rowID: "tm4", count: 2))
        // Read before the message that started it (sent from another device): above the message.
        let earlier = try #require(NewMessagesMarker.find(in: items, since: Self.t(50), seenThrough: nil))
        #expect(earlier == NewMessagesMarker(rowID: "m3", count: 2))
        #expect(NewMessagesMarker.find(in: items, since: Self.t(300), seenThrough: nil) == nil)
        #expect(NewMessagesMarker.find(in: items, since: nil, seenThrough: nil) == nil)
    }

    @Test func partlyReadChatsResumeAfterTheLastMessageSeen() throws {
        let items: [TranscriptItem] = [
            Self.you("m1", at: 0), Self.reply("tm2", from: 1, to: 5),
            Self.you("m3", at: 100), Self.reply("tm4", from: 101, to: 140),
            Self.you("m5", at: 200), Self.reply("tm6", from: 201, to: 260),
            Self.you("m7", at: 300), Self.reply("tm8", from: 301, to: 360),
        ]
        // The gateway's mark is from before (it only moves at the bottom); this device saw tm4.
        let marker = try #require(NewMessagesMarker.find(in: items, since: Self.t(50), seenThrough: "tm4"))
        #expect(marker == NewMessagesMarker(rowID: "m5", count: 2))
        // Read further on another device than here: the later of the two wins.
        let elsewhere = try #require(NewMessagesMarker.find(in: items, since: Self.t(270), seenThrough: "tm4"))
        #expect(elsewhere == NewMessagesMarker(rowID: "m7", count: 1))
        // Marked unread or a gateway without marks: only the device's own.
        let device = try #require(NewMessagesMarker.find(in: items, since: nil, seenThrough: "tm6"))
        #expect(device == NewMessagesMarker(rowID: "m7", count: 1))
        // Seen through the end: nothing new.
        #expect(NewMessagesMarker.find(in: items, since: nil, seenThrough: "tm8") == nil)
    }

    @Test func groupLineSitsAboveTheFirstNewBotMessage() throws {
        let items: [TranscriptItem] = [Self.you("m1", at: 0), Self.bot("m2", "Ada", at: 10), Self.bot("m3", "Ops", at: 20), Self.bot("m4", "Ada", at: 30)]
        let marker = try #require(NewMessagesMarker.find(in: items, since: Self.t(15), seenThrough: nil))
        #expect(marker == NewMessagesMarker(rowID: "m3", count: 2))
    }

    // MARK: Mute

    @Test func mutesEndOnTime() {
        var list = MuteList()
        let now = Self.base
        list.mute("chat-a", for: .hour, now: now)
        list.mute("chat-b", for: .eightHours, now: now)
        list.mute("bot:ada", for: .week, now: now)
        list.mute("group:launch", for: .untilTurnedOff, now: now)
        #expect(list.isMuted("chat-a", now: now.addingTimeInterval(3599)))
        #expect(!list.isMuted("chat-a", now: now.addingTimeInterval(3600)))
        #expect(list.isMuted("chat-b", now: now.addingTimeInterval(7 * 3600)) && !list.isMuted("chat-b", now: now.addingTimeInterval(8 * 3600 + 1)))
        #expect(list.isMuted("bot:ada", now: now.addingTimeInterval(6 * 86_400)))
        #expect(list.isMuted("group:launch", now: now.addingTimeInterval(400 * 86_400)))
        #expect(list.end(of: "group:launch", now: now) == .distantFuture && list.end(of: "nope", now: now) == nil)
        #expect(list.nextEnd(after: now) == now.addingTimeInterval(3600))
        // Ended mutes go; the rest stay.
        let pruned = list.prune(now: now.addingTimeInterval(9 * 3600))
        #expect(pruned && Set(list.ends.keys) == ["bot:ada", "group:launch"])
        let again = list.prune(now: now.addingTimeInterval(9 * 3600))
        #expect(!again)
        list.unmute("group:launch")
        #expect(!list.isMuted("group:launch", now: now))
        // Kept on the device between launches.
        let data = try? JSONEncoder().encode(list)
        #expect(data.flatMap { try? JSONDecoder().decode(MuteList.self, from: $0) } == list)
    }

    // MARK: The jump pill

    @Test func pillPutsMentionsFirstThenNewMessagesThenLive() {
        #expect(JumpPill.choose(mention: ("Ada", "m9"), newCount: 2, firstNewRowID: "m7", isLive: true) == .mention(name: "Ada", rowID: "m9"))
        #expect(JumpPill.choose(mention: nil, newCount: 2, firstNewRowID: "m7", isLive: true) == .newMessages(count: 2, firstRowID: "m7"))
        #expect(JumpPill.choose(mention: nil, newCount: 0, firstNewRowID: nil, isLive: true) == .live)
        #expect(JumpPill.choose(mention: nil, newCount: 0, firstNewRowID: nil, isLive: false) == .latest)
        // A count with nowhere to jump to isn't offered.
        #expect(JumpPill.choose(mention: nil, newCount: 3, firstNewRowID: nil, isLive: false) == .latest)
        #expect(JumpPill.newMessages(count: 2, firstRowID: "m7").target == "m7" && JumpPill.live.target == nil)
    }

    // MARK: Row times

    @Test func rowTimesReadLikeAMessagingApp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Friday 17 October 2026, 14:00 in New York.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 14))!
        func time(_ seconds: Double) -> InboxTime { InboxTime(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        #expect(time(20) == .now)
        #expect(time(120) == .minutes(2))
        #expect(time(3 * 3600) == .time(now.addingTimeInterval(-3 * 3600)))
        #expect(time(16 * 3600) == .yesterday)
        #expect(time(3 * 86_400) == .weekday(now.addingTimeInterval(-3 * 86_400)))
        #expect(time(8 * 86_400) == .date(now.addingTimeInterval(-8 * 86_400)))
    }

    // MARK: Activity

    @Test func activityFollowsTheActiveListAcrossPolls() {
        var tracker = ActivityTracker()
        #expect(!tracker.update(status: "idle", preview: "Last thing said") && tracker.line == nil)
        tracker.update(status: "starting", preview: "Fix the reconnect after sleep")
        #expect(tracker.line == .starting)
        tracker.update(status: "working", preview: "Fix the reconnect after sleep")
        #expect(tracker.line == .thinking)
        // The preview moves off the prompt: the reply is being written.
        tracker.update(status: "working", preview: "The socket reconnects with a backoff of up to five seconds now")
        #expect(tracker.line == .writing("…with a backoff of up to five seconds now"))
        #expect(tracker.update(status: "waiting", preview: nil) && tracker.line == .waiting(.approval))
        tracker.update(status: "idle", preview: "Done.")
        #expect(tracker.line == nil)
        // Joined mid-turn: thinking until the words move.
        var late = ActivityTracker()
        late.update(status: "working", preview: "Half a reply")
        #expect(late.line == .thinking)
        late.update(status: "working", preview: "Half a reply, and more")
        #expect(late.line == .writing("Half a reply, and more"))
    }

    @Test func writingShowsTheNewestWordsFromAWordStart() {
        #expect(ActivityLine.writingTail("Short  reply\nhere") == "Short reply here")
        let tail = ActivityLine.writingTail(String(repeating: "word ", count: 20) + "the end", limit: 20)
        #expect(tail.hasPrefix("…") && tail.hasSuffix("the end") && tail.count <= 21 && !tail.dropFirst().hasPrefix(" "))
        #expect(ActivityLine.thinking.isLive && ActivityLine.thinking.shimmers && !ActivityLine.failed("x").isLive)
        #expect(ActivityLine.tool(symbol: "terminal", title: "Running swift test", progress: nil).shimmers)
        #expect(!ActivityLine.waiting(.approval).shimmers && !ActivityLine.failed("x").shimmers)
        // Markdown's marks don't show, and a long reply is read only at its end.
        #expect(ActivityLine.writingTail("Caches are **global** with `locks`") == "Caches are global with locks")
        let long = String(repeating: "earlier words ", count: 2000) + "and **the** last `few` words"
        let end = ActivityLine.writingTail(long, limit: 20)
        #expect(end.hasPrefix("…") && end.hasSuffix("the last few words") && !end.contains("*") && end.count <= 21)
    }

    // MARK: Group chats

    @Test func roomsListWhoThinksBeforeTheirFirstWords() {
        func event(_ seq: Int, _ kind: String, member: String? = nil) -> RoomEvent {
            var payload: [String: JSONValue] = [:]
            if let member { payload["member_id"] = .string(member) }
            return RoomEvent(seq: seq, kind: kind, actorKind: member == nil ? "user" : "member", actorID: member, payload: .object(payload), createdAt: nil)
        }
        var events = [event(1, "message.user"), event(2, "turn.started", member: "ada"), event(3, "turn.started", member: "ops")]
        #expect(RoomTranscript.thinkingMembers(events) == ["ada", "ops"])
        // Ada's words arrive: only Ops still thinks; a new message from you starts over.
        events.append(event(4, "message.member", member: "ada"))
        #expect(RoomTranscript.thinkingMembers(events) == ["ops"])
        events.append(event(5, "turn.settled", member: "ops"))
        #expect(RoomTranscript.thinkingMembers(events).isEmpty)
        events += [event(6, "turn.started", member: "ada"), event(7, "message.user")]
        #expect(RoomTranscript.thinkingMembers(events).isEmpty)
    }

    @Test func roomsCountMemberMessagesAndFindMentions() {
        func event(_ seq: Int, _ kind: String, _ text: String, member: String? = nil) -> RoomEvent {
            var payload: [String: JSONValue] = ["text": .string(text)]
            if let member { payload["member_id"] = .string(member) }
            return RoomEvent(seq: seq, kind: kind, actorKind: member == nil ? "user" : "member", actorID: member, payload: .object(payload), createdAt: nil)
        }
        let events = [
            event(1, "message.user", "Plan the launch post for Thursday"),
            event(2, "message.member", "On it. @ops can you check the CDN?", member: "ada"),
            event(3, "turn.started", ""),
            event(4, "message.member", "CDN is fine.", member: "ops"),
            event(5, "message.member", "> launch post for Thursday\n\nDraft is ready for you.", member: "ada"),
            event(6, "message.member", "@everyone shipping now", member: "ops"),
        ]
        let all = RoomTranscript.unread(events, after: 1)
        #expect(all.count == 4 && all.mention?.memberID == "ada" && all.mention?.seq == 5)
        let later = RoomTranscript.unread(events, after: 5)
        #expect(later.count == 1 && later.mention?.seq == 6)
        #expect(RoomTranscript.unread(events, after: 6).count == 0)
        #expect(!RoomTranscript.mentionsYou("ping @youtube", yourMessages: []))
        #expect(RoomTranscript.mentionsYou("thanks @you!", yourMessages: []))
        #expect(RoomTranscript.mentionsYou("over to @Sam for the call", yourMessages: [], names: ["sam"]))
        #expect(!RoomTranscript.mentionsYou("over to @samantha", yourMessages: [], names: ["Sam"]))
        #expect(!RoomTranscript.mentionsYou("> something else entirely\n\nok", yourMessages: ["Plan the launch"]))
    }

    // MARK: Last lines

    @Test func lastLineSaysWhoSpokeLast() {
        let reply = TranscriptItem.assistant(AssistantTurn(id: "t1", answer: "## Done\n\n**23 merged PRs**. Two need `your` eye.", startedAt: Self.t(0), finishedAt: Self.t(5)))
        #expect(LastLine.of([Self.you("m0", at: 0), reply]) == LastLine(speaker: .hermes, text: "Done 23 merged PRs. Two need your eye."))
        #expect(LastLine.of([reply, Self.you("m2", at: 10)]) == LastLine(speaker: .you, text: "question"))
        #expect(LastLine.of([reply, Self.bot("m3", "Ada", at: 20), .notice(Notice(id: "n", kind: "model_switch", text: "x"))]) == LastLine(speaker: .named("Ada"), text: "Shipped it"))
        #expect(LastLine.of([]) == nil)
        #expect(LastLine.flatten("```swift\nlet a = 1\n```").count <= 120)
    }

    @Test func lastLineReadsOnlyWhatItShows() {
        #expect(LastLine.flatten("\n\n# Title\r\n\n- **one**\n> two\n") == "Title one two")
        #expect(LastLine.flatten("```\ncode\n```\nAfter the code") == "code After the code")
        // A reply of thousands of lines: its first 120 characters, the same as before.
        let long = (1...5000).map { "Line \($0) of the log" }.joined(separator: "\n")
        let flat = LastLine.flatten(long)
        #expect(flat.count == 120)
        #expect(flat.hasPrefix("Line 1 of the log Line 2 of the log"))
    }

    @Test func botFacesFollowTheirState() {
        func mood(_ line: ActivityLine?, replied: Bool = false, muted: Bool = false, otherwise: FaceMood = .idle) -> FaceMood {
            ActivityLine.faceMood(for: line, justReplied: replied, muted: muted, otherwise: otherwise)
        }
        #expect(mood(.thinking) == .thinking && mood(.starting) == .thinking && mood(.routine("Daily digest")) == .thinking)
        #expect(mood(.tool(symbol: "terminal", title: "Running swift test", progress: nil)) == .working && mood(.writing("…")) == .working)
        #expect(mood(.waiting(.approval)) == .listening)
        #expect(mood(nil, replied: true) == .happy && mood(.thinking, replied: true) == .happy)
        #expect(mood(nil, muted: true) == .sleeping && mood(nil) == .idle)
        // Offline stays offline; a muted Bot at work still works.
        #expect(mood(nil, otherwise: .sleeping) == .sleeping && mood(.thinking, muted: true) == .thinking)
    }

    // MARK: Reply with a quote

    @Test func quotesGoOutAsABlockQuoteAndComeBackAsOne() throws {
        let reply = QuotedReply(quote: "Two options: back off and retry,\nor reopen on wake.", message: "Back off and retry, up to 5 seconds.")
        #expect(reply.text == "> Two options: back off and retry,\n> or reopen on wake.\n\nBack off and retry, up to 5 seconds.")
        let parsed = try #require(QuotedReply.parse(reply.text))
        #expect(parsed.quote == "Two options: back off and retry,\nor reopen on wake." && parsed.message == reply.message)
        // Not a reply: no quote first, or nothing after it.
        #expect(QuotedReply.parse("Plain message\n> later quote") == nil)
        #expect(QuotedReply.parse("> only a quote") == nil)
        #expect(QuotedReply.parse(">no space\n\nok")?.quote == "no space")
        // Long passages are cut at a word; the key ignores how the passage was wrapped.
        let long = String(repeating: "word ", count: 100)
        let cut = QuotedReply.trimmed(long)
        #expect(cut.count <= QuotedReply.maxQuote + 1 && cut.hasSuffix("…"))
        #expect(QuotedReply.key("a  b\n c") != QuotedReply.key("x") && QuotedReply.key("one\ntwo") == QuotedReply.key("one\n  two  "))
    }
}
