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
    /// Images the server kept only as `[screenshot]` placeholders.
    public var imagePlaceholderCount: Int
    /// Images that are still inline in the stored content (`data:` or `https:` URLs).
    public var inlineImageURLs: [String]
    public var timestamp: Date?
    /// Set when another Bot wrote this message (`message_agent`), not the person.
    public var sender: AgentSender?
    /// Set when a routine's output was delivered here (a scheduled job, not the person).
    public var routineName: String?
    /// Files that went with the message (see ``AttachedFiles``).
    public var fileNames: [String] = []
    /// Skills the message used (`/skill` prefixes), shown as chips.
    public var skillNames: [String] = []
    /// What the message was made of when this app sent it (command, skills, Bots and files
    /// inline); `nil` for text from elsewhere.
    public var parts: MessageParts?
    /// Sent with Steer Now while a reply was running (Hermes' `steer` rows).
    public var isSteer = false

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

    public init(id: String, steps: [AssistantStep] = [], answer: String = "", state: State = .complete, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.steps = steps
        self.answer = answer
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
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

    /// Everything a reader would copy: the answer, or the narration if there is no answer.
    public var copyableText: String {
        if !answer.isEmpty { return answer }
        return steps.compactMap { step in
            if case .narration(_, let text) = step { text } else { nil }
        }.joined(separator: "\n\n")
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
            let id = row["id"]?.stringValue ?? row["id"]?.doubleValue.map { String(Int($0)) } ?? "\(index)"
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

/// What a tool's result tried to do: injected instructions, secrets the gateway hid.
public struct ToolRisk: Hashable, Sendable {
    public var risk: String?
    public var findings: [String]
    /// The gateway hid the findings from the model.
    public var redacted: Bool

    public init(risk: String?, findings: [String], redacted: Bool) {
        self.risk = risk
        self.findings = findings
        self.redacted = redacted
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
        let silentRows = hidesSilence ? silentRowIndices(messages) : []
        var items: [TranscriptItem] = []
        var turn: AssistantTurn?
        var pendingText: [String] = []
        var planCallIDs: Set<String> = []

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
            if let current = turn, !(hidesSilence && current.answer.isEmpty && current.steps.isEmpty) {
                items.append(.assistant(current))
            }
            turn = nil
        }

        for (index, message) in messages.enumerated() {
            if silentRows.contains(index) { continue }
            let rowID = message.id.map { "m\($0)" } ?? "i\(index)"
            let kind = message.displayKind

            switch message.role {
            case "user":
                if kind == "hidden" { continue }
                if kind == "steer" {
                    // Steer Now lands mid-turn, after a tool result: the reply continues below it.
                    closeTurn()
                    items.append(.user(steerEntry(id: rowID, message: message)))
                    continue
                }
                if let kind = kind ?? untaggedNoticeKind(message.content.text), noticeKinds.contains(kind) {
                    closeTurn()
                    items.append(.notice(Notice(id: rowID, kind: kind, text: noticeText(kind: kind, content: message.content.text))))
                    continue
                }
                closeTurn()
                items.append(.user(userEntry(id: rowID, message: message)))

            case "assistant":
                if let kind, noticeKinds.contains(kind) {
                    closeTurn()
                    items.append(.notice(Notice(id: rowID, kind: kind, text: noticeText(kind: kind, content: message.content.text))))
                    continue
                }
                if turn == nil {
                    turn = AssistantTurn(id: "t\(rowID)", startedAt: message.timestamp)
                }
                if let reasoning = message.reasoning {
                    flushText(asAnswer: false)
                    turn?.steps.append(.reasoning(id: "\(rowID)-r", text: reasoning))
                }
                let silenced = hidesSilence && BotMentions.isSilenceMarker(message.content.text)
                let text = kind == "hidden" || silenced ? "" : cleanAssistantText(message.content.text)
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
                        turn?.steps.append(.tool(ToolActivity(
                            id: "\(rowID)-c\(callIndex)",
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
                if ToolDescriptor.isPlanTool(message.toolName ?? "") { continue }
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
                        id: rowID, callID: message.toolCallID, name: message.toolName ?? "tool",
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
        return items
    }

    /// Notices stored without a `display_kind`: Hermes' one-shot `hermes chat` injects a finished
    /// background process as a plain user row (Desktop spots it by the same prefix).
    static func untaggedNoticeKind(_ text: String) -> String? {
        let text = text.drop { $0.isWhitespace }
        guard text.hasPrefix("[IMPORTANT: Background process "), !text.prefix(200).contains(" matched watch pattern") else { return nil }
        return "process_complete"
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
        for marker in ["--- Attached Context ---", "--- Context Warnings ---"] {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        var placeholders = 0
        let lines = text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces) == "[screenshot]" {
                placeholders += 1
                return false
            }
            return true
        }
        text = BotMentions.stripNote(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        let files = AttachedFiles.extract(from: text)
        text = files.text
        var sender: AgentSender?
        var routineName: String?
        if let message = BotMentions.parseAgentMessage(text) {
            sender = AgentSender(name: message.senderName, handle: message.senderHandle)
            text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let delivery = BotMentions.parseRoutineDelivery(text) {
            routineName = delivery.name
            text = delivery.output
        }
        var entry = UserEntry(
            id: id,
            text: text,
            imagePlaceholderCount: placeholders,
            inlineImageURLs: message.content.imageURLs,
            timestamp: message.timestamp,
            sender: sender,
            fileNames: files.names
        )
        entry.routineName = routineName
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
        case "async_delegation_complete": return "Background task finished"
        case "process_complete": return "Background process finished"
        default: return trimmed.isEmpty ? kind.replacingOccurrences(of: "_", with: " ").capitalized : trimmed
        }
    }
}
