import Foundation

/// Accumulates streamed ``TurnEvent``s into an ``AssistantTurn`` the UI can render live.
public struct LiveTurn: Sendable, Equatable {
    public var turn: AssistantTurn
    /// Text written since the last tool call; becomes narration or the answer.
    public private(set) var pendingText = ""
    public private(set) var runID: String?
    /// The effective session id, which compression can change mid-turn.
    public private(set) var sessionID: String?
    public private(set) var lastSeq: Int?
    public private(set) var approval: ApprovalRequest?
    /// A transient line such as "Compacting context…".
    public private(set) var status: String?
    public private(set) var usage: TokenUsage?
    public private(set) var runtime: RuntimeInfo?
    /// Events were dropped while disconnected; the transcript must be reloaded.
    public private(set) var needsReload = false

    public init(id: String, sessionID: String?, startedAt: Date = .now) {
        self.turn = AssistantTurn(id: id, state: .streaming, startedAt: startedAt)
        self.sessionID = sessionID
    }

    /// A tool call is running (the Bot is working, not thinking).
    public var isUsingTool: Bool {
        turn.steps.contains { step in
            if case .tool(let tool) = step { tool.status == .running } else { false }
        }
    }

    public var isFinished: Bool {
        switch turn.state {
        case .streaming, .waitingForApproval: false
        case .complete, .stopped, .failed: true
        }
    }

    /// The turn as it should look right now, with in-flight text shown as the answer.
    public var snapshot: AssistantTurn {
        var current = turn
        if !isFinished {
            current.answer = TranscriptBuilder.cleanAssistantText(pendingText)
        }
        return current
    }

    public mutating func apply(_ sequenced: SequencedTurnEvent, now: Date = .now) {
        if let seq = sequenced.seq {
            lastSeq = max(lastSeq ?? seq, seq)
        }
        // The session stream never confirms an approval, and an unanswered one times out
        // as a deny. New assistant text means the model took its next step, so nothing is
        // waiting any more. (Tool events don't count: other tools may run in parallel.)
        if turn.state == .waitingForApproval {
            switch sequenced.event {
            case .textDelta, .finalText, .commentary, .reasoning:
                approval = nil
                turn.state = .streaming
            default:
                break
            }
        }
        switch sequenced.event {
        case .runStarted(let id):
            runID = id

        case .textDelta(let delta):
            pendingText += delta
            status = nil

        case .commentary(let text, let alreadyStreamed):
            guard !alreadyStreamed else { break }
            flushNarration()
            appendNarration(text)

        case .toolStarted(let callID, let name, let preview, let at):
            flushNarration()
            status = nil
            turn.steps.append(.tool(ToolActivity(
                id: "\(turn.id)-s\(turn.steps.count)",
                callID: callID,
                name: name,
                preview: preview,
                status: .running,
                startedAt: at ?? now
            )))

        case .toolFinished(let callID, let name, let failed, let duration, let preview, let at):
            // Pair by call id when the transport has one, else the oldest running call of that tool.
            let byID = callID.flatMap { id in
                turn.steps.firstIndex { step in
                    if case .tool(let tool) = step { return tool.status == .running && tool.callID == id }
                    return false
                }
            }
            guard let index = byID ?? turn.steps.firstIndex(where: { step in
                if case .tool(let tool) = step { return tool.status == .running && tool.name == name }
                return false
            }), case .tool(var tool) = turn.steps[index] else { break }
            tool.status = failed ? .failed : .succeeded
            tool.result = preview ?? tool.result
            if let duration {
                tool.duration = duration
            } else if let start = tool.startedAt {
                tool.duration = max(0, (at ?? now).timeIntervalSince(start))
            }
            turn.steps[index] = .tool(tool)

        case .subagentStarted(let id, let goal):
            flushNarration()
            turn.steps.append(.subagent(SubagentActivity(
                id: id ?? "\(turn.id)-s\(turn.steps.count)",
                goal: goal ?? "Subagent",
                status: .running
            )))

        case .subagentFinished(let id, let summary, let failed):
            let index = turn.steps.firstIndex { step in
                guard case .subagent(let agent) = step, agent.status == .running else { return false }
                return id == nil || agent.id == id
            } ?? turn.steps.firstIndex { step in
                if case .subagent(let agent) = step { return agent.status == .running }
                return false
            }
            if let index, case .subagent(var agent) = turn.steps[index] {
                agent.status = failed ? .failed : .succeeded
                agent.summary = summary
                turn.steps[index] = .subagent(agent)
            }

        case .approvalRequested(let request):
            approval = request
            turn.state = .waitingForApproval

        case .approvalResolved:
            approval = nil
            if turn.state == .waitingForApproval { turn.state = .streaming }

        case .finalText(let text):
            pendingText = text

        case .sessionChanged(let id):
            sessionID = id

        case .status(let text):
            status = text

        case .completed(let output, let usage, let runtime):
            if let output, !output.isEmpty {
                pendingText = output
            }
            self.usage = usage
            self.runtime = runtime
            if let usage { turn.usage = usage }
            finish(.complete, now: now)

        case .failed(let message):
            let fallback = pendingText.isEmpty ? "Hermes couldn't finish this reply." : "The reply was cut short."
            finish(.failed(message ?? fallback), now: now)

        case .cancelled:
            finish(.stopped, now: now)

        case .interrupted(let message):
            finish(.failed(message ?? "The gateway restarted before the reply finished."), now: now)

        case .replayTruncated:
            needsReload = true

        case .reasoning(let text, let replacing):
            guard !text.isEmpty else { break }
            if case .reasoning(let id, let existing)? = turn.steps.last {
                turn.steps[turn.steps.count - 1] = .reasoning(id: id, text: replacing ? text : existing + text)
            } else {
                flushNarration()
                turn.steps.append(.reasoning(id: "\(turn.id)-s\(turn.steps.count)", text: text))
            }

        case .toolDetails(let callID, let name, let diff, let output):
            guard let index = toolIndex(callID: callID, name: name), case .tool(var tool) = turn.steps[index] else { break }
            if let diff { tool.diff = diff }
            if let output { tool.output = output }
            turn.steps[index] = .tool(tool)

        case .toolRisk(let callID, let name, let risk):
            guard let index = toolIndex(callID: callID, name: name), case .tool(var tool) = turn.steps[index] else { break }
            tool.risk = risk
            turn.steps[index] = .tool(tool)

        case .plan(let items):
            turn.plan = items

        case .warning(let text):
            // Several can arrive in one turn; each is its own paragraph.
            if let current = turn.warning, !current.isEmpty {
                if !current.components(separatedBy: "\n\n").contains(text) { turn.warning = current + "\n\n" + text }
            } else {
                turn.warning = text
            }

        case .models(let label, let done, let total, let text, let aggregator):
            var progress = turn.models ?? ModelsProgress()
            if let label { progress.mark(label, done: done, text: text) }
            if let total { progress.total = max(progress.total, total) }
            if let aggregator { progress.aggregator = aggregator }
            progress.total = max(progress.total, progress.references.count)
            turn.models = progress

        case .settled, .titleChanged:
            break // handled by the transport driver
        }
    }

