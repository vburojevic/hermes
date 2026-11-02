import Foundation
import Testing
@testable import HermesKit

struct PendingCallTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private let connected = PendingCall.Facts(hasGateway: true, botMode: .connected, hasBot: true)
    private let connecting = PendingCall.Facts(hasGateway: true, botMode: .connecting)

    @Test func readyAtOnceStartsAndLetsGo() {
        var slot = PendingCallSlot()
        #expect(slot.request(.bot("research"), now: start, facts: connected) == .bot("research"))
        #expect(slot.call == nil)
        // Nothing left to start twice.
        #expect(slot.update(connected, now: at(1)) == nil)
    }

    @Test func hermesStartsWithoutBotMode() {
        var slot = PendingCallSlot()
        let noBotMode = PendingCall.Facts(hasGateway: true, botMode: .notSetUp)
        #expect(slot.request(.hermes, now: start, facts: noBotMode) == .hermes)
    }

    @Test func waitsForBotModeThenStarts() {
        var slot = PendingCallSlot()
        #expect(slot.request(.bot("research"), now: start, facts: connecting) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        // Connected, its Bots not loaded yet: still waiting.
        let loading = PendingCall.Facts(hasGateway: true, botMode: .connected, hasBot: nil)
        #expect(slot.update(loading, now: at(20)) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        #expect(slot.update(connected, now: at(40)) == .bot("research"))
        #expect(slot.call == nil)
    }

    @Test func hermesWaitsForBotModeThatIsConnecting() {
        var slot = PendingCallSlot()
        #expect(slot.request(.hermes, now: start, facts: connecting) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        #expect(slot.update(PendingCall.Facts(hasGateway: true, botMode: .connected), now: at(5)) == .hermes)
    }

    @Test func timesOutAndNeverStartsLater() {
        var slot = PendingCallSlot()
        _ = slot.request(.bot("research"), now: start, facts: connecting)
        #expect(slot.update(connecting, now: at(59.9)) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        #expect(slot.update(connecting, now: at(PendingCall.timeLimit)) == nil)
        #expect(slot.call?.state == .timedOut)
        // Bot Mode comes back eleven seconds later: the call stays timed out.
        #expect(slot.update(connected, now: at(71)) == nil)
        #expect(slot.call?.state == .timedOut)
    }

    @Test func factsReadOnlyAfterTheLimitDontStartIt() {
        // The app was suspended through the whole minute; the first read finds Bot Mode up.
        var slot = PendingCallSlot()
        _ = slot.request(.bot("research"), now: start, facts: connecting)
        #expect(slot.update(connected, now: at(90)) == nil)
        #expect(slot.call?.state == .timedOut)
    }

    @Test func tryAgainWaitsAnotherMinute() {
        var slot = PendingCallSlot()
        _ = slot.request(.bot("research"), now: start, facts: connecting)
        _ = slot.update(connecting, now: at(60))
        #expect(slot.retry(now: at(100), facts: connecting) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        #expect(slot.call?.deadline == at(160))
        #expect(slot.update(connected, now: at(130)) == .bot("research"))
    }

    @Test func cancelForgetsIt() {
        var slot = PendingCallSlot()
        _ = slot.request(.bot("research"), now: start, facts: connecting)
        slot.cancel()
        #expect(slot.call == nil)
        #expect(slot.update(connected, now: at(5)) == nil)
        #expect(slot.retry(now: at(6), facts: connected) == nil)
    }

    @Test func aNewRequestReplacesTheOld() {
        var slot = PendingCallSlot()
        _ = slot.request(.bot("research"), now: start, facts: connecting)
        let first = slot.call?.id
        _ = slot.request(.bot("ada"), now: at(50), facts: connecting)
        #expect(slot.call?.callee == .bot("ada"))
        #expect(slot.call?.id != first)
        // Its own minute: still waiting where the first would have timed out.
        #expect(slot.update(connecting, now: at(70)) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        #expect(slot.update(connected, now: at(80)) == .bot("ada"))
    }

    @Test func botNotOnAConnectedRoster() {
        var slot = PendingCallSlot()
        let missing = PendingCall.Facts(hasGateway: true, botMode: .connected, hasBot: false)
        #expect(slot.request(.bot("atlas"), now: start, facts: missing) == nil)
        #expect(slot.call?.state == .cantStart(.noSuchBot))
        // Settled: a Bot created later doesn't start a call nobody is waiting for.
        #expect(slot.update(connected, now: at(10)) == nil)
        #expect(slot.call?.state == .cantStart(.noSuchBot))
    }

    @Test func botNamedWithoutBotMode() {
        var slot = PendingCallSlot()
        let noBotMode = PendingCall.Facts(hasGateway: true, botMode: .notSetUp)
        #expect(slot.request(.bot("research"), now: start, facts: noBotMode) == nil)
        #expect(slot.call?.state == .cantStart(.botModeNotSetUp))
    }

    @Test func noGateway() {
        var slot = PendingCallSlot()
        let none = PendingCall.Facts(hasGateway: false, botMode: .notSetUp)
        #expect(slot.request(.hermes, now: start, facts: none) == nil)
        #expect(slot.call?.state == .cantStart(.noGateway))
        #expect(slot.request(.bot("research"), now: start, facts: none) == nil)
        #expect(slot.call?.state == .cantStart(.noGateway))
    }

    @Test func waitsWhileNothingIsKnownYet() {
        // A cold launch: the request arrives before the app has read its gateway.
        var slot = PendingCallSlot()
        #expect(slot.request(.hermes, now: start, facts: .unknown) == nil)
        #expect(slot.call?.state == .waitingForBotMode)
        let noBotMode = PendingCall.Facts(hasGateway: true, botMode: .notSetUp)
        #expect(slot.update(noBotMode, now: at(1)) == .hermes)
    }

    @Test func calleeFromABotName() {
        #expect(PendingCall.Callee(botName: nil) == .hermes)
        #expect(PendingCall.Callee(botName: "research") == .bot("research"))
        #expect(PendingCall.Callee.bot("research").botName == "research")
    }
}
