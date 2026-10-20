import Foundation
import Testing
@testable import HermesKit

@Suite("Hermes refusing or too busy to answer")
struct RefusalTests {
    @Test func aChatHeldByAnotherProcessIsNotACapacityLimit() {
        let held = GatewayRPCError(code: 4090, message: "Session x is already active in another Hermes process.",
                                   data: .object(["reason": .string("SESSION_NOT_OWNED")]))
        #expect(held.isHeldElsewhere)
        #expect(held.errorDescription?.contains("Another Hermes process is answering in this chat") == true)
        let cap = GatewayRPCError(code: 4090, message: "Active session limit reached.",
                                  data: .object(["reason": .string("MAX_CONCURRENT_SESSIONS")]))
        #expect(!cap.isHeldElsewhere)
        #expect(cap.errorDescription?.contains("as many chats at once") == true)
        #expect(!GatewayRPCError(code: 4009, message: "busy").isHeldElsewhere)
    }

    @Test func aProxyThatGaveUpSaysBusy() {
        #expect(BackendClient.Failure.http(502, nil).errorDescription == "Hermes didn't answer in time: it's busy right now. Try again in a moment.")
        #expect(BackendClient.Failure.http(500, nil).errorDescription == "The Hermes backend answered 500.")
        #expect(BackendClient.Failure.http(502, "Upstream said no").errorDescription == "Upstream said no")
    }
}

/// A slow backend is busy, not offline: Hermes's dashboard freezes on a loaded Mac and then
/// carries on, so these keep the Bots listed and say the Mac is busy.
@Suite("Slow answers")
struct SlowAnswerTests {
    @Test func proxyTimeoutsAndTimeoutsAreSlow() {
        #expect(BackendClient.isSlowAnswer(BackendClient.Failure.http(502, nil)))
        #expect(BackendClient.isSlowAnswer(BackendClient.Failure.http(504, "Gateway Timeout")))
        #expect(BackendClient.isSlowAnswer(GatewaySocket.Failure.timedOut(method: "profiles.list")))
        #expect(BackendClient.isSlowAnswer(GatewaySocket.Failure.handshakeTimedOut))
        #expect(BackendClient.isSlowAnswer(URLError(.timedOut)))
    }

    @Test func refusalsAndAMissingMachineAreNot() {
        #expect(!BackendClient.isSlowAnswer(BackendClient.Failure.http(404, "Not Found")))
        #expect(!BackendClient.isSlowAnswer(BackendClient.Failure.signInRequired))
        #expect(!BackendClient.isSlowAnswer(BackendClient.Failure.tokenNotFound))
        #expect(!BackendClient.isSlowAnswer(GatewaySocket.Failure.closed("The sign-in was refused.")))
        #expect(!BackendClient.isSlowAnswer(URLError(.cannotConnectToHost)))
        #expect(!BackendClient.isSlowAnswer(URLError(.notConnectedToInternet)))
    }
}
