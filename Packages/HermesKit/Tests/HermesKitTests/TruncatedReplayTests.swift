import Foundation
import Testing
@testable import HermesKit

/// A chat re-attaching on the socket after missing more events than Hermes keeps (512 or 4 MiB a
/// session): the replay has a hole, and the turn takes the steps it missed from its stored rows.
@Suite("A re-attach whose replay was truncated")
struct TruncatedReplayTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private func event(_ type: String, seq: Int, _ payload: String) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "rt", seq: seq, payload: JSONValue.parse(payload)!)
    }

    private func apply(_ event: GatewayEvent, to live: inout LiveTurn) {
        for decoded in GatewayTurnDecoder.decode(event) { live.apply(decoded, now: now) }
    }

    private func callIDs(_ turn: AssistantTurn) -> [String] {
        turn.steps.compactMap { if case .tool(let tool) = $0 { tool.callID } else { nil } }
    }

    /// The chat as Hermes stored it while the socket was down: the person's message, then every
    /// call of the turn so far, the last one still without its result.
    private var stored: [SessionMessage] {
        var rows = [
            SessionMessage(id: 8, role: "user", content: .text("Earlier question"), timestamp: at(-900)),
            SessionMessage(id: 9, role: "assistant", content: .text("Earlier answer."), timestamp: at(-890)),
            SessionMessage(id: 10, role: "user", content: .text("Read every source"), timestamp: at(-120)),
        ]
        for step in 1...5 {
            rows.append(SessionMessage(id: 9 + step * 2, role: "assistant", content: .text(step == 3 ? "Two more to go." : ""),
                                       toolCalls: [ToolCall(id: "c\(step)", name: "web_search", arguments: #"{"query": "source \#(step)"}"#)],
                                       timestamp: at(-120 + Double(step) * 10)))
            if step < 5 {
                rows.append(SessionMessage(id: 10 + step * 2, role: "tool", content: .text("Result \(step)"),
                                           toolCallID: "c\(step)", toolName: "web_search", timestamp: at(-115 + Double(step) * 10)))
            }
        }
        return rows
    }

    @Test func aTruncatedReplayTakesTheStepsItMissedFromTheStoredRows() throws {
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        apply(event("tool.start", seq: 1, #"{"tool_id": "c1", "name": "web_search", "context": "source 1"}"#), to: &live)
        apply(event("tool.complete", seq: 2, #"{"tool_id": "c1", "name": "web_search", "result": "Result 1", "duration_s": 1.4}"#), to: &live)

        // The socket was down for 700 events; Hermes kept the newest 512, and says so.
        let answer = JSONValue.parse(#"""
        {"events": [{"type": "tool.start", "session_id": "rt", "seq": 700,
                     "payload": {"tool_id": "c5", "name": "web_search", "context": "source 5"}}],
         "latest_seq": 700, "truncated": true, "count": 1, "epoch": "e1", "open_requests": []}
        """#)!
        let replay = try #require(EventReplay(answer, runtime: "rt"))
        #expect(replay.truncated)
        #expect(replay.events.map(\.seq) == [700])
        for frame in replay.events { apply(frame, to: &live) }
        live.note(replay)
        #expect(live.needsReload)
        // What the replay alone leaves: the calls from before the drop and after the hole.
        #expect(callIDs(live.turn) == ["c1", "c5"])

        // The stored rows after the message before the turn are the turn so far.
        live.takeStored(from: stored, after: 9)
        #expect(!live.needsReload)
        #expect(callIDs(live.turn) == ["c1", "c2", "c3", "c4", "c5"])
        #expect(live.turn.steps.contains { if case .narration(_, let text) = $0 { text == "Two more to go." } else { false } })
        // The call seen live stays as it was seen; the one still running carries on live.
        guard case .tool(let first) = live.turn.steps.first else { Issue.record("no first step"); return }
        #expect(first.duration == 1.4)
        apply(event("tool.complete", seq: 701, #"{"tool_id": "c5", "name": "web_search", "result": "Result 5"}"#), to: &live)
        let last = live.turn.steps.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }.last
        #expect(last?.callID == "c5")
        #expect(last?.status == .succeeded)
    }

    /// A call that started after the drop and isn't stored yet stays after the stored steps.
    @Test func aCallNotStoredYetStaysAfterTheStoredOnes() throws {
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        apply(event("tool.start", seq: 1, #"{"tool_id": "c1", "name": "web_search"}"#), to: &live)
        apply(event("tool.complete", seq: 2, #"{"tool_id": "c1", "name": "web_search", "result": "Result 1"}"#), to: &live)
        apply(event("tool.start", seq: 700, #"{"tool_id": "c6", "name": "web_search"}"#), to: &live)
        live.apply(SequencedTurnEvent(seq: nil, event: .replayTruncated))
        live.takeStored(from: stored, after: 9)
        #expect(callIDs(live.turn) == ["c1", "c2", "c3", "c4", "c5", "c6"])
        #expect(live.isUsingTool)
    }

    /// Words already on screen keep their identity when their stored copy comes in, so they
    /// don't redraw or fade at the re-attach.
    @Test func wordsSeenLiveKeepTheirIdentity() throws {
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        for (seq, type, payload) in [
            (1, "tool.start", #"{"tool_id": "c1", "name": "web_search"}"#),
            (2, "tool.complete", #"{"tool_id": "c1", "name": "web_search", "result": "Result 1"}"#),
            (3, "tool.start", #"{"tool_id": "c2", "name": "web_search"}"#),
            (4, "tool.complete", #"{"tool_id": "c2", "name": "web_search", "result": "Result 2"}"#),
            (5, "message.delta", #"{"text": "Two more to go."}"#),
            (6, "tool.start", #"{"tool_id": "c3", "name": "web_search"}"#),
        ] { apply(event(type, seq: seq, payload), to: &live) }
        let seen = try #require(live.turn.steps.first { if case .narration = $0 { true } else { false } })
        live.apply(SequencedTurnEvent(seq: nil, event: .replayTruncated))
        live.takeStored(from: stored, after: 9)
        #expect(callIDs(live.turn) == ["c1", "c2", "c3", "c4", "c5"])
        let narration = live.turn.steps.filter { if case .narration = $0 { true } else { false } }
        #expect(narration.map(\.id) == [seen.id])
    }

    /// A call running when the socket dropped that finished in the hole takes its stored end,
    /// rather than running on until the turn ends; reasoning Hermes didn't store stays where it was.
    @Test func aCallThatEndedInTheHoleTakesItsStoredEnd() throws {
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        apply(event("reasoning.delta", seq: 1, #"{"text": "Reading every source in turn."}"#), to: &live)
        apply(event("tool.start", seq: 2, #"{"tool_id": "c1", "name": "web_search"}"#), to: &live)
        apply(event("tool.complete", seq: 3, #"{"tool_id": "c1", "name": "web_search", "result": "Result 1"}"#), to: &live)
        apply(event("tool.start", seq: 4, #"{"tool_id": "c2", "name": "web_search"}"#), to: &live)
        apply(event("tool.start", seq: 700, #"{"tool_id": "c5", "name": "web_search"}"#), to: &live)
        live.apply(SequencedTurnEvent(seq: nil, event: .replayTruncated))
        live.takeStored(from: stored, after: 9)
        #expect(callIDs(live.turn) == ["c1", "c2", "c3", "c4", "c5"])
        let tools = live.turn.steps.compactMap { if case .tool(let tool) = $0 { tool } else { nil } }
        #expect(tools.map(\.status) == [.succeeded, .succeeded, .succeeded, .succeeded, .running])
        #expect(tools[1].result == "Result 2")
        guard case .reasoning(_, let text)? = live.turn.steps.first else { Issue.record("no reasoning first"); return }
        #expect(text == "Reading every source in turn.")
    }

    /// A turn joined after the drop with no call of its own yet: what streamed in after the hole
    /// (reasoning not stored yet) stays after the stored steps.
    @Test func aTurnWithNoCallKeepsWhatStreamedAfterTheHole() {
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        apply(event("reasoning.delta", seq: 700, #"{"text": "Weighing the five sources."}"#), to: &live)
        live.apply(SequencedTurnEvent(seq: nil, event: .replayTruncated))
        live.takeStored(from: stored, after: 9)
        #expect(callIDs(live.turn) == ["c1", "c2", "c3", "c4", "c5"])
        guard case .reasoning(_, let text)? = live.turn.steps.last else { Issue.record("no reasoning last"); return }
        #expect(text == "Weighing the five sources.")
    }

    /// Nothing of the turn stored yet: there's nothing to take, and never the turn before's reply.
    /// The turn stays marked, and its end reads the chat as always.
    @Test func nothingStoredYetIsNoStoredPart() {
        #expect(LiveTurn.storedPart(of: Array(stored.prefix(3)), after: 9) == nil)
        #expect(LiveTurn.storedPart(of: Array(stored.prefix(2)), after: 9) == nil)
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        apply(event("tool.start", seq: 700, #"{"tool_id": "c1", "name": "web_search"}"#), to: &live)
        live.apply(SequencedTurnEvent(seq: nil, event: .replayTruncated))
        live.takeStored(from: Array(stored.prefix(3)), after: 9)
        #expect(live.needsReload)
        #expect(callIDs(live.turn) == ["c1"])
    }

    /// After a gateway restart the numbering starts again (a new epoch): an empty replay with
    /// nothing missing, so nothing is read again (the app replays only on the same runtime anyway).
    @Test func aRestartsEmptyReplayIsntTruncated() throws {
        let answer = JSONValue.parse(#"{"events": [], "latest_seq": 0, "truncated": false, "count": 0, "epoch": "e2", "open_requests": []}"#)!
        let replay = try #require(EventReplay(answer, runtime: "rt"))
        #expect(!replay.truncated)
        #expect(replay.events.isEmpty)
        var live = LiveTurn(id: "live", sessionID: "stored", startedAt: at(-120))
        live.note(replay)
        #expect(!live.needsReload)
        #expect(EventReplay(.object([:]), runtime: "rt") == nil)
    }
}
