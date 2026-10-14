import Foundation
import HermesKit
import Observation

/// App-wide state: the configured bots and which one is in front.
@MainActor
@Observable
final class AppModel {
    private(set) var bots: [BotConfiguration] = []
    private(set) var workspaces: [UUID: BotWorkspace] = [:]
    private(set) var selectedBotID: UUID?
    /// A problem reading or writing local configuration.
    var storageError: String?


    @ObservationIgnored private let store: BotStore

    init(store: BotStore = .standard()) {
        self.store = store
        do {
            bots = try store.load()
        } catch {
            storageError = error.localizedDescription
        }
        for bot in bots {
            workspaces[bot.id] = BotWorkspace(bot: bot, apiKey: try? store.apiKey(for: bot.id), store: store)
        }
        let saved = UserDefaults.standard.string(forKey: PreferenceKey.selectedBot).flatMap(UUID.init(uuidString:))
        selectedBotID = bots.first { $0.id == saved }?.id ?? bots.first?.id
        #if DEBUG
        bootstrapFromEnvironment()
        #endif
        #if HERMES_PUSH
        PushCenter.shared.attach(self)
        #endif
    }

    var currentWorkspace: BotWorkspace? {
        selectedBotID.flatMap { workspaces[$0] }
    }

    /// A Bot Chat is on screen (for menu commands).
    var isShowingBotChat: Bool {
        if case .bot? = currentWorkspace?.selection { return true }
        return false
    }

    func select(_ botID: UUID) {
        guard workspaces[botID] != nil else { return }
        selectedBotID = botID
        UserDefaults.standard.set(botID.uuidString, forKey: PreferenceKey.selectedBot)
        if let workspace = workspaces[botID], !workspace.connection.isOnline {
            Task { await workspace.connect() }
        }
    }

    func apiKey(for botID: UUID) -> String? {
        try? store.apiKey(for: botID)
    }

    // MARK: - Editing bots

    @discardableResult
    func addBot(
        name: String, baseURL: URL, apiKey: String, accent: BotAccent,
        backend: BackendLink? = nil, backendCredential: BackendCredential? = nil
    ) throws -> BotConfiguration {
        let bot = BotConfiguration(name: name, baseURL: baseURL, accent: accent.rawValue, backend: backend)
        try store.setAPIKey(apiKey, for: bot.id)
        if let backendCredential {
            try store.setBackendCredential(backendCredential, for: bot.id)
        }
        var updated = bots
        updated.append(bot)
        do {
            try store.save(updated)
        } catch {
            try? store.removeAPIKey(for: bot.id)
            throw error
        }
        bots = updated
        let workspace = BotWorkspace(bot: bot, apiKey: apiKey, store: store)
        workspaces[bot.id] = workspace
        select(bot.id)
        return bot
    }

    /// Saves edits. Pass `apiKey` only when the key changed, and `backendCredential`
    /// only after a fresh Bot Mode sign-in.
    func updateBot(_ bot: BotConfiguration, apiKey: String?, backendCredential: BackendCredential? = nil) throws {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        if let apiKey {
            try store.setAPIKey(apiKey, for: bot.id)
        }
        if let backendCredential {
            try store.setBackendCredential(backendCredential, for: bot.id)
        } else if bot.backend == nil || bot.backend?.url != bots[index].backend?.url {
            try? store.setBackendCredential(nil, for: bot.id)
        }
        var updated = bots
        updated[index] = bot
        try store.save(updated)
        bots = updated
        workspaces[bot.id]?.update(
            bot: bot, apiKey: apiKey ?? self.apiKey(for: bot.id), keyChanged: apiKey != nil,
            backendSignInChanged: backendCredential != nil
        )
    }

    func removeBot(_ botID: UUID) throws {
        var updated = bots
        updated.removeAll { $0.id == botID }
        try store.save(updated)
        try? store.removeAPIKey(for: botID)
        try? store.setBackendCredential(nil, for: botID)
        #if HERMES_PUSH
        if let workspace = workspaces[botID] { PushCenter.shared.forget(workspace) }
        #endif
        workspaces[botID]?.tearDown()
        workspaces[botID]?.imageStore.removeAll()
        workspaces[botID] = nil
        bots = updated
        UserDefaults.standard.removeObject(forKey: "model.\(botID.uuidString)")
        UserDefaults.standard.removeObject(forKey: "effort.\(botID.uuidString)")
        if selectedBotID == botID {
            selectedBotID = bots.first?.id
            if let id = selectedBotID { select(id) }
        }
    }

