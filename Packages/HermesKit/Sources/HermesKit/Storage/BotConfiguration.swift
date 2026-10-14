import Foundation

/// A Hermes Agent gateway the app can talk to.
///
/// The API key is deliberately not a property: it lives in the Keychain under
/// ``id`` and never touches the JSON file this type is saved to.
public struct BotConfiguration: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    /// Root URL of the gateway, e.g. `http://mac-mini.local:8642` or
    /// `https://hermes.example.com/p/research` for a multiplexed profile.
    public var baseURL: URL
    /// Name of the avatar accent colour.
    public var accent: String
    public var createdAt: Date
    /// The `hermes serve` backend behind this gateway, for Bot Mode. Optional:
    /// sessions work without it.
    public var backend: BackendLink?

    public init(id: UUID = UUID(), name: String, baseURL: URL, accent: String, createdAt: Date = .now, backend: BackendLink? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.accent = accent
        self.createdAt = createdAt
        self.backend = backend
    }

    /// The Hermes profile this gateway serves: the `<name>` of a multiplexed `/p/<name>` URL,
    /// or `nil` for the main profile.
    public var profileName: String? {
        let parts = baseURL.path.split(separator: "/")
        guard let index = parts.firstIndex(of: "p"), parts.indices.contains(index + 1) else { return nil }
        return String(parts[index + 1])
    }

    /// Normalises what a person types into a gateway URL.
    ///
    /// Accepts `host`, `host:port`, full URLs, and pasted OpenAI base URLs ending in
    /// `/v1`. A missing scheme becomes `http` for local-looking hosts and `https`
    /// otherwise; a missing port on plain HTTP becomes Hermes' default `8642`.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
            text = (Self.looksLocal(hostOnly) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        if scheme == "http", components.port == nil, Self.looksLocal(host) {
            components.port = 8642
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/v1/chat/completions", "/v1"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Hosts that are reachable without crossing the public internet.
    public static func looksLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { // IPv6 literal: loopback, link-local or unique-local
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") || host.hasSuffix(".ts.net") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return !host.contains(".") // single-label LAN names like "nas"
        }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // CGNAT range used by Tailscale
        default: return false
        }
    }

    /// True when requests (and the bearer key) would travel unencrypted across the internet.
    public var isInsecureOverInternet: Bool {
        baseURL.scheme == "http" && !Self.looksLocal(baseURL.host() ?? "")
    }

    /// Host and port for compact display, e.g. `mac-mini.local:8642/p/research`.
    public var displayAddress: String {
        var text = baseURL.host() ?? baseURL.absoluteString
        if let port = baseURL.port { text += ":\(port)" }
        let path = baseURL.path(percentEncoded: false)
        if !path.isEmpty, path != "/" { text += path }
        return text
    }
}

/// Where Bot Mode lives: the Hermes backend (`hermes serve`, the dashboard and
/// Hermes Desktop's server) and how the app signs in to it.
public struct BackendLink: Hashable, Codable, Sendable {
    public enum SignIn: String, Codable, Sendable, CaseIterable {
        /// Read the session token from a local, ungated backend (Hermes Desktop's way).
        case automatic
        /// A pasted session token.
        case token
        /// The dashboard's username and password; the session cookies are kept.
        case password
    }

    public var url: URL
    public var signIn: SignIn
    public var username: String?

    public init(url: URL, signIn: SignIn, username: String? = nil) {
        self.url = url
        self.signIn = signIn
        self.username = username
    }

    /// The backend's default port.
    public static let defaultPort = 9119

