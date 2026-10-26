import Foundation
import Testing
@testable import HermesKit

/// What Up Next and the chat show for a message (`docs/follow-ups.md` §4, `docs/chat.md` §4c,
/// §4d): why a row is there, what the tray waits for, a steer Hermes holds while it compacts, a
/// refusal that is never a red error, and what else Stop ended.
@Suite("Up Next and the chat's states")
struct UpNextStateTests {
    // MARK: Why a steer goes next instead (`SendsNextReason`)

    @Test func aSteerSaysWhyItGoesNext() {
        let refusedWhileBuilding = GatewayRPCError(code: 4010, message: "agent does not support steer")
        #expect(SendsNextReason.steer(error: refusedWhileBuilding, turnRunning: true, waitingForApproval: false, attached: true) == .turnStarting)
        #expect(SendsNextReason.steer(error: nil, turnRunning: false, waitingForApproval: false, attached: true) == .turnEnded)
        // Hermes answered `rejected`: its session isn't running any more.
        #expect(SendsNextReason.steer(error: nil, turnRunning: true, waitingForApproval: false, attached: true) == .turnEnded)
        let notAccepting = HermesError.server(status: 409, code: "run_not_accepting_steer", message: "Run is not currently accepting steer input: run_1")
        #expect(SendsNextReason.steer(error: notAccepting, turnRunning: true, waitingForApproval: true, attached: true) == .waitsOnApproval)
        #expect(SendsNextReason.steer(error: notAccepting, turnRunning: true, waitingForApproval: false, runQueued: true, attached: true) == .runQueued)
        // The chat never came back while it waited.
        #expect(SendsNextReason.steer(error: nil, turnRunning: true, waitingForApproval: false, attached: false) == .notBack)
        #expect(SendsNextReason.steer(error: GatewaySocket.Failure.notConnected, turnRunning: true, waitingForApproval: false, attached: true) == .notBack)
    }

    @Test func aSteerTheRunningTurnRefusedNeverReadsAsFinished() {
        // A 409 that came before the turn showed its approval, or with no reason the app can see.
        let notAccepting = HermesError.server(status: 409, code: "run_not_accepting_steer", message: "Run is not currently accepting steer input: run_1")
        #expect(SendsNextReason.steer(error: notAccepting, turnRunning: true, waitingForApproval: false, attached: true) == .turnBusy)
        #expect(UpNextNote.sendsNextInstead(.turnBusy).line(gateway: "Studio Mac")?.contains("finished") == false)
        #expect(SendsNextReason.steer(error: GatewaySocket.Failure.closed("gone"), turnRunning: true, waitingForApproval: false, attached: true) == .turnBusy)
    }

    @Test func eachRowNoteIsPlainWords() {
        #expect(UpNextNote.sendsNextInstead(.turnEnded).line(gateway: "Studio Mac") == "Hermes finished before reading it, so it sends next")
        #expect(UpNextNote.sendsNextInstead(.notBack).line(gateway: "Studio Mac") == "Couldn't reach Studio Mac in time, so it sends next")
        #expect(UpNextNote.clearedByStop.line(gateway: "Studio Mac") == "Stop cleared it from Studio Mac's queue before it ran")
        #expect(UpNextNote.mayHaveArrived.line(gateway: "Studio Mac")?.contains("Check the chat") == true)
    }

    @Test func aRefusalTheQueueWaitsOutLeavesItsWordsToTheTray() {
        let busy = SendRefusal(reason: .ownerBusy(imageRemoved: false), message: "The gateway is running a turn in this chat.")
        #expect(UpNextNote.refused(busy).line(gateway: "Studio Mac") == nil)
        // Only the gateway settles it: the banner has Hermes's sentence, the row says it briefly.
        let unresolved = SendRefusal(reason: .gatewayWorkUnresolved, message: "Session s has outcome-unknown work in the gateway's durable queue.")
        #expect(UpNextNote.refused(unresolved).line(gateway: "Studio Mac") == "Not sent: only the gateway can settle this chat")
    }

    @Test func aRowsReasonIsKeptAcrossARelaunchButARefusalIsAskedAgain() {
        for note in [UpNextNote.clearedByStop, .mayHaveArrived, .sendsNextInstead(.waitsOnApproval), .sendsNextInstead(.noBackground)] {
            #expect(UpNextNote(storedKey: note.storedKey) == note)
        }
        let refusal = SendRefusal(reason: .other, message: "Hermes could not safely reserve this session. Try again.")
        #expect(UpNextNote.refused(refusal).storedKey == nil)
        #expect(UpNextNote(storedKey: nil) == nil)
        #expect(UpNextNote(storedKey: "next.someday") == nil)
    }

    // MARK: What the tray waits for (`UpNextWait`)

