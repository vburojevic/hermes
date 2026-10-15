import Foundation

/// Apps and Tools over the gateway protocol (`docs/connections.md` §1): connectors, MCP servers,
/// plugins and built-in toolsets. Every call is scoped to one Hermes profile.
///
/// The gateway rejects parameters it doesn't know (error 4000), so only documented keys are sent.
/// Secrets go one way: `setAPIKey`, `addServer(bearerToken:)` and plugin secrets are written and
/// never read back.
public struct ConnectionsClient: Sendable {
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let profile: String?
    let transport: Transport

    public init(profile: String?, transport: @escaping Transport) {
        self.profile = profile
        self.transport = transport
    }

    /// `scoped: false` for the few calls whose params have no `profile` key (`reload.mcp`,
    /// `toolsets.list`): they act on the gateway's own profile.
    private func call(_ method: String, _ params: [String: JSONValue] = [:], scoped: Bool = true) async throws -> JSONValue {
        var params = params
        if scoped, let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return try await transport(method, params)
    }

    /// Settings manage the person's own accounts; a chat's request card owns a session's.
    private static let accountOwner: JSONValue = .object(["type": .string("account")])

    // MARK: Apps

    /// The apps and their state. `available: false` means the Nous sign-in state.
    public func connectors() async throws -> (available: Bool, rows: [ConnectorRow]) {
        let result = try await call("connectors.list", ["owner": Self.accountOwner])
        return (result["available"]?.boolValue ?? true, result["connectors"].items.compactMap(ConnectorRow.init(json:)))
    }

    public func catalog() async throws -> [ConnectorCatalogEntry] {
        try await call("connectors.catalog")["connectors"].items.compactMap(ConnectorCatalogEntry.init(json:))
    }

    /// Starts a sign-in: a new app, `alias` for another account, or `reconnect` (with the account's
    /// `connectionID` when it has no alias) to repair one. Returns the operation to follow.
    public func connect(_ connector: String, alias: String? = nil, reconnect: Bool = false, connectionID: String? = nil) async throws -> ConnectionOperation {
        var params: [String: JSONValue] = [
            "owner": Self.accountOwner,
            "connectors": .array([.string(connector)]),
        ]
        if reconnect { params["reconnect"] = .bool(true) }
        if let connectionID, reconnect, alias == nil {
            params["connection_id"] = .string(connectionID)
        } else if let alias {
            params["alias"] = .string(alias)
        }
        let result = try await call("connectors.connect", params)
        guard let operation = ConnectionOperation(json: result) else {
            throw GatewayRPCError(code: 5034, message: "Hermes started no sign-in")
        }
        return operation
    }

    public func operationStatus(_ opID: String) async throws -> ConnectionOperation? {
        ConnectionOperation(json: try await call("connectors.operation.status", ["owner": Self.accountOwner, "op_id": .string(opID)]))
    }

    /// The browser came back (`hermes://connections/done`): Hermes reads the accounts now, not at
    /// its next tick.
    public func wake(_ opID: String) async throws {
        _ = try await call("connectors.operation.wake", ["owner": Self.accountOwner, "op_id": .string(opID)])
    }

    public func accounts(of connector: String? = nil) async throws -> [ConnectorAccount] {
        var params: [String: JSONValue] = [:]
        if let connector { params["connector"] = .string(connector) }
        return try await call("connectors.accounts", params)["accounts"].items.compactMap(ConnectorAccount.init(json:))
    }

    /// Names an account ("personal", "work"). `ALIAS_TAKEN` when another has it.
    public func rename(account connectionID: String, alias: String) async throws -> ConnectorAccount? {
        ConnectorAccount(json: try await call("connectors.accounts.rename", ["connection_id": .string(connectionID), "alias": .string(alias)]))
    }

    public func remove(account connectionID: String) async throws {
        _ = try await call("connectors.accounts.remove", ["connection_id": .string(connectionID)])
    }

    public func tools(of connector: String, refresh: Bool = false) async throws -> ConnectorToolList {
        var params: [String: JSONValue] = ["slug": .string(connector)]
        if refresh { params["refresh"] = .bool(true) }
        return ConnectorToolList(json: try await call("connectors.tools", params))
    }

    public func policy() async throws -> ConnectorPolicy {
        ConnectorPolicy(json: try await call("connectors.policy.get"))
    }

