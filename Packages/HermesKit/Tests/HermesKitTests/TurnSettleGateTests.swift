import Foundation
import Testing
@testable import HermesKit

@Suite("When a turn is over")
struct TurnSettleGateTests {
    private func idle() -> GatewayEvent {
        GatewayEvent(type: "session.info", sessionID: "s", seq: nil, payload: .object(["running": .bool(false), "model": .string("claude")]))
    }

    /// The owner's Butler chat (2026-10-19, 21:47): Hermes built the chat's agent after the prompt
    /// went out and said the session was idle as it did, before it took the prompt 14 s later. That
    /// idle notice isn't the end of the turn; the one after the reply is.
    @Test func idleBeforeHermesTakesThePromptIsNotTheEnd() {
        var gate = TurnSettleGate()
        #expect(!gate.settles) // nothing sent: a chat being created settles too
        gate.send()
        #expect(GatewayTurnDecoder.decode(idle()).map(\.event) == [.settled])
        #expect(!gate.settles) // `_announce_built_agent`, the prompt not taken yet
        gate.take() // the submit answered
        #expect(gate.settles)
        gate.send() // the next message
        #expect(!gate.settles)
    }

    /// A turn started elsewhere (another device, a routine) is taken from its first event.
    @Test func aTurnStartedElsewhereEndsWithItsIdleNotice() {
        var gate = TurnSettleGate()
        gate.take()
        #expect(gate.sent && gate.settles)
    }

    @Test func aTurnThatEndedWithNothingInItIsNotOver() {
        var turn = AssistantTurn(id: "t", state: .complete)
        #expect(turn.endedEmpty)
        turn.answer = "Your next event is the cleaning lady on Wednesday."
        #expect(!turn.endedEmpty)
        #expect(!AssistantTurn(id: "t", steps: [.reasoning(id: "r", text: "Checking the calendar")], state: .complete).endedEmpty)
        #expect(!AssistantTurn(id: "t", state: .failed("No model")).endedEmpty)
        #expect(!AssistantTurn(id: "t", state: .stopped).endedEmpty)
        #expect(!AssistantTurn(id: "t", state: .streaming).endedEmpty)
    }
}
