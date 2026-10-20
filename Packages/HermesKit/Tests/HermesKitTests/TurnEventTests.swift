import Foundation
import Testing
@testable import HermesKit

@Suite("Turn event decoding")
struct TurnEventDecodingTests {
    private func runFrames(_ lines: String) -> [SequencedTurnEvent] {
        var parser = ServerSentEventParser()
        return parser.consume(Array(lines.utf8)).flatMap(RunEventDecoder.decode)
    }

    private func sessionFrames(_ lines: String) -> [SequencedTurnEvent] {
        var parser = ServerSentEventParser()
        return parser.consume(Array(lines.utf8)).flatMap(SessionStreamDecoder.decode)
    }

    @Test func runEventsCarrySeqAndToolDetails() {
        let events = runFrames("""
        : open

        id: 0
        data: {"event": "tool.started", "run_id": "run_1", "timestamp": 1760200000.0, "tool": "terminal", "preview": "ls -la", "seq": 0}

        id: 1
        data: {"event": "tool.completed", "run_id": "run_1", "timestamp": 1760200001.5, "tool": "terminal", "duration": 1.5, "error": false, "preview": "a.txt", "seq": 1}

        id: 2
        data: {"event": "message.delta", "run_id": "run_1", "timestamp": 1760200002.0, "delta": "Done", "seq": 2}

        id: 3
        data: {"event": "run.completed", "run_id": "run_1", "timestamp": 1760200003.0, "output": "Done.", "usage": {"input_tokens": 10, "output_tokens": 2, "total_tokens": 12}, "runtime": {"provider": "nous", "model": "x", "route_source": "global"}, "seq": 3}

        : stream closed


        """)
        #expect(events.map(\.seq) == [0, 1, 2, 3])
        #expect(events[0].event == .toolStarted(id: nil, name: "terminal", preview: "ls -la", at: Date(timeIntervalSince1970: 1760200000)))
        #expect(events[1].event == .toolFinished(id: nil, name: "terminal", failed: false, duration: 1.5, resultPreview: "a.txt", at: Date(timeIntervalSince1970: 1760200001.5)))
        #expect(events[2].event == .textDelta("Done"))
        guard case .completed(let output, let usage, let runtime) = events[3].event else {
            Issue.record("expected completion")
            return
        }
        #expect(output == "Done.")
        #expect(usage?.totalTokens == 12)
        #expect(runtime?.provider == "nous")
    }

