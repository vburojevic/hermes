import Foundation
import Testing
@testable import HermesKit

/// A reply's live state was left behind on a loaded Mac, "Thinking… · 4m 19s" over its own
/// narration, and the finished turn showed again below it with the self-review between them
/// (`docs/chat.md` §2, one turn in one place).
@Suite("One turn, one place")
struct OneTurnOnePlaceTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private static let narration = "A newer release exists (v1.40.5). I'll check what it adds and upgrade."
    private static let reply = "Yes: 1.40.5 imports blood records from PDF and CSV."

    /// The ARGUS turn as Hermes stores it, row by row: the message, the narration with the first
    /// call, three calls and their results, then the reply (written last, late on a busy database).
    private func rows(withReply: Bool) -> [SessionMessage] {
        var rows = [
            SessionMessage(id: 8, role: "user", content: .text("Log breakfast"), timestamp: at(-900)),
            SessionMessage(id: 9, role: "assistant", content: .text("Logged."), timestamp: at(-880)),
            SessionMessage(id: 10, role: "user", content: .text("Check argus if it can import blood records with latest version"), timestamp: at(-259)),
            SessionMessage(id: 11, role: "assistant", content: .text(Self.narration),
                           toolCalls: [ToolCall(id: "c1", name: "terminal", arguments: #"{"command": "argus --version"}"#)], timestamp: at(-250)),
            SessionMessage(id: 12, role: "tool", content: .text(#"{"output": "1.40.4", "exit_code": 0}"#), toolCallID: "c1", toolName: "terminal", timestamp: at(-240)),
            SessionMessage(id: 13, role: "assistant", content: .text(""),
                           toolCalls: [ToolCall(id: "c2", name: "terminal", arguments: #"{"command": "argus upgrade"}"#)], timestamp: at(-200)),
            SessionMessage(id: 14, role: "tool", content: .text(#"{"output": "upgraded", "exit_code": 0}"#), toolCallID: "c2", toolName: "terminal", timestamp: at(-120)),
            SessionMessage(id: 15, role: "assistant", content: .text(""),
                           toolCalls: [ToolCall(id: "c3", name: "terminal", arguments: #"{"command": "argus import --help"}"#)], timestamp: at(-60)),
            SessionMessage(id: 16, role: "tool", content: .text(#"{"output": "import blood <file>", "exit_code": 0}"#), toolCallID: "c3", toolName: "terminal", timestamp: at(-30)),
        ]
        if withReply {
            rows.append(SessionMessage(id: 17, role: "assistant", content: .text(Self.reply), timestamp: at(-2)))
        }
        return rows
    }

    /// The turn as this device saw it live, to its end.
    private func liveTurn(heardEnd: Bool = true) -> LiveTurn {
        var live = LiveTurn(id: "live-1", sessionID: "rt", startedAt: at(-259))
        live.apply(SequencedTurnEvent(seq: 1, event: .commentary(Self.narration, alreadyStreamed: false)), now: at(-250))
        for (seq, call) in ["c1", "c2", "c3"].enumerated() {
            live.apply(SequencedTurnEvent(seq: 2 + seq * 2, event: .toolStarted(id: call, name: "terminal", preview: nil, at: nil)), now: at(-240))
            live.apply(SequencedTurnEvent(seq: 3 + seq * 2, event: .toolFinished(id: call, name: "terminal", failed: false, duration: 5, resultPreview: nil, at: nil)), now: at(-30))
        }
        if heardEnd {
            live.apply(SequencedTurnEvent(seq: 9, event: .persisted(PersistedTurn(userRowID: 10, rowIDs: [10, 11, 12, 13, 14, 15, 16]))), now: at(-2))
            live.apply(SequencedTurnEvent(seq: 9, event: .completed(output: Self.reply, usage: nil, runtime: nil)), now: at(-2))
        }
        return live
    }

    private func assistantTurns(_ items: [TranscriptItem]) -> [AssistantTurn] {
        items.compactMap { if case .assistant(let turn) = $0 { turn } else { nil } }
    }

    // MARK: The reply ended before Hermes stored it (the screenshot)

    /// A read of the chat lands while the reply's row is still queued: the stored rows stop after a
    /// tool's result. They are the turn on screen, not a second one still going somewhere else.
    @Test func aHeldTurnTakesThePlaceOfItsHalfStoredCopy() {
        let messages = rows(withReply: false)
        var built = TranscriptBuilder.build(messages)
        // What the chat did before: the stored copy read as still working (`markMidTurn`)…
        #expect(TranscriptBuilder.markMidTurn(&built, messages: messages, now: now))
        let shown: [TranscriptItem] = [.user(UserEntry(id: "local-1", text: "Check argus if it can import blood records with latest version")),
                                       .assistant(liveTurn().turn)]
        let placed = TurnPlacement.place(shown, userRowID: 10, after: 9, in: built, messages: messages)
        // …and the held copy went under it. Now it's one turn, finished, under its message.
        let turns = assistantTurns(placed)
        #expect(turns.count == 2) // the breakfast reply, and this one
        #expect(turns.last?.id == "live-1")
        #expect(turns.allSatisfy { !$0.isWorking })
        #expect(turns.last?.answer == Self.reply)
        #expect(placed.filter { if case .user = $0 { true } else { false } }.count == 2)
        #expect(placed.last?.id == "live-1")
        guard case .user(let ask)? = placed.dropLast().last else {
            Issue.record("the turn isn't under its message: \(placed.map(\.id))")
            return
        }
        #expect(ask.id == "m10")
    }

    /// Without the receipt's ids (an older Hermes), the newest row from before the turn finds it.
    @Test func withoutIDsTheRowBeforeTheTurnFindsIt() {
        let messages = rows(withReply: false)
        let built = TranscriptBuilder.build(messages)
        let placed = TurnPlacement.place([.assistant(liveTurn().turn)], userRowID: nil, after: 9, in: built, messages: messages)
        #expect(assistantTurns(placed).map(\.id) == ["tm9", "live-1"])
    }

    /// Nothing of it stored yet (turn isolation stores the message late): it shows after the
    /// stored rows, with the person's message, as before.
    @Test func aTurnNothingOfWhichIsStoredGoesAtTheEnd() {
        let messages = Array(rows(withReply: false).prefix(2))
        let built = TranscriptBuilder.build(messages)
        let shown: [TranscriptItem] = [.user(UserEntry(id: "local-1", text: "Check argus")), .assistant(liveTurn().turn)]
        let placed = TurnPlacement.place(shown, userRowID: 10, after: 9, in: built, messages: messages)
        #expect(placed.map(\.id) == ["m8", "tm9", "local-1", "live-1"])
    }

    /// The receipt's ids say whether the stored chat holds the whole turn: its reply's row.
    @Test func theReceiptSaysWhenTheTurnIsStored() throws {
        let payload = try #require(JSONValue.parse(#"{"row_ids": [10, 11, 12, 17], "complete": true, "user_row_id": 10, "final_assistant_row_id": 17}"#))
        let receipt = try #require(PersistedTurn(payload))
        #expect(receipt.userRowID == 10 && receipt.finalAssistantRowID == 17 && receipt.complete)
        #expect(receipt.isStored(in: rows(withReply: true)) == true)
        #expect(receipt.isStored(in: rows(withReply: false)) == false)
        // Committed late, the reply has no id in the receipt: the stored rows decide.
        let late = try #require(PersistedTurn(JSONValue.parse(#"{"row_ids": [10, 11], "complete": false, "user_row_id": 10}"#)))
        #expect(late.isStored(in: rows(withReply: false)) == nil)
        #expect(PersistedTurn(JSONValue.parse(#"{"row_ids": [], "complete": false}"#)) == nil)
    }

    /// `message.complete` hands its receipt to the live turn before it finishes.
    @Test func theLiveTurnKeepsItsReceipt() {
        let frame = GatewayEvent(type: "message.complete", sessionID: "rt", seq: 30, payload: .object([
            "text": .string(Self.reply), "status": .string("complete"),
            "persisted_turn": .object(["row_ids": .array([.number(10), .number(11)]), "user_row_id": .number(10), "complete": .bool(false)]),
        ]))
        var live = LiveTurn(id: "live-1", sessionID: "rt", startedAt: at(-60))
        for event in GatewayTurnDecoder.decode(frame) { live.apply(event, now: now) }
        #expect(live.persisted?.userRowID == 10)
        #expect(live.turn.state == .complete && live.turn.answer == Self.reply)
    }

    // MARK: A run lost on the way (a gateway restart, a stream that never came back)

    /// The session says it's idle and the turn never heard how it ended: what stays on screen
    /// says the app lost track of it, never "Worked for …" as if it had finished.
    @Test func aRunThatEndedUnheardSaysItLostTrack() {
        var live = liveTurn(heardEnd: false)
        live.settleUnheard(now: now)
        #expect(live.isFinished)
        guard case .failed(let line) = live.heldTurn.state else {
            Issue.record("held as \(live.heldTurn.state)")
            return
        }
        #expect(line == LiveTurn.lostTrack)
        // One that heard its end is held as it ended.
        #expect(liveTurn().heldTurn.state == .complete)
    }

    /// The stored rows went further than what the lost turn heard: the turn keeps those steps, in
    /// its own place, and still says it lost track.
    @Test func aLostTurnKeepsTheStepsHermesStored() {
        var heard = LiveTurn(id: "live-1", sessionID: "rt", startedAt: at(-259))
        heard.apply(SequencedTurnEvent(seq: 1, event: .commentary(Self.narration, alreadyStreamed: false)), now: at(-250))
        heard.apply(SequencedTurnEvent(seq: 2, event: .toolStarted(id: "c1", name: "terminal", preview: nil, at: nil)), now: at(-250))
        heard.settleUnheard(now: now)
        let messages = rows(withReply: false)
        let placed = TurnPlacement.place([.assistant(heard.heldTurn)], userRowID: nil, after: 9, in: TranscriptBuilder.build(messages), messages: messages)
        let turn = assistantTurns(placed).last
        #expect(turn?.id == "live-1")
        #expect(turn?.toolCount == 3)
        #expect(turn?.state == .failed(LiveTurn.lostTrack))
    }

    // MARK: Joining a turn that runs (back from the background, a dropped stream, another device)

    /// The stored chat stops partway through the turn running now, and its events arrive: the
    /// stored part carries on live as the same turn, from when the run started, never settled as
    /// done with a second live turn below it.
    @Test func joiningARunningTurnCarriesOnItsStoredPart() {
        let messages = rows(withReply: false)
        var built = TranscriptBuilder.build(messages)
        TranscriptBuilder.markMidTurn(&built, messages: messages, now: now)
        let joined = LiveTurn.joining(built, sessionID: "rt", startedAt: at(-259))
        #expect(assistantTurns(joined.rest).map(\.id) == ["tm9"])
        #expect(joined.live.turn.id == "tm11")
        #expect(joined.live.turn.toolCount == 3 && joined.live.turn.isWorking)
        #expect(joined.live.turn.startedAt == at(-259))
        // A chat whose last turn is over gets a new one, below it.
        let done = TranscriptBuilder.build(rows(withReply: true))
        let next = LiveTurn.joining(done, sessionID: "rt", startedAt: now)
        #expect(next.rest == done)
        #expect(next.live.turn.steps.isEmpty && next.live.turn.id != "tm11")
    }

    // MARK: The run's own time

    /// A stored turn starts when its message does, as the live one does: the live count and the
    /// final "Worked for" agree (they were 4m 19s and 3m 57s).
    @Test func aStoredTurnStartsWithItsMessage() {
        let turn = assistantTurns(TranscriptBuilder.build(rows(withReply: true))).last
        #expect(turn?.startedAt == at(-259))
        #expect(turn?.finishedAt == at(-2))
        // A turn no message started (after a notice) starts with its first row.
        let notice = SessionMessage(id: 20, role: "user", content: .text("Model changed"), timestamp: at(-50), displayKind: "model_switch")
        let after = SessionMessage(id: 21, role: "assistant", content: .text("Switched."), timestamp: at(-40))
        #expect(assistantTurns(TranscriptBuilder.build([notice, after])).last?.startedAt == at(-40))
    }
}
