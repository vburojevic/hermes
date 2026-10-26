import Foundation
import Testing
@testable import HermesKit

/// A message to another Bot shows what was sent in every shape it reaches the app, and a finished
/// step never draws an empty box (`docs/chat.md` §2a, `docs/background-processes.md` §4).
@Suite("Message steps and empty boxes")
struct MessageStepTests {
    private func decode(_ type: String, _ payload: String) -> [SequencedTurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: nil, payload: JSONValue.parse(payload)!))
    }

    private func tools(_ live: LiveTurn) -> [ToolActivity] {
        live.turn.steps.compactMap { step -> ToolActivity? in
            if case .tool(let tool) = step { tool } else { nil }
        }
    }

    /// The socket's `tool.start` and `tool.complete` carry the call's `args` whole
    /// (tui_gateway/tool_progress.py); the live step used to drop them, so a message sent in a
    /// Bot Chat showed an empty box under "Message to Nutritionist".
    @Test func aLiveMessageKeepsTheWordsItSent() {
        var live = LiveTurn(id: "t", sessionID: "s")
        let args = #"{"target": "nutritionist", "message": "Log two eggs and toast for breakfast."}"#
        for event in decode("tool.start", #"{"tool_id": "c1", "name": "message_agent", "context": null, "args": \#(args)}"#) {
            live.apply(event)
        }
        #expect(tools(live).first.flatMap(BotMessageStep.init)?.text == "Log two eggs and toast for breakfast.")
        let result = #"{"status": "queued", "delivery_id": "d1", "to": "@nutritionist", "reply_delivery": "notification", "process_id": "proc_5a1"}"#
        for event in decode("tool.complete", #"{"tool_id": "c1", "name": "message_agent", "args": \#(args), "result": \#(result), "duration_s": 0.4}"#) {
            live.apply(event)
        }
        let tool = tools(live).first
        #expect(tool?.startedProcessID == "proc_5a1")
        let message = tool.flatMap(BotMessageStep.init)
        #expect(message?.target == "nutritionist")
        #expect(message?.text == "Log two eggs and toast for breakfast.")
    }

    /// Only `tool.complete` carried them (progress was off when it started): the step takes them then.
    @Test func argumentsThatComeOnlyWithTheResultStillCount() {
        var live = LiveTurn(id: "t", sessionID: "s")
        for event in decode("tool.start", #"{"tool_id": "c1", "name": "message_agent"}"#) { live.apply(event) }
        for event in decode("tool.complete", #"{"tool_id": "c1", "name": "message_agent", "args": {"target": "hermes", "message": "Ship it."}, "result": {"status": "queued", "to": "@hermes", "process_id": "proc_9"}}"#) {
            live.apply(event)
        }
        #expect(tools(live).first.flatMap(BotMessageStep.init)?.text == "Ship it.")
    }

    /// A turn that missed events takes its stored rows, and keeps each call it saw as it was
    /// seen: one seen without arguments takes the stored call's, so its words show.
    @Test func aTurnThatTakesItsStoredRowsTakesTheWordsToo() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(SequencedTurnEvent(seq: 1, event: .toolStarted(id: "c1", name: "message_agent", preview: nil, at: nil)))
        live.apply(SequencedTurnEvent(seq: 2, event: .replayTruncated))
        let rows = [
            SessionMessage(id: 2, role: "assistant", content: .text(""),
                           toolCalls: [ToolCall(id: "c1", name: "message_agent", arguments: #"{"target": "hermes", "message": "Ship it."}"#)]),
            SessionMessage(id: 3, role: "tool", content: .text(#"{"status": "queued", "to": "@hermes", "process_id": "proc_1"}"#),
                           toolCallID: "c1", toolName: "message_agent"),
        ]
        for case .assistant(let stored) in TranscriptBuilder.build(rows) { live.takeStored(stored) }
        let tool = tools(live).first
        #expect(tool?.status == .succeeded)
        #expect(tool.flatMap(BotMessageStep.init)?.text == "Ship it.")
    }

    /// Typing into a page keeps what was typed off the step, live as stored (`docs/web.md` §4).
    @Test func typingIntoAPageKeepsItsArgumentsOff() {
        var live = LiveTurn(id: "t", sessionID: "s")
        for event in decode("tool.start", #"{"tool_id": "c1", "name": "browser_type", "args": {"ref": "@e3", "text": "hunter2"}}"#) {
            live.apply(event)
        }
        #expect(tools(live).first?.arguments == nil)
    }

    /// Stored, the arguments are a JSON string; some providers encode them twice.
    @Test func storedRowsInEveryShape() {
        func step(arguments: String) -> BotMessageStep? {
            let rows = [
                SessionMessage(id: 1, role: "user", content: .text("Tell the nutritionist")),
                SessionMessage(id: 2, role: "assistant", content: .text(""),
                               toolCalls: [ToolCall(id: "c1", name: "message_agent", arguments: arguments)]),
                SessionMessage(id: 3, role: "tool", content: .text(#"{"status": "queued", "to": "@nutritionist", "process_id": "proc_1"}"#),
                               toolCallID: "c1", toolName: "message_agent"),
            ]
            for case .assistant(let turn) in TranscriptBuilder.build(rows) {
                for case .tool(let tool) in turn.steps { return BotMessageStep(tool) }
            }
            return nil
        }
        #expect(step(arguments: #"{"target": "nutritionist", "message": "Two eggs."}"#)?.text == "Two eggs.")
        #expect(step(arguments: #""{\"target\": \"nutritionist\", \"message\": \"Two eggs.\"}""#)?.text == "Two eggs.")
        // Cut or broken: no words, and the name still comes from what Hermes answered.
        let broken = step(arguments: #"{"target": "nutritionist", "message": "Two e"#)
        #expect(broken?.text == "")
        #expect(broken?.name(botName: { _ in nil }) == "Nutritionist")
    }

    /// A Bot that runs Hermes itself to send the message: the words are the query.
    @Test func theProcessPathShowsTheQuery() {
        func message(_ command: String) -> BotMessageStep? {
            BotMessageStep(ToolActivity(id: "t", name: "terminal", arguments: .object(["command": .string(command), "background": .bool(true)]),
                                        result: #"{"output": "Background process started", "session_id": "proc_2"}"#, status: .succeeded))
        }
        #expect(message(#"hermes -p nutritionist chat -q "Log two eggs.""#).map { [$0.target, $0.text] } == ["nutritionist", "Log two eggs."])
        #expect(message(#"bash -lc "cd ~ && hermes --profile=hermes chat --query='Ship it.'""#).map { [$0.target, $0.text] } == ["hermes", "Ship it."])
        #expect(message("hermes -p writer chat --query-file /tmp/dm.txt")?.text == "")
        #expect(message("hermes chat -q hi")?.target == "default")
        #expect(message("hermes -p writer gateway status") == nil)
        #expect(message("npm run dev") == nil)
    }

    /// No words, no answer, nothing waited for: the title row alone.
    @Test func aMessageWithNothingToShowHasNoBody() {
        let silent = BotMessageStep(target: "hermes", text: "")
        #expect(!silent.showsBody(hasAnswer: false, delivery: nil))
        #expect(silent.showsBody(hasAnswer: false, delivery: .waiting))
        #expect(silent.showsBody(hasAnswer: true, delivery: .replied))
        #expect(BotMessageStep(target: "hermes", text: "Hi").showsBody(hasAnswer: false, delivery: nil))
    }

    /// A process step's box holds the command or the latest line, never blanks.
    @Test func aProcessStepWithNothingToReadHasNoBox() {
        #expect(ProcessSnippet(command: "", latest: nil).isEmpty)
        #expect(ProcessSnippet(command: "  \n", latest: " ").isEmpty)
        #expect(ProcessSnippet(command: "make release", latest: "").latest == nil)
        #expect(ProcessSnippet(command: "", latest: "Signing Hermes.app").latest == "Signing Hermes.app")
    }

    /// A step opens only to something: blanks are no command, output or result.
    @Test func blanksAreNoDetails() {
        let blank = ToolActivity(id: "a", name: "read_file", preview: "  ", result: " \n ", status: .succeeded)
        #expect(!blank.hasDetails && blank.detailsPreview == nil)
        let silentCommand = ToolActivity(id: "b", name: "terminal", arguments: .object(["command": .string("true")]),
                                         result: #"{"output": "   \n", "exit_code": 0}"#, status: .succeeded)
        #expect(silentCommand.commandOutput == nil)
        let typed = ToolActivity(id: "c", name: "browser_type", result: #"{"success": true, "typed": "hunter2"}"#, status: .succeeded)
        #expect(!typed.hasDetails)
        #expect(ToolActivity(id: "d", name: "web_extract", preview: "example.com", status: .succeeded).hasDetails)
    }
}
