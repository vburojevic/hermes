import Foundation

/// A prompt a `/v1/runs` turn waits on, as the run's status lists it (`pending_controls`): an
/// approval or a question, named by its id and the execution generation it was asked in.
public struct RunPrompt: Decodable, Sendable, Hashable {
    public var kind: String
    public var promptID: String
    public var executionGeneration: Int?
    /// The approval card's content, for an approval.
    public var approval: ApprovalRequest?

    enum CodingKeys: String, CodingKey {
        case kind
        case promptID = "prompt_id"
        case executionGeneration = "execution_generation"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        promptID = (try? c.decodeIfPresent(String.self, forKey: .promptID)) ?? ""
        executionGeneration = try? c.decodeIfPresent(Int.self, forKey: .executionGeneration)
        approval = kind == RunPromptAnswer.Kind.approval.rawValue ? try? ApprovalRequest(from: decoder) : nil
    }
}

/// The person's answer to a prompt a `/v1/runs` turn waits on: `POST /v1/runs/{id}/approval` or
/// `/clarify` (`docs/quick-actions.md` §3). Hermes takes exactly `{request_id,
/// execution_generation, choice}` (`answer` for a question) and refuses any other body with 400
/// `invalid_params`; a generation that moved is `stale_generation`, and a prompt it no longer
/// waits on is `approval_not_pending`, both 409.
public struct RunPromptAnswer: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case approval, clarify
    }

    public var kind: Kind
    public var requestID: String?
    /// The choice, or the question's answer.
    public var value: String
    /// The generation the prompt was asked in, when its event said.
    public var generation: Int?

    public init(kind: Kind, requestID: String?, value: String, generation: Int?) {
        self.kind = kind
        self.requestID = requestID
        self.value = value
        self.generation = generation
    }

    public static func approval(_ approval: ApprovalRequest, choice: ApprovalChoice) -> RunPromptAnswer {
        RunPromptAnswer(kind: .approval, requestID: approval.requestID, value: choice.rawValue, generation: approval.executionGeneration)
    }

    public static func clarify(requestID: String, answer: String, generation: Int?) -> RunPromptAnswer {
        RunPromptAnswer(kind: .clarify, requestID: requestID, value: answer, generation: generation)
    }

    /// The body to send with `generation`. Without one, from a gateway whose runs carry none, it's
    /// the `{choice, request_id}` those gateways take.
    public func body(generation: Int?) -> [String: JSONValue] {
        var body: [String: JSONValue] = [kind == .approval ? "choice" : "answer": .string(value)]
        if let requestID {
            body["request_id"] = .string(requestID)
            if let generation { body["execution_generation"] = .number(Double(generation)) }
        }
        return body
    }

    /// Whether the run still waits on this prompt.
    public func isPending(in status: RunStatus) -> Bool {
        !status.isTerminal && status.pendingControls.contains { $0.promptID == requestID && $0.kind == kind.rawValue }
    }

    /// What to do after Hermes refused this answer. `status` is the run's, read after a
    /// `stale_generation` (nil when it couldn't be read); `retried` says the fresh generation was
    /// already tried once.
    public func next(after error: HermesError, status: RunStatus?, retried: Bool) -> RunPromptStep {
        guard case .server(409, let code, _) = error else { return .fail }
        guard code == "stale_generation" else {
            // `approval_not_pending`, or `approval_not_active` from older gateways: answered on
            // another device, timed out, or the turn is over.
            return .settled(.notPending)
        }
        guard let status else { return .fail }
        guard isPending(in: status) else { return .settled(.notPending) }
        guard !retried, let fresh = status.executionGeneration else { return .fail }
        return .retry(generation: fresh)
    }

    /// The refusal in words for the banner: Hermes's message for these is the bare reason.
    public static func describing(_ error: HermesError) -> HermesError {
        guard case .server(let status, let code?, _) = error else { return error }
        switch code {
        case "stale_generation":
            return .server(status: status, code: code, message: "This turn restarted on the gateway before your answer got there. Try again.")
        case "invalid_params":
            return .server(status: status, code: code, message: "Hermes couldn't take that answer. Try again.")
        default:
            return error
        }
    }
}

/// How an answer to a run's prompt went.
public enum RunPromptOutcome: Sendable, Hashable {
    case answered
    /// Hermes stopped waiting for it before the answer got there: answered on another device,
    /// timed out, or the turn ended.
    case notPending
}

/// The step after Hermes refused an answer (`RunPromptAnswer.next`).
public enum RunPromptStep: Sendable, Hashable {
    /// The prompt is still waiting under a newer generation: send it again with that one.
    case retry(generation: Int)
    case settled(RunPromptOutcome)
    /// Say what went wrong; the card comes back.
    case fail
}