    /// The tool call an event is about: by call id, else the newest call of that tool.
    private func toolIndex(callID: String?, name: String) -> Int? {
        if let callID, let index = turn.steps.lastIndex(where: { if case .tool(let tool) = $0 { tool.callID == callID } else { false } }) {
            return index
        }
        return turn.steps.lastIndex { if case .tool(let tool) = $0 { tool.name == name } else { false } }
    }

    /// Marks the turn as stopped locally (e.g. the user cancelled before the server confirmed).
    public mutating func markStopped(now: Date = .now) {
        guard !isFinished else { return }
        finish(.stopped, now: now)
    }

    public mutating func markFailed(_ message: String, now: Date = .now) {
        guard !isFinished else { return }
        finish(.failed(message), now: now)
    }

    private mutating func finish(_ state: AssistantTurn.State, now: Date) {
        turn.answer = TranscriptBuilder.cleanAssistantText(pendingText)
        pendingText = ""
        approval = nil
        status = nil
        for index in turn.steps.indices {
            switch turn.steps[index] {
            case .tool(var tool) where tool.status == .running:
                tool.status = state == .complete ? .succeeded : .failed
                turn.steps[index] = .tool(tool)
            case .subagent(var agent) where agent.status == .running:
                agent.status = state == .complete ? .succeeded : .failed
                turn.steps[index] = .subagent(agent)
            default:
                break
            }
        }
        turn.state = state
        turn.finishedAt = now
    }

    private mutating func flushNarration() {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        appendNarration(text)
    }

    private mutating func appendNarration(_ text: String) {
        let cleaned = TranscriptBuilder.cleanAssistantText(text)
        guard !cleaned.isEmpty else { return }
        turn.steps.append(.narration(id: "\(turn.id)-s\(turn.steps.count)", text: cleaned))
    }
}
