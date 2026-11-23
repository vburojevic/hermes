import Foundation
import Synchronization
import Testing
@testable import HermesKit

/// `BusySignal` (`docs/connecting-and-voice.md` §3): when "Mac is busy" turns on, and how it
/// clears by itself.
@Suite struct BusySignalTests {
    /// A clock the test moves by hand.
    final class TestClock: Sendable {
        private let instant = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { instant.withLock { $0 } }
        func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
    }

    let clock = TestClock()
    /// A fresh signal on `clock`, for each test to change.
    let fresh: BusySignal

    init() {
        let clock = clock
        fresh = BusySignal(now: { clock.now })
    }

    /// Hermes holds a chat-list read for up to 5 s while the person's own reply runs: the case
    /// behind "Mac is busy" after every message.
    @Test func ownTurnSlowsReadsWithoutMakingItBusy() {
        var signal = fresh
        for _ in 0..<3 {
            signal.ownTurn(running: true)
            let read = signal.began()
            clock.advance(.seconds(8))
            signal.stillRunning(read) // the 8 s watcher, with the gateway there
            #expect(!signal.isBusy)
            clock.advance(.seconds(1))
            signal.answered(read)
            #expect(!signal.isBusy)
            clock.advance(.seconds(10))
            signal.ownTurn(running: false)
            clock.advance(.seconds(2))
        }
        #expect(!signal.isBusy)
    }

    @Test func readBeforeTheTurnStartedIsExcusedOnceItStarts() {
        var signal = fresh
        let read = signal.began()
        signal.ownTurn(running: true)
        clock.advance(.seconds(6))
        signal.answered(read)
        #expect(!signal.isBusy)
    }

    @Test func readJustAfterTheTurnEndedIsExcused() {
        var signal = fresh
        signal.ownTurn(running: true)
        clock.advance(.seconds(15))
        signal.ownTurn(running: false)
        clock.advance(.seconds(1))
        let read = signal.began()
        clock.advance(.seconds(6))
        signal.timedOut(read)
        #expect(!signal.isBusy)
    }

    @Test func turnLongOverExcusesNothing() {
        var signal = fresh
        signal.ownTurn(running: true)
        signal.ownTurn(running: false)
        clock.advance(BusySignal.turnAftermath)
        let read = signal.began()
        clock.advance(.seconds(6))
        signal.answered(read)
        #expect(signal.isBusy)
    }

    /// `--starve`: the Mac doesn't answer for a while, then answers quickly for a moment.
    @Test func starvedMacSignsMakeItBusy() {
        var signal = fresh
        let read = signal.began()
        clock.advance(.seconds(8))
        signal.stillRunning(read)
        #expect(signal.isBusy)
        clock.advance(.seconds(4))
        signal.answered(read) // slow: another sign
        #expect(signal.isBusy)
        #expect(signal.clearsAt == nil) // no quick answer since
    }

    @Test func timeoutWithTheGatewayThereIsASign() {
        var signal = fresh
        let read = signal.began()
        clock.advance(.seconds(15))
        signal.timedOut(read)
        #expect(signal.isBusy)
    }

    @Test func unansweredHealthCheckCountsEvenDuringOwnTurn() {
        var signal = fresh
        signal.ownTurn(running: true)
        signal.sign()
        #expect(signal.isBusy)
    }

    @Test func clearsThirtySecondsAfterTheLastSignOnceAnswersAreQuick() {
        var signal = fresh
        signal.sign()
        let signedAt = clock.now
        clock.advance(.seconds(3))
        let read = signal.began()
        clock.advance(.milliseconds(200))
        signal.answered(read)
        #expect(signal.isBusy) // too soon after the sign
        #expect(signal.clearsAt == signedAt + BusySignal.lingers)
        clock.advance(.seconds(26))
        signal.settle()
        #expect(signal.isBusy)
        clock.advance(.seconds(1))
        signal.settle() // what the app's wake-up at `clearsAt` does
        #expect(!signal.isBusy)
        #expect(signal.clearsAt == nil)
    }

    @Test func aNewSignStartsTheWaitOver() {
        var signal = fresh
        signal.sign()
        let quick = signal.began()
        signal.answered(quick)
        clock.advance(.seconds(20))
        signal.sign() // starved again
        #expect(signal.clearsAt == nil)
        let again = signal.began()
        signal.answered(again)
        clock.advance(.seconds(20))
        signal.settle()
        #expect(signal.isBusy)
        clock.advance(.seconds(10))
        signal.settle()
        #expect(!signal.isBusy)
    }

