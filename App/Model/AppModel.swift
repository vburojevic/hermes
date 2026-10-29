import Foundation
import HermesKit
import Observation
import WebKit
#if os(macOS)
import AppKit
#else
import BackgroundTasks
import UIKit
#endif

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
    /// When the app last went to the background: coming back after a real absence starts the
    /// connections afresh (`recycleConnections`).
    @ObservationIgnored private var backgroundedAt: Date?
    /// Removed gateways' web data, deleted at launch once no web view can use it.
    @ObservationIgnored private let retiredWebStores = RetiredWebStores()
    @ObservationIgnored private var webStoreSweep: Task<Void, Never>?

    init(store: BotStore = .standard()) {
        self.store = store
        HermesTips.configure()
        #if os(iOS)
        DeviceCamera.warm()
        #endif
        do {
            bots = try store.load()
        } catch {
            storageError = error.localizedDescription
        }
        for index in bots.indices {
            let key = apiKey(for: bots[index])
            // Read after the key: a Bot whose addresses were just put back has the saved ones.
            workspaces[bots[index].id] = makeWorkspace(bots[index], apiKey: key)
        }
        let saved = UserDefaults.standard.string(forKey: PreferenceKey.selectedBot).flatMap(UUID.init(uuidString:))
        selectedBotID = bots.first { $0.id == saved }?.id ?? bots.first?.id
        sweepRetiredWebStores()
        #if DEBUG
        bootstrapFromEnvironment()
        LaunchTrace.mark("model ready (\(bots.count) gateways)")
        #endif
        #if HERMES_PUSH
        PushCenter.shared.attach(self)
        #endif
        #if os(macOS)
        watchSleep()
        watchActivation()
        #else
        watchProtectedData()
        #endif
    }

    private func makeWorkspace(_ bot: BotConfiguration, apiKey: String?) -> BotWorkspace {
        let workspace = BotWorkspace(bot: bot, apiKey: apiKey, backendCredential: backendCredential(for: bot), store: store)
        workspace.app = self
        return workspace
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
        // Only the gateway in front keeps checking its connection.
        for (id, workspace) in workspaces where id != botID {
            workspace.stopKeepingConnected()
        }
        if let workspace = workspaces[botID] {
            workspace.keepConnected()
            if !workspace.connection.isOnline {
                Task { await workspace.connect() }
            }
        }
    }

    // MARK: - Secrets

    /// A Bot's key, read only for the addresses it was saved for (`BotStore.check`).
    func apiKey(for bot: BotConfiguration) -> String? {
        readSecret(of: bot) { try store.apiKey(for: $0) }
    }

    /// A Bot's Bot Mode sign-in, read only for the addresses it was saved for.
    func backendCredential(for bot: BotConfiguration) -> BackendCredential? {
        readSecret(of: bot) { try store.backendCredential(for: $0) }
    }

    /// Nothing is read for a Bot whose addresses the Keychain can't confirm yet; addresses
    /// bots.json changed under the app go back to the saved ones here too.
    private func readSecret<Secret>(of bot: BotConfiguration, _ read: (BotConfiguration) throws -> Secret?) -> Secret? {
        do {
            return try read(bot)
        } catch BotStore.Refusal.putBack(let saved) {
            putBack(saved)
            return nil
        } catch {
            return nil
        }
    }

    /// The store found other addresses than the ones this Bot's secrets were saved for, and put
    /// the saved ones back in the file (`BotStore.check`): the app goes back to them as well.
    private func putBack(_ saved: BotConfiguration) {
        guard let index = bots.firstIndex(where: { $0.id == saved.id }) else { return }
        var bot = bots[index]
        bot.baseURL = saved.baseURL
        bot.backend = saved.backend
        bots[index] = bot
        workspaces[bot.id]?.update(bot: bot, apiKey: apiKey(for: bot), keyChanged: true)
    }

    /// A Bot loaded while the Keychain was locked has no key or sign-in yet
    /// (`BotStore.isVerified`): it connects again, and reads them once its addresses check out.
    private func retryUnverifiedBots() {
        for workspace in workspaces.values where !store.isVerified(workspace.bot) {
            if workspace.id == selectedBotID {
                Task { await workspace.connect() }
            } else {
                workspace.roster?.connectIfNeeded()
            }
        }
    }

    #if os(iOS)
    /// The Keychain opens with the device's first unlock.
    private func watchProtectedData() {
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryUnverifiedBots() }
        }
    }
    #endif

    // MARK: - Editing bots

    /// The first gateway was just paired: setup runs for it (model, about you, starting points;
    /// `docs/onboarding.md` §3).
    var setupGatewayID: UUID?
    /// What's New is up: the plugin ask waits for it (`docs/plugins.md` §3.3).
    var isShowingWhatsNew = false

    @discardableResult
    func addBot(
        name: String, baseURL: URL, apiKey: String, accent: BotAccent,
        backend: BackendLink? = nil, backendCredential: BackendCredential? = nil, startsSetup: Bool = true
    ) throws -> BotConfiguration {
        let isFirst = bots.isEmpty
        let bot = BotConfiguration(name: name, baseURL: baseURL, accent: accent.rawValue, backend: backend)
        try store.setAPIKey(apiKey, for: bot.id)
        if let backendCredential {
            try store.setBackendCredential(backendCredential, for: bot.id)
        }
        var updated = bots
        updated.append(bot)
        do {
            try store.save(updated, edited: bot)
        } catch {
            try? store.save(bots)
            try? store.removeAPIKey(for: bot.id)
            throw error
        }
        bots = updated
        workspaces[bot.id] = makeWorkspace(bot, apiKey: apiKey)
        select(bot.id)
        if isFirst, startsSetup { setupGatewayID = bot.id }
        return bot
    }

    /// Saves edits. Pass `apiKey` only when the key changed, `backendCredential` only after a
    /// fresh Bot Mode sign-in, and `original`, the Bot as an editor showed it, when there is one.
    func updateBot(
        _ bot: BotConfiguration, apiKey: String?, backendCredential: BackendCredential? = nil, editing original: BotConfiguration? = nil
    ) throws {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        // The edit moves where the Bot's secrets may go, so it starts from addresses they were
        // saved for: ones bots.json changed under the app go back to the saved ones, here and in
        // the edit wherever the person left them as they were.
        var bot = bot
        let basis = original ?? bots[index]
        do {
            try store.check(basis)
        } catch BotStore.Refusal.putBack(let saved) {
            putBack(saved)
            if bot.baseURL == basis.baseURL { bot.baseURL = saved.baseURL }
            if bot.backend == basis.backend { bot.backend = saved.backend }
        }
        var updated = bots
        updated[index] = bot
        let backendMoved = bot.backend == nil || bot.backend?.url != bots[index].backend?.url
        try store.save(updated, edited: bot, previous: bots) {
            if let apiKey {
                try store.setAPIKey(apiKey, for: bot.id)
            }
            if let backendCredential {
                try store.setBackendCredential(backendCredential, for: bot.id)
            } else if backendMoved {
                try? store.setBackendCredential(nil, for: bot.id)
            }
        }
        bots = updated
        workspaces[bot.id]?.update(
            bot: bot, apiKey: apiKey ?? self.apiKey(for: bot), keyChanged: apiKey != nil,
            backendSignInChanged: backendCredential != nil
        )
    }

    func removeBot(_ botID: UUID) throws {
        var updated = bots
        updated.removeAll { $0.id == botID }
        try store.save(updated)
        try? store.removeAPIKey(for: botID)
        try? store.setBackendCredential(nil, for: botID)
        // Its pages close before anything else touches the gateway's stores.
        workspaces[botID]?.closeWebViews()
        #if HERMES_PUSH
        if let workspace = workspaces[botID] { PushCenter.shared.forget(workspace) }
        #endif
        workspaces[botID]?.forgetLocalData()
        workspaces[botID]?.plugins.forget()
        workspaces[botID]?.pluginHub.forget()
        workspaces[botID]?.tearDown()
        workspaces[botID]?.imageStore.removeAll()
        TranscriptCache.removeAll(gateway: botID)
        KeptTurns().removeAll(gateway: botID)
        RosterCache.remove(botID)
        SessionsCache.remove(botID)
        LastLinesCache.remove(botID)
        ModelOptionsCache.remove(botID)
        // Its Inspector tabs.
        let inspectorKeys = ["inspector.pins.\(botID.uuidString)", "inspector.tabs.\(botID.uuidString)."]
        for key in UserDefaults.standard.dictionaryRepresentation().keys where inspectorKeys.contains(where: key.hasPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Its Preview pages' cookies and storage, and the in-app browser's sign-ins on it
        // (`docs/web.md` §6.5), go at the next launch: deleting a store under a web view that
        // still uses it crashes WebKit, and a page on screen lets its web view go only later.
        retiredWebStores.retire([botID] + [BrowserController.retireStore(gateway: botID)].compactMap { $0 })
        workspaces[botID] = nil
        bots = updated
        UserDefaults.standard.removeObject(forKey: "model.\(botID.uuidString)")
        UserDefaults.standard.removeObject(forKey: "effort.\(botID.uuidString)")
        if selectedBotID == botID {
            selectedBotID = bots.first?.id
            if let id = selectedBotID { select(id) }
        }
    }

    /// Deletes the stores removed gateways left behind (`docs/connecting-and-voice.md` §7), at
    /// launch. No web view can use them: the sweep skips every store a current gateway uses, and
    /// nothing makes one for a gateway that's gone. One at a time, on the main actor, as WebKit
    /// expects. With nothing waiting, WebKit isn't touched at all.
    private func sweepRetiredWebStores() {
        #if DEBUG
        // `-HERMES_WEB_STORES_LOG YES`: the stores WebKit has, before and after the sweep, even
        // with nothing waiting, to show the stores are gone.
        let logs = UserDefaults.standard.bool(forKey: "HERMES_WEB_STORES_LOG")
        #else
        let logs = false
        #endif
        guard logs || !retiredWebStores.pending.isEmpty else { return }
        var inUse = Set(bots.map(\.id))
        inUse.formUnion(bots.compactMap { BrowserController.madeStoreID(gateway: $0.id) })
        webStoreSweep = Task { [retiredWebStores] in
            // WebKit's class methods for stores answer on its main run loop, which only exists once
            // WebKit has started in this process: before that, they crash on a background thread
            // and take the app down. Asking for the default store starts it.
            _ = WKWebsiteDataStore.default()
            let existing = await WKWebsiteDataStore.allDataStoreIdentifiers
            let removed = await retiredWebStores.sweep(inUse: inUse, existing: Set(existing)) {
                try await WKWebsiteDataStore.remove(forIdentifier: $0)
            }
            #if DEBUG
            if logs {
                let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                print("WEBSTORES before=\(existing.map(\.uuidString).sorted()) removed=\(removed.map(\.uuidString)) after=\(left.map(\.uuidString).sorted()) waiting=\(retiredWebStores.pending.map(\.uuidString))")
            }
            #endif
        }
    }

    // MARK: - Pairing

    /// What another device needs to connect to this gateway, for its pairing QR code.
    func pairingLink(for botID: UUID) -> PairingLink? {
        guard let bot = bots.first(where: { $0.id == botID }), let key = apiKey(for: bot) else { return nil }
        var token: String?
        if bot.backend?.signIn == .token, case .sessionToken(let value)? = backendCredential(for: bot) {
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
        let returning = backgroundedAt.map { Date.now.timeIntervalSince($0) > 5 } ?? false
        backgroundedAt = nil
        for workspace in workspaces.values where workspace.id != selectedBotID {
            workspace.roster?.resume()
        }
        currentWorkspace?.didBecomeActive()
        guard returning else { return }
        let workspace = currentWorkspace
        Task {
            await recycleConnections()
            // The chat on screen shows what happened while the app was away without waiting for
            // the socket to come back.
            workspace?.currentConversation.catchUpOnReturn()
        }
    }

    /// Every window is gone or hidden: Bot rosters stop polling until the app is back.
    func didEnterBackground() {
        backgroundedAt = .now
        #if os(iOS)
        // iOS suspends the app: Hermes is told its browser went away rather than waiting it out
        // (`docs/web.md` §6.5). The next turn registers it again.
        BrowserController.detachAll()
        #endif
        for workspace in workspaces.values {
            workspace.stopKeepingConnected()
            workspace.roster?.didEnterBackground()
        }
        #if os(iOS)
        scheduleRefresh()
        #endif
    }

    #if os(iOS)
    /// iOS lets the app run now and then while it's away (`.backgroundTask(.appRefresh)`): the
    /// chats it keeps current are read then too, for when no `sync` push comes
    /// (`docs/notifications.md` §2).
    static let refreshTask = "co.caffeinatedcode.hermes.refresh"

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func refreshInBackground() async {
        scheduleRefresh()
        guard let workspace = currentWorkspace else { return }
        let chats = workspace.chatsToKeepCurrent(showing: true)
        let began = Date.now
        ConnectionLog.logger.notice("refresh: keeping \(chats.count, privacy: .public) chats current")
        await workspace.keepCurrent(chats: chats, within: .seconds(20))
        ConnectionLog.logger.notice("refresh: chats read in \(Int(Date.now.timeIntervalSince(began) * 1000), privacy: .public)ms")
    }
    #endif

    /// New connections for the next requests after an absence: the pooled ones may have died
    /// while the app was suspended (or the Mac asleep). A read that starts first and finds a dead
    /// one tries once more on its own (`HermesClient.load`).
    private func recycleConnections() async {
        let rosters = workspaces.values.compactMap(\.roster)
        await HermesClient.recycleConnections()
        for roster in rosters {
            await roster.recycleConnections()
        }
    }

    #if os(macOS)
    /// A sleeping Mac's connections die without a word: the sockets close before it sleeps and
    /// come back as it wakes, so the first minute after waking isn't spent on a dead one.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    private func willSleep() {
        ConnectionLog.logger.notice("app: the Mac is going to sleep")
        for workspace in workspaces.values {
            workspace.stopKeepingConnected()
            workspace.roster?.willSleep()
        }
    }

    private func didWake() {
        ConnectionLog.logger.notice("app: the Mac woke")
        for workspace in workspaces.values where workspace.id != selectedBotID {
            workspace.roster?.didWake()
        }
        currentWorkspace?.didWake()
        let workspace = currentWorkspace
        Task {
            await recycleConnections()
            workspace?.currentConversation.catchUpOnReturn() // what came while it slept
        }
    }

    /// Behind other apps the gateway in front is checked every 2 minutes, not every 30 s
    /// (`BotWorkspace.nextCheck`); back in front, a check that's due goes now.
    private func watchActivation() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryUnverifiedBots()
                self?.currentWorkspace?.cameToFront()
            }
        }
    }
    #endif

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
        // `none` unlinks Bot Mode from the first gateway (UI tests of what needs it).
        if let first = bots.first, first.backend != nil, value("HERMES_BOOTSTRAP_BACKEND") == "none" {
            var bot = first
            bot.backend = nil
            try? updateBot(bot, apiKey: nil)
        }
        // A signed-in Bot Mode (`HERMES_BOOTSTRAP_BACKEND_PASSWORD`, user admin): the mock started
        // with `--password`, which is what Hermes lets drive the app's browser (`docs/web.md` §6).
        let password = value("HERMES_BOOTSTRAP_BACKEND_PASSWORD")
        func link(_ url: URL) -> BackendLink {
            password == nil ? BackendLink(url: url, signIn: .automatic) : BackendLink(url: url, signIn: .password, username: "admin")
        }
        defer {
            if let password, let first = bots.first, first.backend?.signIn == .password, backendCredential(for: first) == nil {
                Task { try? await self.workspaces[first.id]?.roster?.signIn(username: "admin", password: password) }
            }
        }
        if let first = bots.first, first.backend == nil, value("HERMES_BOOTSTRAP_BACKEND") != "none",
           let backend = value("HERMES_BOOTSTRAP_BACKEND").flatMap(BackendLink.normalizedURL(from:)) {
            var bot = first
            bot.backend = link(backend)
            try? updateBot(bot, apiKey: nil)
        }
        guard bots.isEmpty,
              let address = value("HERMES_BOOTSTRAP_URL"), let url = BotConfiguration.normalizedURL(from: address),
              let key = value("HERMES_BOOTSTRAP_KEY")
        else { return }
        let backend = value("HERMES_BOOTSTRAP_BACKEND").flatMap { $0 == "none" ? nil : BackendLink.normalizedURL(from: $0) }.map(link)
        _ = try? addBot(name: value("HERMES_BOOTSTRAP_NAME") ?? "Hermes", baseURL: url, apiKey: key, accent: .gold, backend: backend, startsSetup: false)
    }
    #endif
}
