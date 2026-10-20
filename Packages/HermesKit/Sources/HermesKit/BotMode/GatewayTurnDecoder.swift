import Foundation

/// Maps backend gateway (`/api/ws`) turn events onto ``TurnEvent``s, so Bot Chats
/// share the transcript engine and UI with gateway API chats.
public enum GatewayTurnDecoder {
    public static func decode(_ event: GatewayEvent) -> [SequencedTurnEvent] {
        let payload = event.payload
        let events: [TurnEvent]
        switch event.type {
        case "message.delta":
            events = payload["text"]?.stringValue.map { [.textDelta($0)] } ?? []
        case "message.interim":
            let text = payload["text"]?.stringValue ?? ""
            events = text.isEmpty ? [] : [.commentary(text, alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)]
        case "reasoning.delta", "reasoning.available":
            events = payload["text"]?.stringValue.map { [.reasoning($0, replacing: event.type == "reasoning.available")] } ?? []
        case "thinking.delta":
            // Mostly spinner rewrites; only explained provider waits are worth a status line.
            events = providerWait(payload["text"]?.stringValue).map { [.status($0)] } ?? []
        case "tool.start" where ToolDescriptor.isPlanTool(payload["name"]?.stringValue ?? ""):
            events = [] // the plan shows as a card (todo.updated)
        case "tool.complete" where ToolDescriptor.isPlanTool(payload["name"]?.stringValue ?? ""):
            events = PlanItem.list(from: payload["todos"]).map { [.plan($0)] } ?? []
        case "moa.reference":
            events = [.models(label: payload["label"]?.stringValue, done: true, total: payload["count"]?.truncatedIntValue, text: payload["text"]?.stringValue, aggregator: nil)]
        case "moa.progress":
            events = [.models(label: payload["label"]?.stringValue, done: false, total: payload["refs_total"]?.truncatedIntValue, text: nil, aggregator: nil)]
        case "moa.aggregating":
            events = [.models(label: nil, done: false, total: nil, text: nil, aggregator: payload["aggregator"]?.stringValue ?? "a model")]
        case "todo.updated":
            events = PlanItem.list(from: payload["todos"]).map { [.plan($0)] } ?? []
        case "tool.output_risk":
            let findings: [String]
            if case .array(let rows)? = payload["findings"] { findings = rows.compactMap(\.stringValue) } else { findings = [] }
            let name = payload["name"]?.stringValue ?? "tool"
            let risk = ToolRisk(risk: payload["risk"]?.stringValue, findings: findings,
                                redacted: payload["redacted"]?.boolValue ?? false, tool: name)
            // Characters ordinary pages carry (a zero-width space) earn no note: the step keeps none.
            events = risk.isQuiet ? [] : [.toolRisk(id: payload["tool_id"]?.stringValue, name: name, risk: risk)]
        case "tool.start":
            let name = payload["name"]?.stringValue ?? "tool"
            let preview = nonEmpty(payload["preview"]?.stringValue) ?? nonEmpty(payload["context"]?.stringValue)
                ?? ToolDescriptor.argumentPreview(name: name, arguments: payload["args"])
            events = name.hasPrefix("_") ? [] : [.toolStarted(id: payload["tool_id"]?.stringValue, name: name, preview: preview, at: nil)]
        case "tool.complete":
            let name = payload["name"]?.stringValue ?? "tool"
            let resultText = nonEmpty(payload["result_text"]?.stringValue)
                ?? payload["result"].map { $0.stringValue ?? $0.displayText }
            let preview = nonEmpty(payload["summary"]?.stringValue) ?? resultText.map { String($0.prefix(4000)) }
            var finished: [TurnEvent] = name.hasPrefix("_") ? [] : [.toolFinished(
                id: payload["tool_id"]?.stringValue,
                name: name,
                failed: ToolDescriptor.looksLikeFailure(resultText ?? ""),
                duration: payload["duration_s"]?.doubleValue,
                resultPreview: preview,
                at: nil
            )]
            let diff = nonEmpty(payload["inline_diff"]?.stringValue).flatMap(InlineDiff.unified)
            let output = nonEmpty(payload["result_text"]?.stringValue)
            if !finished.isEmpty, diff != nil || output != nil {
                finished.append(.toolDetails(id: payload["tool_id"]?.stringValue, name: name, diff: diff, output: output))
            }
            if let todos = PlanItem.list(from: payload["todos"]) {
                finished.append(.plan(todos))
            }
            events = finished
        case "status.update":
            let kind = payload["kind"]?.stringValue ?? ""
            let text = nonEmpty(payload["text"]?.stringValue)
            if let text, let warning = warning(kind: kind, text: text) {
                events = [.warning(warning)]
            } else if kind == "process", let text, isProcessNotice(text) {
                // For Hermes, which answers in its next turn: the step and the chip show it.
                events = []
            } else {
                events = ["status", "lifecycle", "compacting", "process"].contains(kind) ? text.map { [.status($0)] } ?? [] : []
            }
        case "subagent.start":
            events = [.subagentStarted(id: payload["subagent_id"]?.stringValue, goal: payload["goal"]?.stringValue)]
        case "subagent.complete":
            let status = payload["status"]?.stringValue ?? "completed"
            events = [.subagentFinished(
                id: payload["subagent_id"]?.stringValue,
                summary: payload["summary"]?.stringValue,
                failed: !["completed", "complete", "ok", "success"].contains(status)
            )]
        case "message.complete":
            let text = payload["text"]?.stringValue ?? payload["rendered"]?.stringValue ?? ""
            let usage = decodeNested(TokenUsage.self, payload["usage"])
            let warning: [TurnEvent] = nonEmpty(payload["warning"]?.stringValue).map { [.warning($0)] } ?? []
            switch payload["status"]?.stringValue {
            case "interrupted":
                events = warning + [.finalText(text), .cancelled]
            case "error":
                let message = nonEmpty(payload["error"]?.stringValue) ?? nonEmpty(payload["failure_reason"]?.stringValue)
                let problem: [TurnEvent] = ProviderProblem.from(surface: payload["error_surface"]).map { [.providerProblem($0)] } ?? []
                events = warning + [.finalText(text)] + problem + [.failed(message)]
            default:
                events = warning + [.finalText(text), .completed(output: text, usage: usage, runtime: nil)]
            }
        case "session.info":
            events = payload["running"]?.boolValue == false ? [.settled] : []
        case "session.title":
            events = nonEmpty(payload["title"]?.stringValue).map { [.titleChanged($0)] } ?? []
        case "request.cancel":
            // `id` is the server request's JSON-RPC id (srq-…), not the approval's request_id.
            events = payload["method"]?.stringValue == "approval" ? [.approvalResolved(requestID: nil)] : []
        case "approval.cancelled":
            events = [.approvalResolved(requestID: nil)]
        case "error":
            // `code: provider_not_configured`: no model provider set up, for the setup flow.
            let problem: [TurnEvent] = payload["code"]?.stringValue == "provider_not_configured"
                ? [.providerProblem(ProviderProblem(kind: .notConfigured))] : []
            events = problem + [.failed(nonEmpty(payload["message"]?.stringValue))]
        default:
            events = []
        }
        return events.map { SequencedTurnEvent(seq: event.seq, event: $0) }
    }