    @Test func runApprovalAndFailures() {
        let events = runFrames("""
        id: 4
        data: {"event": "approval.request", "run_id": "run_1", "command": "rm -rf ./build", "description": "Recursive delete", "request_id": "abc", "choices": ["once", "session", "always", "deny"], "seq": 4}

        id: 5
        data: {"event": "approval.responded", "choice": "once", "request_id": "abc", "resolved": 1, "seq": 5}

        id: 6
        data: {"event": "run.failed", "error": "boom", "seq": 6}


        """)
        #expect(events.map(\.event) == [
            .approvalRequested(ApprovalRequest(requestID: "abc", command: "rm -rf ./build", description: "Recursive delete", choices: [.once, .session, .always, .deny])),
            .approvalResolved(requestID: "abc"),
            .failed("boom"),
        ])
    }

    @Test func internalToolsAreHidden() {
        let events = runFrames("data: {\"event\": \"tool.started\", \"tool\": \"_thinking\", \"seq\": 1}\n\n")
        #expect(events.isEmpty)
    }

    @Test func sessionStreamLifecycle() {
        let events = sessionFrames("""
        event: run.started
        data: {"user_message": {"role": "user", "content": "hi"}, "runtime": {"provider": "", "model": "", "route_source": "global"}, "session_id": "s1", "run_id": "run_9", "seq": 1, "ts": 1760200000.01}

        event: message.started
        data: {"message": {"id": "msg_1", "role": "assistant"}, "session_id": "s1", "run_id": "run_9", "seq": 2, "ts": 1760200000.02}

        event: tool.started
        data: {"message_id": "msg_1", "tool_name": "web_search", "preview": "swift 6", "args": {"query": "swift 6"}, "session_id": "s1", "run_id": "run_9", "seq": 3, "ts": 1760200001.0}

        event: tool.failed
        data: {"message_id": "msg_1", "tool_name": "web_search", "preview": null, "args": null, "session_id": "s1", "run_id": "run_9", "seq": 4, "ts": 1760200002.0}

        event: assistant.delta
        data: {"message_id": "msg_1", "delta": "Hé", "session_id": "s1", "run_id": "run_9", "seq": 5, "ts": 1760200003.0}

        event: assistant.completed
        data: {"session_id": "s2", "message_id": "msg_1", "content": "Héllo", "completed": true, "partial": false, "interrupted": false, "run_id": "run_9", "seq": 6, "ts": 1760200004.0}

        event: run.completed
        data: {"session_id": "s2", "message_id": "msg_1", "completed": true, "messages": [], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}, "runtime": {"provider": "nous"}, "run_id": "run_9", "seq": 7, "ts": 1760200004.0}

        event: done
        data: {"session_id": "s2", "run_id": "run_9", "seq": 8, "ts": 1760200004.0}


        """)
        let kinds = events.map(\.event)
        #expect(kinds.first == .runStarted(runID: "run_9"))
        #expect(kinds.contains(.toolStarted(id: nil, name: "web_search", preview: "swift 6", at: Date(timeIntervalSince1970: 1760200001))))
        #expect(kinds.contains(.toolFinished(id: nil, name: "web_search", failed: true, duration: nil, resultPreview: nil, at: Date(timeIntervalSince1970: 1760200002))))
        #expect(kinds.contains(.textDelta("Hé")))
        #expect(kinds.contains(.finalText("Héllo")))
        #expect(kinds.contains(.sessionChanged("s2")))
        #expect(events.last?.seq == 7)
    }

    @Test func sessionStreamErrorIsTerminal() {
        let events = sessionFrames("event: error\ndata: {\"message\": \"provider exploded\", \"seq\": 3}\n\n")
        #expect(events.map(\.event) == [.failed("provider exploded")])
    }

    @Test func approvalChoicesFallBackToFlags() throws {
        let smart = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"command":"x","smart_denied":true}"#.utf8))
        #expect(smart.choices == [.once, .deny])
        let noSession = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"command":"x","allow_session":false,"allow_permanent":true}"#.utf8))
        #expect(noSession.choices == [.once, .always, .deny])
        let consent = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"command":"","description":"Allow MCP write?","choices":["once"]}"#.utf8))
        #expect(consent.choices == [.once, .deny])
        #expect(consent.summary == "Allow MCP write?")
    }
}

@Suite("Live turn")
struct LiveTurnTests {
    private func event(_ event: TurnEvent, _ seq: Int? = nil) -> SequencedTurnEvent {
        SequencedTurnEvent(seq: seq, event: event)
    }

