import Foundation
import HermesPush

/// A Hermes session (`Session` object of the Sessions API).
public struct HermesSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Where the conversation started: `api_server`, `cli`, `telegram`, `discord`, … (open set).
    public var source: String?
    public var model: String?
    public var title: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var endReason: String?
    public var messageCount: Int?
    public var toolCallCount: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var estimatedCostUSD: Double?
    public var parentSessionID: String?
    /// Only on list rows.
    public var lastActive: Date?
    /// First user message, ≤ 60 characters. Only on list rows.
    public var preview: String?
    /// Original id of a compressed lineage; stable across compression rotations.
    public var lineageRootID: String?
    public var pinned: Bool
    public var archived: Bool
    public var isInternalChild: Bool
    /// Hermes' read mark (`last_read_at`), shared by every device; nil when this gateway's rows
    /// don't carry one (`docs/inbox.md` §1).
    public var readMark: ReadMark?

    enum CodingKeys: String, CodingKey {
        case id, source, model, title, preview, pinned, archived
        case lastReadAt = "last_read_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case messageCount = "message_count"
        case toolCallCount = "tool_call_count"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case estimatedCostUSD = "estimated_cost_usd"
        case parentSessionID = "parent_session_id"
        case lastActive = "last_active"
        case lineageRootID = "_lineage_root_id"
        case isInternalChild = "is_internal_child"
    }

    public init(
        id: String, source: String? = "api_server", model: String? = nil, title: String? = nil,
        startedAt: Date? = .now, lastActive: Date? = .now, preview: String? = nil, messageCount: Int? = 0
    ) {
        self.id = id
        self.source = source
        self.model = model
        self.title = title
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.preview = preview
        self.messageCount = messageCount
        self.pinned = false
        self.archived = false
        self.isInternalChild = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        startedAt = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .startedAt))
        endedAt = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .endedAt))
        endReason = try? c.decodeIfPresent(String.self, forKey: .endReason)
        messageCount = try? c.decodeIfPresent(Int.self, forKey: .messageCount)
        toolCallCount = try? c.decodeIfPresent(Int.self, forKey: .toolCallCount)
        inputTokens = try? c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try? c.decodeIfPresent(Int.self, forKey: .outputTokens)
        estimatedCostUSD = try? c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD)
        parentSessionID = try? c.decodeIfPresent(String.self, forKey: .parentSessionID)
        lastActive = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .lastActive))
        preview = try? c.decodeIfPresent(String.self, forKey: .preview)
        lineageRootID = try? c.decodeIfPresent(String.self, forKey: .lineageRootID)
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        isInternalChild = (try? c.decodeIfPresent(Bool.self, forKey: .isInternalChild)) ?? false
        // Present and null means never tracked (read); absent means not served at all.
        if c.contains(.lastReadAt) {
            readMark = ReadMark(lastReadAt: try? c.decodeIfPresent(Double.self, forKey: .lastReadAt))
        }
    }

    /// The row as the gateway sends it, so the chat list kept on the device (`SessionsCache`) reads
    /// back through the same decoding as a fresh one.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(startedAt?.timeIntervalSince1970, forKey: .startedAt)
        try c.encodeIfPresent(endedAt?.timeIntervalSince1970, forKey: .endedAt)
        try c.encodeIfPresent(endReason, forKey: .endReason)
        try c.encodeIfPresent(messageCount, forKey: .messageCount)
        try c.encodeIfPresent(toolCallCount, forKey: .toolCallCount)
        try c.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try c.encodeIfPresent(outputTokens, forKey: .outputTokens)
        try c.encodeIfPresent(estimatedCostUSD, forKey: .estimatedCostUSD)
        try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encodeIfPresent(lastActive?.timeIntervalSince1970, forKey: .lastActive)
        try c.encodeIfPresent(preview, forKey: .preview)
        try c.encodeIfPresent(lineageRootID, forKey: .lineageRootID)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(archived, forKey: .archived)
        try c.encode(isInternalChild, forKey: .isInternalChild)
        switch readMark {
        case nil: break
        case .untracked: try c.encodeNil(forKey: .lastReadAt)
        case .markedUnread: try c.encode(0.0, forKey: .lastReadAt)
        case .readUntil(let date): try c.encode(date.timeIntervalSince1970, forKey: .lastReadAt)
        }
    }

    /// Unread by Hermes' mark: there's been activity since it was read, or it was marked unread.
    public var isUnreadOnGateway: Bool {
        readMark?.isUnread(lastActive: lastActive) ?? false
    }

    /// A chat opened from somewhere else (the Board, a task's run, a link) before the list has it.
    /// It has no times of its own, so opening it never puts it at the top as "now": its row takes
    /// its last message's time once that's read, and Hermes' when the list has it (`RowTime`).
    public static func opened(id: String) -> HermesSession {
        HermesSession(id: id, startedAt: nil, lastActive: nil)
    }

    /// The name to show: title, else the first message, else a placeholder.
    public var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let preview = listPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty { return preview }
        return "New chat"
    }

    /// Hermes' preview (the first message), unless it's a compaction summary: a compacted chat
    /// starts with one (`CompactionSummary`).
    public var listPreview: String? {
        preview.flatMap { CompactionSummary.matches($0) ? nil : $0 }
    }

    public var hasRealTitle: Bool {
        !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Most recent activity, for ordering and date grouping.
    public var activityDate: Date {
        lastActive ?? startedAt ?? .distantPast
    }

    /// Stable identity across compression rotations (the live id changes, the root does not).
    public var stableID: String { lineageRootID ?? id }

    /// The session was started from this app or another API client.
    public var isFromAPI: Bool { source == nil || source == "api_server" }
}

