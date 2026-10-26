import Foundation
import Testing
@testable import HermesKit

/// A question a `/v1/runs` turn asks, as Hermes Agent projects it (`session_pending_controls.py`
/// `register_clarify`, `session_api_turn.observe_api_controls`): in the run's status and on its
/// events, one question per prompt, answered with one string.
@Suite("Run questions")
struct RunQuestionTests {
    private static let prompt = #"""
    {"kind": "clarify", "prompt_id": "c1", "execution_generation": 3,
     "question": "Where should I deploy the build?\nReply \"skip\" to skip this question.",
     "choices": ["Staging (Recommended)", "Production"], "multi_select": false}
    """#

    private static func status(_ controls: String, state: String = "running") -> RunStatus {
        let json = #"{"run_id": "run_1", "status": "\#(state)", "execution_generation": 3, "pending_controls": [\#(controls)]}"#
        return try! JSONDecoder().decode(RunStatus.self, from: Data(json.utf8))
    }

    private static func question(_ id: String = "c1", timeout: Int? = nil) -> RunPrompt {
        var json = Self.prompt.replacingOccurrences(of: #""c1""#, with: "\"\(id)\"")
        if let timeout { json = json.replacingOccurrences(of: #""multi_select": false"#, with: #""multi_select": false, "timeout_s": \#(timeout)"#) }
        return try! JSONDecoder().decode(RunPrompt.self, from: Data(json.utf8))
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Decoding

    @Test func theStatusListsTheQuestionWithItsPicks() throws {
        let status = Self.status(Self.prompt)
        let prompt = try #require(status.pendingControls.first)
        #expect(prompt.kind == "clarify")
        #expect(prompt.executionGeneration == 3)
        // The card has its own Skip: Hermes's line for chat apps doesn't show.
        #expect(prompt.question == "Where should I deploy the build?")
        #expect(prompt.choices == ["Staging (Recommended)", "Production"])
        #expect(prompt.approval == nil)
        #expect(status.approval == nil)
    }

    @Test func theSkipLineGoesInEveryLanguage() {
        // Hermes's `gateway.clarify.skip_hint` in a few of the languages it ships.
        for hint in ["Reply \"skip\" to skip this question.", "Antworte mit „skip“, um diese Frage zu überspringen.",
                     "Répondez « skip » pour passer cette question.", "この質問をスキップするには「skip」と返信してください。",
                     "Válaszolj „skip” szóval a kérdés kihagyásához."] {
            #expect(RunPrompt.withoutSkipHint("Where?\n\(hint)") == "Where?")
        }
        // A question of its own is left whole.
        #expect(RunPrompt.withoutSkipHint("Should I skip the tests?") == "Should I skip the tests?")
        #expect(RunPrompt.withoutSkipHint("Two lines.\nShould I skip it?") == "Two lines.\nShould I skip it?")
    }

    @Test func itsCardIsASocketChatsQuestionByThePromptsID() throws {
        let request = try #require(Self.question(timeout: 60).questionRequest(receivedAt: start))
        #expect(request.id == "c1")
        #expect(request.method == "clarify")
        #expect(request.kind == .clarify([HermesRequest.Question(id: "c1", question: "Where should I deploy the build?",
                                                                  choices: ["Staging (Recommended)", "Production"])]))
        #expect(request.deadline == start.addingTimeInterval(60))
        #expect(Self.question().questionRequest(receivedAt: start)?.deadline == nil)
    }

    @Test func anApprovalIsntAQuestion() throws {
        let approval = try JSONDecoder().decode(RunPrompt.self, from: Data(#"{"kind": "approval", "prompt_id": "p1", "command": "ls", "choices": ["once", "deny"]}"#.utf8))
        #expect(approval.questionRequest() == nil)
        #expect(approval.choices.isEmpty)
    }

    @Test func multiSelectNeedsPicks() throws {
        let open = try JSONDecoder().decode(RunPrompt.self, from: Data(#"{"kind": "clarify", "prompt_id": "c2", "question": "Why?", "choices": [], "multi_select": true}"#.utf8))
        #expect(open.multiSelect == false)
        #expect(open.questionRequest()?.kind == .clarify([HermesRequest.Question(id: "c2", question: "Why?")]))
    }

    @Test func theRunsEventsCarryTheQuestionAndItsEnd() throws {
        let asked = ServerSentEvent(data: #"""
        {"event": "clarify.request", "run_id": "run_1", "timestamp": 1.0, "kind": "clarify", "prompt_id": "c1",
         "execution_generation": 3, "question": "Where?", "choices": ["Staging"], "multi_select": false, "seq": 4}
        """#)
        let decoded = RunEventDecoder.decode(asked)
        guard case .questionAsked(let prompt)? = decoded.first?.event else {
            Issue.record("no question")
            return
        }
        #expect(decoded.first?.seq == 4)
        #expect(prompt.promptID == "c1")
        #expect(prompt.executionGeneration == 3)
        let settled = ServerSentEvent(data: #"{"event": "clarify.settled", "run_id": "run_1", "prompt_id": "c1", "execution_generation": 3, "seq": 5}"#)
        #expect(RunEventDecoder.decode(settled).map(\.event) == [.questionSettled(promptID: "c1")])
    }

    // MARK: - The answer

    private var request: HermesRequest { Self.question().questionRequest()! }

    @Test func aPickOrWordsGoAsTheyAre() {
        let picked = RunPromptAnswer.clarify(request, result: .object(["answers": .object(["c1": .string("Staging (Recommended)")])]), generation: 3)
        #expect(picked.body(generation: 3) == ["request_id": .string("c1"), "execution_generation": .number(3), "answer": .string("Staging (Recommended)")])
        #expect(picked.kind == .clarify)
    }

    @Test func severalPicksGoAsAList() {
        let picks = RunPromptAnswer.clarify(request, result: .object(["answers": .object(["c1": .array([.string("Europe"), .string("US East")])])]), generation: 3)
        #expect(picks.value == #"["Europe","US East"]"#)
    }

    @Test func aSkipIsNoAnswer() {
        // The card's Skip sends `{}`; a skipped question is `null`. Hermes records "" as skipped.
        #expect(RunPromptAnswer.clarify(request, result: .object([:]), generation: 3).value == "")
        #expect(RunPromptAnswer.clarify(request, result: .object(["answers": .object(["c1": .null])]), generation: 3).value == "")
    }

    // MARK: - Shown and ended

    // The calls that change `RunQuestions` are made outside `#expect`, which can't take them.

    @Test func aQuestionShowsOnce() {
        var questions = RunQuestions()
        let first = questions.ask(Self.question(), runID: "run_1", now: start)
        let again = questions.ask(Self.question(), runID: "run_1", now: start)
        #expect(first?.id == "c1")
        #expect(again == nil)
        #expect(questions.owns("c1"))
        #expect(questions.isAsking(in: "run_1"))
        #expect(!questions.isAsking(in: "run_2"))
        // The status listing it too changes nothing.
        let listed = questions.reconcile(Self.status(Self.prompt), runID: "run_1", readAt: start + 1, now: start + 1)
        #expect(listed.isEmpty)
    }

    @Test func aQuestionOnlyTheStatusListsShows() {
        var questions = RunQuestions()
        let changes = questions.reconcile(Self.status(Self.prompt), runID: "run_1", readAt: start, now: start)
        #expect(changes == [.show(Self.question().questionRequest(receivedAt: start)!)])
        #expect(questions.isAsking(in: "run_1"))
    }

    @Test func aQuestionTheStatusNoLongerListsEnds() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        _ = questions.ask(Self.question("c2", timeout: 30), runID: "run_1", now: start + 1)
        let changes = questions.reconcile(Self.status(""), runID: "run_1", readAt: start + 40, now: start + 40)
        #expect(changes == [.end(id: "c1", .answeredElsewhere), .end(id: "c2", .timedOut)])
        #expect(!questions.isAsking(in: "run_1"))
    }

    @Test func aReadThatBeganBeforeTheQuestionDoesntEndIt() {
        // The event came while the read was on its way: the read can't have listed it.
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start + 2)
        let changes = questions.reconcile(Self.status(""), runID: "run_1", readAt: start + 1, now: start + 3)
        #expect(changes.isEmpty)
        #expect(questions.isAsking(in: "run_1"))
    }

    @Test func aRunThatEndedTakesItsQuestionsWithoutAWord() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        let changes = questions.reconcile(Self.status(Self.prompt, state: "cancelled"), runID: "run_1", readAt: start + 1, now: start + 1)
        #expect(changes == [.drop(id: "c1")])
        #expect(!questions.owns("c1"))
    }

    @Test func anotherRunsStatusLeavesTheseAlone() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        let changes = questions.reconcile(Self.status(""), runID: "run_2", readAt: start + 1, now: start + 1)
        #expect(changes.isEmpty)
        #expect(questions.isAsking(in: "run_1"))
    }

    @Test func answeredHereItStaysDownAndSettlesQuietly() throws {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        let answered = questions.answer("c1")
        let asked = try #require(answered)
        #expect(asked.runID == "run_1")
        #expect(asked.generation == 3)
        let twice = questions.answer("c1")
        #expect(twice == nil) // a double tap answers once
        // Hermes hasn't taken it yet: still listed, but the card doesn't come back.
        let listed = questions.reconcile(Self.status(Self.prompt), runID: "run_1", readAt: start + 1, now: start + 1)
        #expect(listed.isEmpty)
        let ending = questions.settle("c1")
        #expect(ending == nil)
        #expect(!questions.owns("c1"))
    }

    @Test func anAnswerThatDidntGoBringsTheCardBack() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        _ = questions.answer("c1")
        let back = questions.unanswer("c1")
        let backAgain = questions.unanswer("c1")
        #expect(back)
        #expect(questions.isAsking(in: "run_1"))
        #expect(!backAgain)
    }

    @Test func settledWithItsCardUpItWasAnsweredElsewhereOrExpired() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        _ = questions.ask(Self.question("c2", timeout: 30), runID: "run_1", now: start)
        let elsewhere = questions.settle("c1", now: start + 40)
        let expired = questions.settle("c2", now: start + 40)
        let unknown = questions.settle("c3")
        #expect(elsewhere == .answeredElsewhere)
        #expect(expired == .timedOut)
        #expect(unknown == nil)
    }

    @Test func theTurnsEndTakesThemAll() {
        var questions = RunQuestions()
        _ = questions.ask(Self.question(), runID: "run_1", now: start)
        _ = questions.ask(Self.question("c2"), runID: "run_1", now: start + 1)
        _ = questions.answer("c2")
        let ended = questions.endAll()
        #expect(ended == ["c1"])
        #expect(!questions.owns("c1"))
        #expect(!questions.owns("c2"))
    }

    // MARK: - When the status is read

    @Test func aQuietStreamIsReadNowAndThen() {
        let heard = start
        #expect(!RunStatusWatch.due(now: start + 9, heard: heard, read: nil, askingStep: false, cardUp: false))
        #expect(RunStatusWatch.due(now: start + 10, heard: heard, read: nil, askingStep: false, cardUp: false))
        // Not again until the stream's been quiet that long since the last read.
        #expect(!RunStatusWatch.due(now: start + 15, heard: heard, read: start + 10, askingStep: false, cardUp: false))
        #expect(RunStatusWatch.due(now: start + 20, heard: heard, read: start + 10, askingStep: false, cardUp: false))
    }

    @Test func theWatchSleepsUntilTheNextRead() {
        #expect(RunStatusWatch.pause(now: start + 4, heard: start, read: nil, askingStep: false, cardUp: false) == 6)
        #expect(RunStatusWatch.pause(now: start + 1, heard: start, read: nil, askingStep: true, cardUp: false) == 1)
        #expect(RunStatusWatch.pause(now: start + 30, heard: start, read: nil, askingStep: false, cardUp: false) == 0)
    }

    @Test func theQuestionStepIsReadSoonAndACardNowAndThen() {
        #expect(RunStatusWatch.due(now: start + 2, heard: start, read: nil, askingStep: true, cardUp: false))
        #expect(!RunStatusWatch.due(now: start + 10, heard: start, read: nil, askingStep: true, cardUp: true))
        #expect(RunStatusWatch.due(now: start + 15, heard: start, read: nil, askingStep: true, cardUp: true))
    }

    @Test func theQuestionStepIsTheRunningClarifyTool() {
        let asking = AssistantTurn(id: "t", steps: [.tool(ToolActivity(id: "s1", name: "clarify", status: .running))], state: .streaming)
        let done = AssistantTurn(id: "t", steps: [.tool(ToolActivity(id: "s1", name: "clarify", status: .succeeded))], state: .streaming)
        let other = AssistantTurn(id: "t", steps: [.tool(ToolActivity(id: "s1", name: "terminal", status: .running))], state: .streaming)
        #expect(RunStatusWatch.asks(asking))
        #expect(!RunStatusWatch.asks(done))
        #expect(!RunStatusWatch.asks(other))
    }
}