    /// A step is the same view live and stored: both are keyed by Hermes's call id, so a reply
    /// handing over to its stored rows doesn't close what was open or redraw its cards.
    @Test func aStepKeepsItsIdentityFromLiveToStored() throws {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(event(.toolStarted(id: "toolu_01AB", name: "terminal", preview: "ls", at: nil), 1))
        live.apply(event(.toolStarted(id: "toolu_01CD", name: "read_file", preview: "a.md", at: nil), 2))
        live.apply(event(.toolStarted(id: nil, name: "terminal", preview: "pwd", at: nil), 3))
        let liveIDs = live.snapshot.steps.map(\.id)
        #expect(liveIDs[0] == "c:toolu_01AB" && liveIDs[1] == "c:toolu_01CD")
        #expect(liveIDs[2] == "t-s2") // no call id: by position

        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id": 1, "role": "user", "content": "go"},
         {"id": 2, "role": "assistant", "content": "", "tool_calls": [
           {"id": "toolu_01AB", "type": "function", "function": {"name": "terminal", "arguments": "{}"}},
           {"id": "toolu_01CD", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
         {"id": 3, "role": "tool", "tool_call_id": "toolu_01AB", "tool_name": "terminal", "content": "ok"},
         {"id": 4, "role": "tool", "tool_call_id": "toolu_01CD", "tool_name": "read_file", "content": "text"},
         {"id": 5, "role": "assistant", "content": "Done."}]
        """#.utf8))
        let stored = TranscriptBuilder.build(rows).compactMap { item -> AssistantTurn? in
            if case .assistant(let turn) = item { turn } else { nil }
        }.flatMap(\.steps).map(\.id)
        #expect(Array(stored.prefix(2)) == ["c:toolu_01AB", "c:toolu_01CD"])
    }

    @Test func narrationBeforeToolsAndAnswerAfter() {
        var live = LiveTurn(id: "t", sessionID: "s")
        let start = Date(timeIntervalSince1970: 100)
        live.apply(event(.runStarted(runID: "run_1"), 0))
        live.apply(event(.textDelta("Let me check. "), 1))
        live.apply(event(.toolStarted(id: nil, name: "terminal", preview: "ls", at: start), 2))
        #expect(live.snapshot.steps.count == 2)
        #expect(live.snapshot.answer.isEmpty)
        live.apply(event(.toolFinished(id: nil, name: "terminal", failed: false, duration: nil, resultPreview: nil, at: start.addingTimeInterval(2)), 3))
        live.apply(event(.textDelta("Here are "), 4))
        live.apply(event(.textDelta("the files."), 5))
        #expect(live.snapshot.answer == "Here are the files.")
        live.apply(event(.completed(output: "Here are the files.", usage: nil, runtime: nil), 6))

        #expect(live.runID == "run_1")
        #expect(live.lastSeq == 6)
        #expect(live.isFinished)
        #expect(live.turn.state == .complete)
        #expect(live.turn.answer == "Here are the files.")
        guard case .narration(_, let narration) = live.turn.steps[0], case .tool(let tool) = live.turn.steps[1] else {
            Issue.record("unexpected steps \(live.turn.steps)")
            return
        }
        #expect(narration == "Let me check.")
        #expect(tool.status == .succeeded)
        #expect(tool.duration == 2)
    }

    @Test func completionOutputBackfillsMissedDeltas() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(event(.completed(output: "Final answer", usage: nil, runtime: nil)))
        #expect(live.turn.answer == "Final answer")
    }

    @Test func approvalTogglesState() {
        var live = LiveTurn(id: "t", sessionID: "s")
        let request = ApprovalRequest(requestID: "r", command: "rm x", description: nil, choices: [.once, .deny])
        live.apply(event(.approvalRequested(request)))
        #expect(live.turn.state == .waitingForApproval)
        #expect(live.approval == request)
        live.apply(event(.approvalResolved(requestID: "r")))
        #expect(live.turn.state == .streaming)
        #expect(live.approval == nil)
    }

    @Test func activityAfterAnUnansweredApprovalClearsIt() {
        var live = LiveTurn(id: "t", sessionID: "s")
        let request = ApprovalRequest(requestID: "r", command: "rm x", description: nil, choices: [.once, .deny])
        live.apply(event(.toolStarted(id: nil, name: "terminal", preview: "rm x", at: nil)))
        live.apply(event(.approvalRequested(request)))
        // A parallel tool finishing must not hide the card.
        live.apply(event(.toolFinished(id: nil, name: "web_search", failed: false, duration: 1, resultPreview: nil, at: nil)))
        #expect(live.approval == request)
        #expect(live.turn.state == .waitingForApproval)
        // Server-side timeout denies it; the tool finishes blocked and the model writes again.
        live.apply(event(.toolFinished(id: nil, name: "terminal", failed: true, duration: nil, resultPreview: "BLOCKED", at: nil)))
        live.apply(event(.textDelta("Okay, skipped.")))
        #expect(live.approval == nil)
        #expect(live.turn.state == .streaming)
    }

    @Test func cancellationFailsRunningTools() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(event(.toolStarted(id: nil, name: "terminal", preview: nil, at: nil)))
        live.apply(event(.cancelled))
        #expect(live.turn.state == .stopped)
        guard case .tool(let tool) = live.turn.steps.first else {
            Issue.record("missing tool")
            return
        }
        #expect(tool.status == .failed)
    }

    @Test func compressionAdoptsNewSession() {
        var live = LiveTurn(id: "t", sessionID: "old")
        live.apply(event(.sessionChanged("new")))
        #expect(live.sessionID == "new")
    }

    @Test func alreadyStreamedCommentaryIsNotDuplicated() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(event(.textDelta("Working on it")))
        live.apply(event(.commentary("Working on it", alreadyStreamed: true)))
        live.apply(event(.commentary("Fetching data", alreadyStreamed: false)))
        let narrations = live.turn.steps.compactMap { step -> String? in
            if case .narration(_, let text) = step { text } else { nil }
        }
        #expect(narrations == ["Working on it", "Fetching data"])
    }
}
