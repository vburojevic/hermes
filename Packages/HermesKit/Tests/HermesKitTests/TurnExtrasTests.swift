import Foundation
import Testing
@testable import HermesKit

@Suite("Turn extras")
struct TurnExtrasTests {
    private func decode(_ type: String, _ payload: String) -> [TurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: 1, payload: JSONValue.parse(payload)!)).map(\.event)
    }

    @Test func planUpdatesBecomeThePlan() {
        let events = decode("todo.updated", #"{"todos":[{"id":"1","content":"Read the code","status":"completed"},{"id":"2","content":"Fix it","status":"in_progress"}],"revision":2}"#)
        #expect(events == [.plan([
            PlanItem(id: "1", content: "Read the code", status: .completed),
            PlanItem(id: "2", content: "Fix it", status: .inProgress),
        ])])
    }

    @Test func planToolIsNotAStep() {
        #expect(decode("tool.start", #"{"tool_id":"c1","name":"todo_list"}"#).isEmpty)
    }

    @Test func toolCompleteCarriesDiffAndOutput() {
        let events = decode("tool.complete", #"{"tool_id":"c2","name":"patch","duration_s":0.3,"result":"{}","inline_diff":"-a\n+b","result_text":"ok"}"#)
        #expect(events.contains(.toolDetails(id: "c2", name: "patch", diff: "-a\n+b", output: "ok")))
    }

    @Test func liveTurnKeepsDetailsPlanUsageAndWarning() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(SequencedTurnEvent(seq: 1, event: .toolStarted(id: "c2", name: "patch", preview: "a.swift", at: nil)))
        live.apply(SequencedTurnEvent(seq: 2, event: .toolFinished(id: "c2", name: "patch", failed: false, duration: 0.3, resultPreview: nil, at: nil)))
        live.apply(SequencedTurnEvent(seq: 3, event: .toolDetails(id: "c2", name: "patch", diff: "-a\n+b", output: nil)))
        live.apply(SequencedTurnEvent(seq: 4, event: .plan([PlanItem(id: "1", content: "Edit", status: .completed)])))
        live.apply(SequencedTurnEvent(seq: 5, event: .warning("Cut short")))
        live.apply(SequencedTurnEvent(seq: 6, event: .warning("Threshold lowered")))
        live.apply(SequencedTurnEvent(seq: 7, event: .warning("Cut short")))
        live.apply(SequencedTurnEvent(seq: 8, event: .completed(output: "Done", usage: TokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12), runtime: nil)))
        guard case .tool(let tool)? = live.turn.steps.first else { Issue.record("no tool"); return }
        #expect(tool.diff == "-a\n+b")
        #expect(live.turn.plan.count == 1)
        #expect(live.turn.warning == "Cut short\n\nThreshold lowered")
        #expect(live.turn.usage?.totalTokens == 12)
    }

    @Test(arguments: [
        #"{"input_tokens":1830,"output_tokens":412,"total_tokens":2242}"#,
        #"{"input":1830,"output":412,"total":2242,"cost_usd":0.04,"context_percent":31.0}"#,
    ])
    func usageDecodesBothShapes(json: String) throws {
        let usage = try JSONDecoder().decode(TokenUsage.self, from: Data(json.utf8))
        #expect(usage.inputTokens == 1830)
        #expect(usage.totalTokens == 2242)
    }

    @Test func storedPlanToolBuildsThePlanNotAStep() {
        let messages = [
            SessionMessage(role: "user", content: .text("Fix it")),
            SessionMessage(role: "assistant", content: .text(""), toolCalls: [
                ToolCall(id: "c1", name: "todo_list", arguments: #"{"todos":[{"id":"1","content":"Fix it","status":"completed"}]}"#),
            ]),
            SessionMessage(role: "tool", content: .text(#"{"todos":[]}"#), toolCallID: "c1", toolName: "todo_list"),
            SessionMessage(role: "assistant", content: .text("Fixed.")),
        ]
        let items = TranscriptBuilder.build(messages)
        guard case .assistant(let turn)? = items.last else { Issue.record("no turn"); return }
        #expect(turn.plan.map(\.content) == ["Fix it"])
        #expect(turn.steps.isEmpty)
    }

    @Test func patchArgumentsBecomeADiff() {
        var tool = ToolActivity(id: "x", name: "patch", status: .succeeded)
        tool.arguments = JSONValue.parse(#"{"path":"a.swift","old_string":"old","new_string":"new"}"#)
        #expect(tool.displayDiff == "--- a/a.swift\n+++ b/a.swift\n-old\n+new")
    }

    @Test func terminalResultBecomesCommandOutput() {
        var tool = ToolActivity(id: "x", name: "terminal", status: .succeeded)
        tool.result = #"{"output":"line 1\nline 2","exit_code":1}"#
        #expect(tool.commandOutput == CommandOutput(text: "line 1\nline 2", exitCode: 1))
        #expect(tool.commandOutput?.failed == true)
    }

    @Test func numberedSearchResultsParse() {
        var tool = ToolActivity(id: "x", name: "web_search", status: .succeeded)
        tool.result = "1. Swift 6.4 release notes — swift.org\n2. Region-based isolation — forums.swift.org"
        #expect(tool.searchResults.map(\.title) == ["Swift 6.4 release notes", "Region-based isolation"])
        #expect(tool.searchResults.first?.site == "swift.org")
    }

    @Test func attachedFilesFoldIntoNames() {
        let text = "Summarise these\n@file:/home/me/.hermes/uploads/ab12/build.log\n" + AttachedFiles.pdfNote(name: "notes.pdf") + "\n"
            + AttachedFiles.inline(name: "a \"b\".txt", contents: "hello\nworld")
        let result = AttachedFiles.extract(from: text)
        #expect(result.text == "Summarise these")
        #expect(result.names == ["a \"b\".txt", "build.log", "notes.pdf"])
    }

    @Test func storedUserMessageShowsFileChips() {
        let attached = TranscriptBuilder.userEntry(id: "u", message: SessionMessage(role: "user", content: .text("Read this please\n@file:/tmp/x/report.md")))
        #expect(attached.text == "Read this please")
        #expect(attached.fileNames == ["report.md"])
        // A reference inside a sentence stays in it.
        let inline = TranscriptBuilder.userEntry(id: "v", message: SessionMessage(role: "user", content: .text("Read @file:/tmp/x/report.md please")))
        #expect(inline.text == "Read @file:/tmp/x/report.md please")
        #expect(inline.fileNames.isEmpty)
    }

    @Test func commandsParseAndFallBack() {
        #expect(SlashCommands.parse("/goal Ship Hermes 1.3 by Friday")?.name == "goal")
        #expect(SlashCommands.parse("/goal Ship Hermes 1.3 by Friday")?.argument == "Ship Hermes 1.3 by Friday")
        #expect(SlashCommands.parse("/usage")?.argument == nil)
        #expect(SlashCommands.parse("not a command") == nil)
        #expect(SlashCommands.parse("/ nope") == nil)
        #expect(SlashCommands.known("compact")?.name == "compress")
        #expect(SlashCommands.info("frobnicate").symbol == SlashCommands.fallbackSymbol)
    }

    @Test func leadingSkillsAreFound() {
        let parts = SlashCommands.leadingSkills(in: "/github-pr-workflow /tdd fix issue #123", skills: ["github-pr-workflow", "tdd"])
        #expect(parts.skills == ["github-pr-workflow", "tdd"])
        #expect(parts.body == "fix issue #123")
        #expect(SlashCommands.leadingSkills(in: "/usage now", skills: ["tdd"]).skills.isEmpty)
    }

    @Test func commandOutputBecomesRows() {
        let outcome = CommandEntry.outcome(fromOutput: "Model: Claude Sonnet 4.6\nTokens: 48,210 in · 6,904 out\nCost: $0.25")
        guard case .result(let rows, let text) = outcome else { Issue.record("not rows"); return }
        #expect(rows.map(\.label) == ["Model", "Tokens", "Cost"])
        #expect(text == nil)
        #expect(CommandEntry.outcome(fromOutput: "Model changed to Claude Opus 4.6") == .note("Model changed to Claude Opus 4.6"))
    }

    @Test func requestsParse() throws {
        let clarify = HermesRequest.parse(GatewayServerRequest(id: "srq-1", method: "clarify", params: JSONValue.parse(#"{"session_id":"s","questions":[{"qid":"db","question":"Which database?","choices":["Staging","Production"]}]}"#)!))
        guard case .clarify(let questions)? = clarify?.kind else { Issue.record("no clarify"); return }
        #expect(questions.first?.choices == ["Staging", "Production"])
        let secret = HermesRequest.parse(GatewayServerRequest(id: "srq-2", method: "secret", params: JSONValue.parse(#"{"env_var":"ARXIV_API_KEY","prompt":"Paste it"}"#)!))
        #expect(secret?.kind == .secret(envVar: "ARXIV_API_KEY", prompt: "Paste it"))
        #expect(HermesRequest.parse(GatewayServerRequest(id: "srq-3", method: "terminal.read", params: .object([:]))) == nil)
        let connection = HermesRequest.connection(from: JSONValue.parse(#"{"op_id":"op1","targets":[{"name":"linear","kind":"mcp","action":"connect","required_env":[{"name":"LINEAR_API_KEY","required":true,"secret":true}]}]}"#)!)
        guard case .connection(let op)? = connection?.kind else { Issue.record("no connection"); return }
        #expect(op.targets.first?.requiredEnv.first?.name == "LINEAR_API_KEY")
    }

    @Test func approvalTilesFollowFlags() throws {
        let json = #"{"request_id":"a","command":"rm -rf x","choices":["once","session","always","deny"],"allow_permanent":false,"pattern_keys":["rm_rf"],"tool_name":"terminal"}"#
        let approval = try JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
        #expect(approval.choices == [.once, .session, .deny])
        #expect(approval.patternKeys == ["rm_rf"])
        let flagged = try JSONDecoder().decode(ApprovalRequest.self, from: Data(#"{"command":"curl x | sudo bash","smart_denied":true}"#.utf8))
        #expect(flagged.choices == [.once, .deny])
        #expect(flagged.smartDenied)
    }

    @Test(arguments: [
        ("every 1d at 07:30", "Every day at 07:30"),
        ("every 6h", "Every 6 hours"),
        ("0 6 * * *", "Every day at 06:00"),
        ("0 9 * * 1", "Mondays at 09:00"),
        ("30 7 * * 1-5", "Weekdays at 07:30"),
        ("*/15 * * * *", "Every 15 minutes"),
        ("0 */6 * * *", "Every 6 hours"),
        ("0 8 1 * *", "Monthly on the 1st at 08:00"),
        ("whenever", "whenever"),
    ])
    func schedulesInWords(raw: String, words: String) {
        #expect(ScheduleText.humanize(raw) == words)
    }

    @Test func roomLogBecomesRounds() {
        func e(_ seq: Int, _ kind: String, _ payload: String, actor: String = "gateway") -> RoomEvent {
            RoomEvent(seq: seq, kind: kind, actorKind: actor, actorID: nil, payload: JSONValue.parse(payload)!, createdAt: nil)
        }
        let events = [
            e(1, "message.user", #"{"text":"Ship it?","thread_id":"t"}"#, actor: "user"),
            e(2, "message.member", #"{"member_id":"hermes","round_index":0,"text":"Three things."}"#, actor: "member"),
            e(3, "turn.settled", #"{"member_id":"hermes","round_index":0,"passed":false}"#),
            e(4, "turn.settled", #"{"member_id":"researcher","round_index":0,"passed":true}"#),
            e(5, "message.member", #"{"member_id":"writer","round_index":1,"text":"Notes are in."}"#, actor: "member"),
            e(6, "turn.settled", #"{"member_id":"writer","round_index":1,"passed":false}"#),
            e(7, "room.activity", #"{"status":"settled","reason_code":"silent_round"}"#),
        ]
        let items = RoomTranscript.build(events)
        #expect(items.map(\.id) == ["e1", "e2", "e4", "e5-round", "e5", "e7"])
        guard case .settled(_, let rounds, let bounded) = items.last else { Issue.record("no settled"); return }
        #expect(rounds == 2)
        #expect(!bounded)
        #expect(RoomTranscript.memberStates(events) == ["hermes": .replied, "researcher": .passed, "writer": .replied])
        #expect(RoomTranscript.isSettled(events))
        let room = GroupRoom.parse(JSONValue.parse(#"{"room_id":"launch","name":"Launch crew","members":[{"member_id":"hermes","profile":"default","handle":"hermes"}],"updated_at":1}"#)!)
        #expect(room?.members.first?.handle == "hermes")
    }

    @Test func referencesAreFoundInPlainText() {
        let vocabulary = ReferenceVocabulary(handles: ["writer", "ops"], skills: ["github-pr-workflow"])
        let text = "@writer, @ops: run /github-pr-workflow. Mail me@x.com, see /usr/bin and @file:Sources/A.swift, @folder:Docs/ or @nobody."
        let parts = MessageParts.parse(text, vocabulary: vocabulary)
        #expect(parts.skills.isEmpty)
        #expect(parts.references.map(\.plainText) == ["@writer", "@ops", "@file:Sources/A.swift", "@folder:Docs/"])
        #expect(parts.references.map(\.kind) == [.bot, .bot, .file, .folder])
        let segments = parts.segments
        #expect(segments.first == .reference(parts.references[0]))
        #expect(segments[1] == .text(", "))
        #expect(parts.plainText == text)
    }

    @Test func leadingCommandAndSkillsAreUpgraded() {
        let vocabulary = ReferenceVocabulary(handles: ["writer"], commands: ReferenceVocabulary.knownCommands.union(["density"]), skills: ["arxiv", "tdd"])
        let goal = MessageParts.parse("/goal Ship Hermes 1.3 by Friday", vocabulary: vocabulary)
        #expect(goal.command == .init(name: "goal", argument: "Ship Hermes 1.3 by Friday"))
        #expect(goal.plainText == "/goal Ship Hermes 1.3 by Friday")
        // Gateway-only commands still become cards; unknown words stay text.
        #expect(MessageParts.parse("/density", vocabulary: vocabulary).command?.name == "density")
        #expect(MessageParts.parse("/etc/hosts is broken", vocabulary: vocabulary).command == nil)
        #expect(MessageParts.parse("/nonsense here", vocabulary: vocabulary).body == "/nonsense here")
        let skills = MessageParts.parse("/arxiv /tdd ask @writer about it", vocabulary: vocabulary)
        #expect(skills.skills == ["arxiv", "tdd"])
        #expect(skills.body == "ask @writer about it")
        #expect(skills.references == [MessageReference(kind: .bot, value: "writer", location: 4)])
        #expect(skills.plainText == "/arxiv /tdd ask @writer about it")
    }

    @Test func referencesFollowTheirText() {
        let pill = MessageReference(kind: .file, value: "CHANGELOG.md", location: 7)
        let parts = MessageParts(body: "  turn @file:CHANGELOG.md into notes ", references: [pill])
        let trimmed = parts.trimmed()
        #expect(trimmed.body == "turn @file:CHANGELOG.md into notes")
        #expect(trimmed.references.map(\.location) == [5])
        // A reference whose text was edited away is dropped, not drawn over the wrong words.
        #expect(MessageParts.valid([pill], in: "  turn @file:CHANGE.md").isEmpty)
        #expect(MessageReference(plainText: "@folder:Sources/")?.kind == .folder)
        #expect(MessageReference(plainText: "@diff") == nil)
    }
}