struct SessionEnvelope: Decodable {
    var session: HermesSession
}

public struct SessionPage: Decodable, Sendable {
    public var sessions: [HermesSession]
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }

    public init(sessions: [HermesSession], hasMore: Bool) {
        self.sessions = sessions
        self.hasMore = hasMore
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.decode([LossyElement<HermesSession>].self, forKey: .data).compactMap(\.value)
        hasMore = (try? c.decodeIfPresent(Bool.self, forKey: .hasMore)) ?? false
    }
}

/// The dashboard's `GET /api/sessions` (`hermes serve`): `{sessions, total, limit, offset}`.
struct DashboardSessionPage: Decodable {
    var sessions: [HermesSession]

    init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case sessions }
        let c = try decoder.container(keyedBy: Keys.self)
        sessions = try c.decode([LossyElement<HermesSession>].self, forKey: .sessions).compactMap(\.value)
    }
}

// MARK: - Messages

/// One row of `GET /api/sessions/{id}/messages`.
public struct SessionMessage: Codable, Sendable, Hashable {
    public var id: Int?
    public var role: String
    public var content: MessageContent
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var timestamp: Date?
    public var finishReason: String?
    public var reasoning: String?
    /// `nil` for a normal bubble; `hidden` must not render; others are timeline notices.
    public var displayKind: String?
    /// What to show instead of `content` (a steer's own words without Hermes' marker).
    public var displayContent: String?
    /// The row Hermes writes for a message as it takes it into its queue (`display_metadata`
    /// `_queued_prompt`, hermes-agent `_persist_queued_user_row`): the message waits there, or Stop
    /// emptied the queue before it ran. Hermes swaps it for a row of the turn's own when the message
    /// runs, so a marked row is never a turn (`docs/chat.md` §4c).
    public var isWaitingInQueue = false

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case toolName = "tool_name"
        case finishReason = "finish_reason"
        case reasoningContent = "reasoning_content"
        case displayKind = "display_kind"
        case displayContent = "display_content"
        case displayMetadata = "display_metadata"
    }

    public init(
        id: Int? = nil, role: String, content: MessageContent, toolCalls: [ToolCall] = [], toolCallID: String? = nil,
        toolName: String? = nil, timestamp: Date? = nil, reasoning: String? = nil, displayKind: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.timestamp = timestamp
        self.reasoning = reasoning
        self.displayKind = displayKind
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        content = (try? c.decodeIfPresent(MessageContent.self, forKey: .content)) ?? .none
        toolCalls = (try? c.decodeIfPresent([LossyElement<ToolCall>].self, forKey: .toolCalls))?.compactMap(\.value) ?? []
        toolCallID = try? c.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .timestamp))
        finishReason = try? c.decodeIfPresent(String.self, forKey: .finishReason)
        let thinking = (try? c.decodeIfPresent(String.self, forKey: .reasoning))
            ?? (try? c.decodeIfPresent(String.self, forKey: .reasoningContent))
        reasoning = thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? thinking : nil
        displayKind = try? c.decodeIfPresent(String.self, forKey: .displayKind)
        displayContent = try? c.decodeIfPresent(String.self, forKey: .displayContent)
        // An object, or the column's JSON text as the stored rows carry it.
        var metadata = try? c.decodeIfPresent(JSONValue.self, forKey: .displayMetadata)
        if let text = metadata?.stringValue { metadata = JSONValue.parse(text) }
        isWaitingInQueue = metadata?[Self.queuedMarker]?.boolValue == true
    }

    static let queuedMarker = "_queued_prompt"

    /// The same shape as the server's rows, so a cached transcript decodes like a fetched one.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !toolCalls.isEmpty { try c.encode(toolCalls, forKey: .toolCalls) }
        try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try c.encodeIfPresent(toolName, forKey: .toolName)
        try c.encodeIfPresent(timestamp?.timeIntervalSince1970, forKey: .timestamp)
        try c.encodeIfPresent(finishReason, forKey: .finishReason)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(displayKind, forKey: .displayKind)
        try c.encodeIfPresent(displayContent, forKey: .displayContent)
        if isWaitingInQueue { try c.encode(JSONValue.object([Self.queuedMarker: .bool(true)]), forKey: .displayMetadata) }
    }
}

