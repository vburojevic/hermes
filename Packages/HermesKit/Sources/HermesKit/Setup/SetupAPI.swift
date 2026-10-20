import Foundation

// The reads behind Settings → Setup and the fixes it makes (`docs/setup.md` §4). Each fix writes
// only what the person tapped, through the route Hermes Desktop uses for the same setting. The
// config itself is read and written with `config(profile:)` and `updateConfig(_:profile:)`
// (`GatewayAudio.swift`); updating Hermes itself is `HermesUpdate.swift`.

extension BackendClient {
    /// Whether the Board's plugin answers (`GET /api/plugins/kanban/workflow`): a turned-off
    /// plugin is "Plugin not found", an older Hermes has no such route at all.
    public func boardAvailability() async throws -> GatewaySetupFacts.Board {
        do {
            _ = try await kanban("workflow")
            return .on
        } catch Failure.http(404, let detail) {
            return detail == "Plugin not found" ? .turnedOff : .missing
        }
    }

    /// Built-in toolsets that are on but have no key (`GET /api/tools/toolsets`, `configured`
    /// false): Hermes leaves their tools out until one is set (`docs/setup.md` §4.5).
    public func toolsetsWithoutKeys(profile: String?) async throws -> Set<String> {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        let rows = try await rest("api/tools/toolsets", query: query)
        return Set(rows.items.compactMap { row in
            guard row["enabled"]?.boolValue == true, row["configured"]?.boolValue == false else { return nil }
            return row["name"]?.stringValue
        })
    }

    /// Whether connected apps are turned on in the profile's config (`tools.connectors`, a switch
    /// or `{enabled}`; on unless set off, like `ConnectorConfig.from_raw`).
    public func appsTurnedOn(profile: String?) async throws -> Bool {
        GatewaySetup.appsTurnedOn(config: try await config(profile: profile))
    }

    /// Whether this gateway is signed in to Nous (`GET /api/providers/oauth`).
    public func signedInToNous(profile: String?) async throws -> Bool {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return GatewaySetup.signedInToNous(oauthProviders: try await rest("api/providers/oauth", query: query))
    }

    /// Turns the Board's plugin back on: `kanban` out of `plugins.disabled`. Its routes come back
    /// without a restart.
    public func enableBoard() async throws {
        let disabled = try await config(profile: nil)["plugins"]?["disabled"]?.strings ?? []
        let kept = disabled.filter { $0 != "kanban" }.map(JSONValue.string)
        try await updateConfig(.object(["plugins": .object(["disabled": .array(kept)])]), profile: nil)
    }
}

extension GatewaySetup {
    /// `tools.connectors` is a switch or `{enabled}`, and on unless set off
    /// (`ConnectorConfig.from_raw`).
    public static func appsTurnedOn(config: JSONValue) -> Bool {
        let connectors = config["tools"]?["connectors"]
        if let on = connectors?.boolValue { return on }
        return connectors?["enabled"]?.boolValue ?? true
    }

    /// `nous`'s `status.logged_in` in `GET /api/providers/oauth`.
    public static func signedInToNous(oauthProviders: JSONValue) -> Bool {
        let nous = oauthProviders["providers"].items.first { $0["id"]?.stringValue == "nous" }
        return nous?["status"]?["logged_in"]?.boolValue ?? false
    }
}

/// A toolset's providers and their keys (`GET /api/tools/toolsets/{name}/config`), for adding a
/// key from the app (`docs/setup.md` §4.5). Key values never come back, only whether each is set.
public struct ToolsetKeys: Sendable, Equatable {
    public struct Provider: Sendable, Equatable, Identifiable {
        public struct Key: Sendable, Equatable, Identifiable {
            public var name: String
            public var prompt: String
            public var url: URL?
            public var isSet: Bool
            public var id: String { name }
        }

        public var name: String
        public var badge: String?
        public var keys: [Key]
        /// `ready`, `needs_keys`, `needs_auth`, `needs_setup`.
        public var status: String
        public var isActive: Bool
        public var id: String { name }
    }

    public var providers: [Provider]

    /// Providers a key makes work: ones with keys to fill, not the Nous-managed rows.
    public var takingKeys: [Provider] { providers.filter { !$0.keys.isEmpty } }

    public init(json: JSONValue) {
        providers = json["providers"].items.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            if row["requires_nous_auth"]?.boolValue == true || row["managed_nous_feature"]?.stringValue != nil { return nil }
            let keys = row["env_vars"].items.compactMap { env -> Provider.Key? in
                guard let key = env["key"]?.stringValue else { return nil }
                return Provider.Key(name: key, prompt: env["prompt"]?.stringValue ?? key,
                                    url: env["url"]?.stringValue.flatMap(URL.init(string:)), isSet: env["is_set"]?.boolValue ?? false)
            }
            let badge = row["badge"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return Provider(name: name, badge: badge, keys: keys, status: row["status"]?.stringValue ?? "",
                            isActive: row["is_active"]?.boolValue ?? false)
        }
    }
}

extension BackendClient {
    private static func toolsetPath(_ name: String) -> String {
        "api/tools/toolsets/" + escape(name)
    }

    public func toolsetKeys(_ name: String, profile: String?) async throws -> ToolsetKeys {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        return ToolsetKeys(json: try await rest(Self.toolsetPath(name) + "/config", query: query))
    }

    /// Saves keys to the gateway's `.env` (`PUT …/env`; Hermes accepts only the toolset's own
    /// variables), then makes `provider` the one the toolset uses (`PUT …/provider`). The values
    /// are sent once and kept nowhere in the app.
    public func saveToolsetKeys(_ name: String, provider: String, keys: [String: String], profile: String?) async throws {
        let query = profile.map { [URLQueryItem(name: "profile", value: $0)] } ?? []
        var env: [String: JSONValue] = [:]
        for (key, value) in keys { env[key] = .string(value) }
        _ = try await rest(Self.toolsetPath(name) + "/env", method: "PUT", query: query, body: .object(["env": .object(env)]))
        _ = try await rest(Self.toolsetPath(name) + "/provider", method: "PUT", query: query, body: .object(["provider": .string(provider)]))
    }
}
