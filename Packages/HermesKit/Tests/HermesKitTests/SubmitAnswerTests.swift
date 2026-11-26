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

    /// The session authority (Hermes Agent 0.23.3 and newer) answers with its admission receipt
    /// (`gateway/session_contract.py` `AdmissionReceipt`). A new message's receipt says `queued`,
    /// an idle chat's too, since its turn starts only after the admission is written
    /// (`gateway/session_authority.py` `_submit`): it is the message's turn, not one ahead of it.
    @Test func theSessionAuthoritysReceiptIsRead() {
        let ref = #""ref": {"profile_id": "writer", "session_id": "s-1"}, "sequence": 3, "outcome": null, "authority_epoch": 1, "execution_generation": null"#
        let admitted = answer(#"{"admission_id": "adm-1", \#(ref), "status": "queued"}"#)
        #expect(admitted == .admitted(admissionID: "adm-1"))
        #expect(admitted.ownsTheNextTurn)
        #expect(!admitted.startedItsTurn)
        #expect(!admitted.isQueued)
        #expect(admitted.userRowID == nil)
        // Handed to the running turn (`STEERING`), or already running.
        let started = answer(#"{"admission_id": "adm-1", \#(ref), "status": "started"}"#)
        #expect(started == .started(userRowID: nil))
        #expect(started.ownsTheNextTurn)
    }

    /// The legacy dispatcher's `queued` carries no admission: a turn runs ahead of the message.
    @Test func aLegacyQueuedIsBehindATurn() {
        #expect(!answer(#"{"status": "queued"}"#).ownsTheNextTurn)
        #expect(!answer(#"{"status": "queued", "admission_id": "adm-1", "forwarded": true}"#).ownsTheNextTurn)
        #expect(answer(#"{"status": "streaming", "user_row_id": 7}"#).userRowID == 7)
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
