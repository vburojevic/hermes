import Foundation
import Testing
@testable import HermesKit

/// Answers to a `/v1/runs` turn's approvals and questions, as Hermes Agent's run store takes them
/// (`respond_run`): exactly `{request_id, execution_generation, choice|answer}`.
@Suite("Run prompts", .serialized)
struct RunPromptTests {
    private static let waiting = #"""
    {"run_id": "run_1", "status": "waiting_for_approval", "session_id": "s1", "admission_id": "adm_1",
     "execution_generation": 4, "output": "", "usage": {},
     "pending_controls": [{"kind": "approval", "prompt_id": "p1", "execution_generation": 4,
       "command": "rm -rf ./build", "description": "Recursive delete", "choices": ["once", "deny", "session", "always"]}]}
    """#

    private static func refusal(_ status: Int, _ reason: String) -> StubProtocol.Response {
        .init(status: status, body: Data(#"{"error":{"message":"\#(reason)","type":"invalid_request_error","param":null,"code":"\#(reason)"}}"#.utf8))
    }

    private func makeClient(host: String, handler: @escaping @Sendable (URLRequest) -> StubProtocol.Response) -> HermesClient {
        StubProtocol.lock.withLock { StubProtocol.routes[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(baseURL: URL(string: "http://\(host):8642")!, apiKey: "secret-key-0123456789",
                            session: URLSession(configuration: configuration))
    }

    private func answers(for host: String) -> [JSONValue] {
        StubProtocol.requests(for: host)
            .filter { $0.httpMethod == "POST" }
            .compactMap { JSONValue.parse(String(decoding: $0.httpBody ?? Data(), as: UTF8.self)) }
    }

    private func approval(generation: Int?) -> ApprovalRequest {
        var approval = ApprovalRequest(requestID: "p1", command: "rm -rf ./build", description: nil, choices: [.once, .deny])
        approval.executionGeneration = generation
        return approval
    }

    // MARK: - The body

    @Test func anApprovalNamesItsPromptAndGeneration() {
        let body = RunPromptAnswer.approval(approval(generation: 3), choice: .once).body(generation: 3)
        #expect(Set(body.keys) == ["request_id", "execution_generation", "choice"])
        #expect(body["request_id"] == .string("p1"))
        #expect(body["execution_generation"] == .number(3))
        #expect(body["choice"] == .string("once"))
    }

    @Test func aQuestionsAnswerIsItsAnswer() {
        let body = RunPromptAnswer.clarify(requestID: "c1", answer: "Blue", generation: 2).body(generation: 2)
        #expect(Set(body.keys) == ["request_id", "execution_generation", "answer"])
        #expect(body["answer"] == .string("Blue"))
    }

    @Test func aGatewayWithoutGenerationsGetsTheBodyItTakes() {
        let body = RunPromptAnswer.approval(approval(generation: nil), choice: .deny).body(generation: nil)
        #expect(body == ["choice": .string("deny"), "request_id": .string("p1")])
    }

    // MARK: - Decoding

    @Test func theRunsEventCarriesTheGeneration() throws {
        let frame = ServerSentEvent(data: #"""
        {"event": "approval.request", "run_id": "run_1", "command": "rm -rf ./build", "execution_generation": 4,
         "request_id": "p1", "allow_session": true, "allow_permanent": true, "choices": ["once", "session", "always", "deny"], "seq": 2}
        """#)
        guard case .approvalRequested(let approval)? = RunEventDecoder.decode(frame).first?.event else {
            Issue.record("no approval")
            return
        }
        #expect(approval.requestID == "p1")
        #expect(approval.executionGeneration == 4)
    }

    @Test func theRunsStatusListsWhatItWaitsOn() throws {
        let status = try JSONDecoder().decode(RunStatus.self, from: Data(Self.waiting.utf8))
        #expect(status.executionGeneration == 4)
        #expect(status.pendingControls.map(\.promptID) == ["p1"])
        // The card comes back from the status after a dropped stream, in the tiles' order.
        let approval = try #require(status.approval)
        #expect(approval.requestID == "p1")
        #expect(approval.executionGeneration == 4)
        #expect(approval.choices == [.once, .session, .always, .deny])
    }

    // MARK: - After a refusal

    @Test func aMovedGenerationIsTriedOnceMoreWhileThePromptWaits() throws {
        let status = try JSONDecoder().decode(RunStatus.self, from: Data(Self.waiting.utf8))
        let answer = RunPromptAnswer.approval(approval(generation: 3), choice: .once)
        let stale = HermesError.server(status: 409, code: "stale_generation", message: "stale_generation")
        #expect(answer.next(after: stale, status: status, retried: false) == .retry(generation: 4))
        #expect(answer.next(after: stale, status: status, retried: true) == .fail)
        #expect(answer.next(after: stale, status: nil, retried: false) == .fail)
    }

    @Test func aMovedGenerationWithThePromptGoneIsSettled() throws {
        var status = try JSONDecoder().decode(RunStatus.self, from: Data(Self.waiting.utf8))
        status.pendingControls = []
        let stale = HermesError.server(status: 409, code: "stale_generation", message: "stale_generation")
        #expect(RunPromptAnswer.approval(approval(generation: 3), choice: .once).next(after: stale, status: status, retried: false) == .settled(.notPending))
        // Another prompt waiting isn't this one.
        let other = RunPromptAnswer(kind: .clarify, requestID: "p1", value: "Blue", generation: 3)
        let waiting = try JSONDecoder().decode(RunStatus.self, from: Data(Self.waiting.utf8))
        #expect(other.next(after: stale, status: waiting, retried: false) == .settled(.notPending))
    }

    @Test func notPendingIsSettledAndAMalformedAnswerFails() {
        let answer = RunPromptAnswer.approval(approval(generation: 3), choice: .once)
        let notPending = HermesError.server(status: 409, code: "approval_not_pending", message: "approval_not_pending")
        #expect(answer.next(after: notPending, status: nil, retried: false) == .settled(.notPending))
        let invalid = HermesError.server(status: 400, code: "invalid_params", message: "invalid_params")
        #expect(answer.next(after: invalid, status: nil, retried: false) == .fail)
        #expect(answer.next(after: .unreachable(host: "h", reason: .timedOut), status: nil, retried: false) == .fail)
    }

    // MARK: - Over the wire

    @Test func theAnswerGoesWithTheEventsGeneration() async throws {
        let host = "prompt-answer.test"
        let client = makeClient(host: host) { _ in .init(status: 200, body: Data(#"{"run_id":"run_1","status":"resolved","prompt_id":"p1"}"#.utf8)) }
        let outcome = try await client.answer(.approval(approval(generation: 3), choice: .once), runID: "run_1")
        #expect(outcome == .answered)
        let requests = StubProtocol.requests(for: host)
        #expect(requests.map { $0.url?.path() } == ["/v1/runs/run_1/approval"])
        // An integer, as Hermes checks its type.
        let raw = String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(raw.contains(#""execution_generation":3"#))
        #expect(answers(for: host) == [.object(["request_id": .string("p1"), "execution_generation": .number(3), "choice": .string("once")])])
    }

    @Test func aGenerationTheEventDidntCarryIsReadFromTheRun() async throws {
        let host = "prompt-status.test"
        let client = makeClient(host: host) { request in
            request.httpMethod == "GET"
                ? .init(status: 200, body: Data(Self.waiting.utf8))
                : .init(status: 200, body: Data(#"{"run_id":"run_1","status":"resolved","prompt_id":"p1"}"#.utf8))
        }
        try await client.answer(RunPromptAnswer(kind: .approval, requestID: "p1", value: "deny", generation: nil), runID: "run_1")
        #expect(StubProtocol.requests(for: host).map { $0.url?.path() } == ["/v1/runs/run_1", "/v1/runs/run_1/approval"])
        #expect(answers(for: host).first?["execution_generation"] == .number(4))
    }

    @Test func aRunThatCantBeReadIsntAnsweredWithTheShortBody() async throws {
        let host = "prompt-status-down.test"
        let client = makeClient(host: host) { _ in Self.refusal(503, "storage_unavailable") }
        // The caller's retry takes it from here: nothing went out that Hermes would refuse for good.
        await #expect(throws: HermesError.server(status: 503, code: "storage_unavailable", message: "storage_unavailable")) {
            try await client.answer(RunPromptAnswer(kind: .approval, requestID: "p1", value: "once", generation: nil), runID: "run_1")
        }
        #expect(StubProtocol.requests(for: host).map(\.httpMethod) == ["GET"])
    }

    @Test func aRunAnOlderGatewayDoesntListTakesTheShortBody() async throws {
        let host = "prompt-status-missing.test"
        let client = makeClient(host: host) { request in
            request.httpMethod == "GET"
                ? .init(status: 404, body: Data(#"{"error":{"message":"Run not found: run_1","type":"invalid_request_error","param":null,"code":"run_not_found"}}"#.utf8))
                : .init(status: 200, body: Data(#"{"object":"hermes.run.approval_response","run_id":"run_1","choice":"once","resolved":1}"#.utf8))
        }
        #expect(try await client.answer(RunPromptAnswer(kind: .approval, requestID: "p1", value: "once", generation: nil), runID: "run_1") == .answered)
        #expect(answers(for: host) == [.object(["choice": .string("once"), "request_id": .string("p1")])])
    }

    @Test func aStaleGenerationIsReadAgainAndSentOnce() async throws {
        let host = "prompt-stale.test"
        let posts = Counter()
        let client = makeClient(host: host) { request in
            if request.httpMethod == "GET" { return .init(status: 200, body: Data(Self.waiting.utf8)) }
            return posts.next() == 0
                ? Self.refusal(409, "stale_generation")
                : .init(status: 200, body: Data(#"{"run_id":"run_1","status":"resolved","prompt_id":"p1"}"#.utf8))
        }
        let outcome = try await client.answer(.approval(approval(generation: 3), choice: .once), runID: "run_1")
        #expect(outcome == .answered)
        #expect(answers(for: host).map { $0["execution_generation"] } == [.number(3), .number(4)])
    }

    @Test func aStaleGenerationWhosePromptWentSettles() async throws {
        // What Hermes does: the prompt goes with its generation, so the run no longer lists it.
        let host = "prompt-stale-gone.test"
        let moved = #"{"run_id": "run_1", "status": "running", "execution_generation": 4, "pending_controls": []}"#
        let client = makeClient(host: host) { request in
            request.httpMethod == "GET" ? .init(status: 200, body: Data(moved.utf8)) : Self.refusal(409, "stale_generation")
        }
        let outcome = try await client.answer(.approval(approval(generation: 3), choice: .once), runID: "run_1")
        #expect(outcome == .notPending)
        #expect(answers(for: host).count == 1)
    }

    @Test func aGenerationStaleTwiceIsAnError() async throws {
        let host = "prompt-stale-twice.test"
        let client = makeClient(host: host) { request in
            request.httpMethod == "GET" ? .init(status: 200, body: Data(Self.waiting.utf8)) : Self.refusal(409, "stale_generation")
        }
        // Said in words, never Hermes's bare reason.
        let words = "This turn restarted on the gateway before your answer got there. Try again."
        await #expect(throws: HermesError.server(status: 409, code: "stale_generation", message: words)) {
            try await client.answer(.approval(self.approval(generation: 3), choice: .once), runID: "run_1")
        }
        #expect(answers(for: host).count == 2)
    }

    @Test func aMalformedAnswerIsSaidInWords() async throws {
        let host = "prompt-invalid.test"
        let client = makeClient(host: host) { _ in Self.refusal(400, "invalid_params") }
        await #expect(throws: HermesError.server(status: 400, code: "invalid_params", message: "Hermes couldn't take that answer. Try again.")) {
            try await client.answer(.approval(self.approval(generation: 3), choice: .once), runID: "run_1")
        }
    }

    @Test func aPromptAnsweredElsewhereSettles() async throws {
        let host = "prompt-elsewhere.test"
        let client = makeClient(host: host) { _ in Self.refusal(409, "approval_not_pending") }
        let outcome = try await client.answer(.approval(approval(generation: 3), choice: .once), runID: "run_1")
        #expect(outcome == .notPending)
        #expect(answers(for: host).count == 1)
    }

    @Test func aPromptSettledAsItWasAnsweredSettles() async throws {
        let host = "prompt-resolved.test"
        let client = makeClient(host: host) { _ in .init(status: 200, body: Data(#"{"run_id":"run_1","status":"already_resolved","prompt_id":"p1"}"#.utf8)) }
        #expect(try await client.answer(.approval(approval(generation: 3), choice: .once), runID: "run_1") == .notPending)
    }

    @Test func aQuestionsAnswerGoesToClarify() async throws {
        let host = "prompt-clarify.test"
        let client = makeClient(host: host) { _ in .init(status: 200, body: Data(#"{"run_id":"run_1","status":"resolved","prompt_id":"c1"}"#.utf8)) }
        try await client.answer(.clarify(requestID: "c1", answer: "Blue", generation: 2), runID: "run_1")
        #expect(StubProtocol.requests(for: host).map { $0.url?.path() } == ["/v1/runs/run_1/clarify"])
        #expect(answers(for: host) == [.object(["request_id": .string("c1"), "execution_generation": .number(2), "answer": .string("Blue")])])
    }
}

/// Counts calls across the stub's threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