    private func wait(editing: Bool = false, forChat: Bool = false, turn: Bool = false, reachable: Bool = true,
                      onGateway: Bool = false, allHeld: Bool = false) -> UpNextWait {
        UpNextWait.of(isEditing: editing, waitsForChat: forChat, turnHoldsChat: turn, reachable: reachable,
                      heldOnGateway: onGateway, allHeld: allHeld)
    }

    @Test func theTraySaysWhenThisReplyIsDoneOnlyWhileOneRuns() {
        #expect(wait(turn: true) == .reply)
        // Nothing runs (a relaunch, an idle reconnect, after Stop): Send sends the first.
        #expect(wait() == .sendSendsFirst)
        #expect(wait(reachable: false) == .gatewayAway)
        #expect(wait(turn: true, reachable: false) == .gatewayAway)
    }

    @Test func messagesThatOnlyGoWithASendNeverSitUnderSendsWhenDone() {
        // A durable-queue refusal or a Stop give-back: held, nothing running.
        #expect(wait(allHeld: true) == .sendSendsFirst)
        #expect(wait(turn: true, allHeld: true) == .yourSend)
        #expect(wait(reachable: false, allHeld: true) == .sendSendsFirst)
    }

    @Test func aHeldChatAndTheGatewaysQueueSayWhatTheyWaitFor() {
        #expect(wait(forChat: true, turn: true) == .chat)
        #expect(wait(onGateway: true) == .gatewayTurn)
        #expect(wait(turn: true, onGateway: true) == .reply)
        #expect(wait(editing: true, forChat: true) == .editing)
    }

    // MARK: Compaction

    @Test func aSteerHermesTakesWhileItCompactsWaitsInItsQueue() {
        let queued = JSONValue.object(["status": .string("queued")])
        #expect(SteerOutcome.steer(result: queued, error: nil, compacting: true) == .heldByHermes)
        #expect(SteerOutcome.steer(result: queued, error: nil, compacting: false) == .accepted)
    }

    @Test func aTurnKnowsWhileHermesCompacts() {
        let compacting = GatewayEvent(type: "status.update", sessionID: "s", seq: 1, payload: .object(["kind": .string("compacting"), "text": .string("Summarizing…")]))
        let events = GatewayTurnDecoder.decode(compacting).map(\.event)
        #expect(events == [.status("Summarizing…"), .compacting(true)])
        var turn = LiveTurn(id: "t", sessionID: "s")
        for event in events { turn.apply(SequencedTurnEvent(seq: nil, event: event)) }
        #expect(turn.isCompacting)
        turn.apply(SequencedTurnEvent(seq: nil, event: .textDelta("Done.")))
        #expect(!turn.isCompacting)
    }

    @Test func compactionEndsWithHermessCompactedLine() {
        let done = GatewayEvent(type: "status.update", sessionID: "s", seq: 2,
                                payload: .object(["kind": .string("compacted"), "text": .string("✓ Context compaction complete — continuing turn...")]))
        #expect(GatewayTurnDecoder.decode(done).map(\.event) == [.compacting(false)])
        var turn = LiveTurn(id: "t", sessionID: "s")
        turn.apply(SequencedTurnEvent(seq: nil, event: .compacting(true)))
        turn.apply(SequencedTurnEvent(seq: nil, event: .reasoning("Now the deletes.", replacing: false)))
        #expect(!turn.isCompacting)
    }

    // MARK: Refusals and Stop

    @Test func aRefusalIsNeverARedError() {
        #expect(HermesError.refused("Hermes could not safely reserve this session. Try again.").isRefusal)
        #expect(HermesError.server(status: 409, code: "queue_full", message: "queue_full").isRefusal)
        #expect(HermesError.server(status: 429, code: "rate_limit_exceeded", message: "Too many concurrent runs (max 10)").isRefusal)
        #expect(!HermesError.server(status: 500, code: nil, message: "boom").isRefusal)
        #expect(!HermesError.unauthorized.isRefusal)
    }

    @Test func tryAgainOnlyWhereSendingAgainCanHelp() {
        #expect(HermesError.refused("Hermes could not safely reserve this session. Try again.").refusalOffersRetry)
        #expect(HermesError.server(status: 409, code: "queue_full", message: "queue_full").refusalOffersRetry)
        #expect(!HermesError.server(status: 404, code: "not_found", message: "not_found").refusalOffersRetry)
        #expect(!HermesError.server(status: 409, code: "permission_denied", message: "permission_denied").refusalOffersRetry)
    }

    @Test func stopSaysWhatElseItEnded() {
        #expect(StopReceipt.line(helpersStopped: 0, approvalDeclined: false) == nil)
        #expect(StopReceipt.line(helpersStopped: 1, approvalDeclined: false) == "Stop also stopped 1 helper.")
        #expect(StopReceipt.line(helpersStopped: 2, approvalDeclined: true) == "Stop also stopped 2 helpers and declined the approval Hermes was waiting on.")
        #expect(StopReceipt.line(helpersStopped: 0, approvalDeclined: true) == "Stop also declined the approval Hermes was waiting on.")
    }
}
