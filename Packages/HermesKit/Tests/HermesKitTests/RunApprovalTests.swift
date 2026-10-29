import Foundation
import Testing
@testable import HermesKit

/// How a `/v1/runs` turn's approval card ends, as Hermes Agent says it on the run's events
/// (`session_pending_controls.py`: `approval.settled` with `{prompt_id, execution_generation}`
/// when it stops waiting, however that came about).
@Suite("Run approvals")
struct RunApprovalTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private static func approval(_ id: String = "p1", generation: Int? = 4, timeout: Int? = nil) -> ApprovalRequest {
        let timeoutField = timeout.map { #", "timeout_s": \#($0)"# } ?? ""
        let generationField = generation.map { #", "execution_generation": \#($0)"# } ?? ""
        let json = #"""
        {"kind": "approval", "prompt_id": "\#(id)", "command": "rm -rf ./build", "description": "Recursive delete",
         "choices": ["once", "deny", "session", "always"]\#(generationField)\#(timeoutField)}
        """#
        return try! JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
    }

    private static func settled(_ id: String, generation: Int = 4) -> TurnEvent? {
        let frame = ServerSentEvent(data: #"""
        {"event": "approval.settled", "run_id": "run_1", "timestamp": 1.0, "prompt_id": "\#(id)", "execution_generation": \#(generation), "seq": 9}
        """#)
        return RunEventDecoder.decode(frame).first?.event
    }

    private func liveTurn(showing approval: ApprovalRequest) -> LiveTurn {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(SequencedTurnEvent(seq: 1, event: .approvalRequested(approval)))
        return live
    }

    // MARK: - Decoding

    @Test func theRunsEventsSayWhenHermesStopsWaiting() {
        #expect(Self.settled("p1") == .approvalSettled(promptID: "p1", generation: 4))
        // Nothing to match a card by: nothing to do.
        #expect(RunEventDecoder.decode(ServerSentEvent(data: #"{"event": "approval.settled", "run_id": "run_1"}"#)).isEmpty)
    }

    @Test func anOlderGatewaysResponseStillClearsTheCard() throws {
        let frame = ServerSentEvent(data: #"{"event": "approval.responded", "choice": "once", "request_id": "p1", "resolved": 1}"#)
        let event = try #require(RunEventDecoder.decode(frame).first?.event)
        var live = liveTurn(showing: Self.approval())
        live.apply(SequencedTurnEvent(seq: 2, event: event))
        #expect(live.approval == nil)
        #expect(live.turn.state == .streaming)
    }

    @Test func theApprovalSaysHowLongHermesWaits() {
        #expect(Self.approval(timeout: 300).timeout == 300)
        #expect(Self.approval().timeout == nil)
    }

    // MARK: - The card

    @Test func answeredOnAnotherDeviceTheCardGoesWithALine() throws {
        var approvals = RunApprovals()
        approvals.show(Self.approval(), now: start)
        let event = try #require(Self.settled("p1"))
        guard case .approvalSettled(let id, let generation) = event else {
            Issue.record("not a settle")
            return
        }
        let ending = approvals.settle(id, generation: generation, now: start.addingTimeInterval(5))
        #expect(ending == .answeredElsewhere)

        var live = liveTurn(showing: Self.approval())
        live.apply(SequencedTurnEvent(seq: 2, event: event))
        #expect(live.approval == nil)
        #expect(live.turn.state == .streaming)
    }

    @Test func pastItsDeadlineHermesStoppedWaiting() {
        var approvals = RunApprovals()
        approvals.show(Self.approval(timeout: 60), now: start)
        let ending = approvals.settle("p1", generation: 4, now: start.addingTimeInterval(61))
        #expect(ending == .timedOut)

        // Before it, another device answered.
        var early = RunApprovals()
        early.show(Self.approval(timeout: 60), now: start)
        let earlyEnding = early.settle("p1", generation: 4, now: start.addingTimeInterval(30))
        #expect(earlyEnding == .answeredElsewhere)
    }

    @Test func theDeadlineCountsFromWhenHermesAsked() throws {
        // The run's events carry when Hermes asked; this stream attached 3 s later and replayed it.
        let frame = ServerSentEvent(data: #"""
        {"event": "approval.request", "run_id": "run_1", "timestamp": \#(start.timeIntervalSince1970), "request_id": "p1",
         "command": "rm -rf ./build", "execution_generation": 4, "choices": ["once", "deny"], "timeout_s": 20, "seq": 2}
        """#)
        guard case .approvalRequested(let approval)? = RunEventDecoder.decode(frame).first?.event else {
            Issue.record("no approval")
            return
        }
        #expect(approval.askedAt == start)
        var approvals = RunApprovals()
        approvals.show(approval, now: start.addingTimeInterval(3))
        let ending = approvals.settle("p1", generation: 4, now: start.addingTimeInterval(20.2))
        #expect(ending == .timedOut)

        // A gateway clock ahead of this device's counts from when the card showed.
        var ahead = RunApprovals()
        var early = approval
        early.askedAt = start.addingTimeInterval(60)
        ahead.show(early, now: start)
        let aheadEnding = ahead.settle("p1", generation: 4, now: start.addingTimeInterval(15))
        #expect(aheadEnding == .answeredElsewhere)
    }

    @Test func aCardTheRunsStatusRaisedEndsTheSameWay() throws {
        // A gateway that left the approval off the events lists it in the run's status, with no
        // time it asked: its deadline counts from when the card showed.
        let json = #"""
        {"run_id": "run_1", "status": "waiting_for_approval", "execution_generation": 4,
         "pending_controls": [{"kind": "approval", "prompt_id": "p1", "execution_generation": 4,
           "command": "rm -rf ./build", "choices": ["once", "deny"], "timeout_s": 20}]}
        """#
        let approval = try #require(try JSONDecoder().decode(RunStatus.self, from: Data(json.utf8)).approval)
        #expect(approval.askedAt == nil)

        var late = RunApprovals()
        late.show(approval, now: start)
        let ending = late.settle("p1", generation: 4, now: start.addingTimeInterval(21))
        #expect(ending == .timedOut)

        var elsewhere = RunApprovals()
        elsewhere.show(approval, now: start)
        let elsewhereEnding = elsewhere.settle("p1", generation: 4, now: start.addingTimeInterval(5))
        #expect(elsewhereEnding == .answeredElsewhere)
    }

    @Test func theEventAfterTheStatusBringsTheDeadlineForward() {
        // The status raised the card 10 s after Hermes asked; the stream, attached late, then
        // replays the asking with its time.
        var approvals = RunApprovals()
        approvals.show(Self.approval(timeout: 20), now: start.addingTimeInterval(10))
        var event = Self.approval(timeout: 20)
        event.askedAt = start
        approvals.show(event, now: start.addingTimeInterval(11))
        let ending = approvals.settle("p1", generation: 4, now: start.addingTimeInterval(20.2))
        #expect(ending == .timedOut)
    }

    @Test func aSettleForAnotherPromptLeavesTheCardUp() throws {
        var approvals = RunApprovals()
        approvals.show(Self.approval(), now: start)
        let ending = approvals.settle("p2", generation: 4, now: start)
        #expect(ending == nil)
        #expect(!approvals.isSettled("p1"))

        var live = liveTurn(showing: Self.approval())
        live.apply(SequencedTurnEvent(seq: 2, event: try #require(Self.settled("p2"))))
        #expect(live.approval?.requestID == "p1")
        #expect(live.turn.state == .waitingForApproval)
    }

    @Test func aSettleFromAnotherGenerationLeavesTheCardUp() throws {
        var approvals = RunApprovals()
        approvals.show(Self.approval(generation: 4), now: start)
        let ending = approvals.settle("p1", generation: 5, now: start)
        #expect(ending == nil)
        let sends = approvals.answer("p1")
        #expect(sends)

        var live = liveTurn(showing: Self.approval(generation: 4))
        live.apply(SequencedTurnEvent(seq: 2, event: try #require(Self.settled("p1", generation: 5))))
        #expect(live.approval?.requestID == "p1")
    }

    @Test func aTapAfterTheSettleSendsNothing() {
        var approvals = RunApprovals()
        approvals.show(Self.approval(), now: start)
        _ = approvals.settle("p1", generation: 4, now: start)
        #expect(approvals.isSettled("p1"))
        let sends = approvals.answer("p1")
        #expect(!sends)
    }

    @Test func answeredHereItSettlesWithoutALine() {
        var approvals = RunApprovals()
        approvals.show(Self.approval(), now: start)
        let sends = approvals.answer("p1")
        #expect(sends)
        let ending = approvals.settle("p1", generation: 4, now: start)
        #expect(ending == nil)
        // The answer that didn't go doesn't bring the card back: Hermes has stopped waiting.
        let comesBack = approvals.unanswer("p1")
        #expect(!comesBack)
    }

    @Test func anAnswerThatDidntGoBringsTheCardBack() {
        var approvals = RunApprovals()
        approvals.show(Self.approval(timeout: 60), now: start)
        let sends = approvals.answer("p1")
        #expect(sends)
        let comesBack = approvals.unanswer("p1")
        #expect(comesBack)
        // Back up, with its deadline from when it was first shown.
        let ending = approvals.settle("p1", generation: 4, now: start.addingTimeInterval(90))
        #expect(ending == .timedOut)
    }

    @Test func aNewTurnForgetsTheLastOnesApprovals() {
        var approvals = RunApprovals()
        approvals.show(Self.approval(), now: start)
        _ = approvals.settle("p1", generation: 4, now: start)
        approvals.endAll()
        #expect(!approvals.isSettled("p1"))
    }
}
