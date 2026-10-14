import Foundation

/// A Hermes session (`Session` object of the Sessions API).
public struct HermesSession: Decodable, Sendable, Hashable, Identifiable {
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

    enum CodingKeys: String, CodingKey {
        case id, source, model, title, preview, pinned, archived
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
    }

    /// The name to show: title, else the first message, else a placeholder.
    public var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty { return preview }
        return "New chat"
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

// MARK: - Messages

/// One row of `GET /api/sessions/{id}/messages`.
public struct SessionMessage: Decodable, Sendable, Hashable {
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

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, reasoning
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case toolName = "tool_name"
        case finishReason = "finish_reason"
        case reasoningContent = "reasoning_content"
        case displayKind = "display_kind"
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
    }
}

/// Message content: a string, multimodal parts, or nothing.
public enum MessageContent: Decodable, Sendable, Hashable {
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

public struct ContentPart: Decodable, Sendable, Hashable {
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
}

public struct ToolCall: Decodable, Sendable, Hashable {
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
                if let value = try? c.decodeIfPresent(Double.self, forKey: Key(key)) { return Int(value) }
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
    public var sessionID: String?
    public var output: String?
    public var error: String?
    public var usage: TokenUsage?
    public var runtime: RuntimeInfo?
    public var approval: ApprovalRequest?

    enum CodingKeys: String, CodingKey {
        case status, output, error, usage, runtime, approval
        case runID = "run_id"
        case sessionID = "session_id"
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
        approval = try? c.decodeIfPresent(ApprovalRequest.self, forKey: .approval)
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

    public var id: String { requestID ?? gatewayRequestID ?? (command ?? "") + (description ?? "") }

    enum CodingKeys: String, CodingKey {
        case command, description, choices
        case requestID = "request_id"
        case allowSession = "allow_session"
        case allowPermanent = "allow_permanent"
        case smartDenied = "smart_denied"
        case toolName = "tool_name"
        case patternKey = "pattern_key"
        case patternKeys = "pattern_keys"
    }

    public init(requestID: String?, command: String?, description: String?, choices: [ApprovalChoice]) {
        self.requestID = requestID
        self.command = command
        self.description = description
        self.choices = choices
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try? c.decodeIfPresent(String.self, forKey: .requestID)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        toolName = try? c.decodeIfPresent(String.self, forKey: .toolName)
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
            choices = raw.compactMap(ApprovalChoice.init(rawValue:)).filter { choice in
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
