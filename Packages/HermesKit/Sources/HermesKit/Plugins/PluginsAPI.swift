import Foundation

/// The machine a gateway runs on (`GET /api/system/stats`, `hermes_cli/web_routers/status.py`):
/// what a catalog entry's `platforms` and `requires_hermes` are checked against, and the name the
/// person's devices share for it.
public struct GatewaySystem: Sendable, Hashable {
    /// `Darwin`, `Linux` or `Windows`, as Python's `platform.system()` says it.
    public let os: String
    public let hostname: String
    public let hermesVersion: String

    public init(os: String, hostname: String, hermesVersion: String) {
        self.os = os
        self.hostname = hostname
        self.hermesVersion = hermesVersion
    }
}

/// A catalog entry's state on the gateway (`plugins.manage presence`): whether the app it drives
/// is there, and the catalog's disclosure sentence.
public struct CatalogPresence: Sendable, Hashable {
    public let name: String
    public let title: String
    /// `present`, `missing_app`, `app_not_running` or `unknown`.
    public let state: String
    public let sentence: String
    public let disclosure: String
}

extension BackendClient {
    public func system() async throws -> GatewaySystem {
        let stats = try await rest("api/system/stats")
        return GatewaySystem(os: stats["os"]?.stringValue ?? "", hostname: stats["hostname"]?.stringValue ?? "",
                             hermesVersion: stats["hermes_version"]?.stringValue ?? "")
    }
}

extension ConnectionsClient {
    /// The named catalog entries' state here, in the order asked; unknown names are left out.
    public func presence(of names: [String]) async throws -> [CatalogPresence] {
        let result = try await call("plugins.manage", ["action": .string("presence"), "names": .array(names.map(JSONValue.string))])
        return result["presence"].items.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return CatalogPresence(name: name, title: row["title"]?.stringValue ?? name, state: row["state"]?.stringValue ?? "unknown",
                                   sentence: row["sentence"]?.stringValue ?? "", disclosure: row["disclosure"]?.stringValue ?? "")
        }
    }

    /// Re-reads the gateway's `.env` after a key was written with `PUT /api/env`. Hermes takes no
    /// params here (not even `profile`): it reloads the profile it was started with.
    @discardableResult
    public func reloadEnv() async throws -> Int {
        try await call("reload.env", [:], scoped: false)["updated"].int ?? 0
    }
}
