import Foundation

// MCP servers, plugins and built-in toolsets (`tui_gateway/contracts/tools_mcp_plugins.py`,
// `docs/connections.md` §4–6). Secrets never come back from Hermes: only env-key names and whether
// a value is set.

// MARK: - MCP servers

/// A server's live state (`McpRuntimeStatus`).
public enum McpStatus: String, Sendable, Hashable {
    case connected, connecting, failed, lazy, disabled, configured
}

/// One MCP server: its config (`McpServerSummary`) joined with its live state (`McpServerRuntimeRow`).
public struct McpServer: Sendable, Hashable, Identifiable {
    public var name: String
    /// `stdio` (a command) or `http` / `sse` (a URL).
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    /// The env keys its config reads; never their values.
    public var envKeys: [String]
    /// `oauth`, `header`, or none.
    public var auth: String?
    public var oauthTokensPresent: Bool?
    public var enabled: Bool
    /// `config`, or `plugin` for one a plugin brought (removed with the plugin, not here).
    public var source: String
    public var plugin: String?
    public var status: McpStatus?
    public var toolCount: Int?

    public var id: String { name }

    public init(
        name: String, transport: String, url: String? = nil, command: String? = nil, args: [String] = [], envKeys: [String] = [],
        auth: String? = nil, enabled: Bool = true, source: String = "config", plugin: String? = nil, status: McpStatus? = nil, toolCount: Int? = nil
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.auth = auth
        self.enabled = enabled
        self.source = source
        self.plugin = plugin
        self.status = status
        self.toolCount = toolCount
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        transport = json["transport"]?.stringValue ?? "stdio"
        url = json["url"]?.stringValue
        command = json["command"]?.stringValue
        args = json["args"].strings
        envKeys = json["env"].strings
        auth = json["auth"]?.stringValue
        oauthTokensPresent = json["oauth_tokens_present"]?.boolValue
        enabled = json["enabled"]?.boolValue ?? true
        source = json["source"]?.stringValue ?? "config"
        plugin = json["plugin"]?.stringValue
        // `tools` in the config is a filter, not a count; the runtime row carries the count.
        if case .number(let count)? = json["tools"] { toolCount = Int(count) }
    }

    /// Adds the live state from `mcp.servers.status`.
    mutating func apply(runtime row: JSONValue) {
        status = row["status"]?.stringValue.flatMap(McpStatus.init(rawValue:))
        toolCount = row["tools"].int ?? toolCount
    }

    public var isFromPlugin: Bool { source == "plugin" }
    public var usesURL: Bool { url != nil || transport != "stdio" }

    /// The command line or URL, as the setup row shows it.
    public var address: String {
        if let url { return url }
        return ([command].compactMap { $0 } + args).joined(separator: " ")
    }
}

/// A curated server Hermes can add (`McpCatalogEntry`).
public struct McpPreset: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    /// The env keys it needs before it can start.
    public var requires: [String]
    public var transport: String
    public var installed: Bool
    public var enabled: Bool
    public var connectorSlug: String?

    public var id: String { name }

    public init(name: String, description: String = "", requires: [String] = [], transport: String = "stdio", installed: Bool = false, enabled: Bool = false) {
        self.name = name
        self.description = description
        self.requires = requires
        self.transport = transport
        self.installed = installed
        self.enabled = enabled
    }

    /// `"http"`, or what a gateway that sends the Python object's repr means by it
    /// (`TransportSpec(type='http', …)`).
    static func transport(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "stdio" }
        guard let start = raw.range(of: "type='") else { return raw }
        return String(raw[start.upperBound...].prefix { $0 != "'" })
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        description = json["description"]?.stringValue ?? ""
        requires = json["requires"].strings
        transport = Self.transport(json["transport"]?.stringValue)
        installed = json["installed"]?.boolValue ?? false
        enabled = json["enabled"]?.boolValue ?? false
        connectorSlug = json["connector_slug"]?.stringValue
    }
}

/// What a test found (`McpServersTestResult`): connect, list tools, disconnect.
public struct McpTestResult: Sendable, Hashable {
    public var ok: Bool
    public var tools: [String]
    public var error: String?
    public var oauthNeeded: Bool
    public var testedAt: Date

    public init(ok: Bool, tools: [String] = [], error: String? = nil, oauthNeeded: Bool = false, testedAt: Date = .now) {
        self.ok = ok
        self.tools = tools
        self.error = error
        self.oauthNeeded = oauthNeeded
        self.testedAt = testedAt
    }