    // MARK: - Pairing

    /// What another device needs to connect to this gateway, for its pairing QR code.
    func pairingLink(for botID: UUID) -> PairingLink? {
        guard let bot = bots.first(where: { $0.id == botID }), let key = apiKey(for: botID) else { return nil }
        var token: String?
        if bot.backend?.signIn == .token, case .sessionToken(let value)? = backendCredential(for: botID) {
            token = value
        }
        return PairingLink(name: bot.name, gateway: bot.baseURL, apiKey: key, backend: bot.backend, backendToken: token)
    }

    /// The gateway already saved for this link's address, if any.
    func existingBot(for link: PairingLink) -> BotConfiguration? {
        bots.first { $0.baseURL == link.gateway }
    }

    /// The step a pairing connect is on, for progress and for explaining a failure.
    enum PairingStep: Sendable {
        case gateway, botMode
    }

    /// A pairing connect that failed at `step`.
    struct PairingFailure: Error {
        let step: PairingStep
        let underlying: any Error
    }

    /// What a successful pairing check found, ready to save.
    struct VerifiedPairing: Sendable {
        let link: PairingLink
        let backend: BackendLink?
        let credential: BackendCredential?
    }

    /// Checks a paired gateway and signs in to its Bot Mode (unless skipped), without saving
    /// anything yet. Each check has a deadline, so an unreachable Mac fails in seconds.
    func verifyPairing(
        _ link: PairingLink, password: String = "", includingBotMode: Bool = true,
        progress: (PairingStep) -> Void = { _ in }
    ) async throws -> VerifiedPairing {
        progress(.gateway)
        do {
            do {
                _ = try await Self.withDeadline(seconds: 12) { try await Self.probe(baseURL: link.gateway, apiKey: link.apiKey) }
            } catch where Self.failedFast(error) {
                // iOS asks for Local Network access on the first try and fails it; try once more.
                try await Task.sleep(for: .seconds(1.5))
                _ = try await Self.withDeadline(seconds: 12) { try await Self.probe(baseURL: link.gateway, apiKey: link.apiKey) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PairingFailure(step: .gateway, underlying: error)
        }
        let backend = includingBotMode ? link.backend : nil
        var credential: BackendCredential?
        if let backend {
            progress(.botMode)
            do {
                credential = try await Self.withDeadline(seconds: 20) {
                    try await Self.probeBackend(
                        url: backend.url, signIn: backend.signIn, token: link.backendToken ?? "",
                        username: backend.username ?? "", password: password, existing: nil
                    ).credential
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PairingFailure(step: .botMode, underlying: error)
            }
        }
        try Task.checkCancellation()
        return VerifiedPairing(link: link, backend: backend, credential: credential)
    }

    /// Saves a verified pairing: a new gateway, or the one already saved for this address
    /// (keeping its Bot Mode when the code has none). Makes it the current gateway.
    @discardableResult
    func save(_ pairing: VerifiedPairing) throws -> BotConfiguration {
        let link = pairing.link
        if var bot = existingBot(for: link) {
            if let backend = pairing.backend { bot.backend = backend }
            try updateBot(bot, apiKey: link.apiKey, backendCredential: pairing.credential)
            select(bot.id)
            return bot
        }
        return try addBot(
            name: link.name, baseURL: link.gateway, apiKey: link.apiKey, accent: .gold,
            backend: pairing.backend, backendCredential: pairing.credential
        )
    }

    /// A connection refused or blocked outright (not a timeout): worth one quick retry.
    nonisolated static func failedFast(_ error: any Error) -> Bool {
        if let error = error as? URLError { return error.code != .timedOut && error.code != .cancelled }
        if case .unreachable(_, let reason)? = error as? HermesError { return reason != .timedOut }
        return false
    }

    /// Runs `operation`, giving up with a timeout after `seconds`.
    nonisolated static func withDeadline<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: - Lifecycle

    func didBecomeActive() {
        for workspace in workspaces.values where workspace.id != selectedBotID {
            workspace.roster?.resume()
        }
        currentWorkspace?.didBecomeActive()
    }

    /// Every window is gone or hidden: Bot rosters stop polling until the app is back.
    func didEnterBackground() {
        for workspace in workspaces.values {
            workspace.roster?.didEnterBackground()
        }
    }

    // MARK: - Probing

    struct ProbeResult: Sendable {
        var version: String?
        var agentName: String?
    }

    /// Checks an address and key before saving them, in the order a person would debug:
    /// is anything there, is it Hermes, does the key work, is it new enough.
    nonisolated static func probe(baseURL: URL, apiKey: String) async throws -> ProbeResult {
        let client = HermesClient(baseURL: baseURL, apiKey: apiKey)
        let health = try await client.health()
        let capabilities = try await client.capabilities()
        guard capabilities.supportsNativeClient else { throw HermesError.unsupportedServer }
        return ProbeResult(version: health.version, agentName: capabilities.model)
    }

    struct BackendProbe: Sendable {
        var credential: BackendCredential?
        var version: String?
        var botCount: Int
    }

    /// Signs in to a Bot Mode backend and reads its roster once, before the link is saved.
    nonisolated static func probeBackend(
        url: URL, signIn: BackendLink.SignIn, token: String, username: String, password: String,
        existing: BackendCredential?
    ) async throws -> BackendProbe {
        let client = BackendClient(baseURL: url, credential: existing)
        let status = try await client.status()
        switch signIn {
        case .automatic:
            if status.authRequired {
                throw HermesError.server(status: 401, code: nil, message: String(localized: "This backend needs a sign-in. Choose “Username & password”."))
            }
            _ = try await client.discoverSessionToken()
        case .token:
            if !token.isEmpty {
                await client.useSessionToken(token)
            } else if existing == nil {
                throw HermesError.server(status: 401, code: nil, message: String(localized: "Paste the backend's session token."))
            }
        case .password:
            if !password.isEmpty {
                try await client.signIn(username: username, password: password)
            } else if existing == nil {
                throw HermesError.server(status: 401, code: nil, message: String(localized: "Enter the backend's username and password."))
            }
        }
        let socket = GatewaySocket(url: try await client.gatewaySocketURL())
        try await socket.connect()
        defer { Task { await socket.close() } }
        let result = try await socket.request("profiles.list", ["include_sessions": .bool(false)], timeout: .seconds(30))
        var count = 0
        if case .array(let rows)? = result["profiles"] { count = rows.count }
        return BackendProbe(credential: await client.credential, version: status.version, botCount: count)
    }

    func backendCredential(for botID: UUID) -> BackendCredential? {
        store.backendCredential(for: botID)
    }

    #if DEBUG
    /// A session to open on launch (`-HERMES_OPEN_SESSION <id>`), for screenshot automation.
    func takeLaunchSession() -> String? {
        guard !launchSessionTaken else { return nil }
        launchSessionTaken = true
        return ProcessInfo.processInfo.environment["HERMES_OPEN_SESSION"] ?? UserDefaults.standard.string(forKey: "HERMES_OPEN_SESSION")
    }

    @ObservationIgnored private var launchSessionTaken = false

    /// Lets UI tests and screenshot runs start against a mock gateway without typing.
    private func bootstrapFromEnvironment() {
        // Environment variables, or `-HERMES_BOOTSTRAP_URL value` launch arguments.
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        func value(_ name: String) -> String? { environment[name] ?? defaults.string(forKey: name) }
        if let first = bots.first, first.backend == nil,
           let backend = value("HERMES_BOOTSTRAP_BACKEND").flatMap(BackendLink.normalizedURL(from:)) {
            var bot = first
            bot.backend = BackendLink(url: backend, signIn: .automatic)
            try? updateBot(bot, apiKey: nil)
        }
        guard bots.isEmpty,
              let address = value("HERMES_BOOTSTRAP_URL"), let url = BotConfiguration.normalizedURL(from: address),
              let key = value("HERMES_BOOTSTRAP_KEY")
        else { return }
        let backend = value("HERMES_BOOTSTRAP_BACKEND").flatMap(BackendLink.normalizedURL(from:)).map {
            BackendLink(url: $0, signIn: .automatic)
        }
        _ = try? addBot(name: value("HERMES_BOOTSTRAP_NAME") ?? "Hermes", baseURL: url, apiKey: key, accent: .gold, backend: backend)
    }
    #endif
}