    /// Applies a change against the revision the caller saw. If someone else changed the policy
    /// meanwhile (`POLICY_CONFLICT`), it re-reads, rebuilds the change from the fresh policy and
    /// tries once more.
    @discardableResult
    public func setPolicy(_ policy: ConnectorPolicy, change: @Sendable (ConnectorPolicy) -> ConnectorPolicyChange) async throws -> ConnectorPolicy {
        do {
            return try await write(change(policy), revision: policy.expectedRevision)
        } catch where ConnectorErrorReason(error: error) == .policyConflict {
            let fresh = try await self.policy()
            return try await write(change(fresh), revision: fresh.expectedRevision)
        }
    }

    private func write(_ change: ConnectorPolicyChange, revision: String) async throws -> ConnectorPolicy {
        _ = try await call("connectors.policy.set", ["change": change.json, "expected_revision": .string(revision)])
        // The result has only the effective rules; the layers say what's locked.
        return try await policy()
    }

    // MARK: MCP servers

    public func mcpCatalog() async throws -> [McpPreset] {
        try await call("mcp.catalog")["servers"].items.compactMap(McpPreset.init(json:))
    }

    /// Configured servers with their live state.
    public func mcpServers() async throws -> [McpServer] {
        async let configured = call("mcp.servers.list")
        async let runtime = call("mcp.servers.status")
        var servers = try await configured["servers"].items.compactMap(McpServer.init(json:))
        let rows = (try? await runtime)?["servers"].items ?? []
        for row in rows {
            guard let name = row["name"]?.stringValue, let index = servers.firstIndex(where: { $0.name == name }) else { continue }
            servers[index].apply(runtime: row)
        }
        return servers
    }

    /// Adds a server from a preset and/or a config (`url` or `command` + `args`, `env`, `auth`).
    @discardableResult
    public func addServer(name: String, preset: String? = nil, config: [String: JSONValue]? = nil, bearerToken: String? = nil) async throws -> McpServer? {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let preset { params["preset"] = .string(preset) }
        if let config { params["config"] = .object(config) }
        if let bearerToken, !bearerToken.isEmpty { params["bearer_token"] = .string(bearerToken) }
        return try await call("mcp.servers.add", params)["server"].flatMap(McpServer.init(json:))
    }

    /// Writes a key to the profile's `.env`; Hermes answers with its env name only.
    @discardableResult
    public func setAPIKey(server: String, value: String, envVar: String? = nil) async throws -> String? {
        var params: [String: JSONValue] = ["name": .string(server), "value": .string(value)]
        if let envVar { params["env_var"] = .string(envVar) }
        return try await call("mcp.servers.set_api_key", params)["env_var"]?.stringValue
    }

    public func testServer(_ name: String) async throws -> McpTestResult {
        McpTestResult(json: try await call("mcp.servers.test", ["name": .string(name)]))
    }

    public func removeServer(_ name: String) async throws {
        _ = try await call("mcp.servers.remove", ["name": .string(name)])
    }

    public func startOAuth(server: String) async throws -> McpOAuthFlow {
        let result = try await call("mcp.servers.oauth.start", ["name": .string(server)])
        guard let id = result["session_id"]?.stringValue, let url = result["auth_url"]?.stringValue.flatMap(URL.init(string:)) else {
            throw GatewayRPCError(code: 5000, message: "Hermes started no sign-in")
        }
        return McpOAuthFlow(sessionID: id, authURL: url)
    }

    public func pollOAuth(server: String, flow: String) async throws -> McpOAuthState {
        let result = try await call("mcp.servers.oauth.poll", ["name": .string(server), "session_id": .string(flow)])
        switch result["status"]?.stringValue {
        case "approved": return .approved(tools: result["tools"].items.compactMap { $0["name"]?.stringValue })
        case "error": return .failed(result["error_message"]?.stringValue ?? String(localized: "Sign-in failed"))
        default: return .pending
        }
    }

    public func cancelOAuth(server: String, flow: String) async throws {
        _ = try await call("mcp.servers.oauth.cancel", ["name": .string(server), "session_id": .string(flow)])
    }

    /// Open chats rebuild their MCP tools (the prompt cache is invalidated): after an add, a
    /// remove or a key change. `confirm` skips Hermes's "are you sure".
    public func reloadMCP() async throws {
        _ = try await call("reload.mcp", ["confirm": .bool(true)], scoped: false)
    }

