import Foundation
import Synchronization

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

    /// Hosts that are reachable without crossing the public internet, judged by the name alone:
    /// an address literal by its range (`HostAddresses`), a name by its suffix. A name can still
    /// resolve anywhere, so this decides how a connection is described, not what the app may reach
    /// without asking (`HostAddresses.resolvesLocal` does that).
    public static func looksLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = HostAddresses.literal(host) { return HostAddresses.isLocal(address) }
        if host.contains(":") { return false } // not a valid IPv6 address
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".internal") || host.hasSuffix(".ts.net") {
            return true
        }
        return !host.contains(".") // single-label LAN names like "nas"
    }

    /// The gateway's and its backend's host names, lowercased: the only places a reply's picture
    /// loads from by itself (`WebLink.isOnGateway`).
    public var hosts: Set<String> {
        Set([baseURL.host(), backend?.url.host()].compactMap { $0?.lowercased() })
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
    /// The addresses each Bot was last confirmed for, against its pin read or written then. Shared
    /// by every copy of this store.
    private let verified = Verified()

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

    /// The saved Bots. A gateway or backend address that differs from the one its secrets were
    /// saved for (`Destinations`) is put back, and the file with it: `bots.json` is a plain file
    /// any app of this user can rewrite on the Mac, which isn't sandboxed, and a changed address
    /// would otherwise carry the Keychain's key to another server. A Bot whose pin can't be read
    /// yet (the Keychain before the first unlock) stays unverified: its secrets are read only once
    /// a later read finds its addresses pinned (`check`).
    public func load() throws -> [BotConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var bots = try JSONDecoder().decode([BotConfiguration].self, from: data)
        var restored = false
        for index in bots.indices {
            if case .putBack(let pinned) = examine(bots[index]) {
                bots[index] = pinned
                restored = true
            }
        }
        if restored { try save(bots) }
        return bots
    }

    /// Writes the list. `edited` is the Bot the person just added or changed in the app: its
    /// addresses become the ones its key and sign-in may go to, and the save fails when that can't
    /// be recorded. No other Bot's pin moves, so an address the app didn't set stays unverified.
    public func save(_ bots: [BotConfiguration], edited: BotConfiguration? = nil) throws {
        try write(bots)
        if let edited {
            try pin(edited)
            verified.set(Destinations(edited), for: edited.id)
        }
    }

    /// Saves the person's edit of `edited`, then writes its new secrets (`secrets`): a new key
    /// waits for its addresses to be pinned, so it never sits under the old ones. When the secrets
    /// can't be written, the edit is undone: `previous` goes back, and its pin with it.
    public func save(
        _ bots: [BotConfiguration], edited: BotConfiguration, previous: [BotConfiguration], secrets: () throws -> Void
    ) throws {
        try save(bots, edited: edited)
        do {
            try secrets()
        } catch {
            try? save(previous, edited: previous.first { $0.id == edited.id })
            throw error
        }
    }

    private func write(_ bots: [BotConfiguration]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bots).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Where a Bot's key and Bot Mode sign-in may be sent: the addresses the app itself last saved
    /// for it, kept in the Keychain next to them.
    struct Destinations: Codable, Equatable, Sendable {
        var gateway: URL
        var backend: BackendLink?

        init(_ bot: BotConfiguration) {
            gateway = bot.baseURL
            backend = bot.backend
        }
    }

    /// Why no secret was read for a Bot.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Its pin can't be read (or, saved before pins, written) now, so its addresses can't be
        /// checked.
        case unverified
        /// Its addresses aren't the ones its secrets were saved for: this is the Bot with those
        /// back, as the file now has it too.
        case putBack(BotConfiguration)

        public var errorDescription: String? {
            switch self {
            case .unverified: HermesError.keychainUnavailable.errorDescription
            case .putBack: nil // the app goes on with the saved addresses
            }
        }
    }

    /// Checks `bot`'s addresses against its pin, read now. Throws `Refusal.putBack` with the
    /// pinned addresses (put back in the file too) when they differ, and `Refusal.unverified` when
    /// the pin can't be read.
    public func check(_ bot: BotConfiguration) throws {
        switch examine(bot) {
        case .verified:
            return
        case .unverified:
            throw Refusal.unverified
        case .putBack(let pinned):
            try? putBackInFile(pinned)
            throw Refusal.putBack(pinned)
        }
    }

    /// Whether a read has confirmed `bot`'s addresses since this store last couldn't.
    public func isVerified(_ bot: BotConfiguration) -> Bool {
        verified.destinations(for: bot.id) == Destinations(bot)
    }

    /// Why a read gave no key for `bot`: none is saved, or its addresses can't be checked yet.
    public func missingKey(for bot: BotConfiguration) -> HermesError {
        isVerified(bot) ? .missingAPIKey : .keychainUnavailable
    }

    private enum Outcome {
        case verified, unverified, putBack(BotConfiguration)
    }

    private func examine(_ bot: BotConfiguration) -> Outcome {
        let pinned: Destinations
        do {
            if let found = try destinations(for: bot.id) {
                pinned = found
            } else {
                // Saved before addresses were pinned: what's there now is pinned, once that's
                // actually written.
                try pin(bot)
                pinned = Destinations(bot)
            }
        } catch {
            verified.set(nil, for: bot.id)
            return .unverified
        }
        verified.set(pinned, for: bot.id)
        guard pinned != Destinations(bot) else { return .verified }
        var restored = bot
        restored.baseURL = pinned.gateway
        restored.backend = pinned.backend
        return .putBack(restored)
    }

    /// The pinned addresses back in the file, for the Bot alone.
    private func putBackInFile(_ pinned: BotConfiguration) throws {
        var bots = try JSONDecoder().decode([BotConfiguration].self, from: Data(contentsOf: fileURL))
        guard let index = bots.firstIndex(where: { $0.id == pinned.id }) else { return }
        bots[index].baseURL = pinned.baseURL
        bots[index].backend = pinned.backend
        try write(bots)
    }

    /// Nil when none were pinned; throws when the Keychain can't be read.
    func destinations(for bot: BotConfiguration.ID) throws -> Destinations? {
        guard let text = try keychain.string(for: "\(bot.uuidString).destinations") else { return nil }
        return try? JSONDecoder().decode(Destinations.self, from: Data(text.utf8))
    }

    private func pin(_ bot: BotConfiguration) throws {
        let data = try JSONEncoder().encode(Destinations(bot))
        try keychain.setString(String(decoding: data, as: UTF8.self), for: "\(bot.id.uuidString).destinations")
    }

    /// The key, read only for the addresses it was saved for (`check`).
    public func apiKey(for bot: BotConfiguration) throws -> String? {
        try check(bot)
        return try keychain.string(for: bot.id.uuidString)
    }

    public func setAPIKey(_ key: String, for bot: BotConfiguration.ID) throws {
        try keychain.setString(key, for: bot.uuidString)
    }

    /// Forgets the key, and where it could go.
    public func removeAPIKey(for bot: BotConfiguration.ID) throws {
        verified.set(nil, for: bot)
        try keychain.removeValue(for: bot.uuidString)
        try? keychain.removeValue(for: "\(bot.uuidString).destinations")
    }

    /// The Bot Mode sign-in (session token or cookies), next to the API key, read only for the
    /// addresses it was saved for (`check`).
    public func backendCredential(for bot: BotConfiguration) throws -> BackendCredential? {
        try check(bot)
        guard let text = try keychain.string(for: "\(bot.id.uuidString).backend") else { return nil }
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

    private final class Verified: Sendable {
        private let state = Mutex<[BotConfiguration.ID: Destinations]>([:])

        func destinations(for bot: BotConfiguration.ID) -> Destinations? {
            state.withLock { $0[bot] }
        }

        func set(_ destinations: Destinations?, for bot: BotConfiguration.ID) {
            state.withLock { $0[bot] = destinations }
        }
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
