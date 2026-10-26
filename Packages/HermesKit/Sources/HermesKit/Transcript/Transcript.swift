import Foundation

/// A conversation as the app renders it: user bubbles, assistant turns, timeline notices.
public enum TranscriptItem: Identifiable, Hashable, Sendable {
    case user(UserEntry)
    case assistant(AssistantTurn)
    case notice(Notice)
    /// A slash command run in the app, with its outcome.
    case command(CommandEntry)

    public var id: String {
        switch self {
        case .user(let entry): entry.id
        case .assistant(let turn): turn.id
        case .notice(let notice): notice.id
        case .command(let command): command.id
        }
    }
}

public struct UserEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// Images the server kept only as `[screenshot]` placeholders or `@image:` paths (``StoredImages``).
    public var imagePlaceholderCount: Int
    /// Images that are still inline in the stored content (`data:` or `https:` URLs).
    public var inlineImageURLs: [String]
    public var timestamp: Date?
    /// Set when another Bot wrote this message (`message_agent`), not the person.
    public var sender: AgentSender?
    /// Set when a routine, a webhook or other automation delivered this message, not the person.
    public var delivery: DeliverySource?
    /// Files that went with the message (see ``AttachedFiles``).
    public var fileNames: [String] = []
    /// Skills the message used (`/skill` prefixes), shown as chips.
    public var skillNames: [String] = []
    /// What the message was made of when this app sent it (command, skills, Bots and files
    /// inline); `nil` for text from elsewhere.
    public var parts: MessageParts?
    /// Sent with Steer Now while a reply was running (Hermes' `steer` rows).
    public var isSteer = false
    /// A voice message: the recording's path on the gateway (`voice-<uuid>.m4a`); the text is its
    /// transcript.
    public var voicePath: String?

    public init(id: String, text: String, imagePlaceholderCount: Int = 0, inlineImageURLs: [String] = [], timestamp: Date? = nil, sender: AgentSender? = nil, fileNames: [String] = [], skillNames: [String] = []) {
        self.id = id
        self.text = text
        self.fileNames = fileNames
        self.skillNames = skillNames
        self.imagePlaceholderCount = imagePlaceholderCount
        self.inlineImageURLs = inlineImageURLs
        self.timestamp = timestamp
        self.sender = sender
    }

    /// The person wrote it: not another Bot, a routine or anything else that delivers into a chat.
    /// Only such a message is "You", theirs to edit, resend or answer by voice, and never unread.
    public var isFromPerson: Bool { sender == nil && delivery == nil }

    /// The routine whose output this is.
    public var routineName: String? {
        get { if case .routine(let name)? = delivery { name } else { nil } }
        set { delivery = newValue.map(DeliverySource.routine) }
    }
}

/// Mixture of agents: who has answered, and which model combines the answers (`modelsCard`).
public struct ModelsProgress: Hashable, Sendable {
    public struct Reference: Hashable, Sendable {
        public var label: String
        public var isDone: Bool
        public var text: String?
    }

    public var references: [Reference] = []
    public var total: Int = 0
    public var aggregator: String?

    public init() {}

    public var doneCount: Int { references.filter(\.isDone).count }

    mutating func mark(_ label: String, done: Bool, text: String? = nil) {
        if let index = references.firstIndex(where: { $0.label == label }) {
            references[index].isDone = references[index].isDone || done
            if let text { references[index].text = text }
        } else {
            references.append(Reference(label: label, isDone: done, text: text))
        }
    }
}

/// The Bot behind a bot-to-bot message.
public struct AgentSender: Hashable, Sendable {
    public var name: String
    /// The profile handle (`hermes` for the primary profile).
    public var handle: String

    public init(name: String, handle: String) {
        self.name = name
        self.handle = handle
    }
}