    @Test func aSlowRequestOutHoldsTheClearingUntilItEnds() {
        var signal = fresh
        signal.sign()
        let quick = signal.began()
        signal.answered(quick)
        let slow = signal.began()
        clock.advance(.seconds(31))
        signal.settle()
        #expect(signal.isBusy) // a request that counts is still out and slow
        #expect(signal.clearsAt == nil)
        signal.ended(slow) // cancelled: it says nothing about the Mac
        #expect(!signal.isBusy)
    }

    @Test func overlappingRequestsThatThrowOrAreCancelledNeverLeaveItStuck() {
        var signal = fresh
        signal.sign()
        let first = signal.began()
        let second = signal.began()
        let third = signal.began()
        clock.advance(.seconds(2))
        signal.answered(first) // quick
        clock.advance(.seconds(10))
        signal.ended(second) // failed
        signal.ended(third) // cancelled
        signal.ended(third) // ending twice does nothing
        signal.answered(second) // nor answering after it ended
        clock.advance(.seconds(18))
        signal.settle()
        #expect(!signal.isBusy)
    }

    @Test func ownTurnRequestOutDoesNotHoldTheClearing() {
        var signal = fresh
        signal.sign()
        let quick = signal.began()
        signal.answered(quick)
        signal.ownTurn(running: true)
        _ = signal.began() // a chat-list read held by the token flush, never answered yet
        clock.advance(.seconds(31))
        signal.settle()
        #expect(!signal.isBusy)
    }

    @Test func resetClearsAtOnce() {
        var signal = fresh
        signal.sign()
        signal.reset()
        #expect(!signal.isBusy)
        #expect(signal.clearsAt == nil)
    }

    final class Chat {}

    /// A chat deleted while its reply runs never says the turn ended: once it's forgotten, a
    /// starved Mac reads busy again.
    @Test func chatDeletedMidTurnStopsExcusingSlowAnswers() {
        var turns = BusySignal.OwnTurns<Chat>()
        var signal = fresh
        let deleted = Chat()
        let other = Chat()
        turns.set(deleted, running: true)
        turns.set(other, running: true)
        turns.set(other, running: false)
        signal.ownTurn(running: turns.anyRunning)
        #expect(turns.anyRunning)

        turns.forget(deleted) // `cancelAll`, with its turn still running
        signal.ownTurn(running: turns.anyRunning)
        #expect(!turns.anyRunning)

        clock.advance(BusySignal.turnAftermath)
        let read = signal.began()
        clock.advance(.seconds(8))
        signal.stillRunning(read)
        #expect(signal.isBusy)
    }

    @Test func chatThatGoesAwayStopsCounting() {
        var turns = BusySignal.OwnTurns<Chat>()
        var chat: Chat? = Chat()
        turns.set(chat!, running: true)
        #expect(turns.anyRunning)
        chat = nil
        #expect(!turns.anyRunning)
    }

    /// `BotRoster`: a `profiles.list` read per refresh, a stalled socket and a slow connect as
    /// signs, and the person's Bot Chat turns excused.
    @Test func rosterPath() {
        var signal = fresh
        // A Bot Chat's turn slows the roster read: not busy.
        signal.ownTurn(running: true)
        var read = signal.began()
        clock.advance(.seconds(7))
        signal.answered(read)
        #expect(!signal.isBusy)
        signal.ownTurn(running: false)
        clock.advance(.seconds(10))

        // A read that times out with the socket open, and a stalled socket: busy.
        read = signal.began()
        clock.advance(.seconds(30))
        signal.timedOut(read)
        #expect(signal.isBusy)
        clock.advance(.seconds(5))
        signal.sign() // socket stalled
        let lastSign = clock.now

        // The next turn's slow read is no sign, and no quick answer either.
        signal.ownTurn(running: true)
        read = signal.began()
        clock.advance(.seconds(6))
        signal.answered(read)
        #expect(signal.clearsAt == nil)
        signal.ownTurn(running: false)

        // A quick read after it: busy clears 30 s after the stall, with nothing else happening.
        clock.advance(.seconds(10))
        read = signal.began()
        signal.answered(read)
        #expect(signal.clearsAt == lastSign + BusySignal.lingers)
        clock.advance(.seconds(14))
        signal.settle()
        #expect(!signal.isBusy)
    }
}
