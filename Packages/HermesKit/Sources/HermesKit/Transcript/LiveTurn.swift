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
    /// Where Hermes stored the turn's rows, from its end (`message.complete.persisted_turn`).
    public private(set) var persisted: PersistedTurn?
    /// The turn ended without hearing how: the session said it was idle with no end of the turn
    /// before it (a gateway restart, a stream that never came back).
    public private(set) var endedUnheard = false

    public init(id: String, sessionID: String?, startedAt: Date = .now) {
        self.turn = AssistantTurn(id: id, state: .streaming, startedAt: startedAt)
        self.sessionID = sessionID
    }

    /// Carries on a turn the stored chat holds partway (this device joined it running): its steps
    /// and text so far stay, under the same identity, and the live events add to them.
    public init(continuing stored: AssistantTurn, sessionID: String?, startedAt: Date? = nil) {
        var turn = stored
        turn.state = .streaming
        turn.finishedAt = nil
        if let startedAt { turn.startedAt = startedAt }
        pendingText = turn.answer
        turn.answer = ""
        self.turn = turn
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
            let media = AgentAudio.split(pendingText)
            current.answer = TranscriptBuilder.cleanAssistantText(media.text)
            current.audio += media.audio
        }
        current.relateRewrites()
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
                id: ToolActivity.stableID(callID: callID, fallback: "\(turn.id)-s\(turn.steps.count)", in: turn.steps),
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

        case .providerProblem(let problem):
            turn.providerProblem = problem

        case .failed(let message):
            if turn.providerProblem == nil { turn.providerProblem = ProviderProblem.from(message: message) }
            let fallback = pendingText.isEmpty ? "Hermes couldn't finish this reply." : "The reply was cut short."
            finish(.failed(message ?? fallback), now: now)

        case .held(let hold):
            // The chat takes it to wait for the chat instead; a turn that gets this far shows Hermes's words.
            finish(.failed(hold.sentence), now: now)

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

        case .persisted(let receipt):
            persisted = receipt

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

    /// The session says it's idle and the turn never heard how it ended. It ends here so the chat
    /// can read how it ended; until the stored chat says, it holds as lost (`heldTurn`).
    public mutating func settleUnheard(now: Date = .now) {
        guard !isFinished else { return }
        endedUnheard = true
        finish(.complete, now: now)
    }

    /// What a turn that lost its run says until the stored chat shows how it ended (`docs/chat.md`
    /// §2): one line, with Reload, in the turn's header (`turnHeaderLost`). Never an endless shimmer.
    public static var lostTrack: String {
        String(localized: "Lost track of this reply. Reload to see how it ended.")
    }

    /// The turn as it stays on screen while its stored rows aren't whole: as it ended, or, when
    /// it never heard its end, saying the app lost track of it rather than "Worked for …".
    public var heldTurn: AssistantTurn {
        var held = snapshot
        if endedUnheard, !held.endedEmpty { held.state = .failed(Self.lostTrack) }
        return held
    }

    /// A turn this device joins while it runs (back from the background, a dropped stream,
    /// another device's turn). When the stored chat stops partway through a turn, that is this
    /// one (Hermes takes one writer per chat): its stored part carries on live as the same turn,
    /// rather than settling as done with a second turn below it. Its time is the run's own
    /// (`turn_started_at`), so the live count and the final "Worked for" agree.
    /// - Returns: the rows without the stored part taken over, and the live turn.
    public static func joining(_ items: [TranscriptItem], sessionID: String?, startedAt: Date?,
                               id: String = "live-\(UUID().uuidString)") -> (rest: [TranscriptItem], live: LiveTurn) {
        guard let last = items.indices.last, case .assistant(let stored) = items[last], stored.isWorking else {
            return (items, LiveTurn(id: id, sessionID: sessionID, startedAt: startedAt ?? .now))
        }
        return (Array(items.dropLast()), LiveTurn(continuing: stored, sessionID: sessionID, startedAt: startedAt))
    }

    /// The part of this turn Hermes has stored so far (it stores as it goes): the rows after
    /// `after`, the newest stored message from before the turn. `nil` while nothing of it is.
    public static func storedPart(of messages: [SessionMessage], after: Int?) -> AssistantTurn? {
        let rows = messages.filter { message in
            guard let after else { return true }
            return (message.id ?? .max) > after
        }
        guard case .assistant(let stored)? = TranscriptBuilder.build(rows).last else { return nil }
        return stored
    }

    /// A re-attach's replay (`session.events.since`): one with a hole marks the turn for its stored
    /// rows (`needsReload`), as a run's `replay.truncated` does.
    public mutating func note(_ replay: EventReplay) {
        if replay.truncated { needsReload = true }
    }

    /// A turn marked for its stored rows takes the steps it missed from them (`takeStored`): the
    /// rows after `after`, the newest stored message from before the turn. Nothing while none of
    /// it is stored; it stays marked then.
    public mutating func takeStored(from messages: [SessionMessage], after: Int?) {
        guard needsReload, !isFinished, let part = Self.storedPart(of: messages, after: after) else { return }
        takeStored(part)
    }

    /// Takes the steps this turn missed (`needsReload`) from its stored part: the stored steps
    /// in their order, each call and each piece of words already on screen kept as it was seen
    /// (same identity; a call seen running that finished in the hole takes its stored end), words
    /// seen that Hermes didn't store kept before the call they came before, then what streamed
    /// in after the newest call seen (with none in common, from the live turn's first call: the
    /// words before a call are stored with it; with no call at all, the words not stored yet).
    /// A stored call without its result still runs.
    /// Calls pair by their ids, which the socket's events carry and the API server's don't.
    public mutating func takeStored(_ stored: AssistantTurn) {
        let live = turn.steps
        func callID(_ step: AssistantStep) -> String? {
            if case .tool(let tool) = step { tool.callID } else { nil }
        }
        func words(_ step: AssistantStep) -> String? {
            switch step {
            case .narration(_, let text): "narration:" + text
            case .reasoning(_, let text): "reasoning:" + text
            case .tool, .subagent: nil
            }
        }
        var kept: Set<String> = []
        var newestSeen: Int?
        var steps = stored.steps.map { step -> AssistantStep in
            if case .tool(var tool) = step, let id = tool.callID {
                if let index = live.firstIndex(where: { callID($0) == id }), case .tool(var seen) = live[index] {
                    newestSeen = max(newestSeen ?? index, index)
                    kept.insert(seen.id)
                    if seen.status == .running, let result = tool.result {
                        seen.status = tool.status
                        seen.result = seen.result ?? result
                    }
                    return .tool(seen)
                }
                if tool.result == nil { tool.status = .running }
                return .tool(tool)
            }
            if let stored = words(step), let same = live.first(where: { !kept.contains($0.id) && words($0) == stored }) {
                kept.insert(same.id)
                return same
            }
            return step
        }
        if let newestSeen {
            for index in live.indices where index < newestSeen && words(live[index]) != nil && !kept.contains(live[index].id) {
                let next = live[(index + 1)...].first { step in callID(step).map { id in steps.contains { callID($0) == id } } ?? false }
                let at = next.flatMap { next in steps.firstIndex { $0.id == next.id } } ?? steps.count
                steps.insert(live[index], at: at)
                kept.insert(live[index].id)
            }
        }
        let firstCall: Int? = live.firstIndex { step in
            if case .tool = step { return true }
            return false
        }
        if newestSeen == nil, firstCall == nil {
            steps += live.filter { words($0) != nil && !kept.contains($0.id) }
        } else {
            steps += live[((newestSeen.map { $0 + 1 }) ?? firstCall ?? live.count)...].filter { !kept.contains($0.id) }
        }
        turn.steps = steps
        if !stored.plan.isEmpty { turn.plan = stored.plan }
        needsReload = false
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
        let media = AgentAudio.split(pendingText)
        turn.answer = TranscriptBuilder.cleanAssistantText(media.text)
        turn.audio += media.audio
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
        let media = AgentAudio.split(text)
        turn.audio += media.audio
        let cleaned = TranscriptBuilder.cleanAssistantText(media.text)
        guard !cleaned.isEmpty else { return }
        turn.steps.append(.narration(id: "\(turn.id)-s\(turn.steps.count)", text: cleaned))
    }
}

/// What `session.events.since` answers a chat attaching again on the socket: the events it
/// missed, newest last, and whether Hermes still held them all. It keeps 512 events or 4 MiB a
/// session (tui_gateway/event_replay.py); older ones are gone, and `truncated` says the replay
/// has a hole, so the turn takes its stored rows (`LiveTurn.takeStored`).
public struct EventReplay: Sendable, Equatable {
    public var events: [GatewayEvent]
    public var truncated: Bool

    public init?(_ result: JSONValue, runtime: String) {
        guard case .array(let frames)? = result["events"] else { return nil }
        events = frames.map { frame in
            GatewayEvent(
                type: frame["type"]?.stringValue ?? "", sessionID: runtime,
                seq: frame["seq"]?.truncatedIntValue, payload: frame["payload"] ?? .object([:])
            )
        }
        truncated = result["truncated"]?.boolValue ?? false
    }
}