public struct Notice: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var text: String
    /// The background processes or helpers a "finished" notice is about, several when notices in
    /// a row fold into one (`TranscriptBuilder.foldingFinishedWork`).
    public var work: [FinishedWork] = []
    /// When it was stored.
    public var timestamp: Date?

    public init(id: String, kind: String, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Everything the agent did for one user message.
public struct AssistantTurn: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case complete
        case streaming
        case waitingForApproval
        case stopped
        case failed(String)
    }

    public var id: String
    /// Work before the answer, in order: reasoning, narration and tool calls.
    public var steps: [AssistantStep]
    /// The final answer: text written after the last tool call.
    public var answer: String
    public var state: State
    public var startedAt: Date?
    public var finishedAt: Date?
    /// The agent's checklist for this turn (`todo_list`, `todo.updated`), shown above the steps.
    public var plan: [PlanItem] = []
    /// Tokens, cost and context use, when the transport reports them.
    public var usage: TokenUsage?
    /// What to know about a finished reply (`message.complete.warning`).
    public var warning: String?
    /// Several models answering at once (`moa.*`), then one combining them.
    public var models: ModelsProgress?
    /// Notes the person steered this turn with, each where Hermes read it (`steerStep`).
    public var steers: [SteerNote] = []
    /// Audio the Bot sent (`MEDIA:` lines), drawn as listen strips (`docs/voice.md` §2).
    public var audio: [AgentAudio] = []
    /// Why a failed turn failed, when it was the model provider's credentials (`docs/setup.md` §4.3).
    public var providerProblem: ProviderProblem?
    /// What Hermes's background self-review of this reply did (`ReviewNote`), a quiet note after it.
    public var review: String?
    /// The Bot ended the turn with a silence marker (`[SILENT]`, Bot Chats): it chose not to reply.
    public var keptQuiet = false

    public init(id: String, steps: [AssistantStep] = [], answer: String = "", state: State = .complete, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.steps = steps
        self.answer = answer
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// The turn as a chat's list places it, without its words: its id, state and times, and the
    /// helpers it started (`delegate_task`). A running reply's outline changes as it starts
    /// helpers and as it ends, not with each streamed word.
    public var outline: AssistantTurn {
        let delegations = steps.filter { step in
            if case .tool(let tool) = step { tool.name == "delegate_task" } else { false }
        }
        return AssistantTurn(id: id, steps: delegations, state: state, startedAt: startedAt, finishedAt: finishedAt)
    }

    public var toolCount: Int {
        steps.reduce(0) { count, step in
            if case .tool = step { count + 1 } else { count }
        }
    }

    public var reasoningText: String {
        steps.compactMap { step in
            if case .reasoning(_, let text) = step { text } else { nil }
        }.joined(separator: "\n\n")
    }

    public var isWorking: Bool {
        state == .streaming || state == .waitingForApproval
    }

    /// When the step running now started, so the header's live words count its time ("Running the
    /// tests… · 12s", `docs/chat.md` §4a); nil unless the last step is a tool still running.
    public var runningStepStart: Date? {
        guard isWorking, case .tool(let tool)? = steps.last, tool.status == .running else { return nil }
        return tool.startedAt
    }

    /// The app couldn't find out how the run ended (`TurnRecovery` gave up): the header says why,
    /// with Reload (`turnHeaderLost`).
    public var lostTrack: Bool { lostReason != nil }

    /// Why the app lost track of this turn, when it did.
    public var lostReason: LostTurn? {
        if case .failed(let line) = state { LostTurn(line: line) } else { nil }
    }

    /// The turn saying the app lost track of it, and why (`docs/chat.md` §2). What was still running
    /// stops with it, as a failed turn's steps do; a Reload that finds it stored partway settles them.
    public func lost(_ reason: LostTurn, now: Date = .now) -> AssistantTurn {
        var turn = self
        turn.state = .failed(reason.line)
        turn.finishedAt = finishedAt ?? now
        turn.steps = steps.map { step in
            switch step {
            case .tool(var tool) where tool.status == .running:
                tool.status = .failed
                return .tool(tool)
            case .subagent(var agent) where agent.status == .running:
                agent.status = .failed
                return .subagent(agent)
            default:
                return step
            }
        }
        return turn
    }

    /// A turn the app lost track of, after the person's Reload read a stored chat that still doesn't
    /// hold it whole (`docs/chat.md` §2): it ended there (`endedPartway`). `nil` for a turn that didn't
    /// lose track.
    public func settledAfterLoss(cutOff: Set<String>, messages: [SessionMessage]) -> AssistantTurn? {
        guard lostTrack else { return nil }
        return endedPartway(cutOff: cutOff, messages: messages)
    }

    /// A turn whose end the app didn't hear, and whose stored rows still stop partway with nothing
    /// running (`TurnRecovery`): what Hermes stored is how it ended, and it says "Stopped" as an
    /// interrupted turn does (`TurnPlacement` gave it the stored steps when they went further). What
    /// was cut off ended with it: a call Hermes stored without a result, and a step still running
    /// when the app stopped hearing (`LiveTurn.cutOff`) with no stored result either; one whose result
    /// Hermes stored finished. A call heard to its end stays as it was, with or without a preview.
    public func endedPartway(cutOff: Set<String>, messages: [SessionMessage], now: Date = .now) -> AssistantTurn {
        let answered = Set(messages.compactMap { $0.role == "tool" ? $0.toolCallID : nil })
        let called = Set(messages.flatMap { $0.toolCalls.map(\.id) })
        var turn = self
        turn.state = .stopped
        turn.finishedAt = finishedAt ?? now
        turn.steps = steps.map { step in
            switch step {
            case .tool(var tool):
                let cut = cutOff.contains(tool.id) || tool.status == .running
                if tool.callID.map(answered.contains) ?? false {
                    guard cut else { return step }
                    tool.status = .succeeded
                } else {
                    guard cut || (tool.callID.map(called.contains) ?? false) else { return step }
                    tool.status = .failed
                }
                return .tool(tool)
            case .subagent(var agent) where cutOff.contains(agent.id) || agent.status == .running:
                agent.status = .failed
                return .subagent(agent)
            default:
                return step
            }
        }
        return turn
    }

    /// Ended with nothing in it: no word, step, plan, sound, warning or steer, and no failure. A
    /// turn on screen never ends like that (`docs/chat.md` §2): Hermes is still taking it, or its
    /// reply isn't stored yet.
    public var endedEmpty: Bool {
        state == .complete && answer.isEmpty && steps.isEmpty && plan.isEmpty && audio.isEmpty
            && warning == nil && steers.isEmpty
    }

    /// Everything a reader would copy: the answer, or the narration if there is no answer.
    public var copyableText: String {
        // A widget copies as its words, never as its directive (`docs/widgets.md` §2).
        if !answer.isEmpty { return ReplySplitter.readableText(answer) }
        return ReplySplitter.readableText(narration)
    }

    /// The turn as the chat list, a notification or the Live Activity shows it: its words
    /// without widgets, not even their `alt` (`docs/widgets.md` §8).
    public var previewText: String {
        let source = answer.isEmpty ? narration : answer
        let words = WidgetPrivacy.previewText(source)
        if words.isEmpty, WidgetPrivacy.hasWidgets(source) { return String(localized: "Sent a widget") }
        return words
    }

    private var narration: String {
        steps.compactMap { step in
            if case .narration(_, let text) = step { text } else { nil }
        }.joined(separator: "\n\n")
    }
}

/// A message sent with Steer while the turn ran, and the step Hermes read it after.
public struct SteerNote: Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// How many of the turn's steps came before it was read.
    public var afterStep: Int
    public var timestamp: Date?

    public init(id: String, text: String, afterStep: Int, timestamp: Date? = nil) {
        self.id = id
        self.text = text
        self.afterStep = afterStep
        self.timestamp = timestamp
    }
}

