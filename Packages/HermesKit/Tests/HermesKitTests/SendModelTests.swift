import Foundation
import Testing
@testable import HermesKit

/// The send model's pieces (`docs/chat.md` §4c): what a steer's answer means, Hermes's held queue
/// through Stop and re-attach, photos staged for a prompt Hermes didn't take, Up Next's order and
/// the gateway's own queue.
@Suite("The send model")
struct SendModelTests {
    // MARK: Steer and redirect (`SteerOutcome`)

    @Test func anAcceptedSteerIsReadInItsTurn() {
        #expect(SteerOutcome.steer(result: .object(["status": .string("queued")]), error: nil) == .accepted)
    }

    @Test func aSteerTheTurnCantTakeGoesAsTheNextMessageNeverMissed() {
        // The turn ended first.
        #expect(SteerOutcome.steer(result: .object(["status": .string("rejected")]), error: nil) == .nextMessage)
        // Its agent was still being built (4010), or any other answer Hermes gave.
        #expect(SteerOutcome.steer(result: nil, error: GatewayRPCError(code: 4010, message: "agent does not support steer")) == .nextMessage)
        // No socket to send it on: it never went.
        #expect(SteerOutcome.steer(result: nil, error: GatewaySocket.Failure.notConnected) == .nextMessage)
    }

    @Test func aSteerWhoseAnswerWasLostWaitsForTheStoredTurnNeverSentTwice() {
        #expect(SteerOutcome.steer(result: nil, error: GatewaySocket.Failure.timedOut(method: "session.steer")) == .unknown)
        #expect(SteerOutcome.steer(result: nil, error: GatewaySocket.Failure.closed("gone")) == .unknown)
        #expect(SteerOutcome.redirect(result: nil, error: GatewaySocket.Failure.closed("gone")) == .unknown)
    }

    @Test func aRedirectHermesHoldsGoesInItsQueue() {
        #expect(SteerOutcome.redirect(result: .object(["status": .string("redirected")]), error: nil) == .redirected)
        #expect(SteerOutcome.redirect(result: .object(["status": .string("queued")]), error: nil) == .heldByHermes)
        #expect(SteerOutcome.redirect(result: .object(["status": .string("rejected")]), error: nil) == .nextMessage)
    }

    @Test func overTheAPIServerARunThatCantTakeASteerSendsItNext() {
        #expect(SteerOutcome.apiServer(error: nil) == .accepted)
        // Waiting for the person's approval, queued or stopping.
        #expect(SteerOutcome.apiServer(error: HermesError.server(status: 409, code: "run_not_accepting_steer", message: "Run is waiting_for_approval")) == .nextMessage)
        #expect(SteerOutcome.apiServer(error: HermesError.unreachable(host: "mac", reason: .timedOut)) == .unknown)
    }

    // MARK: Hermes's held queue (`GatewayHeldQueue`)

    @Test func stopGivesBackEveryHeldMessageWhole() {
        var held = GatewayHeldQueue<String>()
        held.hold("Photo", item: "the photo message")
        held.hold("after that", item: nil)
        let cleared = held.purged()
        #expect(cleared.map(\.line) == ["Photo", "after that"])
        #expect(cleared.map(\.item) == ["the photo message", nil])
        #expect(held.isEmpty)
    }

    @Test func reattachingKeepsWhatThisDeviceSentThoughHermesShowsOnlyTheFirst() {
        var held = GatewayHeldQueue<String>()
        held.hold("first", item: "1")
        held.hold("second", item: "2")
        held.attached(head: "first\n\nsecond")
        #expect(held.lines == ["first", "second"])
        // Nothing held there any more: it ran, or went with a Stop elsewhere.
        held.attached(head: nil)
        #expect(held.isEmpty)
        // One from another device.
        held.attached(head: "from the Mac")
        #expect(held.lines == ["from the Mac"])
        #expect(held.entries.first?.item == nil)
    }

    @Test func hermesSendsOnePhotoMessagePerTurnSoTheSecondStaysHeld() {
        var held = GatewayHeldQueue<String>()
        held.hold("Photo A", item: "a", isTextOnly: false)
        held.hold("Photo B", item: "b", isTextOnly: false)
        // The first turn starts from Hermes's queue: it carries A alone.
        #expect(held.taken().map(\.line) == ["Photo A"])
        #expect(held.lines == ["Photo B"])
        // Stop during A's turn empties Hermes's queue: B comes back, never lost.
        #expect(held.purged().map(\.item) == ["b"])
    }

    @Test func wordsJoinTheHeadOnlyWhileNothingWaitsBehindIt() {
        var held = GatewayHeldQueue<String>()
        held.hold("first", item: nil)
        held.hold("second", item: nil)   // joins the head: one turn
        held.hold("Photo", item: nil, isTextOnly: false)
        held.hold("third", item: nil)    // behind a photo: a turn of its own
        #expect(held.envelopes.map { $0.map(\.line) } == [["first", "second"], ["Photo"], ["third"]])
        #expect(held.taken().map(\.line) == ["first", "second"])
        #expect(held.taken().map(\.line) == ["Photo"])
        #expect(held.lines == ["third"])
    }

