import Foundation

/// One step of an agent turn, normalised from either streaming transport
/// (`/v1/runs/{id}/events` or `/api/sessions/{id}/chat/stream`).
public enum TurnEvent: Sendable, Equatable {
    case runStarted(runID: String)
    /// Raw answer text as it streams. Text written before a tool call is narration.
    case textDelta(String)
    /// Mid-turn progress text. When `alreadyStreamed`, it also arrived as deltas.
    case commentary(String, alreadyStreamed: Bool)
    /// `id` pairs start and finish exactly when the transport provides one.
    case toolStarted(id: String?, name: String, preview: String?, at: Date?)
    case toolFinished(id: String?, name: String, failed: Bool, duration: TimeInterval?, resultPreview: String?, at: Date?)
    /// Streamed reasoning text; `replacing` carries the whole block so far (Desktop's `reasoning.available`).
    case reasoning(String, replacing: Bool)
    /// The turn is fully over on the server (Desktop's `session.info running:false`).
    case settled
    case titleChanged(String)
    case subagentStarted(id: String?, goal: String?)
    case subagentFinished(id: String?, summary: String?, failed: Bool)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(requestID: String?)
    /// The authoritative final answer (session stream `assistant.completed`).
    case finalText(String)
    /// Compression rotated the conversation onto a new session id.
    case sessionChanged(String)
    case status(String)
    case completed(output: String?, usage: TokenUsage?, runtime: RuntimeInfo?)
    case failed(String?)
    case cancelled
    case interrupted(String?)
    /// The server dropped events we missed while disconnected; reload the transcript.
    case replayTruncated
    /// Extra detail for a finished tool call: its diff and full output (gateway protocol).
    case toolDetails(id: String?, name: String, diff: String?, output: String?)
    /// The agent's checklist, replaced whole (`todo.updated`, `todos` on `tool.complete`).
    case plan([PlanItem])
    /// What a tool's result tried to do (`tool.output_risk`).
    case toolRisk(id: String?, name: String, risk: ToolRisk)
    /// One line to know about a finished reply (`message.complete.warning`).
    case warning(String)
    /// Mixture of agents: a model answered (`moa.reference`), progress (`moa.progress`), or the
    /// combining model started (`moa.aggregating`).
    case models(label: String?, done: Bool, total: Int?, text: String?, aggregator: String?)
}

/// A decoded event with the stream sequence number used to resume.
public struct SequencedTurnEvent: Sendable, Equatable {
    public var seq: Int?
    public var event: TurnEvent

    public init(seq: Int?, event: TurnEvent) {
        self.seq = seq
        self.event = event
    }
}

/// Decodes `GET /v1/runs/{id}/events` frames: `id: <seq>` and the event name inside the JSON.
public enum RunEventDecoder {
    public static func decode(_ frame: ServerSentEvent) -> [SequencedTurnEvent] {
        guard let payload = JSONValue.parse(frame.data) else { return [] }
        let name = payload["event"]?.stringValue ?? frame.event
        let seq = payload["seq"]?.doubleValue.map { Int($0) } ?? frame.lastEventID.flatMap { Int($0) }
        let at = HermesDate.fromEpoch(payload["timestamp"]?.doubleValue)
        let events: [TurnEvent]
        switch name {
        case "message.delta":
            events = payload["delta"]?.stringValue.map { [.textDelta($0)] } ?? []
        case "message.interim":
            let text = payload["text"]?.stringValue ?? ""
            events = text.isEmpty ? [] : [.commentary(text, alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)]
        case "tool.started":
            let tool = payload["tool"]?.stringValue ?? "tool"
            events = tool.hasPrefix("_") ? [] : [.toolStarted(id: nil, name: tool, preview: nonEmpty(payload["preview"]?.stringValue), at: at)]
        case "tool.completed":
            let tool = payload["tool"]?.stringValue ?? "tool"
            events = tool.hasPrefix("_") ? [] : [.toolFinished(
                id: nil,
                name: tool,
                failed: payload["error"]?.boolValue ?? false,
                duration: payload["duration"]?.doubleValue,
                resultPreview: nonEmpty(payload["preview"]?.stringValue),
                at: at
            )]
        case "subagent.start":
            events = [.subagentStarted(
                id: payload["subagent_id"]?.stringValue ?? payload["child_session_id"]?.stringValue,
                goal: payload["goal"]?.stringValue ?? payload["preview"]?.stringValue
            )]
        case "subagent.complete":
            let status = payload["status"]?.stringValue ?? "completed"
            events = [.subagentFinished(
                id: payload["subagent_id"]?.stringValue ?? payload["child_session_id"]?.stringValue,
                summary: payload["summary"]?.stringValue,
                failed: !["completed", "ok", "success"].contains(status)
            )]
        case "approval.request":
            events = decodeApproval(frame.data).map { [.approvalRequested($0)] } ?? []
        case "approval.responded":
            events = [.approvalResolved(requestID: payload["request_id"]?.stringValue)]
        case "run.completed":
            events = [.completed(
                output: payload["output"]?.stringValue,
                usage: decodeNested(TokenUsage.self, payload["usage"]),
                runtime: decodeNested(RuntimeInfo.self, payload["runtime"])
            )]
        case "run.failed":
            events = [.failed(payload["error"]?.stringValue)]
        case "run.cancelled":
            events = [.cancelled]
        case "run.interrupted":
            events = [.interrupted(payload["error"]?.stringValue)]
        case "replay.truncated":
            events = [.replayTruncated]
        case "reasoning.available":
            events = nonEmpty(payload["text"]?.stringValue).map { [.reasoning($0, replacing: true)] } ?? []
        default:
            events = [] // run.steered (the steer shows as the person's message) and future events
        }
        return events.map { SequencedTurnEvent(seq: seq, event: $0) }
    }
}

