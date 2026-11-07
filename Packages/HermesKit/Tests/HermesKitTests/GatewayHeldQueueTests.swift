import Foundation
import Testing
@testable import HermesKit

/// Hermes let the chat go while this device was away (the WS-orphan reap), and the next
/// `session.resume` found it holding nothing (`GatewayHeldQueue.attached(head:)`,
/// `docs/follow-ups.md` §4): the stored chat says which held messages ran, and the rest come back
/// to Up Next whole.
@Suite("Hermes's held queue after an attach")
struct GatewayHeldQueueTests {
    /// The device's own copy of a message, attachments included.
    struct Message: Equatable {
        var text: String
        var photos: [String] = []
    }

    /// The stored chat: `slow, count to ten` is the turn the messages waited behind.
    static func stored(_ json: String) throws -> [SessionMessage] {
        try JSONDecoder().decode([SessionMessage].self, from: Data(json.utf8))
    }

    static func holding(_ messages: [Message], after: Int? = 4) -> GatewayHeldQueue<Message> {
        var held = GatewayHeldQueue<Message>()
        for message in messages {
            held.hold(message.text, item: message, isTextOnly: message.photos.isEmpty, after: after)
        }
        return held
    }

    @Test func aMessageThatRanWhileAwayStaysGone() throws {
        var held = Self.holding([Message(text: "and the receipt", photos: ["receipt.jpg"])])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        #expect(held.isEmpty)
        let rows = try Self.stored(#"""
        [{"id": 4, "role": "assistant", "content": "Earlier reply."},
         {"id": 5, "role": "user", "content": "slow, count to ten"},
         {"id": 6, "role": "assistant", "content": "One, two…"},
         {"id": 7, "role": "user", "content": "and the receipt"},
         {"id": 8, "role": "assistant", "content": "Got the receipt."}]
        """#)
        #expect(dropped.givenBack(stored: rows).isEmpty)
    }

    @Test func wordsHermesJoinedIntoOneTurnRanAndStayGone() throws {
        // Two text-only messages joined Hermes's head envelope and ran as one turn, one row.
        var held = Self.holding([Message(text: "first thing"), Message(text: "and another")])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        let rows = try Self.stored(#"""
        [{"id": 5, "role": "user", "content": "slow, count to ten"},
         {"id": 6, "role": "assistant", "content": "One, two…"},
         {"id": 7, "role": "user", "content": "first thing\n\nand another"},
         {"id": 8, "role": "assistant", "content": "Both done."}]
        """#)
        #expect(dropped.givenBack(stored: rows).isEmpty)
    }

    @Test func aHeldSteerWithOnlyItsWordsComesBackToo() throws {
        // A steer Hermes held while it compacted: this device's own, kept as its words.
        var held = GatewayHeldQueue<Message>()
        held.hold("look at the logs first", item: nil, after: 4)
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        let rows = try Self.stored(#"[{"id": 5, "role": "user", "content": "slow, count to ten"}]"#)
        let given = dropped.givenBack(stored: rows)
        #expect(given.map(\.entry.line) == ["look at the logs first"])
        #expect(given.map(\.maybeSent) == [false])
    }

    @Test func behindAnotherDevicesHeadTheTrayStillKnowsWhereItsTurnBegan() throws {
        var held = GatewayHeldQueue<Message>()
        held.attached(head: "from the Mac")
        held.hold("thanks", item: Message(text: "thanks", photos: ["a.jpg"]), isTextOnly: false, after: 4)
        #expect(held.after == 4)
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        // The same words earlier in the chat are not this message running.
        let rows = try Self.stored(#"""
        [{"id": 3, "role": "user", "content": "thanks"},
         {"id": 5, "role": "user", "content": "slow, count to ten"},
         {"id": 6, "role": "user", "content": "from the Mac"}]
        """#)
        #expect(dropped.givenBack(stored: rows).map(\.entry.line) == ["thanks"])
    }

    @Test func messagesThatNeverRanComeBackInOrderWithTheirAttachments() throws {
        let photo = Message(text: "what is this?", photos: ["a.jpg", "b.jpg"])
        let file = Message(text: "and this file", photos: ["c.pdf"])
        var held = Self.holding([photo, file])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        // Hermes retired the rows it kept while they waited: gone, or set aside as hidden.
        let rows = try Self.stored(#"""
        [{"id": 5, "role": "user", "content": "slow, count to ten"},
         {"id": 6, "role": "user", "content": "what is this?", "display_kind": "hidden"},
         {"id": 7, "role": "assistant", "content": "One, two…"}]
        """#)
        let given = dropped.givenBack(stored: rows)
        #expect(given.map(\.entry.item) == [photo, file])
        #expect(given.map(\.maybeSent) == [false, false])
    }

    @Test func aStoredWaitingRowComesBackMaybeSent() throws {
        var held = Self.holding([Message(text: "still waiting", photos: ["a.jpg"]), Message(text: "never stored", photos: ["b.jpg"])])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        let rows = try Self.stored(#"""
        [{"id": 5, "role": "user", "content": "slow, count to ten"},
         {"id": 6, "role": "user", "content": "still waiting", "display_metadata": "{\"_queued_prompt\": true}"}]
        """#)
        let given = dropped.givenBack(stored: rows)
        #expect(given.map(\.entry.line) == ["still waiting", "never stored"])
        #expect(given.map(\.maybeSent) == [true, false])
    }

    @Test func theTurnTheyWaitedBehindAndEarlierMessagesDontCountAsRun() throws {
        // The same words were sent before, and the turn they waited behind holds them too.
        var held = Self.holding([Message(text: "thanks", photos: ["a.jpg"])])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        let rows = try Self.stored(#"""
        [{"id": 3, "role": "user", "content": "thanks"},
         {"id": 4, "role": "assistant", "content": "Any time."},
         {"id": 5, "role": "user", "content": "slow, then say thanks"}]
        """#)
        #expect(dropped.givenBack(stored: rows).map(\.entry.line) == ["thanks"])
    }

    @Test func whenTheChatCantBeReadEveryMessageComesBackMaybeSent() throws {
        var held = Self.holding([Message(text: "one"), Message(text: "two", photos: ["a.jpg"])])
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        let given = dropped.givenBack(stored: nil)
        #expect(given.map(\.entry.line) == ["one", "two"])
        #expect(given.map(\.maybeSent) == [true, true])
    }

    @Test func onlyThisDevicesOwnMessagesComeBack() throws {
        var held = GatewayHeldQueue<Message>()
        held.attached(head: "from the Mac")
        let attached = held.attached(head: nil)
        let dropped = try #require(attached)
        #expect(dropped.givenBack(stored: []).isEmpty)
    }

    @Test func anAttachWithSomethingHeldOrNothingInTheTrayDropsNothing() {
        var held = Self.holding([Message(text: "first")])
        let stillHeld = held.attached(head: "first")
        #expect(stillHeld?.entries.count == nil)
        #expect(held.lines == ["first"])
        var empty = GatewayHeldQueue<Message>()
        let nothing = empty.attached(head: nil)
        #expect(nothing?.entries.count == nil)
    }

    @Test func theBaselineIsTheFirstHeldMessagesAndGoesWithTheTray() {
        var held = GatewayHeldQueue<Message>()
        held.hold("first", item: Message(text: "first"), after: 4)
        held.hold("second", item: Message(text: "second"), isTextOnly: false, after: 9)
        #expect(held.after == 4)
        held.removeAll()
        #expect(held.after == nil)
        held.hold("later", item: Message(text: "later"), after: 12)
        #expect(held.after == 12)
    }

    @Test func theirNoteSaysHermesClearedThemAndSurvivesARelaunch() {
        let note = UpNextNote.droppedByGateway
        #expect(note.line(gateway: "Studio Mac") == "Studio Mac cleared it from its queue before it ran")
        #expect(note.storedKey == "dropped")
        #expect(UpNextNote(storedKey: note.storedKey) == note)
        #expect(!note.sendsNext)
    }
}
