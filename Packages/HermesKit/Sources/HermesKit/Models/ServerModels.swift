import Foundation

// MARK: - Health & capabilities

public struct HealthStatus: Decodable, Sendable, Hashable {
    public var status: String
    public var platform: String?
    public var version: String?
}

/// `GET /v1/capabilities`. Only the flags the app acts on are modelled; unknown keys are ignored.
public struct ServerCapabilities: Decodable, Sendable, Hashable {
    public struct Features: Decodable, Sendable, Hashable {
        public var runSubmission: Bool?
        public var runEventsSSE: Bool?
        public var runStop: Bool?
        public var runSteer: Bool?
        public var runApprovalResponse: Bool?
        public var sessionResources: Bool?
        public var sessionChat: Bool?
        public var sessionChatStreaming: Bool?
        public var sessionFork: Bool?
        public var sessionModelLock: Bool?
        public var modelOptions: Bool?
        public var skillsAPI: Bool?

        enum CodingKeys: String, CodingKey {
            case runSubmission = "run_submission"
            case runEventsSSE = "run_events_sse"
            case runStop = "run_stop"
            case runSteer = "run_steer"
            case runApprovalResponse = "run_approval_response"
            case sessionResources = "session_resources"
            case sessionChat = "session_chat"
            case sessionChatStreaming = "session_chat_streaming"
            case sessionFork = "session_fork"
            case sessionModelLock = "session_model_lock"
            case modelOptions = "model_options"
            case skillsAPI = "skills_api"
        }
    }

    public var platform: String?
    /// The advertised agent model name: the profile name, or `hermes-agent`.
    public var model: String?
    public var features: Features

    /// The minimum this app needs: server-side sessions and detached runs.
    public var supportsNativeClient: Bool {
        features.sessionResources == true && features.runSubmission == true && features.runEventsSSE == true
    }
}

// MARK: - Model picker

/// `GET /api/model/options`.
public struct ModelOptions: Decodable, Sendable, Hashable {
    public var providers: [ModelProvider]
    /// Current global default model and provider.
    public var model: String?
    public var provider: String?

    enum CodingKeys: String, CodingKey { case providers, model, provider }

    public init(providers: [ModelProvider], model: String?, provider: String?) {
        self.providers = providers
        self.model = model
        self.provider = provider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? container.decode([LossyElement<ModelProvider>].self, forKey: .providers))?.compactMap(\.value) ?? []
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
    }

    /// Providers that can actually serve a request right now.
    public var usableProviders: [ModelProvider] {
        providers.filter { $0.isUsable && !$0.models.isEmpty }
    }
}

public struct ModelProvider: Decodable, Sendable, Hashable, Identifiable {
    public struct ModelCapability: Decodable, Sendable, Hashable {
        public var fast: Bool?
        public var reasoning: Bool?
        public var canDisableReasoning: Bool?

        enum CodingKeys: String, CodingKey {
            case fast, reasoning
            case canDisableReasoning = "can_disable_reasoning"
        }
    }

    public struct Pricing: Decodable, Sendable, Hashable {
        public var input: String?
        public var output: String?
        public var free: Bool?
    }

    public var slug: String
    public var name: String
    public var isCurrent: Bool
    public var models: [String]
    public var authenticated: Bool?
    public var warning: String?
    public var aliases: [String]?
    public var capabilities: [String: ModelCapability]?
    public var featuredModels: [String]?
    public var unavailableModels: [String]?
    public var pricing: [String: Pricing]?

    public var id: String { slug }

    /// Skeleton rows for providers without credentials report `authenticated: false`.
    public var isUsable: Bool { authenticated != false }

    public func matches(provider: String?) -> Bool {
        guard let provider, !provider.isEmpty else { return false }
        return slug == provider || name == provider || (aliases ?? []).contains(provider)
    }

    public func supportsReasoning(_ model: String) -> Bool {
        capabilities?[model]?.reasoning ?? true
    }

    public func isUnavailable(_ model: String) -> Bool {
        (unavailableModels ?? []).contains(model)
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, models, authenticated, warning, aliases, capabilities, pricing
        case isCurrent = "is_current"
        case featuredModels = "featured_models"
        case unavailableModels = "unavailable_models"
    }

    public init(slug: String, name: String, isCurrent: Bool, models: [String], authenticated: Bool? = true) {
        self.slug = slug
        self.name = name
        self.isCurrent = isCurrent
        self.models = models
        self.authenticated = authenticated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? slug
        isCurrent = (try? container.decodeIfPresent(Bool.self, forKey: .isCurrent)) ?? false
        models = (try? container.decodeIfPresent([String].self, forKey: .models)) ?? []
        authenticated = try? container.decodeIfPresent(Bool.self, forKey: .authenticated)
        warning = try? container.decodeIfPresent(String.self, forKey: .warning)
        aliases = try? container.decodeIfPresent([String].self, forKey: .aliases)
        capabilities = try? container.decodeIfPresent([String: ModelCapability].self, forKey: .capabilities)
        featuredModels = try? container.decodeIfPresent([String].self, forKey: .featuredModels)
        unavailableModels = try? container.decodeIfPresent([String].self, forKey: .unavailableModels)
        pricing = try? container.decodeIfPresent([String: Pricing].self, forKey: .pricing)
    }
}

/// A model the user chose for a conversation.
public struct ModelSelection: Codable, Sendable, Hashable {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    /// The last path segment, e.g. `anthropic/claude-sonnet-4.6` → `claude-sonnet-4.6`.
    public var shortName: String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

/// Reasoning effort ladder accepted by `model_options.reasoning_effort`.
public enum ReasoningEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Disables reasoning (`"none"` on the wire).
    case off = "none"
    case minimal, low, medium, high, xhigh, max

    public var id: String { rawValue }
}

// MARK: - Discovery

public struct Skill: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String?
    public var category: String?

    public var id: String { name }
}

public struct Toolset: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var label: String?
    public var description: String?
    public var enabled: Bool?
    public var configured: Bool?
    public var tools: [String]?

    public var id: String { name }
}

struct ListEnvelope<Element: Decodable>: Decodable {
    var data: [Element]

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([LossyElement<Element>].self, forKey: .data).compactMap(\.value)
    }
}

/// Decodes an array element without failing the whole array when one element is malformed.
struct LossyElement<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