/// Decodes `POST /api/sessions/{id}/chat/stream` frames: the event name is on the `event:` line.
public enum SessionStreamDecoder {
    public static func decode(_ frame: ServerSentEvent) -> [SequencedTurnEvent] {
        guard let payload = JSONValue.parse(frame.data) else { return [] }
        let seq = payload["seq"]?.doubleValue.map { Int($0) }
        let at = HermesDate.fromEpoch(payload["ts"]?.doubleValue)
        var events: [TurnEvent] = []
        switch frame.event {
        case "run.started":
            if let runID = payload["run_id"]?.stringValue { events = [.runStarted(runID: runID)] }
        case "assistant.delta":
            if let delta = payload["delta"]?.stringValue { events = [.textDelta(delta)] }
        case "assistant.commentary":
            let text = payload["text"]?.stringValue ?? ""
            if !text.isEmpty { events = [.commentary(text, alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)] }
        case "tool.started":
            let tool = payload["tool_name"]?.stringValue ?? "tool"
            if !tool.hasPrefix("_") {
                events = [.toolStarted(id: nil, name: tool, preview: nonEmpty(payload["preview"]?.stringValue), at: at)]
            }
        case "tool.completed", "tool.failed":
            let tool = payload["tool_name"]?.stringValue ?? "tool"
            if !tool.hasPrefix("_") {
                events = [.toolFinished(id: nil, name: tool, failed: frame.event == "tool.failed", duration: nil, resultPreview: nil, at: at)]
            }
        case "approval.request":
            if let approval = decodeApproval(frame.data) { events = [.approvalRequested(approval)] }
        case "assistant.completed":
            if let sessionID = payload["session_id"]?.stringValue { events.append(.sessionChanged(sessionID)) }
            events.append(.finalText(payload["content"]?.stringValue ?? ""))
        case "run.completed":
            if let sessionID = payload["session_id"]?.stringValue { events.append(.sessionChanged(sessionID)) }
            events.append(.completed(
                output: nil,
                usage: decodeNested(TokenUsage.self, payload["usage"]),
                runtime: decodeNested(RuntimeInfo.self, payload["runtime"])
            ))
        case "run.failed":
            // The failure text, if any, already arrived as `assistant.completed.content`.
            events = [.failed(nil)]
        case "run.cancelled":
            events = [.cancelled]
        case "error":
            events = [.failed(payload["message"]?.stringValue)]
        default:
            events = [] // message.started, tool.progress, done
        }
        return events.map { SequencedTurnEvent(seq: seq, event: $0) }
    }
}

func nonEmpty(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}

func decodeApproval(_ data: String) -> ApprovalRequest? {
    try? JSONDecoder().decode(ApprovalRequest.self, from: Data(data.utf8))
}

func decodeNested<T: Decodable>(_ type: T.Type, _ value: JSONValue?) -> T? {
    guard let value, value != .null, let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