    init(json: JSONValue, now: Date = .now) {
        ok = json["ok"]?.boolValue ?? false
        tools = json["tools"].items.compactMap { $0["name"]?.stringValue }
        error = json["error"]?.stringValue
        oauthNeeded = json["oauth_needed"]?.boolValue ?? false
        testedAt = now
    }
}

/// An MCP OAuth sign-in in progress (`mcp.servers.oauth.start`).
public struct McpOAuthFlow: Sendable, Hashable {
    public var sessionID: String
    public var authURL: URL
}

/// A poll of that sign-in (`McpOauthPollResult`).
public enum McpOAuthState: Sendable, Hashable {
    case pending
    case approved(tools: [String])
    case failed(String)
}

// MARK: - Plugins

/// The live state of a server a plugin brings (`PluginServerState`).
public struct PluginServerState: Sendable, Hashable {
    /// `connected`, `app_not_running`, `missing_app`, `version_too_old`…
    public var name: String
    public var state: String
    /// What's missing, in Hermes's words ("Xcode isn't running on Studio Mac").
    public var sentence: String

    public var isProblem: Bool { state != "connected" && state != "unknown" }
}

/// One field of a plugin's settings, from its manifest schema (`PluginSettingField`).
public struct PluginSettingField: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case string, number, boolean, `enum`, secret, json }

    public var key: String
    public var kind: Kind
    public var label: String
    public var description: String
    public var required: Bool
    /// Non-secret fields only; a secret never carries its value.
    public var value: JSONValue?
    public var defaultValue: JSONValue?
    public var choices: [String]
    /// A secret's `.env` name.
    public var env: String?
    /// A secret is set.
    public var hasValue: Bool

    public var id: String { key }

    init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue else { return nil }
        self.key = key
        kind = json["type"]?.stringValue.flatMap(Kind.init(rawValue:)) ?? .string
        label = json["label"]?.stringValue ?? key
        description = json["description"]?.stringValue ?? ""
        required = json["required"]?.boolValue ?? false
        value = kind == .secret ? nil : json["value"].flatMap { $0 == .null ? nil : $0 }
        defaultValue = json["default"].flatMap { $0 == .null ? nil : $0 }
        choices = json["choices"].strings
        env = json["env"]?.stringValue
        hasValue = json["has_value"]?.boolValue ?? false
    }
}

/// An installed plugin (`AgentPluginRow`).
public struct HermesPlugin: Sendable, Hashable, Identifiable {
    public var name: String
    /// The canonical key `toggle` writes.
    public var key: String
    public var version: String
    public var description: String
    /// `bundled`, `user` or `git`; only installs can be removed, bundled ones only turned off.
    public var source: String
    /// `enabled` or `not enabled`.
    public var status: String
    public var servers: [PluginServerState]
    public var catalogName: String?
    /// `official` or `community`.
    public var tier: String?
    public var installedSHA: String?
    public var catalogVersion: String?
    public var updateAvailable: Bool
    public var pinnedSHA: String?
    public var settings: [PluginSettingField]

    public var id: String { key }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        key = json["key"]?.stringValue ?? name
        version = json["version"]?.stringValue ?? ""
        description = json["description"]?.stringValue ?? ""
        source = json["source"]?.stringValue ?? "user"
        status = json["status"]?.stringValue ?? "enabled"
        servers = json["servers"].items.compactMap { row in
            row["name"]?.stringValue.map { PluginServerState(name: $0, state: row["state"]?.stringValue ?? "unknown", sentence: row["sentence"]?.stringValue ?? "") }
        }
        catalogName = json["catalog_name"]?.stringValue
        tier = json["catalog_tier"]?.stringValue
        installedSHA = json["installed_sha"]?.stringValue
        catalogVersion = json["catalog_version"]?.stringValue
        updateAvailable = json["update_available"]?.boolValue ?? false
        pinnedSHA = json["pinned_sha"]?.stringValue
        settings = json["settings_schema"].items.compactMap(PluginSettingField.init(json:))
    }

    public var isEnabled: Bool { status == "enabled" }
    public var isBundled: Bool { source == "bundled" }
    public var canRemove: Bool { !isBundled }
    /// The first server problem, in Hermes's words.
    public var problem: String? { servers.first(where: \.isProblem)?.sentence.nilIfEmpty }
}