public enum AssistantStep: Identifiable, Hashable, Sendable {
    case reasoning(id: String, text: String)
    case narration(id: String, text: String)
    case tool(ToolActivity)
    case subagent(SubagentActivity)

    public var id: String {
        switch self {
        case .reasoning(let id, _), .narration(let id, _): id
        case .tool(let tool): tool.id
        case .subagent(let subagent): subagent.id
        }
    }
}

public struct ToolActivity: Identifiable, Hashable, Sendable {
    /// A step's identity: Hermes's own call id when the transport has one, so the live step and
    /// its stored row are the same view (its open state, its cards) when the reply hands over;
    /// the position otherwise, or when the id is already taken in this turn.
    static func stableID(callID: String?, fallback: String, in steps: [AssistantStep]) -> String {
        guard let callID, !callID.isEmpty else { return fallback }
        let id = "c:\(callID)"
        return steps.contains { $0.id == id } ? fallback : id
    }

    public enum Status: Hashable, Sendable { case running, succeeded, failed }

    public var id: String
    public var callID: String?
    public var name: String
    /// A short summary of the arguments (`ls -la`, a search query, a path).
    public var preview: String?
    public var arguments: JSONValue?
    public var result: String?
    public var status: Status
    public var startedAt: Date?
    public var duration: TimeInterval?
    /// A file change as a unified diff (`tool.complete.inline_diff`).
    public var diff: String?
    /// The full result text, when the gateway sends it (`tool.complete.result_text`).
    public var output: String?
    /// Prompt injection or secrets found in the result (`tool.output_risk`).
    public var risk: ToolRisk?

    public init(
        id: String, callID: String? = nil, name: String, preview: String? = nil, arguments: JSONValue? = nil,
        result: String? = nil, status: Status, startedAt: Date? = nil, duration: TimeInterval? = nil
    ) {
        self.id = id
        self.callID = callID
        self.name = name
        self.preview = preview
        self.arguments = arguments
        self.result = result
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
    }
}

