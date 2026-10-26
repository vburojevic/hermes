import Foundation
import Testing
@testable import HermesKit

/// Hermes starts the next turn the moment one ends: a steer the turn never read, or what its queue
/// holds, goes as a turn of its own right after the idle notice. Its events came while the app
/// still finished the last turn, went into that turn, and the steer was marked missed while Hermes
/// answered it (`docs/chat.md` §2, `docs/follow-ups.md` §2).
@Suite("The next turn's events wait while a turn finishes")
struct NextTurnHoldTests {
    @Test("Before the turn ends, nothing waits")
    func beforeTheEnd() {
        var hold = NextTurnHold<String>()
        let delta = hold.holds("message.delta", startsTurn: true, turnEnded: false)
        #expect(!delta)
        let toolEnd = hold.holds("tool.complete", startsTurn: false, turnEnded: false)
        #expect(!toolEnd)
        #expect(!hold.isHolding)
    }

    @Test("After the end, the ended turn's own notices still reach it")
    func endedTurnsNotices() {
        var hold = NextTurnHold<String>()
        // The idle notice and the turn's last status come after its end and belong to it.
        let idle = hold.holds("session.info", startsTurn: false, turnEnded: true)
        #expect(!idle)
        let status = hold.holds("status.update", startsTurn: false, turnEnded: true)
        #expect(!status)
        #expect(!hold.isHolding)
    }

    @Test("A turn starting after the end waits, with everything after it, in order")
    func nextTurnWaits() {
        var hold = NextTurnHold<String>()
        let start = hold.holds("message.start", startsTurn: true, turnEnded: true)
        #expect(start)
        // Its first words, a step's end, its own idle notice: all the next turn's.
        let delta = hold.holds("message.delta", startsTurn: true, turnEnded: true)
        #expect(delta)
        let toolEnd = hold.holds("tool.complete", startsTurn: false, turnEnded: true)
        #expect(toolEnd)
        // Still waiting even once the last turn is gone, until it is released.
        let idle = hold.holds("session.info", startsTurn: false, turnEnded: false)
        #expect(idle)
        let released = hold.release()
        #expect(released == ["message.start", "message.delta", "tool.complete", "session.info"])
        #expect(!hold.isHolding)
        let again = hold.release()
        #expect(again.isEmpty)
    }
}

/// Up Next never sent by itself once the moment it waited for had passed: after a relaunch, an idle
/// reconnect, or once what held it cleared, it said "sends when this reply is done" with no reply
/// running (`docs/follow-ups.md` §4).
@Suite("Up Next sends by itself once the chat is free")
struct UpNextDrainTests {
    struct Item: Equatable {
        let text: String
        var isHeld = false
    }

    let idle = UpNext.Chat(turnHoldsChat: false, reachable: true)

    @Test("Idle and reachable after a relaunch: the first message goes")
    func relaunch() {
        let queue = [Item(text: "one"), Item(text: "two")]
        #expect(UpNext.next(in: queue, chat: idle, isHeld: \.isHeld) == Item(text: "one"))
    }

    @Test("Not sent and Maybe sent messages never go by themselves")
    func heldStay() {
        let queue = [Item(text: "maybe", isHeld: true), Item(text: "queued")]
        #expect(UpNext.next(in: queue, chat: idle, isHeld: \.isHeld) == Item(text: "queued"))
        #expect(UpNext.next(in: [Item(text: "maybe", isHeld: true)], chat: idle, isHeld: \.isHeld) == nil)
    }

    @Test("Whatever holds the chat keeps the queue waiting", arguments: [
        UpNext.Chat(turnHoldsChat: true, reachable: true),
        UpNext.Chat(turnHoldsChat: false, reachable: false),
        UpNext.Chat(turnHoldsChat: false, reachable: true, paused: true),
        UpNext.Chat(turnHoldsChat: false, reachable: true, waitsForChat: true),
        UpNext.Chat(turnHoldsChat: false, reachable: true, expectsGatewayTurn: true),
        UpNext.Chat(turnHoldsChat: false, reachable: true, sendsOnLoad: true),
        // Loaded in the background after a relaunch, never opened: its queue stays.
        UpNext.Chat(turnHoldsChat: false, reachable: true, opened: false),
    ])
    func waits(chat: UpNext.Chat) {
        #expect(!chat.isFree)
        #expect(UpNext.next(in: [Item(text: "one")], chat: chat, isHeld: \.isHeld) == nil)
    }

    @Test("Hermes gets the messages in the order they were queued, the held one staying first")
    func order() {
        var queue = [Item(text: "maybe", isHeld: true), Item(text: "one"), Item(text: "two"), Item(text: "three")]
        var received: [String] = []
        // One per turn: each goes once the turn before it has ended.
        while let next = UpNext.next(in: queue, chat: idle, isHeld: \.isHeld) {
            queue.removeAll { $0 == next }
            received.append(next.text)
        }
        #expect(received == ["one", "two", "three"])
        #expect(queue == [Item(text: "maybe", isHeld: true)])
    }

    @Test("Nothing waiting, nothing goes")
    func empty() {
        #expect(UpNext.next(in: [Item](), chat: idle, isHeld: \.isHeld) == nil)
    }
}

/// Over the API server, a run's events are swept 300 s after it was created whenever nothing
/// listens, even while it runs: back from the background after that, the app got 404 on the events
/// and said "Reconnecting…" with no steps until the run ended (`docs/chat.md` §2).
@Suite("A run whose events Hermes swept is followed by its status")
struct RunFollowTests {
    private func status(_ value: String) throws -> RunStatus {
        try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id": "run_1", "status": "\#(value)"}"#.utf8))
    }

    @Test("A 404 on the events means they're gone; a dropped connection doesn't")
    func eventsGone() {
        #expect(RunFollow.eventsGone(after: HermesError.notFound(message: "Run not found: run_1")))
        #expect(!RunFollow.eventsGone(after: URLError(.networkConnectionLost)))
        #expect(!RunFollow.eventsGone(after: nil))
    }

    @Test("Events gone and the run still running: its status is followed, never Reconnecting")
    func watchesStatus() throws {
        #expect(RunFollow.next(eventsGone: true, status: .success(try status("running"))) == .watchStatus)
        #expect(RunFollow.next(eventsGone: true, status: .success(try status("waiting_for_approval"))) == .watchStatus)
        #expect(RunFollow.next(eventsGone: true, status: .success(try status("queued"))) == .watchStatus)
        // A read that failed (offline) keeps following the status, not the events that are gone.
        #expect(RunFollow.next(eventsGone: true, status: .failure(URLError(.notConnectedToInternet))) == .watchStatus)
    }

    @Test("The run ended: its status says how, events or not", arguments: ["completed", "failed", "cancelled", "interrupted"])
    func ends(value: String) throws {
        #expect(RunFollow.next(eventsGone: true, status: .success(try status(value))) == .end)
        #expect(RunFollow.next(eventsGone: false, status: .success(try status(value))) == .end)
    }

    @Test("A dropped stream with the run running listens again")
    func listens() throws {
        #expect(RunFollow.next(eventsGone: false, status: .success(try status("running"))) == .listen)
        #expect(RunFollow.next(eventsGone: false, status: .failure(URLError(.timedOut))) == .listen)
    }

    @Test("Hermes no longer has the run: the stored chat says how it ended")
    func recovers() {
        #expect(RunFollow.next(eventsGone: true, status: .failure(HermesError.notFound(message: nil))) == .recover)
        #expect(RunFollow.next(eventsGone: false, status: .failure(HermesError.notFound(message: nil))) == .recover)
    }
}