    /// Normalises a typed backend address; a missing port on a local host becomes 9119.
    public static func normalizedURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let hostOnly = host.split(separator: ":").first.map(String.init) ?? host
            text = (BotConfiguration.looksLocal(hostOnly) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        if scheme == "http", components.port == nil, BotConfiguration.looksLocal(host) {
            components.port = defaultPort
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The usual backend address for a gateway: same host, port 9119.
    public static func suggestedURL(forGateway gateway: URL) -> URL? {
        guard var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false), components.host != nil else { return nil }
        if gateway.scheme == "http" {
            components.port = defaultPort
        }
        components.path = ""
        return components.url
    }

    /// Only loopback backends hand out their token without a sign-in.
    public var isLoopback: Bool {
        let host = (url.host() ?? "").lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    public var isInsecureOverInternet: Bool {
        url.scheme == "http" && !BotConfiguration.looksLocal(url.host() ?? "")
    }

    public var displayAddress: String {
        var text = url.host() ?? url.absoluteString
        if let port = url.port { text += ":\(port)" }
        return text
    }
}

/// Persists bot configurations to a JSON file and their keys to the Keychain.
public struct BotStore: Sendable {
    public let fileURL: URL
    public let keychain: KeychainStore

    public init(fileURL: URL, keychain: KeychainStore) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    /// The store in the app's Application Support directory.
    public static func standard() -> BotStore {
        let directory = HermesStorage.applicationSupport
        return BotStore(
            fileURL: directory.appending(path: "bots.json"),
            // Per bundle id, so the Debug app ("Hermes Dev") never sees the real app's keys.
            keychain: KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes").api-key")
        )
    }

    public func load() throws -> [BotConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([BotConfiguration].self, from: data)
    }

    public func save(_ bots: [BotConfiguration]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bots).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func apiKey(for bot: BotConfiguration.ID) throws -> String? {
        try keychain.string(for: bot.uuidString)
    }

    public func setAPIKey(_ key: String, for bot: BotConfiguration.ID) throws {
        try keychain.setString(key, for: bot.uuidString)
    }

    public func removeAPIKey(for bot: BotConfiguration.ID) throws {
        try keychain.removeValue(for: bot.uuidString)
    }

    /// The Bot Mode sign-in (session token or cookies), next to the API key.
    public func backendCredential(for bot: BotConfiguration.ID) -> BackendCredential? {
        guard let text = try? keychain.string(for: "\(bot.uuidString).backend") else { return nil }
        return try? JSONDecoder().decode(BackendCredential.self, from: Data(text.utf8))
    }

    public func setBackendCredential(_ credential: BackendCredential?, for bot: BotConfiguration.ID) throws {
        guard let credential else {
            try keychain.removeValue(for: "\(bot.uuidString).backend")
            return
        }
        let data = try JSONEncoder().encode(credential)
        try keychain.setString(String(decoding: data, as: UTF8.self), for: "\(bot.uuidString).backend")
    }
}

/// Where this build keeps its files.
///
/// The Mac app is not sandboxed (it ships as a Developer ID DMG), so Application Support is shared
/// with every other app. Folders are named by bundle id, the convention for unsandboxed apps: the
/// real app uses `co.caffeinatedcode.hermes`, Debug's "Hermes Dev" uses `….dev`, so the two run side
/// by side, and neither touches `Hermes/`, which belongs to Hermes Desktop.
public enum HermesStorage {
    public static let releaseBundleIdentifier = "co.caffeinatedcode.hermes"

    public static var applicationSupport: URL {
        #if os(macOS)
        let bundle = Bundle.main.bundleIdentifier ?? releaseBundleIdentifier
        let directory = URL.applicationSupportDirectory.appending(path: bundle, directoryHint: .isDirectory)
        migrateIfNeeded(into: directory)
        return directory
        #else
        // iOS and iPadOS give every app its own container, so nothing is shared there.
        return URL.applicationSupportDirectory.appending(path: "Hermes", directoryHint: .isDirectory)
        #endif
    }

    #if os(macOS)
    /// Hermes 1.0 (2610121617) kept its two items in `Application Support/Hermes`, Hermes Desktop's
    /// folder. Move exactly those (and only when they're ours) into this build's own folder, once.
    private static func migrateIfNeeded(into directory: URL) {
        guard Bundle.main.bundleIdentifier == releaseBundleIdentifier else { return }
        let fileManager = FileManager.default
        let legacy = URL.applicationSupportDirectory.appending(path: "Hermes", directoryHint: .isDirectory)
        let legacyBots = legacy.appending(path: "bots.json")
        let newBots = directory.appending(path: "bots.json")
        guard fileManager.fileExists(atPath: legacyBots.path(percentEncoded: false)),
              !fileManager.fileExists(atPath: newBots.path(percentEncoded: false)),
              let data = try? Data(contentsOf: legacyBots),
              (try? JSONDecoder().decode([BotConfiguration].self, from: data)) != nil
        else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacyBots, to: newBots)
        let legacyImages = legacy.appending(path: "SentImages", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: legacyImages.path(percentEncoded: false)) {
            try? fileManager.moveItem(at: legacyImages, to: directory.appending(path: "SentImages", directoryHint: .isDirectory))
        }
    }
    #endif
}