    /// Desktop's `providerWaitText`: wait notices the core emits after prolonged silence.
    /// A status that's a lasting note about the turn, not progress: Hermes' `warn` kind, and the
    /// "⚠" diagnostics it sends as plain lifecycle text (a safety refusal, a guardrail halt, the
    /// compression model's window). Without the "⚠", which the note draws itself.
    /// A `status.update {kind: "process"}` about a background process ("Background Process
    /// Finished: make release", "[IMPORTANT: Background process proc_… …]"): Hermes's to act on,
    /// never a status line (`docs/background-processes.md` §1).
    public static func isProcessNotice(_ text: String) -> Bool {
        text.range(of: "background process", options: .caseInsensitive) != nil
    }

    static func warning(kind: String, text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let flagged = text.unicodeScalars.first == "\u{26A0}" // "⚠" or "⚠️"
        // Any kind: the gateway re-tags lifecycle text that mentions compression as `compacting`
        // (tui_gateway/server.py `_status_update`), and the compression warnings all do.
        guard kind == "warn" || (flagged && providerWait(text) == nil) else { return nil }
        guard flagged else { return text }
        let body = String(String.UnicodeScalarView(text.unicodeScalars.drop {
            $0 == "\u{26A0}" || $0 == "\u{FE0F}" || $0.properties.isWhitespace
        }))
        return body.isEmpty ? nil : body
    }

    static func providerWait(_ text: String?) -> String? {
        guard let text = nonEmpty(text) else { return nil }
        let pattern = #"^(?:⏳|⚠|↻|⚙)\s*(?:(?:still\s+)?waiting on|loading|processing prompt|no (?:output|response)|model returned|rate limited|provider (?:overloaded|temporarily unavailable))"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil ? text : nil
    }

    /// An `approval` server request as an ``ApprovalRequest`` answerable by its JSON-RPC id.
    public static func approval(from request: GatewayServerRequest) -> ApprovalRequest? {
        guard request.method == "approval", let data = try? JSONEncoder().encode(request.params),
              var approval = try? JSONDecoder().decode(ApprovalRequest.self, from: data)
        else { return nil }
        approval.gatewayRequestID = request.id
        return approval
    }
}