/// One item of the agent's plan.
public struct PlanItem: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case pending, inProgress = "in_progress", completed, cancelled
    }

    public var id: String
    public var content: String
    public var status: Status

    public init(id: String, content: String, status: Status) {
        self.id = id
        self.content = content
        self.status = status
    }

    /// `[{id, content, status}]`, as `todo_list` arguments, results and `todo.updated` carry it.
    public static func list(from value: JSONValue?) -> [PlanItem]? {
        guard case .array(let rows)? = value else { return nil }
        return rows.enumerated().compactMap { index, row in
            guard let content = row["content"]?.stringValue, !content.isEmpty else { return nil }
            let id = row["id"]?.stringValue ?? row["id"]?.truncatedIntValue.map(String.init) ?? "\(index)"
            return PlanItem(id: id, content: content, status: Status(rawValue: row["status"]?.stringValue ?? "") ?? .pending)
        }
    }

    /// `todo_list` with `merge: true` updates items by id and keeps the rest.
    public static func merged(_ update: [PlanItem], into plan: [PlanItem]) -> [PlanItem] {
        var result = plan
        for item in update {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}

public struct SubagentActivity: Identifiable, Hashable, Sendable {
    public var id: String
    public var goal: String
    public var summary: String?
    public var status: ToolActivity.Status
}

// MARK: - Folding stored messages

public enum TranscriptBuilder {
    static let noticeKinds: Set<String> = [
        "model_switch", "personality_switch", "auto_continue", "async_delegation_complete",
        "process_complete", "internal_notification", "failed_turn", "skill_invocation",
    ]

    /// Folds the server's message rows into renderable items, following Hermes Desktop's rules:
    /// assistant tool-call rows and their tool results merge into one turn with the text that follows.
    /// - Parameter hidesSilence: Bot Chat rules: a reply that is only a silence marker (`[SILENT]`,
    ///   `NO_REPLY`…) is not shown, nor is the internal notification it answered. Plain chats keep
    ///   the marker, as Hermes does.
    public static func build(_ messages: [SessionMessage], hidesSilence: Bool = false) -> [TranscriptItem] {
        let messages = keepingTurnsWhole(messages)
        let silentRows = hidesSilence ? silentRowIndices(messages) : []
        var items: [TranscriptItem] = []
        var turn: AssistantTurn?
        var pendingText: [String] = []
        var planCallIDs: Set<String> = []
        // A turn starts when the message it answers does, as the live turn does (`docs/chat.md` §4a).
        var askedAt: Date?

        func flushText(asAnswer: Bool) {
            guard var current = turn else { return }
            let text = pendingText.joined(separator: "\n\n")
            pendingText.removeAll()
            guard !text.isEmpty else { return }
            if asAnswer {
                current.answer = text
            } else {
                current.steps.append(.narration(id: "\(current.id)-n\(current.steps.count)", text: text))
            }
            turn = current
        }

        func closeTurn() {
            flushText(asAnswer: true)
            if var current = turn, !(hidesSilence && current.answer.isEmpty && current.steps.isEmpty) {
                current.relateRewrites()
                items.append(.assistant(current))
            }
            turn = nil
        }

        for (index, stored) in messages.enumerated() {
            if silentRows.contains(index) {
                if stored.role == "assistant" { turn?.keptQuiet = true }
                continue
            }
            // A message waiting in Hermes's queue, or one Stop cleared from it, isn't a turn: the Up
            // Next tray shows it while it waits, and Up Next gives it back after a Stop.
            if stored.role == "user", stored.isWaitingInQueue { continue }
            var message = stored
            let rowID = message.id.map { "m\($0)" } ?? "i\(index)"
            let kind = message.displayKind
            if kind == nil || kind == "hidden", message.role == "user" || message.role == "assistant",
               let parts = CompactionSummary.parse(message.content.text) {
                // A compaction's summary is nobody's message: a divider in its place, with the
                // message Hermes folded it into before it and the one it leads after it. Hermes's
                // projection hides a summary on its own, but keeps its words (`_project_for_display`).
                closeTurn()
                // The divider says when Hermes compacted the chat (`compactionDivider`).
                var divider = Notice(id: "\(rowID)-s", kind: Notice.compactionKind, text: parts.summary)
                divider.timestamp = message.timestamp
                if kind == "hidden" {
                    if !parts.summary.isEmpty {
                        items.append(.notice(divider))
                    }
                    continue
                }
                if !parts.before.isEmpty {
                    var prior = message
                    prior.content = .text(parts.before)
                    prior.toolCalls = []
                    if message.role == "user" {
                        items.append(.user(userEntry(id: "\(rowID)-p", message: prior)))
                    } else {
                        let text = cleanAssistantText(parts.before)
                        items.append(.assistant(AssistantTurn(id: "t\(rowID)-p", answer: text, startedAt: message.timestamp, finishedAt: message.timestamp)))
                    }
                }
                if !parts.summary.isEmpty {
                    items.append(.notice(divider))
                }
                guard !parts.after.isEmpty || !message.toolCalls.isEmpty else { continue }
                message.content = .text(parts.after)
            }
            if message.role == "user", kind != "steer" {
                askedAt = kind.map(noticeKinds.contains) == true ? nil : message.timestamp
            }

            switch message.role {
            case "user":
                if kind == "hidden" { continue }
                if kind == nil, HermesScaffold.isHidden(message.content.text) { continue }
                if kind == "steer" {
                    // A steer lands mid-turn, after a tool result, and the same reply goes on: it
                    // stays in that turn, read after the steps so far, as it showed live.
                    let entry = steerEntry(id: rowID, message: message)
                    flushText(asAnswer: false)
                    if var current = turn {
                        current.steers.append(SteerNote(id: rowID, text: entry.text, afterStep: current.steps.count, timestamp: message.timestamp))
                        turn = current
                    } else {
                        items.append(.user(entry))
                    }
                    continue
                }
                // A finished process or helpers reads as such whatever Hermes tagged it: on a
                // messaging platform it's an `internal_notification` with a footer.
                let noticeKind = finishedWorkKind(message.content.text) ?? kind ?? untaggedNoticeKind(message.content.text)
                if let kind = noticeKind, noticeKinds.contains(kind),
                   !isDelivered(kind: kind, text: message.content.text) {
                    closeTurn()
                    items.append(.notice(notice(id: rowID, kind: kind, message: message)))
                    continue
                }
                closeTurn()
                items.append(.user(userEntry(id: rowID, message: message)))

            case "assistant":
                if let kind, noticeKinds.contains(kind) {
                    closeTurn()
                    items.append(.notice(notice(id: rowID, kind: kind, message: message)))
                    continue
                }
                if turn == nil {
                    turn = AssistantTurn(id: "t\(rowID)", startedAt: askedAt ?? message.timestamp)
                    askedAt = nil
                }
                if let reasoning = message.reasoning {
                    flushText(asAnswer: false)
                    turn?.steps.append(.reasoning(id: "\(rowID)-r", text: reasoning))
                }
                let silenced = hidesSilence && BotMentions.isSilenceMarker(message.content.text)
                if silenced { turn?.keptQuiet = true }
                let media = AgentAudio.split(message.content.text)
                if kind != "hidden", !silenced, !media.audio.isEmpty { turn?.audio += media.audio }
                let text = kind == "hidden" || silenced ? "" : cleanAssistantText(media.text)
                if !text.isEmpty {
                    pendingText.append(text)
                }
                if !message.toolCalls.isEmpty {
                    flushText(asAnswer: false)
                    for (callIndex, call) in message.toolCalls.enumerated() {
                        let arguments = call.parsedArguments
                        if ToolDescriptor.isPlanTool(call.name) {
                            // The plan is a card above the steps, not a step.
                            if let items = PlanItem.list(from: arguments?["todos"]) {
                                let merge = arguments?["merge"]?.boolValue ?? false
                                let current = turn?.plan ?? []
                                turn?.plan = merge ? PlanItem.merged(items, into: current) : items
                            }
                            planCallIDs.insert(call.id ?? "")
                            continue
                        }
                        if WidgetToolResult.toolNames.contains(call.name) {
                            // The card is the step (`docs/widgets.md` §2).
                            planCallIDs.insert(call.id ?? "")
                            continue
                        }
                        let stepID = ToolActivity.stableID(callID: call.id, fallback: "\(rowID)-c\(callIndex)", in: turn?.steps ?? [])
                        turn?.steps.append(.tool(ToolActivity(
                            id: stepID,
                            callID: call.id,
                            name: call.name,
                            preview: ToolDescriptor.argumentPreview(name: call.name, arguments: arguments),
                            arguments: arguments,
                            status: .succeeded,
                            startedAt: message.timestamp
                        )))
                    }
                }
                turn?.finishedAt = message.timestamp

            case "tool":
                guard var current = turn else { continue }
                if let callID = message.toolCallID, planCallIDs.contains(callID) { continue }
                if ToolDescriptor.isPlanTool(message.toolName ?? "") || WidgetToolResult.toolNames.contains(message.toolName ?? "") { continue }
                let output = cleanToolOutput(message.content.text)
                let failed = ToolDescriptor.looksLikeFailure(output)
                // Pair by call id among calls still without a result, else by tool name.
                let candidates = current.steps.indices.filter { index in
                    if case .tool(let tool) = current.steps[index], tool.result == nil { return true }
                    return false
                }
                let match = candidates.first { index in
                    if case .tool(let tool) = current.steps[index] { return tool.callID != nil && tool.callID == message.toolCallID }
                    return false
                } ?? candidates.first { index in
                    if case .tool(let tool) = current.steps[index] { return tool.name == message.toolName }
                    return false
                }
                if let match, case .tool(var tool) = current.steps[match] {
                    tool.result = output
                    tool.status = failed ? .failed : .succeeded
                    if let start = tool.startedAt, let end = message.timestamp, end >= start {
                        tool.duration = end.timeIntervalSince(start)
                    }
                    current.steps[match] = .tool(tool)
                } else {
                    current.steps.append(.tool(ToolActivity(
                        id: ToolActivity.stableID(callID: message.toolCallID, fallback: rowID, in: current.steps),
                        callID: message.toolCallID, name: message.toolName ?? "tool",
                        result: output, status: failed ? .failed : .succeeded, startedAt: message.timestamp
                    )))
                }
                current.finishedAt = message.timestamp
                turn = current

            default:
                continue // system rows
            }
        }
        closeTurn()
        return foldingFinishedWork(linkingFinishedProcesses(hidesSilence ? withoutRoutineEchoes(items) : items))
    }

    /// Each finished process gets what its notice doesn't carry from the step that started it
    /// (`docs/chat.md` §2a): when it started, and its command or the Bot it messaged when the
    /// notice names only its id. Hermes holds a completion until the chat is free, so the notice's
    /// time is when it ended only when Hermes was idle while it ran: the turn that started it ended
    /// within a few seconds of starting it, and nothing but other notices came after that turn.
    /// Otherwise it has no duration here; the gateway's list can still say (`FinishedProcess.timed`).
    static func linkingFinishedProcesses(_ items: [TranscriptItem]) -> [TranscriptItem] {
        guard items.contains(where: { if case .notice(let notice) = $0 { notice.work.contains(where: \.isProcess) } else { false } }) else { return items }
        var items = items
        var starts: [String: ToolActivity] = [:]
        // Processes whose notice's time can still be read as their end.
        var idle: Set<String> = []
        for index in items.indices {
            switch items[index] {
            case .assistant(let turn):
                idle.removeAll()
                for case .tool(let tool) in turn.steps {
                    guard let id = tool.startedProcessID else { continue }
                    starts[id] = tool
                    if let started = tool.startedAt, let ended = turn.finishedAt, ended.timeIntervalSince(started) <= idleTurnEnd {
                        idle.insert(id)
                    }
                }
            case .notice(var notice) where notice.work.contains(where: \.isProcess):
                notice.work = notice.work.map { work in
                    guard case .process(var process) = work else { return work }
                    if let tool = starts[process.id] { process.link(startedBy: tool) }
                    if idle.contains(process.id) { process.endedAt = process.endedAt ?? notice.timestamp }
                    return .process(process)
                }
                notice.text = Notice.finishedLine(notice.work) ?? notice.text
                items[index] = .notice(notice)
            case .notice:
                continue
            default:
                idle.removeAll()
            }
        }
        return items
    }

    /// How soon after starting a process its turn must end for the chat to have been idle.
    static let idleTurnEnd: TimeInterval = 10

    /// A stored notice, with what it's about when it's finished work.
    static func notice(id: String, kind: String, message: SessionMessage) -> Notice {
        let work = FinishedWork.parse(kind: kind, text: message.content.text)
        var notice = Notice(id: id, kind: kind, text: Notice.finishedLine(work) ?? noticeText(kind: kind, content: message.content.text))
        notice.work = work
        notice.timestamp = message.timestamp
        return notice
    }

    /// Notices of finished work in a row, with nothing between them, are one line that opens to
    /// each: "3 background processes finished" (`docs/chat.md` §2a). Processes and helpers fold
    /// apart. The line keeps the first notice's identity, so one that joins it doesn't move it.
    static func foldingFinishedWork(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var kept: [TranscriptItem] = []
        kept.reserveCapacity(items.count)
        for item in items {
            if case .notice(let next) = item, !next.work.isEmpty,
               case .notice(var folded)? = kept.last, folded.kind == next.kind, !folded.work.isEmpty {
                folded.work += next.work
                folded.text = Notice.finishedLine(folded.work) ?? folded.text
                folded.timestamp = next.timestamp ?? folded.timestamp
                kept[kept.count - 1] = .notice(folded)
                continue
            }
            kept.append(item)
        }
        return kept
    }

    /// The kind of a finished process's or helpers' notice by its words, however it's tagged.
    static func finishedWorkKind(_ text: String) -> String? {
        let head = text.drop { $0.isWhitespace }
        if head.hasPrefix(FinishedProcess.prefix) || head.range(of: #"^\[IMPORTANT: \d+ background processes completed( for this session)?\."#, options: .regularExpression) != nil {
            return "process_complete"
        }
        if head.hasPrefix("[ASYNC DELEGATION ") { return "async_delegation_complete" }
        return nil
    }

    /// Rows another writer stored in the middle of a turn go after it. A model writes nothing while
    /// its tool calls wait for their results, so a row stored then (a routine's delivery and its
    /// reply, another Bot's message from a one-shot `hermes chat`) isn't part of the turn: a turn
    /// broken there showed in two halves, with a step in both (its call above the delivery, its
    /// result below). A steer is read inside the turn and stays where it is.
    static func keepingTurnsWhole(_ messages: [SessionMessage]) -> [SessionMessage] {
        var kept: [SessionMessage] = []
        kept.reserveCapacity(messages.count)
        var waiting: [String?] = [] // the turn's calls still without a result (nil: a call without an id)
        var aside: [SessionMessage] = []
        for message in messages {
            if !waiting.isEmpty {
                if message.role == "tool" {
                    if let index = waiting.firstIndex(where: { $0 != nil && $0 == message.toolCallID }) ?? waiting.firstIndex(where: { $0 == nil }) {
                        waiting.remove(at: index)
                        kept.append(message)
                        continue
                    }
                } else if message.displayKind == "steer" {
                    kept.append(message)
                    continue
                }
                aside.append(message)
                continue
            }
            if message.role == "user", message.displayKind != "steer", !aside.isEmpty {
                kept += aside // after the turn, before the next message
                aside = []
            }
            kept.append(message)
            if message.role == "assistant" {
                waiting = message.toolCalls.map(\.id)
            }
        }
        return kept + aside
    }

    /// Bot Chat rules: Hermes asks the Bot to summarize each routine delivery, and some Bots
    /// answer with the delivery again, so the chat showed the same brief twice, the second time
    /// without its formatting. A reply straight after a delivery that used no tools and repeats it
    /// (`BotMentions.repeats`) keeps only the lines it adds, and isn't shown when it adds none:
    /// the routine's card has the rest.
    static func withoutRoutineEchoes(_ items: [TranscriptItem]) -> [TranscriptItem] {
        var kept: [TranscriptItem] = []
        kept.reserveCapacity(items.count)
        for item in items {
            if case .assistant(var turn) = item, case .user(let delivery)? = kept.last, delivery.delivery != nil,
               !turn.steps.contains(where: { if case .tool = $0 { true } else { false } }),
               let added = BotMentions.linesAdded(by: turn.answer, to: delivery.text) {
                if added.isEmpty { continue }
                turn.answer = added
                kept.append(.assistant(turn))
                continue
            }
            kept.append(item)
        }
        return kept
    }

    /// The stored rows from before a turn this device has in flight: up to the turn's message once
    /// Hermes has stored it, else all of them. That message is the newest one from the person with
    /// its words (after anything Hermes put before them, like an attached file) stored no earlier
    /// than a few minutes before it was sent, or any stored after it was sent. A chat whose history
    /// comes only after a message went out (a busy Mac) shows it above that message, and never the
    /// message twice.
    public static func history(_ messages: [SessionMessage], before ask: String?, sentAt: Date?) -> [SessionMessage] {
        let words = ask?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cut = messages.lastIndex { message in
            // A steer is read partway through the turn, never the message that opened it.
            guard message.role == "user", message.displayKind != "hidden", message.displayKind != "steer" else { return false }
            guard let sentAt, let stored = message.timestamp else {
                return !words.isEmpty && message.content.text.trimmingCharacters(in: .whitespacesAndNewlines) == words
            }
            if stored >= sentAt.addingTimeInterval(-2) { return true }
            guard !words.isEmpty, stored >= sentAt.addingTimeInterval(-300) else { return false }
            return message.content.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(words)
        }
        guard let cut else { return messages }
        return Array(messages[..<cut])
    }

    /// The stored messages hold a turn that ended after message `after`: a message newer than
    /// that, ending in the reply (an answer without tool calls) or a failed turn's notice. A
    /// stopped turn may store no answer at all: your message is enough.
    public static func holdsTurn(_ messages: [SessionMessage], after: Int?, stopped: Bool = false) -> Bool {
        let fresh = messages.filter { message in
            guard let after else { return true }
            return (message.id ?? .max) > after
        }
        guard fresh.contains(where: { $0.role == "user" }) || after == nil else { return false }
        if stopped || fresh.contains(where: { $0.displayKind == "failed_turn" }) { return true }
        guard let last = fresh.last(where: { $0.role != "tool" }) else { return false }
        return last.role == "assistant" && last.toolCalls.isEmpty
    }

    /// The newest stored message from before a turn, which the turn's stored rows follow. With the
    /// person's message still shown as sent from here (`ask`), the rows before it, even when the
    /// stored chat already holds the turn: taking the newest row then made the turn's own rows its
    /// history, so the turn never seemed stored and showed twice. A turn this device joined partway
    /// may be stored from its message on already (Hermes without turn isolation stores as it goes):
    /// its rows then start before that message, not after the newest one held.
    public static func newestBeforeTurn(_ messages: [SessionMessage], ask: String?, sentAt: Date?) -> Int? {
        if let ask { return history(messages, before: ask, sentAt: sentAt).last?.id }
        guard let start = messages.lastIndex(where: { $0.role == "user" && $0.displayKind != "steer" }),
              !holdsTurn(Array(messages[start...]), after: nil)
        else { return messages.last?.id }
        return start > 0 ? messages[start - 1].id : nil
    }

    /// How long a turn whose stored rows stop mid-work still counts as working.
    public static let midTurnStaleAfter: TimeInterval = 20 * 60

    /// The stored chat's last turn hasn't ended: its last row is a tool call or a tool's result,
    /// so Hermes is still on it somewhere the app hears nothing from (a Bot's one-shot `hermes
    /// chat`, a routine), unless its last row is older than `staleAfter` (a turn that died).
    public static func endsMidTurn(_ messages: [SessionMessage], now: Date = .now,
                                   staleAfter: TimeInterval = midTurnStaleAfter) -> Bool {
        guard let last = lastTurnRow(messages),
              last.role == "tool" || (last.role == "assistant" && !last.toolCalls.isEmpty),
              let at = last.timestamp else { return false }
        return now.timeIntervalSince(at) < staleAfter
    }

    /// How long another Bot's message (or a routine's output) with nothing after it still counts as
    /// being answered. Its first step is stored after the first model call, so a turn silent this
    /// long has died (the sender's delivery is stopped when Hermes closes the sender's chat).
    public static let replyToBotStaleAfter: TimeInterval = 10 * 60

    /// The chat's last row is a message Hermes answers in a one-shot `hermes -p <bot> chat`, with
    /// nothing after it yet: another Bot's, or a routine's output stored without a display kind
    /// (Hermes's scheduler hands it to that process; one tagged `internal_notification` is a
    /// dashboard turn, which the app hears). Hermes stores it as that turn starts, and the reply
    /// follows from that process, which the app hears nothing from (`docs/chat.md`, a turn going on
    /// elsewhere).
    public static func awaitsReply(_ messages: [SessionMessage], now: Date = .now,
                                   staleAfter: TimeInterval = replyToBotStaleAfter) -> Bool {
        guard let last = lastTurnRow(messages), last.role == "user", answeredElsewhere(last) != nil,
              let at = last.timestamp else { return false }
        return now.timeIntervalSince(at) < staleAfter
    }

    /// Who a message answered in a one-shot `hermes chat` is from: the Bot that sent it, or the
    /// routine whose output it is.
    enum ElsewhereSender {
        case bot(String)
        case routine(String)
    }

    static func answeredElsewhere(_ message: SessionMessage) -> ElsewhereSender? {
        let text = message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let agent = BotMentions.parseAgentMessage(text) { return .bot(agent.senderName) }
        guard message.displayKind == nil, let routine = BotMentions.parseRoutineDelivery(text) else { return nil }
        return .routine(routine.name)
    }

    /// A turn runs where no events reach the app: it stopped mid-work, or it has only just taken
    /// another Bot's message or a routine's output. The chat, its row, its tile and the jump line
    /// show it working.
    public static func runsElsewhere(_ messages: [SessionMessage], now: Date = .now) -> Bool {
        endsMidTurn(messages, now: now) || awaitsReply(messages, now: now)
    }

    /// The rows `build` keeps in a turn decide it: a hidden nudge or a steer stored last doesn't end
    /// the turn (they're skipped, or read inside it), so the turn doesn't flip between done and
    /// working from one poll to the next.
    static func lastTurnRow(_ messages: [SessionMessage]) -> SessionMessage? {
        messages.last { message in
            switch message.role {
            case "assistant", "tool": true
            case "user": message.displayKind != "hidden" && message.displayKind != "steer"
            default: false
            }
        }
    }

    /// When the stored rows stop mid-turn (`endsMidTurn`), the last turn shows as working: its
    /// timer runs, what it last said shows, and a call without a result yet runs. Returns whether
    /// it did.
    @discardableResult
    public static func markMidTurn(_ items: inout [TranscriptItem], messages: [SessionMessage], now: Date = .now) -> Bool {
        if awaitsReply(messages, now: now), case .user(let message)? = items.last {
            // Another Bot's message or a routine's output, its answer not started in the stored rows
            // yet: a working turn under it, until the first step is stored.
            let at = lastTurnRow(messages)?.timestamp
            items.append(.assistant(AssistantTurn(id: "t-reply-\(message.id)", state: .streaming, startedAt: at)))
            return true
        }
        guard endsMidTurn(messages, now: now),
              let index = items.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
              index == items.count - 1, case .assistant(var turn) = items[index], turn.state == .complete else { return false }
        turn.state = .streaming
        turn.finishedAt = nil
        if let open = turn.steps.lastIndex(where: { if case .tool(let tool) = $0 { tool.result == nil } else { false } }),
           case .tool(var tool) = turn.steps[open] {
            tool.status = .running
            turn.steps[open] = .tool(tool)
        }
        items[index] = .assistant(turn)
        return true
    }

    /// The stored rows stop mid-work (`endsMidTurn`) in a turn that answers the person's own message,
    /// not another Bot's or a routine's output (Hermes answers those in a one-shot `hermes chat` the
    /// gateway knows nothing of): a turn of the chat's own session, which the gateway says is running
    /// while it is (`session.resume`'s `running`). When it says nothing runs, the turn died where it
    /// stopped (a gateway restart) and `TurnRecovery` settles it, rather than it showing as working
    /// for 20 minutes after a relaunch (`docs/chat.md` §2).
    public static func endsOwnMidTurn(_ messages: [SessionMessage], now: Date = .now) -> Bool {
        guard endsMidTurn(messages, now: now),
              let ask = messages.last(where: { $0.role == "user" && $0.displayKind != "hidden" && $0.displayKind != "steer" })
        else { return false }
        return answeredElsewhere(ask) == nil
    }

    /// The stored row the chat's last turn ends with so far (`settleMidTurn` keys on it).
    public static func lastTurnRowID(_ messages: [SessionMessage]) -> Int? {
        lastTurnRow(messages)?.id
    }

    /// A stored turn that stops mid-work, settled by `TurnRecovery` (nothing ran for it): it ended
    /// where Hermes stored it, "Stopped" (`AssistantTurn.endedPartway`). It's known by its last
    /// stored row, `endedAt`: a row stored after that is the turn going on after all, and it shows
    /// as working again (`markMidTurn`). Returns whether it settled it.
    @discardableResult
    public static func settleMidTurn(_ items: inout [TranscriptItem], messages: [SessionMessage], endedAt rowID: Int?) -> Bool {
        guard let rowID, let last = lastTurnRow(messages), last.id == rowID,
              let index = items.indices.last, case .assistant(let turn) = items[index] else { return false }
        items[index] = .assistant(turn.endedPartway(cutOff: [], messages: messages, now: last.timestamp ?? .now))
        return true
    }

    /// What Hermes tags `internal_notification` is a message something delivered (a routine's
    /// output, another Bot's message, a script's or a plugin's): it reads as theirs
    /// (`UserEntry.delivery`, `sender`), not a one-line notice. Only Hermes's own notes stay notices.
    static func isDelivered(kind: String, text: String) -> Bool {
        let text = String(text.drop { $0.isWhitespace })
        return kind == "internal_notification" && (BotMentions.parseAgentMessage(text) != nil || Delivery.parse(text, displayKind: kind) != nil)
    }

    /// Notices stored without a `display_kind`: Hermes' one-shot `hermes chat` injects a finished
    /// background process as a plain user row (Desktop spots it by the same prefix), and an
    /// interrupted turn picked up again was stored untyped before Hermes typed it.
    static func untaggedNoticeKind(_ text: String) -> String? {
        if HermesScaffold.isAutoContinue(text) { return "auto_continue" }
        return finishedWorkKind(text)
    }

    /// Assistant rows that are only a silence marker, plus an `internal_notification` user row whose
    /// whole reply was silent (Hermes lets only that machinery kind vanish with its reply).
    static func silentRowIndices(_ messages: [SessionMessage]) -> Set<Int> {
        var silent: Set<Int> = []
        var notification: Int?
        var replyIsSilent = false
        func settle() {
            if let notification, replyIsSilent { silent.insert(notification) }
        }
        for (index, message) in messages.enumerated() {
            switch message.role {
            case "user":
                settle()
                notification = message.displayKind == "internal_notification" ? index : nil
                replyIsSilent = false
            case "assistant":
                let text = message.content.text
                if BotMentions.isSilenceMarker(text) {
                    if message.toolCalls.isEmpty { silent.insert(index) }  // else build() keeps its steps
                    replyIsSilent = true
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    replyIsSilent = false
                    notification = nil
                }
            default:
                break
            }
        }
        settle()
        return silent
    }

    // MARK: Text cleanup

    /// A steer's words: Hermes' `display_content`, else the text inside its out-of-band marker.
    static func steerEntry(id: String, message: SessionMessage) -> UserEntry {
        var text = message.displayContent ?? message.content.text
        if message.displayContent == nil {
            let lines = text.components(separatedBy: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("[OUT-OF-BAND USER MESSAGE") && !trimmed.hasPrefix("[/OUT-OF-BAND USER MESSAGE")
            }
            text = lines.joined(separator: "\n")
        }
        var entry = UserEntry(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), timestamp: message.timestamp)
        entry.isSteer = true
        return entry
    }

    static func userEntry(id: String, message: SessionMessage) -> UserEntry {
        var text = message.content.text
        // A request Hermes restated after a compaction is the person's message it replaced.
        if let restated = CompactionSummary.restatedRequest(text) { text = restated }
        text = HermesScaffold.withoutMemoryContext(text)
        // The photos' lines come last, after any attached context, so they're read first.
        let photos = StoredImages.split(text)
        text = photos.text
        // A skill used elsewhere is stored expanded: the skill as a chip, the words as typed.
        let invocation = SkillInvocation.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let invocation { text = invocation.instruction }
        for marker in ["--- Attached Context ---", "--- Context Warnings ---"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        var placeholders = photos.count
        let lines = text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces) == "[screenshot]" {
                placeholders += 1
                return false
            }
            return true
        }
        text = BotMentions.stripNote(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        let voicePath = VoiceMessageFile.path(in: text)
        let files = AttachedFiles.extract(from: text)
        text = files.text
        var sender: AgentSender?
        var delivery: DeliverySource?
        if let message = BotMentions.parseAgentMessage(text) {
            sender = AgentSender(name: message.senderName, handle: message.senderHandle)
            text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let delivered = Delivery.parse(text, displayKind: message.displayKind) {
            delivery = delivered.source
            text = delivered.body
        }
        var entry = UserEntry(
            id: id,
            text: text,
            imagePlaceholderCount: placeholders,
            inlineImageURLs: message.content.imageURLs,
            timestamp: message.timestamp,
            sender: sender,
            // The recording is the bubble, not a file chip.
            fileNames: files.names.filter { !VoiceMessageFile.isVoiceMessage($0) },
            skillNames: invocation?.skills ?? []
        )
        entry.voicePath = voicePath
        entry.delivery = delivery
        return entry
    }

    /// Replaces raw `MEDIA:/path` tags (unloadable on another device) with a readable note.
    public static func cleanAssistantText(_ text: String) -> String {
        guard text.contains("MEDIA:") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("MEDIA:") {
                let path = trimmed.dropFirst("MEDIA:".count).trimmingCharacters(in: .whitespaces)
                let file = path.split(separator: "/").last.map(String.init) ?? path
                output.append("*Attachment on server: \(file)*")
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the `<untrusted_tool_result>` envelope Hermes puts around web and browser output.
    public static func cleanToolOutput(_ text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix("<untrusted_tool_result") else { return output }
        if let tagEnd = output.firstIndex(of: ">") {
            output = String(output[output.index(after: tagEnd)...])
        }
        if output.hasSuffix("</untrusted_tool_result>") {
            output.removeLast("</untrusted_tool_result>".count)
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The first paragraph is a fixed boilerplate sentence about untrusted content.
        if let blank = output.range(of: "\n\n") {
            output = String(output[blank.upperBound...])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func noticeText(kind: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "model_switch": return trimmed.isEmpty ? "Model changed" : trimmed
        case "auto_continue": return "Resumed an interrupted turn"
        case "failed_turn": return trimmed.isEmpty ? "This turn failed" : trimmed
        case "async_delegation_complete": return "Helpers finished"
        case "process_complete": return "A background process finished"
        default: return trimmed.isEmpty ? kind.replacingOccurrences(of: "_", with: " ").capitalized : trimmed
        }
    }
}
