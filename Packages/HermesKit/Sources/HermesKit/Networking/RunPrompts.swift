import Foundation
import HermesPush

/// A prompt a `/v1/runs` turn waits on, as the run's status lists it (`pending_controls`) and its
/// `clarify.request` event carries it: an approval or a question, named by its id and the
/// execution generation it was asked in (`gateway/session_pending_controls.py`).
public struct RunPrompt: Decodable, Sendable, Hashable {
    public var kind: String
    public var promptID: String
    public var executionGeneration: Int?
    /// The approval card's content, for an approval.
    public var approval: ApprovalRequest?
    /// A question's words and picks. Hermes asks one question per prompt; the first pick may end
    /// in "(Recommended)", as on the socket.
    public var question: String?
    public var choices: [String] = []
    public var multiSelect = false
    /// How long Hermes waits for the answer, when it says (a local viewer's turn).
    public var timeout: TimeInterval?
    /// When Hermes asked, by the gateway's clock: a run's event carries it (`timestamp`); its
    /// status doesn't.
    public var askedAt: Date?

    enum CodingKeys: String, CodingKey {
        case kind, question, choices
        case promptID = "prompt_id"
        case executionGeneration = "execution_generation"
        case multiSelect = "multi_select"
        case timeout = "timeout_s"
        case askedAt = "timestamp"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        promptID = (try? c.decodeIfPresent(String.self, forKey: .promptID)) ?? ""
        executionGeneration = try? c.decodeIfPresent(Int.self, forKey: .executionGeneration)
        approval = kind == RunPromptAnswer.Kind.approval.rawValue ? try? ApprovalRequest(from: decoder) : nil
        guard kind == RunPromptAnswer.Kind.clarify.rawValue else { return }
        // Nothing invisible or reordering hides in the question. The picks go back as they came:
        // the answer is the pick's own text.
        question = VisibleText.of((try? c.decodeIfPresent(String.self, forKey: .question)).map(Self.withoutSkipHint))
        choices = (try? c.decodeIfPresent([String].self, forKey: .choices)) ?? []
        multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) == true && !choices.isEmpty
        timeout = (try? c.decodeIfPresent(Double.self, forKey: .timeout)).flatMap { $0 > 0 ? $0 : nil }
        askedAt = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .askedAt))
    }

    /// The question's card, as a socket chat shows a `clarify` of one question: its id is the
    /// prompt's, and so is the question's, which its answer names (`RunPromptAnswer.clarify`).
    /// Its deadline counts from when Hermes asked, so an event that arrived late (a stream attached
    /// after the asking) doesn't move it past Hermes's own; a question only a status read lists was
    /// asked by `listedAt`, when that read began. A clock ahead of this device's counts from now.
    public func questionRequest(receivedAt: Date = .now, listedAt: Date? = nil) -> HermesRequest? {
        guard kind == RunPromptAnswer.Kind.clarify.rawValue, !promptID.isEmpty, let question, !question.isEmpty else { return nil }
        let asked = min(askedAt ?? listedAt ?? receivedAt, receivedAt)
        return HermesRequest(
            id: promptID,
            method: "clarify",
            kind: .clarify([HermesRequest.Question(id: promptID, question: question, choices: choices, multiSelect: multiSelect)]),
            receivedAt: receivedAt,
            deadline: timeout.map { asked.addingTimeInterval($0) }
        )
    }

    /// Hermes adds a line for chat apps, where a typed "skip" answers the card
    /// (`gateway/run_turn_runner.py` `_clarify_callback_sync`, `gateway.clarify.skip_hint`). The
    /// card has its own Skip, and a typed "skip" over the API server would be taken as the answer.
    /// Every language Hermes ships says it as one last line with the word `skip` in its own quotes
    /// ("skip", „skip“, « skip », 「skip」…), so that line goes, whatever the language.
    static func withoutSkipHint(_ question: String) -> String {
        guard let newline = question.lastIndex(of: "\n") else { return question }
        let line = question[question.index(after: newline)...]
        guard line.contains(/[\u{22}\u{201E}\u{201C}\u{AB}\u{300C}]\s?skip\s?[\u{22}\u{201C}\u{201D}\u{BB}\u{300D}]/) else { return question }
        return String(question[..<newline])
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

    /// The answer to a run's question from its card's result, `{answers: {qid: …}}` as a socket
    /// chat's card sends it. Hermes takes one string (`resolve_gateway_clarify`): the words or
    /// pick; for several picks, the labels as a JSON array, which its clarify tool reads as a
    /// list; and for a skip, nothing, which it records as skipped.
    public static func clarify(_ request: HermesRequest, result: JSONValue, generation: Int?) -> RunPromptAnswer {
        let value: String = switch result["answers"]?[request.id] {
        case .string(let text)?: text
        case .array(let picks)?:
            (try? JSONEncoder().encode(picks.compactMap(\.stringValue))).map { String(decoding: $0, as: UTF8.self) } ?? ""
        default: ""
        }
        return .clarify(requestID: request.id, answer: value, generation: generation)
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

/// How a `/v1/runs` turn's approval cards end (`docs/quick-actions.md` §3). Hermes says
/// `approval.settled` on the run's events when it stops waiting on one, however that came about:
/// answered here or on another device, timed out, or its generation ended. It doesn't say which,
/// so the card's own story decides, as for a question's `clarify.settled` (`RunQuestions`).
public struct RunApprovals: Sendable {
    private struct Shown: Sendable {
        var generation: Int?
        var deadline: Date?
    }

    /// Cards up here, by prompt id.
    private var shown: [String: Shown] = [:]
    /// Answered here, and possibly not with Hermes yet: a settle says nothing.
    private var answered: [String: Shown] = [:]
    /// Prompts Hermes stopped waiting on: an answer to one isn't sent.
    private var settled: Set<String> = []

    public init() {}

    /// The approval's card is up. Its deadline, when Hermes gave one, counts from when Hermes
    /// asked: an event that arrived late (a stream attached after the asking) doesn't move it past
    /// Hermes's own, and one after a status read raised the card brings it forward. A clock ahead
    /// of this device's counts from now.
    public mutating func show(_ approval: ApprovalRequest, now: Date = .now) {
        guard let id = approval.requestID, !settled.contains(id) else { return }
        let asked = min(approval.askedAt ?? now, now)
        let deadline = approval.timeout.map { asked.addingTimeInterval($0) }
        guard shown[id] == nil, answered[id] == nil else {
            guard let deadline else { return }
            if let up = shown[id]?.deadline, deadline < up { shown[id]?.deadline = deadline }
            if let sent = answered[id]?.deadline, deadline < sent { answered[id]?.deadline = deadline }
            return
        }
        shown[id] = Shown(generation: approval.executionGeneration, deadline: deadline)
    }

    /// Hermes stopped waiting on `id` (`approval.settled`): how its card ends, or nil when none is
    /// up here (answered here, never shown, or asked in another generation).
    public mutating func settle(_ id: String, generation: Int?, now: Date = .now) -> RequestSync.Ending? {
        if let card = shown[id] ?? answered[id], let generation, let asked = card.generation, asked != generation { return nil }
        settled.insert(id)
        answered[id] = nil
        guard let card = shown.removeValue(forKey: id) else { return nil }
        return RequestSync.ended(shown: [RequestSync.Card(id: id, deadline: card.deadline)], open: [], now: now).first?.ending
    }

    /// Whether Hermes already stopped waiting on `id`: an answer tapped now goes nowhere.
    public func isSettled(_ id: String) -> Bool {
        settled.contains(id)
    }

    /// The person answered `id` here: false when Hermes already stopped waiting on it, and the
    /// answer isn't sent.
    @discardableResult
    public mutating func answer(_ id: String) -> Bool {
        guard !settled.contains(id) else { return false }
        answered[id] = shown.removeValue(forKey: id) ?? answered[id] ?? Shown()
        return true
    }

    /// The answer didn't go: the card comes back. False when Hermes stopped waiting meanwhile.
    public mutating func unanswer(_ id: String) -> Bool {
        guard !settled.contains(id), let card = answered.removeValue(forKey: id) else { return false }
        shown[id] = card
        return true
    }

    /// The turn is over: its approvals go with it.
    public mutating func endAll() {
        shown = [:]
        answered = [:]
        settled = []
    }
}