/// Message content: a string, multimodal parts, or nothing.
public enum MessageContent: Codable, Sendable, Hashable {
    case text(String)
    case parts([ContentPart])
    case none

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([LossyElement<ContentPart>].self).compactMap(\.value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        case .none: try container.encodeNil()
        }
    }

    /// All text, with parts joined by newlines.
    public var text: String {
        switch self {
        case .text(let text): text
        case .parts(let parts): parts.compactMap(\.text).joined(separator: "\n")
        case .none: ""
        }
    }

    public var imageURLs: [String] {
        guard case .parts(let parts) = self else { return [] }
        return parts.compactMap(\.imageURL)
    }
}

public struct ContentPart: Codable, Sendable, Hashable {
    public var type: String
    public var text: String?
    public var imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "text"
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        // `image_url` is either a bare string or `{"url": …, "detail": …}`.
        if let url = try? c.decodeIfPresent(String.self, forKey: .imageURL) {
            imageURL = url
        } else if let object = try? c.decodeIfPresent(JSONValue.self, forKey: .imageURL) {
            imageURL = object["url"]?.stringValue
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    public var id: String?
    public var name: String
    /// JSON-encoded arguments; may be invalid JSON.
    public var arguments: String

    enum CodingKeys: String, CodingKey { case id, function }
    enum FunctionKeys: String, CodingKey { case name, arguments }

    public init(id: String?, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        let function = try c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        name = try function.decode(String.self, forKey: .name)
        if let text = try? function.decodeIfPresent(String.self, forKey: .arguments) {
            arguments = text
        } else if let object = try? function.decodeIfPresent(JSONValue.self, forKey: .arguments) {
            arguments = object.displayText
        } else {
            arguments = ""
        }
    }

    public var parsedArguments: JSONValue? { JSONValue.parse(arguments) }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        var function = c.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(arguments, forKey: .arguments)
    }
}

struct MessagesEnvelope: Decodable {
    var sessionID: String?
    var data: [SessionMessage]

    enum CodingKeys: String, CodingKey {
        case data
        case sessionID = "session_id"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        data = try c.decode([LossyElement<SessionMessage>].self, forKey: .data).compactMap(\.value)
    }
}

public struct SessionTranscript: Sendable {
    /// The live (post-compression) session id the server resolved.
    public var sessionID: String
    public var messages: [SessionMessage]
    /// The newest page only: earlier messages exist and can be fetched (`offset`).
    public var hasEarlier = false

    public init(sessionID: String, messages: [SessionMessage], hasEarlier: Bool = false) {
        self.sessionID = sessionID
        self.messages = messages
        self.hasEarlier = hasEarlier
    }

    /// How many rows the first page of a chat asks for: enough for a screen or two of the latest
    /// turns, a fraction of the 500 the API server sends by default (tool output makes rows big).
    public static let firstPage = 150

    /// How many rows a chat that already shows its transcript asks for to catch up: what arrived
    /// since, put after the rows held (`appending(toEarlier:)`). A page that doesn't reach back to
    /// them is followed by bigger ones until it does. A busy Mac answers a short page much sooner.
    public static let catchUpPage = 24

    /// This page put after earlier rows already held: rows both have are kept once (pages
    /// counted from the newest overlap when new rows arrive in between).
    public func appending(toEarlier earlier: [SessionMessage]) -> [SessionMessage] {
        guard let firstID = messages.first?.id else { return messages }
        return earlier.filter { ($0.id ?? .max) < firstID } + messages
    }

