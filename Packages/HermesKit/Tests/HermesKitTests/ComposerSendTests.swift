import Foundation
import Testing
@testable import HermesKit

/// The composer is never dead (`ComposerSend`, `docs/chat.md` §4b): whatever the turn flags say,
/// something in the field can be sent, steered or queued. A tester's Mac once held a message in
/// Up Next with Send greyed out, because a turn the app never heard end kept the chat "open".
@Suite("What Send does")
struct ComposerSendTests {
    /// Every combination of the turn flags, with or without a helper being written to.
    private static var everyState: [ComposerSend.State] {
        var states: [ComposerSend.State] = []
        for bits in 0..<(1 << 6) {
            func flag(_ n: Int) -> Bool { bits & (1 << n) != 0 }
            states.append(ComposerSend.State(
                hasContent: true, hasQueued: flag(0), isWorking: flag(1), isStopping: flag(2),
                isFinishing: flag(3), isTurnOpen: flag(4), steersHelper: false, isReachable: flag(5)
            ))
        }
        return states
    }

    @Test func somethingInTheFieldAlwaysHasSomewhereToGo() {
        for state in Self.everyState {
            #expect(ComposerSend.decide(state) != nil, "no action for \(state)")
            var helper = state
            helper.steersHelper = true
            #expect(ComposerSend.decide(helper) == .steerHelper)
        }
    }

    @Test func nothingRunningSends() {
        #expect(ComposerSend.decide(.init(hasContent: true)) == .send)
        // Away or busy gateways never grey Send out: the message waits for them (`delivery`).
        #expect(ComposerSend.decide(.init(hasContent: true, isReachable: false)) == .send)
        #expect(ComposerSend.decide(.init(hasContent: true, hasQueued: true)) == .send)
    }

    @Test func aLiveTurnIsSteered() {
        #expect(ComposerSend.decide(.init(hasContent: true, isWorking: true)) == .steer)
        // Our own gateway turn is open while it streams: still a steer.
        #expect(ComposerSend.decide(.init(hasContent: true, isWorking: true, isTurnOpen: true)) == .steer)
    }

    /// The flags that used to leave Send greyed out: each one queues instead.
    @Test func aTurnThatCantTakeANoteQueues() {
        // Open on the gateway with nothing streaming: started elsewhere, or its end missed.
        #expect(ComposerSend.decide(.init(hasContent: true, hasQueued: true, isTurnOpen: true)) == .queue)
        // Finishing: its stored rows are being read.
        #expect(ComposerSend.decide(.init(hasContent: true, isFinishing: true)) == .queue)
        #expect(ComposerSend.decide(.init(hasContent: true, isFinishing: true, isTurnOpen: true)) == .queue)
        // Stopping: Hermes hasn't said the turn ended yet.
        #expect(ComposerSend.decide(.init(hasContent: true, isWorking: true, isStopping: true)) == .queue)
    }

    @Test func anEmptyFieldSendsTheFirstQueuedOnceNothingHoldsTheChat() {
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true)) == .sendQueued)
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true, isTurnOpen: true)) == nil)
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true, isFinishing: true)) == nil)
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true, isWorking: true)) == nil)
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true, isReachable: false)) == nil)
        #expect(ComposerSend.decide(.init(hasContent: false)) == nil)
        // A helper target with nothing typed sends nothing to it, and doesn't hold up the queue.
        #expect(ComposerSend.decide(.init(hasContent: false, hasQueued: true, steersHelper: true)) == .sendQueued)
    }
}

@Suite("A turn that holds the chat with nothing running")
struct StuckTurnTests {
    @Test func onlyAFlagWithoutAStreamingTurnHolds() {
        #expect(StuckTurn.holds(isTurnOpen: true, isFinishing: false, isWorking: false))
        #expect(StuckTurn.holds(isTurnOpen: false, isFinishing: true, isWorking: false))
        #expect(StuckTurn.holds(isTurnOpen: true, isFinishing: true, isWorking: false))
        #expect(!StuckTurn.holds(isTurnOpen: true, isFinishing: false, isWorking: true))
        #expect(!StuckTurn.holds(isTurnOpen: false, isFinishing: false, isWorking: false))
    }

    @Test func theGatewaySettlesIt() {
        #expect(StuckTurn.outcome(running: false) == .settle)
        #expect(StuckTurn.outcome(running: true) == .follow)
        #expect(StuckTurn.outcome(running: nil) == .askAgain)
        #expect(StuckTurn.grace == .seconds(10))
    }

    /// Before Up Next sends after a settle, the stored chat is read: a message Hermes already has
    /// from since the chat was held isn't sent a second time.
    @Test func aQueuedMessageTheChatAlreadyHasIsntSentAgain() {
        let heldSince = Date(timeIntervalSince1970: 1_792_000_000)
        let stored = [
            SessionMessage(id: 7, role: "user", content: .text("check the build"), timestamp: heldSince.addingTimeInterval(-600)),
            SessionMessage(id: 8, role: "assistant", content: .text("Green."), timestamp: heldSince.addingTimeInterval(-590)),
            SessionMessage(id: 9, role: "user", content: .text("and the docs"), timestamp: heldSince.addingTimeInterval(4)),
        ]
        #expect(SubmitCheck.arrived("and the docs", sentAt: heldSince, knownNewestID: 8, in: stored))
        #expect(!SubmitCheck.arrived("check the build", sentAt: heldSince, knownNewestID: 8, in: stored))
        #expect(!SubmitCheck.arrived("and the tests", sentAt: heldSince, knownNewestID: 8, in: stored))
    }
}
