import Foundation
@testable import HermesKit
import Testing

/// Reads made on this device reach the push plugin once each, whenever the gateway can be reached,
/// so the person's other devices drop them from their badges (`docs/notifications.md` §2 Reading).
@Suite("Push read queue")
struct PushReadQueueTests {
    private let start = Date(timeIntervalSince1970: 1_792_560_000)

    private func activity(_ times: [String: Date]) -> (String, Bool) -> Date? {
        { id, _ in times[id] }
    }

    /// The Mac app, opened but never in front, read a chat before it had checked for the plugin:
    /// the read was dropped, and the iPhone kept counting the chat. Now it waits and goes once.
    @Test func aReadMadeBeforeThePluginIsKnownWaitsAndGoesOnce() {
        var queue = PushReadQueue()
        let known = activity(["s1": start, "s1_root": start])
        queue.add(chats: ["s1", "s1_root"], rooms: [], now: start, lastActive: known)
        #expect(queue.isDue(now: start))

        // The gateway can't be reached yet: it stays, and backs off.
        let first = queue.take(now: start, lastActive: known)
        #expect(first?.chats.keys.sorted() == ["s1", "s1_root"])
        #expect(!queue.isDue(now: start), "nothing goes twice while a batch is on its way")
        queue.failed(now: start)
        #expect(!queue.isDue(now: start.addingTimeInterval(4)))
        #expect(queue.isDue(now: start.addingTimeInterval(5)))

        // Back online: it goes now, and once it lands, never again.
        queue.retryNow()
        let second = queue.take(now: start.addingTimeInterval(1), lastActive: known)
        #expect(second == first)
        queue.sent(second!)
        #expect(queue.isEmpty)
        #expect(queue.take(now: start.addingTimeInterval(2), lastActive: known) == nil)
    }

    /// A read of a chat that has news since doesn't go: the plugin would stamp it as it hears it and
    /// count the newer reply read on every device.
    @Test func aReadWhoseChatMovedOnIsDropped() {
        var queue = PushReadQueue()
        queue.add(chats: ["s1", "s2"], rooms: ["room_1"], now: start, lastActive: activity(["s1": start, "s2": start, "room_1": start]))
        let later = activity(["s1": start.addingTimeInterval(60), "s2": start, "room_1": start])
        let batch = queue.take(now: start.addingTimeInterval(90), lastActive: later)
        #expect(batch?.chats.keys.sorted() == ["s2"])
        #expect(batch?.rooms.keys.sorted() == ["room_1"])
        queue.sent(batch!)
        #expect(queue.isEmpty)
    }

    /// The gateway's clock, not this device's: a gateway a few seconds ahead never makes a fresh read
    /// look stale.
    @Test func readsCompareOnTheGatewaysClock() {
        var queue = PushReadQueue()
        let ahead = activity(["s1": start.addingTimeInterval(8)])
        queue.add(chats: ["s1"], rooms: [], now: start, lastActive: ahead)
        #expect(queue.take(now: start, lastActive: ahead)?.chats.keys.sorted() == ["s1"])
    }

    /// Read again while a batch is on its way, after news came in: the later read still goes.
    @Test func aLaterReadOfTheSameChatStays() {
        var queue = PushReadQueue()
        queue.add(chats: ["s1"], rooms: [], now: start, lastActive: activity(["s1": start]))
        let batch = queue.take(now: start, lastActive: activity(["s1": start]))!
        let moved = activity(["s1": start.addingTimeInterval(30)])
        queue.add(chats: ["s1"], rooms: [], now: start.addingTimeInterval(31), lastActive: moved)
        queue.sent(batch)
        #expect(queue.chats["s1"] == start.addingTimeInterval(30))
        #expect(queue.isDue(now: start.addingTimeInterval(31)))
    }

    /// Kept across launches, but never mid-send: a batch whose answer a quit lost goes again.
    @Test func itsKeptAcrossLaunches() throws {
        var queue = PushReadQueue()
        queue.add(chats: ["s1"], rooms: ["room_1"], now: start, lastActive: activity([:]))
        _ = queue.take(now: start, lastActive: activity([:]))
        let restored = try JSONDecoder().decode(PushReadQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored.chats == queue.chats && restored.rooms == queue.rooms)
        #expect(!restored.isSending)
        #expect(restored.isDue(now: start))
    }

    /// A read kept from before a relaunch, or from before the gateway went away, is judged against
    /// the list as it is now, never an empty or stale one: a chat this device doesn't know yet waits
    /// for the list, and goes only if nothing came in since it was read.
    @Test func aReadWaitsForTheListBeforeItGoes() {
        var queue = PushReadQueue()
        queue.add(chats: ["s1", "s2"], rooms: ["room_1"], now: start,
                  lastActive: activity(["s1": start, "s2": start, "room_1": start]))
        // Relaunched: the list isn't in yet, so nothing goes, and nothing is lost.
        #expect(queue.take(now: start.addingTimeInterval(60), lastActive: activity([:])) == nil)
        #expect(queue.isHolding && queue.chats.count == 2 && queue.rooms.count == 1)
        // The list came in: s1 got a reply meanwhile (its read would clear that reply elsewhere), s2 didn't.
        let listed = activity(["s1": start.addingTimeInterval(30), "s2": start, "room_1": start])
        let batch = queue.take(now: start.addingTimeInterval(90), lastActive: listed)
        #expect(batch?.chats.keys.sorted() == ["s2"])
        #expect(batch?.rooms.keys.sorted() == ["room_1"])
        queue.sent(batch!)
        #expect(queue.isEmpty && !queue.isHolding)
    }

    /// A read whose chat never shows up (deleted meanwhile) waits no longer than the plugin would
    /// remember it.
    @Test func aHeldReadIsDroppedAfterTheLimit() {
        var queue = PushReadQueue()
        queue.add(chats: ["gone"], rooms: [], now: start, lastActive: activity([:]))
        #expect(queue.take(now: start, lastActive: activity([:])) == nil)
        #expect(queue.take(now: start.addingTimeInterval(PushReadQueue.holdLimit - 1), lastActive: activity([:])) == nil)
        #expect(!queue.isEmpty)
        #expect(queue.take(now: start.addingTimeInterval(PushReadQueue.holdLimit), lastActive: activity([:])) == nil)
        #expect(queue.isEmpty && !queue.isHolding)
    }

    /// One `read` names at most 50 of each; the rest go with the next.
    @Test func bigBatchesSplit() {
        var queue = PushReadQueue()
        let ids = (0..<60).map { "s\($0)" }
        let known = activity(Dictionary(uniqueKeysWithValues: ids.map { ($0, start) }))
        queue.add(chats: ids, rooms: [], now: start, lastActive: known)
        let first = queue.take(now: start, lastActive: known)!
        #expect(first.chats.count == PushReadQueue.batchLimit)
        queue.sent(first)
        #expect(queue.chats.count == 10 && queue.isDue(now: start))
    }
}