    /// Whether the reply a notification announced (sent at `sentAt`) is in these rows: the newest
    /// is Hermes's, stored no earlier than 15 s before the notice went out (Hermes stamps a row as
    /// it stores it, and notifies as the turn ends). Without a send time: any reply newer than the
    /// newest row held when the notification was opened.
    public static func showsAnnouncedReply(_ rows: [SessionMessage], sentAt: Date?, heldNewest: Int?) -> Bool {
        guard let newest = rows.last, newest.role == "assistant" else { return false }
        if let sentAt, let stamp = newest.timestamp { return stamp >= sentAt.addingTimeInterval(-15) }
        return heldNewest != nil && newest.id != heldNewest
    }

    /// An earlier page put before the rows held now.
    public static func merge(earlier: [SessionMessage], before rows: [SessionMessage]) -> [SessionMessage] {
        guard let firstID = rows.first?.id else { return earlier + rows }
        return earlier.filter { ($0.id ?? .min) < firstID } + rows
    }
}

// MARK: - Runs

public struct RuntimeInfo: Decodable, Sendable, Hashable {
    public var provider: String?
    public var model: String?
    public var routeSource: String?

    enum CodingKeys: String, CodingKey {
        case provider, model
        case routeSource = "route_source"
    }
}

/// A turn's (or session's) usage. The API server sends `input_tokens`…; the gateway
/// protocol's `Usage` sends `input`, `output`, `total` plus cost and context use.
public struct TokenUsage: Decodable, Sendable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?
    public var costUSD: Double?
    public var contextUsed: Int?
    public var contextMax: Int?
    /// 0–100.
    public var contextPercent: Double?
    public var model: String?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Int.self, forKey: Key(key)) { return value }
                if let value = try? c.decodeIfPresent(Double.self, forKey: Key(key)) { return Int(checking: value) }
            }
            return nil
        }
        func double(_ key: String) -> Double? { try? c.decodeIfPresent(Double.self, forKey: Key(key)) }
        inputTokens = int("input_tokens", "input")
        outputTokens = int("output_tokens", "output")
        totalTokens = int("total_tokens", "total")
        reasoningTokens = int("reasoning_tokens", "reasoning")
        cacheReadTokens = int("cache_read_tokens", "cache_read")
        costUSD = double("cost_usd")
        contextUsed = int("context_used")
        contextMax = int("context_max")
        contextPercent = double("context_percent")
        model = try? c.decodeIfPresent(String.self, forKey: Key("model"))
    }
}

/// `GET /v1/runs/{run_id}`.
public struct RunStatus: Decodable, Sendable, Hashable {
    public var runID: String
    public var status: String

    /// Hermes took the run but runs it after the turn in front of it (its FIFO); `POST /v1/runs`
    /// answers `started` for it all the same, and no event comes until it runs.
    public var isQueued: Bool { status == "queued" }
    public var sessionID: String?
    public var output: String?
    public var error: String?
    public var usage: TokenUsage?
    public var runtime: RuntimeInfo?
    public var approval: ApprovalRequest?
    /// The run's execution generation: an answer to one of its prompts names it.
    public var executionGeneration: Int?
    /// The approvals and questions the run waits on.
    public var pendingControls: [RunPrompt] = []

    enum CodingKeys: String, CodingKey {
        case status, output, error, usage, runtime, approval
        case runID = "run_id"
        case sessionID = "session_id"
        case executionGeneration = "execution_generation"
        case pendingControls = "pending_controls"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown"
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        output = try? c.decodeIfPresent(String.self, forKey: .output)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        usage = try? c.decodeIfPresent(TokenUsage.self, forKey: .usage)
        runtime = try? c.decodeIfPresent(RuntimeInfo.self, forKey: .runtime)
        executionGeneration = try? c.decodeIfPresent(Int.self, forKey: .executionGeneration)
        pendingControls = (try? c.decodeIfPresent([RunPrompt].self, forKey: .pendingControls)) ?? []
        // Hermes's run store lists the approval among the prompts it waits on; older gateways name it.
        approval = (try? c.decodeIfPresent(ApprovalRequest.self, forKey: .approval))
            ?? pendingControls.lazy.compactMap(\.approval).first
    }

    public var isTerminal: Bool {
        ["completed", "failed", "cancelled", "interrupted"].contains(status)
    }
}

struct RunCreated: Decodable {
    var runID: String
    enum CodingKeys: String, CodingKey { case runID = "run_id" }
}

