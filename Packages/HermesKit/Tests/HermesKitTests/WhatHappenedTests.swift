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

    // MARK: Background processes

    private func processNotice(_ id: String, _ command: String, exit: Int, output: String, outcome: String = "completed normally") -> String {
        "[IMPORTANT: Background process \(id) \(outcome) (exit code \(exit)).\nCommand: \(command)\nOutput:\n\(output)]"
    }

    @Test func aFinishedProcessSaysWhichAndHowItEnded() throws {
        let tests = try #require(FinishedProcess.parse(processNotice("proc_a", "python3 -B -m unittest discover", exit: 1,
                                                                     output: "\u{1B}[31mFAILED\u{1B}[0m (failures=1)", outcome: "exited")).first)
        #expect(tests.id == "proc_a")
        #expect(tests.outcome == .failed(exitCode: 1))
        #expect(tests.output == "FAILED (failures=1)")
        #expect(tests.line() == "Tests failed · exit 1")
        #expect(tests.isFailure)
        let fetch = try #require(FinishedProcess.parse(processNotice("proc_b", "git fetch origin", exit: 0, output: "")).first)
        #expect(fetch.line() == "git fetch finished")
        let stopped = FinishedProcess.parse("[IMPORTANT: Background process proc_c terminated by Hermes (exit code -15, SIGTERM).\nCommand: npm run dev\nOutput:\nbye]")
        #expect(stopped.first?.line() == "Dev server was stopped")
        let watch = FinishedProcess.parse("[IMPORTANT: Background process proc_d matched watch pattern \"ERROR\".\nCommand: tail -f app.log\nMatched output:\nERROR disk full\n(2 earlier matches were suppressed by rate limit)]")
        #expect(watch.first?.outcome == .matched(pattern: "ERROR"))
        #expect(watch.first?.output == "ERROR disk full")
        #expect(watch.first?.line() == "Watching app.log printed “ERROR”")
    }

    /// Hermes batches completions that land together, and appends a footer on messaging platforms.
    @Test func aBatchNamesEachProcess() {
        let batch = "[IMPORTANT: 2 background processes completed. Treat these results as one batch and give one consolidated response; preserve failures and actionable results.]\n\n"
            + processNotice("proc_a", "make test", exit: 0, output: "ok\n\nall good") + "\n\n" + processNotice("proc_b", "swift build", exit: 2, output: "error", outcome: "exited")
            + "\n\n[INTERNAL NOTIFICATION — generated by the Hermes gateway, not written by a human user.]"
        let processes = FinishedProcess.parse(batch)
        #expect(processes.map(\.id) == ["proc_a", "proc_b"])
        #expect(processes.first?.output == "ok\n\nall good")
        #expect(Notice.finishedLine(processes.map(FinishedWork.process)) == "2 background processes finished · 1 failed")
    }

    /// A message to another Bot is delivered by a background process; its completion carries the reply.
    @Test func aDeliveryCarriesTheBotsReply() {
        let runner = "/Users/sam/.hermes/hermes-agent/venv/bin/python /Users/sam/.hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery query-file /tmp/dm.json /Users/sam/.local/bin/hermes -p engineer chat -Q"
        let relay = FinishedProcess.parse(processNotice("proc_e", runner, exit: 0, output: "Reply from Engineer:\nAll green."))[0]
        #expect(relay.recipient == "engineer")
        #expect(relay.answer == .replied("All green."))
        #expect(relay.line() == "Engineer replied")
        #expect(relay.line(botName: { $0 == "engineer" ? "Eng" : nil }) == "Eng replied")
        let live = FinishedProcess.parse(processNotice("proc_f", runner, exit: 0, output: #"{"reply": "On it.", "status": "settled", "delivery_id": "dm_1"}"#))[0]
        #expect(live.answer == .replied("On it."))
        let plain = FinishedProcess.parse(processNotice("proc_g", runner, exit: 0, output: "Sure, done."))[0]
        #expect(plain.answer == .replied("Sure, done."))
        let failed = FinishedProcess.parse(processNotice("proc_h", runner, exit: 1, output: "Delivery to Engineer failed [reason: target_busy]: engineer is busy", outcome: "exited"))[0]
        #expect(failed.answer == .failed("Engineer is busy"))
        #expect(failed.line() == "Your message to Engineer wasn't delivered")
        #expect(failed.isFailure)
        #expect(Notice.finishedLine([relay, live].map(FinishedWork.process)) == "Engineer replied 2 times")
    }

    @Test func noticesInARowFoldIntoOneLine() throws {
        let messages = [
            row(1, "user", "Check things"),
            row(2, "assistant", "Started."),
            row(3, "user", processNotice("proc_a", "make test", exit: 0, output: "ok"), kind: "process_complete"),
            // Untagged, as Hermes's one-shot `hermes chat` stores it.
            row(4, "user", processNotice("proc_b", "make build", exit: 0, output: "ok")),
            row(5, "assistant", "[SILENT]"),
            row(6, "user", processNotice("proc_c", "npm run dev", exit: 1, output: "x", outcome: "exited"), kind: "internal_notification"),
            row(7, "assistant", "The dev server died."),
            row(8, "user", processNotice("proc_d", "make lint", exit: 0, output: ""), kind: "process_complete"),
        ]
        let items = TranscriptBuilder.build(messages, hidesSilence: true)
        let notices = items.compactMap { if case .notice(let notice) = $0 { notice } else { nil } }
        #expect(notices.count == 2)
        // The silent reply between the first three is gone, so they fold; the reply after breaks the run.
        #expect(notices[0].id == "m3")
        #expect(notices[0].work.count == 3)
        #expect(notices[0].text == "3 background processes finished · 1 failed")
        #expect(notices[1].text == "Build finished")
        #expect(TranscriptBuilder.turn(startingProcess: "proc_a", in: items) == nil)
        #expect(TranscriptBuilder.finished(process: "proc_c", in: items)?.outcome == .failed(exitCode: 1))
    }

    // MARK: Helpers

    @Test func helpersFinishedNameThemAndTheirOutcome() {
        let batch = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_1]
        A background fan-out unit you dispatched earlier — 2 subagent(s) — has finished.

        Role: leaf   Model: m   Total duration: 20s

        --- ✓ TASK 1/2: Research pricing pages  (status=completed, api_calls=4, 12s) ---
        Three of five show yearly prices first.
        Full live transcript (complete tool/assistant trace): /tmp/t1.jsonl

        --- ✗ TASK 2/2: Review the draft  (status=timeout, 600s) ---
        (no summary — status=timeout: hit the 600s limit)
        """
        let helpers = FinishedHelper.parse(batch)
        #expect(helpers.map(\.goal) == ["Research pricing pages", "Review the draft"])
        #expect(helpers[0].result == "Three of five show yearly prices first.")
        #expect(helpers[1].status == "timeout")
        #expect(helpers[1].result == "Hit the 600s limit.")
        #expect(Notice.finishedLine(helpers.map(FinishedWork.helper)) == "2 helpers finished: Research pricing pages, Review the draft · 1 failed")

        let single = """
        [ASYNC DELEGATION COMPLETE — deleg_2]
        A background subagent you dispatched earlier has finished.

        Original goal: Find the flaky test
        Status: completed   API calls: 3   Duration: 40s
        --- RESULT ---
        It's test_sync; it sleeps 1 s.
        """
        let one = FinishedHelper.parse(single)
        #expect(one == [FinishedHelper(goal: "Find the flaky test", status: "completed", result: "It's test_sync; it sleeps 1 s.")])
        #expect(Notice.finishedLine(one.map(FinishedWork.helper)) == "Helper finished: Find the flaky test")
        let items = TranscriptBuilder.build([row(1, "user", single, kind: "async_delegation_complete"), row(2, "user", batch, kind: "async_delegation_complete")])
        guard case .notice(let notice)? = items.first else { Issue.record("no notice"); return }
        #expect(notice.work.count == 3)
        #expect(notice.text == "3 helpers finished: Find the flaky test, Research pricing pages, Review the draft · 1 failed")
    }

    // MARK: Messages between Bots

    @Test func aMessageStepShowsItsWordsAndItsAnswer() throws {
        var tool = ToolActivity(id: "c:1", callID: "1", name: "message_agent", status: .succeeded)
        tool.arguments = .object(["target": .string("engineer"), "message": .string("Run the tests, please.")])
        tool.result = #"{"status": "queued", "to": "@engineer", "process_id": "proc_x", "reply_delivery": "notification"}"#
        let step = try #require(BotMessageStep(tool))
        #expect(step.text == "Run the tests, please.")
        #expect(step.recipientName == "engineer")
        #expect(step.name(botName: { _ in nil }) == "Engineer")
        #expect(step.name(botName: { $0 == "engineer" ? "Engineer" : nil }) == "Engineer")
        #expect(tool.startedProcessID == "proc_x")
        #expect(tool.startedProcessName == "Message to Engineer")
        var reply = UserEntry(id: "u2", text: "All green.", sender: AgentSender(name: "Engineer", handle: "engineer"))
        reply.timestamp = nil
        let items: [TranscriptItem] = [.assistant(AssistantTurn(id: "t1", steps: [.tool(tool)])), .user(reply)]
        #expect(step.reply(in: items, sentBy: "c:1")?.text == "All green.")
        #expect(TranscriptBuilder.turn(startingProcess: "proc_x", in: items)?.id == "t1")
        #expect(Delivery.answering(in: items + [.assistant(AssistantTurn(id: "t2", answer: "Thanks."))]) == ["t2": .bot(AgentSender(name: "Engineer", handle: "engineer"))])

        tool.result = #"{"error": "target_busy: profile 'engineer' is busy with another message. Try later.", "reason": "target_busy"}"#
        #expect(BotMessageStep(tool)?.error == "Engineer is busy with another message.")
    }

    /// The step says where the message stands, not what its delivery process did
    /// (`processStepMessage`): "Replied · 4 min", "Waiting · 2 min", "Not delivered".
    @Test func aMessageStepSaysWhetherItWasAnswered() {
        #expect(BotMessageStep.delivery(state: .running, replied: false, failed: false) == .waiting)
        #expect(BotMessageStep.delivery(state: .finished, replied: true, failed: false) == .replied)
        // A reply found in the chat counts, whatever the process list says now.
        #expect(BotMessageStep.delivery(state: .ended, replied: true, failed: false) == .replied)
        #expect(BotMessageStep.delivery(state: nil, replied: true, failed: false) == .replied)
        #expect(BotMessageStep.delivery(state: .finished, replied: false, failed: true) == .notDelivered)
        #expect(BotMessageStep.delivery(state: .failed, replied: false, failed: false) == .notDelivered)
        // Ended some other way, or not listed yet: the process's own state says it.
        #expect(BotMessageStep.delivery(state: .stopped, replied: false, failed: false) == nil)
        #expect(BotMessageStep.delivery(state: .finished, replied: false, failed: false) == nil)
        #expect(BotMessageStep.delivery(state: nil, replied: false, failed: false) == nil)

        #expect(BotMessageStep.stateLabel(.replied, duration: 240) == "Replied · 4 min")
        #expect(BotMessageStep.stateLabel(.waiting, duration: 130) == "Waiting · 2 min")
        #expect(BotMessageStep.stateLabel(.waiting, duration: nil) == "Waiting")
        #expect(BotMessageStep.stateLabel(.notDelivered, duration: 30) == "Not delivered")
    }

    @Test func aMachineStyleBriefFoldsToItsSummary() {
        let brief = "[HANDOFF] Release 2.4 notes: status and open items\n\n## Status\nDraft written.\n\n## Done\n- Draft\n- Screenshots\n\n"
            + "## Open items\n- Owner: you. Decide on the bug number.\n\n## Facts\nRelease: 2.4\nDeadline: 09:00\nChannel: blog\n"
            + String(repeating: "More detail about the release that runs on. ", count: 14)
        #expect(HandoffBrief.summary(brief) == "Release 2.4 notes: status and open items")
        let headed = "## Sync audit\nThe sync audit is done and the results are below for you.\n\n## Findings\n" + String(repeating: "- A finding that matters\n", count: 30)
        #expect(HandoffBrief.summary(headed) == "Sync audit")
        // A long message in plain sentences is a message: it folds to a few lines instead.
        let prose = String(repeating: "I looked at the logs and nothing stood out, so I left it running. ", count: 14)
        #expect(HandoffBrief.summary(prose) == nil)
        #expect(LongText.isLong(prose))
        #expect(!LongText.isLong("Short and sweet."))
        #expect(LongText.tail("a\nb\nc", lines: 2) == ("b\nc", 1))
    }
}
