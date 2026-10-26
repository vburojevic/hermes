import Foundation
import Testing
@testable import HermesKit

/// What Hermes did with a message, from `prompt.submit`'s answer (`docs/chat.md` §4c): only
/// `streaming` means the message started a turn of its own.
@Suite("What prompt.submit's answer says")
struct SubmitAnswerTests {
    private func answer(_ json: String) -> SubmitAnswer {
        SubmitAnswer(result: JSONValue.parse(json))
    }

    @Test func anIdleChatStartsTheMessagesOwnTurn() {
        #expect(answer(#"{"status": "streaming", "user_row_id": 42}"#) == .started(userRowID: 42))
        #expect(answer(#"{"status": "streaming"}"#).startedItsTurn)
        // An older Hermes that answered without a status.
        #expect(answer("{}").startedItsTurn)
    }

    @Test func aBusyChatQueuesTheMessageBehindItsTurn() {
        let queued = answer(#"{"status": "queued"}"#)
        #expect(queued == .queuedBehindTurn)
        #expect(!queued.startedItsTurn)
        #expect(queued.isQueued)
    }

    @Test func theGatewaysQueueIsToldApart() {
        let forwarded = answer(#"{"status": "queued", "admission_id": "adm-1", "forwarded": true}"#)
        #expect(forwarded == .queuedOnGateway(admissionID: "adm-1"))
        #expect(forwarded.isQueued)
        #expect(!forwarded.startedItsTurn)
    }

    @Test func aMessageThatWentIntoTheRunningTurnIsNotATurnOfItsOwn() {
        #expect(answer(#"{"status": "steered"}"#) == .steered)
        #expect(answer(#"{"status": "redirected"}"#) == .redirected)
        #expect(!answer(#"{"status": "steered"}"#).startedItsTurn)
        #expect(!answer(#"{"status": "redirected"}"#).isQueued)
    }

    @Test func aTypedStopPhraseStartsNothing() {
        let stopped = answer(#"{"voice_stopped": true}"#)
        #expect(stopped == .voiceStopped)
        #expect(!stopped.startedItsTurn)
        #expect(!stopped.isQueued)
    }
}
