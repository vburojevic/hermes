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
    /// How the app passes an access gateway in front of this gateway and its backend; nil is none
    /// (`docs/connecting-and-voice.md` §11). Its secret is in the Keychain (`BotStore.accessSecret`).
    public var access: GatewayAccess?

    public init(
        id: UUID = UUID(), name: String, baseURL: URL, accent: String, createdAt: Date = .now, backend: BackendLink? = nil,
        access: GatewayAccess? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.accent = accent
        self.createdAt = createdAt
        self.backend = backend
        self.access = access
    }

    /// The addresses an access gateway's headers may go to: the gateway's and its backend's.
    public var accessAddresses: [URL] {
        [baseURL] + (backend.map { [$0.url] } ?? [])
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

/// What an address answers when Bot Mode checks it before signing in (`GET /api/status`,
/// `docs/setup.md` §4.1): the sign-ins Edit Gateway offers there, or why it offers none.
public enum BackendCheck: Hashable, Sendable {
    /// A Hermes backend, with the sign-ins Bot Mode can use on it, in the order they're shown.
    case backend(signIns: [BackendLink.SignIn], version: String?)
    /// Hermes's API server (the gateway) answered, not the backend: no sign-in can work here.
    case apiServer
    /// A Hermes backend whose only sign-ins (Nous, single sign-on) Bot Mode can't use.
    case unsupported(providers: [String])
    /// Something other than Hermes answered.
    case notHermes
    /// Nothing answered, or not in time. The reason is the network's, in words.
    case unreachable(String)

    /// The sign-ins a backend that reported `status` accepts from Bot Mode. An ungated backend
    /// (Hermes binds one only to loopback) hands out its session token: Automatic, or a pasted
    /// token. A gated one takes a token with `session-token` and a password with `basic`, and
    /// none when it signs in only with Nous or single sign-on.
    public static func signIns(for status: BackendStatus) -> [BackendLink.SignIn] {
        guard status.authRequired else { return [.automatic, .token] }
        var signIns: [BackendLink.SignIn] = []
        if status.authProviders.contains("session-token") { signIns.append(.token) }
        if status.supportsPassword { signIns.append(.password) }
        return signIns
    }

    /// What a backend that reported `status` is to Bot Mode.
    public static func classify(_ status: BackendStatus) -> BackendCheck {
        let signIns = signIns(for: status)
        return signIns.isEmpty ? .unsupported(providers: status.authProviders) : .backend(signIns: signIns, version: status.version)
    }

    /// The sign-ins Edit Gateway offers. An address that didn't answer keeps every one on offer,
    /// as before the check; one that can't take Bot Mode offers none.
    public var offeredSignIns: [BackendLink.SignIn] {
        switch self {
        case .backend(let signIns, _): signIns
        case .unreachable: BackendLink.SignIn.allCases
        case .apiServer, .unsupported, .notHermes: []
        }
    }

    /// The sign-in Edit Gateway selects: the current one while it's offered, otherwise
    /// Automatic, then a password, then a token. Password is selected only where the backend
    /// said it has one, never on an address that didn't answer.
    public func preferredSignIn(current: BackendLink.SignIn?) -> BackendLink.SignIn? {
        let offered = offeredSignIns
        if let current, offered.contains(current) { return current }
        if offered.contains(.automatic) { return .automatic }
        if case .backend = self, offered.contains(.password) { return .password }
        return offered.contains(.token) ? .token : nil
    }

    /// Bot Mode can sign in here (or the address didn't answer, so it may yet).
    public var acceptsBotMode: Bool {
        switch self {
        case .backend, .unreachable: true
        case .apiServer, .unsupported, .notHermes: false
        }
    }
}

/// Why Bot Mode stopped trying to connect (`docs/setup.md` §4.1): no retry can get past it, so
/// it waits for the sign-in, the address or Bot Mode to change, or for Check Again.
public enum BotModeStop: Hashable, Sendable {
    /// The backend refused the sign-in, or takes none Bot Mode can use.
    case refused
    /// The address is Hermes's API server (the gateway), not its backend.
    case wrongServer

    /// What a failed connect means once the address was checked. `signInRefused` when the
    /// backend answered 401 to Bot Mode's credential. An address that didn't answer, or a
    /// backend that only failed some other way, is retried as before. An address that isn't
    /// Hermes at all keeps its own error, which already stops the retries.
    public static func after(_ check: BackendCheck, signInRefused: Bool) -> BotModeStop? {
        switch check {
        case .apiServer: .wrongServer
        case .notHermes: nil
        case .unsupported: .refused
        case .backend: signInRefused ? .refused : nil
        case .unreachable: nil
        }
    }
}

/// What Edit Gateway's Save keeps of Bot Mode when its address or sign-in can't work yet
/// (`docs/setup.md` §4.1). Save never waits on Bot Mode: the gateway's edits and Bot Mode's
/// fields are saved as typed, and Bot Mode starts stopped instead of asking the backend again.
public struct BotModeSave: Equatable, Sendable {
    /// Bot Mode's address and sign-in, as typed.
    public var link: BackendLink
    /// The typed session token, so the sign-in that was refused is the one shown and tried
    /// after Check Again; nil for the other sign-ins and when none was typed.
    public var credential: BackendCredential?
    /// Where Bot Mode starts; nil when the fields may yet work, so it connects as usual.
    public var stop: BotModeStop?

    /// `check` is what the address answered on Save (nil when the answer is stale),
    /// `signInRefused` when the backend refused the typed sign-in.
    public init(link: BackendLink, typedToken: String, check: BackendCheck?, signInRefused: Bool) {
        self.link = link
        let token = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        credential = link.signIn == .token && !token.isEmpty ? .sessionToken(token) : nil
        var stop = check.flatMap { BotModeStop.after($0, signInRefused: signInRefused) }
        if stop == nil, signInRefused { stop = .refused }
        // A sign-in the backend doesn't take is refused before it's sent.
        if stop == nil, case .backend(let signIns, _)? = check, !signIns.contains(link.signIn) { stop = .refused }
        self.stop = stop
    }
}

/// Persists bot configurations to a JSON file and their keys to the Keychain.
public struct BotStore: Sendable {
    public let fileURL: URL
    public let keychain: KeychainStore
    /// The client certificates proxies ask for, found by the fingerprint each Bot's access names.
    public let identities: ClientIdentityStore
    /// The addresses each Bot was last confirmed for, against its pin read or written then. Shared
    /// by every copy of this store.
    private let verified = Verified()

    public init(fileURL: URL, keychain: KeychainStore, identities: ClientIdentityStore = .keychain) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.identities = identities
    }

    /// The store in the app's Application Support directory. `identities` is the Keychain's, but
    /// for a Debug run on the Mac that keeps certificates in memory (`-HERMES_MEMORY_CERTIFICATES`).
    public static func standard(identities: ClientIdentityStore = .keychain) -> BotStore {
        let directory = HermesStorage.applicationSupport
        return BotStore(
            fileURL: directory.appending(path: "bots.json"),
            // Per bundle id, so the Debug app ("Hermes Dev") never sees the real app's keys.
            keychain: KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes").api-key"),
            identities: identities
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

    /// Forgets the key, the access gateway's secret and session, and where they could go.
    public func removeAPIKey(for bot: BotConfiguration.ID) throws {
        verified.set(nil, for: bot)
        try keychain.removeValue(for: bot.uuidString)
        try? keychain.removeValue(for: "\(bot.uuidString).access")
        try? keychain.removeValue(for: "\(bot.uuidString).access-session")
        try? keychain.removeValue(for: "\(bot.uuidString).destinations")
    }

    /// The service token's secret for the access gateway in front of `bot`, read only for the
    /// addresses it was saved for (`check`), like the key.
    public func accessSecret(for bot: BotConfiguration) throws -> String? {
        try check(bot)
        return try keychain.string(for: "\(bot.id.uuidString).access")
    }

    /// Saves the secret, or removes it when nil or empty.
    public func setAccessSecret(_ secret: String?, for bot: BotConfiguration.ID) throws {
        guard let secret, !secret.isEmpty else {
            try keychain.removeValue(for: "\(bot.uuidString).access")
            return
        }
        try keychain.setString(secret, for: "\(bot.uuidString).access")
    }

    /// The access gateway's session from its sign-in page (`docs/connecting-and-voice.md`
    /// §11.10), read only for the addresses it was saved for (`check`): its cookies are as good as
    /// a password until they run out.
    public func accessSession(for bot: BotConfiguration) throws -> AccessSession? {
        try check(bot)
        guard let text = try keychain.string(for: "\(bot.id.uuidString).access-session") else { return nil }
        return try? JSONDecoder().decode(AccessSession.self, from: Data(text.utf8))
    }

    /// Saves the session, or removes it when nil.
    public func setAccessSession(_ session: AccessSession?, for bot: BotConfiguration.ID) throws {
        guard let session else {
            try keychain.removeValue(for: "\(bot.uuidString).access-session")
            return
        }
        let data = try JSONEncoder().encode(session)
        try keychain.setString(String(decoding: data, as: UTF8.self), for: "\(bot.uuidString).access-session")
    }

    /// What `bot`'s requests carry past its access gateway, or nil when none is set up or its
    /// secret can't be read. A session that ran out is still sent: the access gateway's refusal
    /// of it is what says to sign in again (`AccessRefusal.signInExpired`).
    public func accessCredentials(for bot: BotConfiguration) -> GatewayAccessRegistry.Credentials? {
        guard let access = bot.access else { return nil }
        var token: GatewayAccessRegistry.Credentials?
        if access.method == .serviceToken, !access.clientID.isEmpty,
           let secret = try? accessSecret(for: bot), !secret.isEmpty {
            token = .serviceToken(access, secret: secret)
        } else if access.method == .browserSignIn, let session = try? accessSession(for: bot), !session.cookies.isEmpty {
            token = session.credentials
        }
        guard let certificate = access.clientCertificate, let identity = try? clientIdentity(for: bot) else { return token }
        return (token ?? .init(method: access.method)).presenting(identity, as: certificate)
    }

    /// The client certificate's identity for the proxy in front of `bot`, read only for the
    /// addresses it was saved for (`check`), like the key: `bots.json` names it by fingerprint,
    /// and a rewritten address must not take it to another server.
    public func clientIdentity(for bot: BotConfiguration) throws -> ClientIdentity? {
        guard let fingerprint = bot.access?.clientCertificate?.fingerprint else { return nil }
        try check(bot)
        return try identities.identity(fingerprint: fingerprint)
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

    /// This build's layout (`StorageLayout`).
    public static let layout: StorageLayout = {
        #if os(macOS)
        let isMac = true
        #else
        let isMac = false
        #endif
        return StorageLayout(applicationSupport: .applicationSupportDirectory, caches: .cachesDirectory,
                             bundleIdentifier: Bundle.main.bundleIdentifier, isMac: isMac)
    }()

    /// Where the app's queues, outbox, waiting chats and group posts live: the system folder on iOS,
    /// this build's own folder in it on the Mac.
    public static var supportRoot: URL { layout.supportRoot }

    /// Where the app's caches live, the same way.
    public static var cachesRoot: URL { layout.cachesRoot }

    /// An item under `supportRoot`, about to be read (`StorageLayout.itemToRead`).
    public static func supportItemToRead(_ relativePath: String, isDirectory: Bool, isOurs: (URL) -> Bool) -> URL {
        layout.itemToRead(relativePath, isDirectory: isDirectory, isOurs: isOurs)
    }

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

/// Where the app's queues and caches go under the system's Application Support and Caches folders.
///
/// On iOS every app has its own container, so they sit straight in the system folders. The Mac app
/// isn't sandboxed, so there they sit in a folder named by bundle id, and Hermes and Hermes Dev
/// never read each other's outbox or Up Next. Up to Hermes 1.0 beta (2611190410) the Mac app kept
/// them straight in the shared folders; the release app carries its own queued items over one at a
/// time, as it reads them (`itemToRead`). Caches aren't carried over: they fill again from the
/// gateway.
public struct StorageLayout: Sendable {
    public var applicationSupport: URL
    public var caches: URL
    public var bundleIdentifier: String?
    public var isMac: Bool

    public init(applicationSupport: URL, caches: URL, bundleIdentifier: String?, isMac: Bool) {
        self.applicationSupport = applicationSupport
        self.caches = caches
        self.bundleIdentifier = bundleIdentifier
        self.isMac = isMac
    }

    public var supportRoot: URL { ownFolder(in: applicationSupport) }
    public var cachesRoot: URL { ownFolder(in: caches) }

    /// Only the release app carries items over: what Hermes Dev left in the shared folder stays
    /// there for the person to clear.
    public var carriesLegacyItemsOver: Bool {
        isMac && bundleIdentifier == HermesStorage.releaseBundleIdentifier
    }

    private func ownFolder(in root: URL) -> URL {
        guard isMac else { return root }
        return root.appending(path: bundleIdentifier ?? HermesStorage.releaseBundleIdentifier, directoryHint: .isDirectory)
    }

    /// The item at `relativePath` under `supportRoot`, about to be read. When it isn't there but the
    /// shared folder has one that `isOurs` accepts, the release app moves that one item (a folder
    /// with its attachments, or a file) over first. Nothing else in the shared folder is read,
    /// listed or changed.
    public func itemToRead(_ relativePath: String, isDirectory: Bool, isOurs: (URL) -> Bool) -> URL {
        let hint: URL.DirectoryHint = isDirectory ? .isDirectory : .notDirectory
        let item = supportRoot.appending(path: relativePath, directoryHint: hint)
        guard carriesLegacyItemsOver else { return item }
        let fileManager = FileManager.default
        let legacy = applicationSupport.appending(path: relativePath, directoryHint: hint)
        guard !fileManager.fileExists(atPath: item.path(percentEncoded: false)),
              fileManager.fileExists(atPath: legacy.path(percentEncoded: false)),
              isOurs(legacy)
        else { return item }
        try? fileManager.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: legacy, to: item)
        return item
    }
}
