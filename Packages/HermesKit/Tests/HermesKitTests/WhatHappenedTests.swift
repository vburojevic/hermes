import Foundation
import Testing
@testable import HermesKit

/// Lines that say in plain words what happened: a turn with tools and no reply, background
/// processes and helpers finishing, messages between Bots (`docs/chat.md` §1, §2a).
@Suite("What happened")
struct WhatHappenedTests {
    private func row(_ id: Int, _ role: String, _ text: String, kind: String? = nil, calls: [ToolCall] = [],
                     callID: String? = nil, tool: String? = nil) -> SessionMessage {
        var message = SessionMessage(id: id, role: role, content: .text(text), toolCalls: calls, toolCallID: callID, toolName: tool,
                                     timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 + id)), displayKind: kind)
        message.finishReason = calls.isEmpty ? "stop" : "tool_calls"
        return message
    }

    private func call(_ id: String, _ name: String, _ arguments: String) -> ToolCall {
        ToolCall(id: id, name: name, arguments: arguments)
    }

    private func turns(_ items: [TranscriptItem]) -> [AssistantTurn] {
        items.compactMap { if case .assistant(let turn) = $0 { turn } else { nil } }
    }

    // MARK: A turn with tools and no reply

    @Test func aTurnWithToolsAndNoReplySaysWhatItDid() throws {
        let messages = [
            row(1, "user", "[IMPORTANT: Background process proc_a1 completed normally (exit code 0).]"),
            row(2, "assistant", "", calls: [call("c1", "terminal", #"{"command":"python3 -B -m unittest discover -s tests"}"#),
                                             call("c2", "terminal", #"{"command":"git fetch origin"}"#)]),
            row(3, "tool", #"{"output":"OK","exit_code":0}"#, callID: "c1", tool: "terminal"),
            row(4, "tool", #"{"output":"","exit_code":0}"#, callID: "c2", tool: "terminal"),
            row(5, "assistant", "[SILENT]"),
        ]
        let turn = try #require(turns(TranscriptBuilder.build(messages, hidesSilence: true)).first)
        #expect(turn.keptQuiet)
        #expect(WorkLine.text(for: turn) == "Ran the tests and a command · no reply needed")
        // Without the marker it only says there was none.
        let plain = try #require(turns(TranscriptBuilder.build(Array(messages.dropLast()))).first)
        #expect(WorkLine.text(for: plain) == "Ran the tests and a command · no reply")
    }

    @Test func theLineNamesTwoKindsOfWorkThenCountsTheRest() {
        func tool(_ name: String, _ command: String? = nil) -> AssistantStep {
            var activity = ToolActivity(id: UUID().uuidString, name: name, status: .succeeded)
            if let command { activity.arguments = .object(["command": .string(command)]) }
            return .tool(activity)
        }
        var turn = AssistantTurn(id: "t", steps: [tool("read_file"), tool("read_file"), tool("terminal", "ls")])
        #expect(WorkLine.text(for: turn) == "Read 2 files and ran a command · no reply")
        turn.steps += [tool("web_search"), tool("patch")]
        #expect(WorkLine.text(for: turn) == "Read 2 files, ran a command and 2 more · no reply")
        turn.steps = [tool("message_agent")]
        #expect(WorkLine.text(for: turn) == "Messaged a Bot · no reply")
        turn.steps = [tool("terminal", "swift build -c release"), tool("terminal", "make test")]
        #expect(WorkLine.text(for: turn) == "Ran a build and the tests · no reply")
    }

    @Test func aTurnThatSaidSomethingOrRunsHasNoLine() {
        let step = AssistantStep.tool(ToolActivity(id: "a", name: "terminal", status: .succeeded))
        #expect(WorkLine.text(for: AssistantTurn(id: "t", steps: [step], answer: "Done.")) == nil)
        #expect(WorkLine.text(for: AssistantTurn(id: "t", steps: [step, .narration(id: "n", text: "Checking")])) == nil)
        #expect(WorkLine.text(for: AssistantTurn(id: "t", steps: [step], state: .streaming)) == nil)
        #expect(WorkLine.text(for: AssistantTurn(id: "t", steps: [.reasoning(id: "r", text: "Hmm")])) == nil)
    }
}