/// A catalog plugin to suggest (`plugins.manage {action: onboarding}`).
public struct CatalogPlugin: Sendable, Hashable, Identifiable {
    public var name: String
    public var title: String
    public var description: String
    public var tier: String
    /// `present`, `missing_app`, `app_not_running`, `unknown`.
    public var appState: String
    public var sentence: String

    public var id: String { name }

    public init(name: String, title: String, description: String = "", tier: String = "community", appState: String = "unknown", sentence: String = "") {
        self.name = name
        self.title = title
        self.description = description
        self.tier = tier
        self.appState = appState
        self.sentence = sentence
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        title = json["title"]?.stringValue ?? name
        description = json["description"]?.stringValue ?? ""
        tier = json["tier"]?.stringValue ?? "community"
        appState = json["app_state"]?.stringValue ?? "unknown"
        sentence = json["sentence"]?.stringValue ?? ""
    }
}

/// What a plugin does now and what waits (`PluginActivation`).
public struct PluginActivation: Sendable, Hashable {
    /// MCP tools and skills usable in open chats from their next turn.
    public var liveTools: [String]
    public var liveSkills: [String]
    /// Python tools and prompt changes that apply from the next chat.
    public var deferredTools: [String]
    public var deferredPrompt: [String]

    init(json: JSONValue?) {
        let live = json?["live_now"]
        liveTools = live?["mcp_servers"].items.flatMap { $0["tools"].strings } ?? []
        liveSkills = live?["skills"].items.compactMap { $0["name"]?.stringValue } ?? []
        deferredTools = json?["deferred"]?["tools"].strings ?? []
        deferredPrompt = json?["deferred"]?["prompt"].strings ?? []
    }

    public var isEmpty: Bool { liveTools.isEmpty && liveSkills.isEmpty && deferredTools.isEmpty && deferredPrompt.isEmpty }
}

/// The outcome of install, toggle, update, remove or settings (`PluginsManageResult`).
public struct PluginActionResult: Sendable, Hashable {
    public var ok: Bool
    public var unchanged: Bool
    public var plugin: HermesPlugin?
    public var warnings: [String]
    /// Env keys the plugin still needs: fields to fill.
    public var missingEnv: [String]
    public var knownIssues: [String]
    public var restartRequired: Bool
    public var activation: PluginActivation?
    /// An update that widens the plugin's access waits for the person (`delta_lines`).
    public var consentRequired: Bool
    public var deltaLines: [String]
    public var error: String?

    init(json: JSONValue) {
        ok = json["ok"]?.boolValue ?? true
        unchanged = json["unchanged"]?.boolValue ?? false
        plugin = json["plugin"].flatMap(HermesPlugin.init(json:))
        warnings = json["warnings"].strings
        missingEnv = json["missing_env"].strings
        knownIssues = json["known_issues"].strings
        restartRequired = json["restart_required"]?.boolValue ?? false
        activation = json["activation"].map { PluginActivation(json: $0) }
        consentRequired = json["consent_required"]?.boolValue ?? false
        deltaLines = json["delta_lines"].strings
        error = json["error"]?.stringValue
    }

    /// Something to tell the person after the action.
    public var hasNotes: Bool { !warnings.isEmpty || !missingEnv.isEmpty || !knownIssues.isEmpty || restartRequired }
}

/// `hermes://plugin/install?catalog=` resolved (`plugins.catalog.lookup`).
public enum PluginLookup: Sendable, Hashable {
    case found(name: String, repo: String)
    case unknown
    case unavailable
}

// MARK: - Built-in toolsets

/// One of Hermes's own toolsets (`ToolsetRow` from `toolsets.list` / `tools.list`).
public struct BuiltInToolset: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var toolCount: Int
    public var enabled: Bool
    public var tools: [String]

    public var id: String { name }

    public init(name: String, description: String = "", toolCount: Int = 0, enabled: Bool = true, tools: [String] = []) {
        self.name = name
        self.description = description
        self.toolCount = toolCount
        self.enabled = enabled
        self.tools = tools
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue else { return nil }
        self.name = name
        description = json["description"]?.stringValue ?? ""
        tools = json["tools"].strings
        toolCount = json["tool_count"].int ?? tools.count
        enabled = json["enabled"]?.boolValue ?? false
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