    /// Turns whole MCP servers on or off: `enabled` is every server that should be on (replace
    /// semantics). `tools.configure` only excludes single tools (`server:tool`).
    public func setEnabledServers(_ enabled: [String]) async throws {
        _ = try await call("profiles.configure", ["enabled_mcp_servers": .array(enabled.map(JSONValue.string))])
    }

    // MARK: On / off

    /// Turns built-in toolsets on or off.
    public func setToolsets(_ names: [String], enabled: Bool) async throws {
        _ = try await call("tools.configure", ["action": .string(enabled ? "enable" : "disable"), "names": .array(names.map(JSONValue.string))])
    }

    // MARK: Plugins

    public func plugins() async throws -> [HermesPlugin] {
        try await manage(["action": .string("list")])["plugins"].items.compactMap(HermesPlugin.init(json:))
    }

    /// Curated catalog plugins this OS runs, for suggestions.
    public func catalogPlugins() async throws -> [CatalogPlugin] {
        try await manage(["action": .string("onboarding")])["onboarding"].items.compactMap(CatalogPlugin.init(json:))
    }

    public func togglePlugin(_ key: String, enable: Bool) async throws -> PluginActionResult {
        PluginActionResult(json: try await manage(["action": .string("toggle"), "key": .string(key), "enable": .bool(enable)]))
    }

    public func installPlugin(catalogName: String) async throws -> PluginActionResult {
        PluginActionResult(json: try await manage(["action": .string("install"), "catalog_name": .string(catalogName), "enable": .bool(true)]))
    }

    public func installPlugin(repo: String, ref: String? = nil) async throws -> PluginActionResult {
        var params: [String: JSONValue] = ["action": .string("install"), "repo": .string(repo), "enable": .bool(true)]
        if let ref, !ref.isEmpty { params["ref"] = .string(ref) }
        return PluginActionResult(json: try await manage(params))
    }

    /// Re-pins to the catalog's version. If the update widens access Hermes answers
    /// `consent_required` and changes nothing until it's retried with `acceptCapabilities`.
    public func updatePlugin(_ name: String, acceptCapabilities: Bool = false) async throws -> PluginActionResult {
        var params: [String: JSONValue] = ["action": .string("update"), "name": .string(name)]
        if acceptCapabilities { params["accept_capabilities"] = .bool(true) }
        return PluginActionResult(json: try await manage(params))
    }

    public func removePlugin(_ name: String) async throws -> PluginActionResult {
        PluginActionResult(json: try await manage(["action": .string("remove"), "name": .string(name)]))
    }

    /// Saves non-secret settings; secrets go through the write-only key path.
    public func savePluginSettings(_ key: String, values: [String: JSONValue]) async throws -> PluginActionResult {
        PluginActionResult(json: try await manage(["action": .string("settings"), "key": .string(key), "values": .object(values)]))
    }

    public func lookupPlugin(_ name: String) async throws -> PluginLookup {
        let result = try await call("plugins.catalog.lookup", ["name": .string(name)])
        switch result["status"]?.stringValue {
        case "found":
            guard let entry = result["entry"], let name = entry["name"]?.stringValue else { return .unknown }
            return .found(name: name, repo: entry["repo"]?.stringValue ?? "")
        case "unavailable": return .unavailable
        default: return .unknown
        }
    }

    /// Each toolset's tool names (`tools.list`): a plugin's tools live in the toolset named
    /// after its key. `AgentPluginRow` doesn't list them.
    public func toolsetTools() async throws -> [String: [String]] {
        var tools: [String: [String]] = [:]
        for row in try await call("tools.list", scoped: false)["toolsets"].items {
            if let name = row["name"]?.stringValue { tools[name] = row["tools"].strings }
        }
        return tools
    }

    /// Every skill name (`skills.manage list`); a plugin's are qualified `<plugin>:<skill>`.
    public func skillNames() async throws -> [String] {
        try await call("skills.manage", ["action": .string("list")])["skills"].fields.values.flatMap(\.strings)
    }

    private func manage(_ params: [String: JSONValue]) async throws -> JSONValue {
        try await call("plugins.manage", params)
    }

    // MARK: Built-in

    public func toolsets() async throws -> [BuiltInToolset] {
        try await call("toolsets.list", scoped: false)["toolsets"].items.compactMap(BuiltInToolset.init(json:))
    }
}