    @Test func stopGivesBackOnlyWhatNeverRan() throws {
        var held = GatewayHeldQueue<String>()
        held.hold("ran already", item: "1", isTextOnly: false)
        held.hold("never ran", item: "2", isTextOnly: false)
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id": 7, "role": "user", "content": "ran already"},
         {"id": 8, "role": "user", "content": "never ran", "display_metadata": "{\"_queued_prompt\": true}"}]
        """#.utf8))
        // Hermes started the first one's turn just before the Stop (a row of its own); the second
        // has only the row Hermes keeps for a message waiting in its queue.
        #expect(held.purged(ranSince: rows).map(\.item) == ["2"])
        #expect(held.isEmpty)
    }

    @Test func aRowHermesKeepsForAQueuedMessageIsNotATurn() throws {
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id": 1, "role": "user", "content": "hello"},
         {"id": 2, "role": "assistant", "content": "Hi."},
         {"id": 3, "role": "user", "content": "cleared by Stop", "display_metadata": {"_queued_prompt": true}}]
        """#.utf8))
        #expect(rows.map(\.isWaitingInQueue) == [false, false, true])
        let users = TranscriptBuilder.build(rows).compactMap { item -> String? in
            if case .user(let entry) = item { entry.text } else { nil }
        }
        #expect(users == ["hello"])
        // Kept across the device's cache.
        let again = try JSONDecoder().decode([SessionMessage].self, from: JSONEncoder().encode(rows))
        #expect(again.map(\.isWaitingInQueue) == [false, false, true])
    }

    @Test func aMessageThatNeverReachedTheQueueLeavesTheTray() {
        var held = GatewayHeldQueue<String>()
        held.hold("a", item: "a")
        held.hold("b", item: "b")
        #expect(held.release("a")?.item == "a")
        #expect(held.lines == ["b"])
        #expect(held.release("missing") == nil)
    }

    // MARK: Photos staged for a prompt (`StagedImages`)

    @Test func photosAndPDFPagesAreNotedByPath() {
        var staged = StagedImages()
        staged.staged(.object(["attached": .bool(true), "path": .string("/a.jpg")]))
        staged.staged(.object(["pages": .array([.object(["path": .string("/p1.png")]), .object(["path": .string("/p2.png")])])]))
        #expect(staged.paths == ["/a.jpg", "/p1.png", "/p2.png"])
    }

    @Test func photosAreTakenBackUnlessThePromptMayHaveThem() {
        // Refused: Hermes leaves them staged for the next message.
        #expect(StagedImages.takeBack(after: GatewayRPCError(code: 4090, message: "no", data: nil), promptSent: true))
        // The prompt never went.
        #expect(StagedImages.takeBack(after: GatewaySocket.Failure.notConnected, promptSent: false))
        #expect(StagedImages.takeBack(after: CancellationError(), promptSent: false))
        // Its answer was lost: the prompt may have them.
        #expect(!StagedImages.takeBack(after: GatewaySocket.Failure.closed("gone"), promptSent: true))
    }

    // MARK: Up Next's order (`UpNext`)

    @Test func aMessageWaitsBehindATurnAHeldChatAndWhatAlreadyWaits() {
        #expect(UpNext.goesNow(turnRunning: false, waitsForChat: false, othersWaiting: false, queuePaused: false))
        #expect(!UpNext.goesNow(turnRunning: true, waitsForChat: false, othersWaiting: false, queuePaused: false))
        // Send Again, Talk or Try Again on a chat another process holds: behind the refused message.
        #expect(!UpNext.goesNow(turnRunning: false, waitsForChat: true, othersWaiting: true, queuePaused: false))
        #expect(!UpNext.goesNow(turnRunning: false, waitsForChat: false, othersWaiting: true, queuePaused: false))
        // A queue Stop paused waits for the person's Send, not the new message.
        #expect(UpNext.goesNow(turnRunning: false, waitsForChat: false, othersWaiting: true, queuePaused: true))
    }

    // MARK: The gateway's own queue

    @Test func theGatewaysPendingListSaysWhatStillWaits() {
        let waiting = JSONValue.parse(#"{"stored_session_id": "s", "pending_submissions": [{"admission_id": "a", "status": "queued", "user": "for the owner"}]}"#)!
        #expect(GatewayQueue.pendingOnGateway(in: waiting) == ["for the owner"])
        let started = JSONValue.parse(#"{"stored_session_id": "s", "pending_submissions": []}"#)!
        #expect(GatewayQueue.pendingOnGateway(in: started) == [])
        #expect(GatewayQueue.pendingOnGateway(in: .object(["running": .bool(true)])) == nil)
    }
}