/// A tool call waiting on a human decision.
public struct ApprovalRequest: Decodable, Sendable, Hashable, Identifiable {
    public var requestID: String?
    public var command: String?
    public var description: String?
    public var choices: [ApprovalChoice]
    /// On the backend gateway an approval is a server→client request; this is its JSON-RPC id.
    public var gatewayRequestID: String?
    /// The tool asking ("terminal").
    public var toolName: String?
    /// What an allow covers ("rm_rf").
    public var patternKeys: [String] = []
    /// Hermes's safety check flagged it: only a one-time override is on offer.
    public var smartDenied = false
    /// The card's title when the asker names one ("Save to memory?").
    public var title: String?
    /// The run's execution generation it was asked in (`/v1/runs`): the answer names it.
    public var executionGeneration: Int?
    /// How long Hermes waits for the answer, when it says (a `/v1/runs` turn's `timeout_s`).
    public var timeout: TimeInterval?
    /// When Hermes asked, by the gateway's clock: a run's event carries it (`timestamp`), so a
    /// deadline counts from the asking, not from when the event reached this device.
    public var askedAt: Date?

    public var id: String { requestID ?? gatewayRequestID ?? (command ?? "") + (description ?? "") }

    enum CodingKeys: String, CodingKey {
        case command, description, choices
        case requestID = "request_id"
        case promptID = "prompt_id"
        case executionGeneration = "execution_generation"
        case allowSession = "allow_session"
        case allowPermanent = "allow_permanent"
        case smartDenied = "smart_denied"
        case timeout = "timeout_s"
        case askedAt = "timestamp"
        case toolName = "tool_name"
        case patternKey = "pattern_key"
        case patternKeys = "pattern_keys"
        case title
    }

    public init(requestID: String?, command: String?, description: String?, choices: [ApprovalChoice]) {
        self.requestID = requestID
        self.command = command
        self.description = description
        self.choices = choices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A run's event says `request_id`; its status lists the same prompt as `prompt_id`.
        requestID = (try? c.decodeIfPresent(String.self, forKey: .requestID)) ?? (try? c.decodeIfPresent(String.self, forKey: .promptID))
        executionGeneration = try? c.decodeIfPresent(Int.self, forKey: .executionGeneration)
        timeout = (try? c.decodeIfPresent(Double.self, forKey: .timeout)).flatMap { $0 > 0 ? $0 : nil }
        askedAt = HermesDate.fromEpoch(try? c.decodeIfPresent(Double.self, forKey: .askedAt))
        // Shown as they'd run: nothing invisible or reordering hides in them (`VisibleText`).
        command = VisibleText.of(try? c.decodeIfPresent(String.self, forKey: .command))
        description = VisibleText.of(try? c.decodeIfPresent(String.self, forKey: .description))
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
        title = VisibleText.of(try? c.decodeIfPresent(String.self, forKey: .title))
        let flagged = (try? c.decodeIfPresent(Bool.self, forKey: .smartDenied)) == true
        smartDenied = flagged
        if let keys = try? c.decodeIfPresent([String].self, forKey: .patternKeys) {
            patternKeys = keys
        } else if let key = try? c.decodeIfPresent(String.self, forKey: .patternKey) {
            patternKeys = [key]
        }
        let allowSession = try? c.decodeIfPresent(Bool.self, forKey: .allowSession)
        let allowPermanent = try? c.decodeIfPresent(Bool.self, forKey: .allowPermanent)
        if let raw = try? c.decodeIfPresent([String].self, forKey: .choices) {
            // Tiles follow both the offered choices and the allow_* flags.
            // In the tiles' order, whichever order Hermes listed them in.
            choices = ApprovalChoice.allCases.filter { raw.contains($0.rawValue) }.filter { choice in
                switch choice {
                case .session: allowSession != false && !flagged
                case .always: allowPermanent != false && !flagged
                default: true
                }
            }
        } else if flagged {
            choices = [.once, .deny]
        } else {
            var derived: [ApprovalChoice] = [.once]
            if allowSession != false { derived.append(.session) }
            if allowPermanent != false { derived.append(.always) }
            derived.append(.deny)
            choices = derived
        }
        if !choices.contains(.deny) { choices.append(.deny) }
    }

    /// What to show as the headline: the command, else the description.
    public var summary: String {
        let command = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? (description ?? "A tool needs your approval") : command
    }
}

public enum ApprovalChoice: String, Sendable, Hashable, CaseIterable {
    case once, session, always, deny
}
