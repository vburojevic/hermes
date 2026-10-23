import Foundation
import HermesKit
import SwiftUI
import Observation

/// What Hermes on one gateway can reach (`docs/connections.md`): apps, MCP servers, plugins and
/// built-in toolsets. Every list keeps its last known value, so an offline gateway still shows
/// it (dimmed); every action re-reads what it changed, so the page follows the gateway without a
/// manual refresh. Secrets go one way and are never kept here.
@MainActor
@Observable
final class AppsAndToolsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case apps, mcp, plugins, builtIn

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apps: String(localized: "Apps")
            case .mcp: String(localized: "MCP")
            case .plugins: String(localized: "Plugins")
            case .builtIn: String(localized: "Built-in")
            }
        }
    }

    /// A connected app: its state, catalog entry, accounts and tool count.
    nonisolated struct ConnectedApp: Identifiable, Hashable, Sendable {
        var row: ConnectorRow
        var entry: ConnectorCatalogEntry?
        var accounts: [ConnectorAccount]
        var toolCount: Int?

        var id: String { row.connector }
        var name: String { entry?.name ?? row.connector.capitalized }
        var description: String { entry?.description ?? "" }
        var logoURL: URL? { entry?.logoURL }
        var needsAttention: Bool { row.needsAttention || accounts.contains { $0.status.needsAttention && $0.active } }
        /// The account Hermes uses.
        var activeAccount: ConnectorAccount? { accounts.first(where: \.active) ?? accounts.first }
    }

    /// What a plugin brings, gathered from its toolset, its MCP servers and its skills.
    struct PluginAdds: Hashable {
        var tools: [String] = []
        var skills: [String] = []
    }

    /// An update that widens a plugin's access, waiting for the person.
    struct UpdateConsent: Identifiable, Hashable {
        let plugin: HermesPlugin
        let lines: [String]
        var id: String { plugin.key }
    }

    /// What Hermes said after a plugin action: warnings, keys it still needs, a restart.
    struct PluginNotes: Identifiable, Hashable {
        let id = UUID()
        let pluginName: String
        let result: PluginActionResult
    }

    /// Weak: the workspace owns this model (`BotWorkspace.appsAndTools`), and a strong
    /// reference back kept a removed gateway's whole graph alive.
    @ObservationIgnored private(set) weak var workspace: BotWorkspace?

    // MARK: State

    var tab: Tab = .apps

    /// What the page shows on top (iPhone, iPad): rows with a switch open on a tap, no chevron.
    enum Route: Hashable {
        case app(String), server(String), plugin(String)
        /// A plugin's review (`pluginReview`), the app's own page of one of its plugins, and the
        /// hub's lists (`docs/plugins.md` §4).
        case review(PluginSubject), appPlugin(String), pluginCatalog, hiddenSuggestions, installedPlugins
    }

    var route: Route?
    /// Sheets the plugin hub opens, kept here so they hang off the page, not a Form section.
    var installsFromGit = false
    var pluginKeysFor: HermesPlugin?
    /// The profile this page manages (the gateway's own, or the root).
    var scopeProfile: String { profileName ?? "default" }
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    private(set) var appsAvailable = true
    /// Why apps aren't available (`connectors.list available: false`): Hermes's gate is the
    /// `tools.connectors` switch, then a Nous account that includes them (`docs/setup.md` §4.5).
    enum AppsBlock: Equatable { case signIn, turnedOff, notIncluded }
    private(set) var appsBlock = AppsBlock.signIn
    /// The apps as the gateway last listed them.
    private var gatewayApps: [ConnectedApp] = []
    private var appChanges = PendingChanges<ConnectedApp>()
    /// Connected apps, with every change still on its way (`docs/chat.md` §4a).
    var apps: [ConnectedApp] { appChanges.applied(to: gatewayApps) }
    private(set) var catalog: [ConnectorCatalogEntry] = []
    private(set) var toolLists: [String: ConnectorToolList] = [:]
    private(set) var policy: ConnectorPolicy?
    /// Tool switches still on their way to the policy.
    private var toolChanges = PendingChanges<ToolChoice>()
    private(set) var appsError: String?

    private var gatewayServers: [McpServer] = []
    private var serverChanges = PendingChanges<McpServer>()
    var servers: [McpServer] { serverChanges.applied(to: gatewayServers) }
    private(set) var presets: [McpPreset] = []
    /// The last test of each server: how a failed one says why.
    private(set) var serverTests: [String: McpTestResult] = [:]
    private(set) var serversError: String?

    private var gatewayPlugins: [HermesPlugin] = []
    private var pluginChanges = PendingChanges<HermesPlugin>()
    var plugins: [HermesPlugin] { pluginChanges.applied(to: gatewayPlugins) }
    private(set) var catalogPlugins: [CatalogPlugin] = []
    private(set) var pluginAdds: [String: PluginAdds] = [:]
    private(set) var pluginsError: String?

    private var gatewayToolsets: [BuiltInToolset] = []
    private var toolsetChanges = PendingChanges<BuiltInToolset>()
    var toolsets: [BuiltInToolset] { toolsetChanges.applied(to: gatewayToolsets) }
    private(set) var toolsetsError: String?
    /// On, but with no key on the gateway: Hermes leaves their tools out (`docs/setup.md` §4.5).
    private(set) var toolsetsWithoutKeys: Set<String> = []
    /// The toolset Add a Key is open for.
    var addingKeyFor: BuiltInToolset?

    /// Something to say in an alert.
    var message: String?
    /// A change the gateway refused, said once: what was put back, and why.
    var refusal: RefusedChange?
    /// A sign-in under way (slug or server name).
    private(set) var signingIn: String?
    /// Work under way on one item (key of the row).
    private(set) var busy: Set<String> = []
    var consent: UpdateConsent?
    var pluginNotes: PluginNotes?

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    // MARK: Gateway

    private var roster: BotRoster? { workspace?.roster }

    /// Apps and Tools speak the gateway protocol: Bot Mode's socket.
    var isOnline: Bool { roster?.isConnected ?? false }
    var needsBotMode: Bool { roster == nil }
    var gatewayName: String { workspace?.bot.name ?? "" }
    private var profileName: String? { workspace?.bot.profileName }

    private var client: ConnectionsClient? {
        guard let roster, roster.isConnected else { return nil }
        return ConnectionsClient(profile: profileName) { method, params in
            try await roster.request(method, params)
        }
    }

    // MARK: Summary

    var connectedApps: [ConnectedApp] { apps }

    /// Catalog apps not connected yet.
    var addableApps: [ConnectorCatalogEntry] {
        let connected = Set(apps.map(\.id))
        return catalog.filter { !connected.contains($0.slug) }
    }

    var installedPlugins: [HermesPlugin] { plugins.filter { !$0.isBundled } }
    var bundledPlugins: [HermesPlugin] { plugins.filter(\.isBundled) }

    /// Expired or revoked apps and MCP servers that couldn't connect.
    var needsYouCount: Int {
        apps.filter(\.needsAttention).count + servers.filter { $0.enabled && $0.status == .failed }.count
    }

    /// "4 apps · 4 MCP servers · 1 needs you".
    var summary: String {
        guard hasLoaded else { return isOnline ? String(localized: "Loading…") : String(localized: "Not connected") }
        var parts: [String] = []
        if appsAvailable {
            parts.append(apps.count == 1 ? String(localized: "1 app") : String(localized: "\(apps.count) apps"))
        }
        parts.append(servers.count == 1 ? String(localized: "1 MCP server") : String(localized: "\(servers.count) MCP servers"))
        if needsYouCount > 0 {
            parts.append(needsYouCount == 1 ? String(localized: "1 needs you") : String(localized: "\(needsYouCount) need you"))
        }
        return parts.joined(separator: " · ")
    }

    /// "7 built-in tools on · 4 apps · 4 MCP servers" (Skills' Tools and Apps row).
    var toolsSummary: String {
        guard hasLoaded else { return summary }
        let builtIn = BuiltInToolsetInfo.main.filter { name in toolsets.contains { $0.name == name && $0.enabled } }.count
        var parts = [String(localized: "\(builtIn) built-in tools on")]
        if appsAvailable {
            parts.append(apps.count == 1 ? String(localized: "1 app") : String(localized: "\(apps.count) apps"))
        }
        parts.append(servers.count == 1 ? String(localized: "1 MCP server") : String(localized: "\(servers.count) MCP servers"))
        return parts.joined(separator: " · ")
    }

    // MARK: Loading

    func load() async {
        guard let client else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        async let apps: Void = loadApps(client)
        async let servers: Void = loadServers(client)
        async let plugins: Void = loadPlugins(client)
        async let toolsets: Void = loadToolsets(client)
        _ = await (apps, servers, plugins, toolsets)
    }

    private func loadApps(_ client: ConnectionsClient) async {
        do {
            let (available, rows) = try await client.connectors()
            appsAvailable = available
            guard available else {
                gatewayApps = []
                appsError = nil
                await readAppsBlock()
                return
            }
            async let catalog = client.catalog()
            async let accounts = client.accounts()
            async let policy = client.policy()
            let entries = (try? await catalog) ?? self.catalog
            let allAccounts = (try? await accounts) ?? []
            self.catalog = entries
            self.policy = (try? await policy) ?? self.policy
            var lists = toolLists
            await withTaskGroup(of: (String, ConnectorToolList?).self) { group in
                for row in rows where row.connected {
                    group.addTask { (row.connector, try? await client.tools(of: row.connector)) }
                }
                for await (slug, list) in group {
                    if let list { lists[slug] = list }
                }
            }
            toolLists = lists
            gatewayApps = rows.filter(\.connected).map { row in
                ConnectedApp(
                    row: row,
                    entry: entries.first { $0.slug == row.connector },
                    accounts: allAccounts.filter { $0.connector == row.connector && !$0.disabled },
                    toolCount: lists[row.connector]?.tools.count
                )
            }
            appsError = nil
        } catch {
            if ConnectorErrorReason(error: error) == .needsNousAuth {
                appsAvailable = false
                gatewayApps = []
                appsError = nil
                appsBlock = .signIn
            } else {
                appsError = ConnectorErrorReason.line(for: error)
            }
        }
    }

    /// Turned off, signed in without apps in the plan, or not signed in: each has its own fix.
    private func readAppsBlock() async {
        guard let backend = roster?.backendClient else { return }
        let profile = workspace?.bot.profileName
        if (try? await backend.appsTurnedOn(profile: profile)) == false {
            appsBlock = .turnedOff
        } else if (try? await backend.signedInToNous(profile: profile)) == true {
            appsBlock = .notIncluded
        } else {
            appsBlock = .signIn
        }
    }

    /// Turn On, for apps turned off in the gateway's config (`PUT /api/config`).
    func turnOnApps() async {
        guard let backend = roster?.backendClient else { return }
        busy.insert("apps")
        defer { busy.remove("apps") }
        do {
            try await backend.updateConfig(.object(["tools": .object(["connectors": .object(["enabled": .bool(true)])])]), profile: workspace?.bot.profileName)
        } catch {
            message = error.localizedDescription
        }
        await load()
    }

    private func loadServers(_ client: ConnectionsClient) async {
        do {
            gatewayServers = try await client.mcpServers()
            presets = (try? await client.mcpCatalog()) ?? presets
            serversError = nil
        } catch {
            serversError = error.localizedDescription
        }
    }

    private func loadPlugins(_ client: ConnectionsClient) async {
        do {
            gatewayPlugins = try await client.plugins()
            catalogPlugins = (try? await client.catalogPlugins()) ?? catalogPlugins
            pluginsError = nil
            let toolsets = (try? await client.toolsetTools()) ?? [:]
            let skills = (try? await client.skillNames()) ?? []
            var adds: [String: PluginAdds] = [:]
            for plugin in plugins where !plugin.isBundled {
                var tools = toolsets[plugin.key] ?? toolsets[plugin.name] ?? []
                if tools.isEmpty {
                    for server in plugin.servers { tools += toolsets["mcp-\(server.name)"] ?? toolsets[server.name] ?? [] }
                }
                let prefix = plugin.key + ":"
                adds[plugin.key] = PluginAdds(
                    tools: tools,
                    skills: skills.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                )
            }
            pluginAdds = adds
        } catch {
            pluginsError = error.localizedDescription
        }
    }

    private func loadToolsets(_ client: ConnectionsClient) async {
        do {
            gatewayToolsets = try await client.toolsets()
            toolsetsError = nil
        } catch {
            toolsetsError = error.localizedDescription
        }
        // Over REST: `toolsets.list` doesn't say which have their keys.
        if let backend = roster?.backendClient,
           let missing = try? await backend.toolsetsWithoutKeys(profile: workspace?.bot.profileName) {
            toolsetsWithoutKeys = missing
        }
    }

    /// A toolset's providers and whether their keys are set, for Add a Key (`docs/setup.md` §4.5).
    func toolsetKeys(_ name: String) async throws -> ToolsetKeys {
        guard let backend = roster?.backendClient else { throw HermesError.invalidResponse(String(localized: "\(gatewayName) isn't connected.")) }
        return try await backend.toolsetKeys(name, profile: workspace?.bot.profileName)
    }

    /// Saves a toolset's keys on the gateway and makes `provider` the one it uses; then reads
    /// again which toolsets still need a key. The sheet has closed: the toolset stops asking for
    /// a key at once, and asks again with a note if the gateway refuses. The keys aren't kept.
    func saveToolsetKeys(_ name: String, provider: String, keys: [String: String]) async {
        guard let backend = roster?.backendClient else {
            message = String(localized: "\(gatewayName) isn't connected.")
            return
        }
        let wasMissing = toolsetsWithoutKeys.remove(name) != nil
        do {
            try await backend.saveToolsetKeys(name, provider: provider, keys: keys, profile: workspace?.bot.profileName)
        } catch {
            if wasMissing { toolsetsWithoutKeys.insert(name) }
            let note = RefusedChange(String(localized: "Couldn't save the key for \(name)"),
                                     message: ConnectorErrorReason.line(for: error) + " " + String(localized: "Add it again."))
            refusal = note
            AccessibilityNotification.Announcement("\(note.title). \(note.message)").post()
        }
        if let missing = try? await backend.toolsetsWithoutKeys(profile: workspace?.bot.profileName) {
            toolsetsWithoutKeys = missing
        }
    }

    /// A change the person made: shown at once through `changes`, sent with `work` (which takes
    /// the answer into the gateway's lists), then settled. A refusal puts it back and says so.
    private func change<Item: Identifiable & Sendable>(
        _ changes: ReferenceWritableKeyPath<AppsAndToolsModel, PendingChanges<Item>>, _ change: PendingChanges<Item>.Change,
        for id: Item.ID, refused title: String, _ work: (ConnectionsClient) async throws -> Void
    ) async where Item.ID: Sendable {
        guard let client else {
            message = String(localized: "\(gatewayName) isn't connected.")
            return
        }
        let token = self[keyPath: changes].begin(change, for: id)
        do {
            try await work(client)
        } catch {
            if self[keyPath: changes].isNewest(token, for: id) {
                let note = RefusedChange(title, message: ConnectorErrorReason.line(for: error) + " " + String(localized: "It's back as it was."))
                refusal = note
                AccessibilityNotification.Announcement("\(note.title). \(note.message)").post()
            }
        }
        self[keyPath: changes].settle(token, for: id)
    }

    /// Runs `work` against the gateway, marking `key` busy and turning failures into one line.
    private func perform(_ key: String, _ work: (ConnectionsClient) async throws -> Void) async {
        guard let client else {
            message = String(localized: "\(gatewayName) isn't connected.")
            return
        }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await work(client)
        } catch {
            message = ConnectorErrorReason.line(for: error)
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    // MARK: Apps

    /// Apps come through the person's Nous account: the gateway signs in by device code, the
    /// browser shows Nous's approval page, and the app polls until it's approved.
    func signInToNous() async {
        guard let roster else { return }
        signingIn = "nous"
        defer { signingIn = nil }
        do {
            let profile = profileName
            let flow = try await roster.startProviderSignIn(provider: "nous", profile: profile)
            let browser = BrowserClosed()
            Task { @MainActor in
                _ = await BrowserSignIn.shared.open(flow.url)
                browser.at = .now
            }
            defer { BrowserSignIn.shared.cancel() }
            while true {
                try await Task.sleep(for: .seconds(max(flow.interval, 1)))
                let status = try await roster.pollProviderSignIn(provider: "nous", sessionID: flow.sessionID, profile: profile)
                if status == "approved" { break }
                if status != "pending" {
                    message = String(localized: "The Nous sign-in didn't finish. Try again.")
                    return
                }
                if let closed = browser.at, Date.now.timeIntervalSince(closed) > 6 { return }
            }
            if let client { await loadApps(client) }
        } catch {
            message = error.localizedDescription
        }
    }

    func app(_ slug: String) -> ConnectedApp? { apps.first { $0.id == slug } }

    func tools(of slug: String) -> [ConnectorTool] { toolLists[slug]?.tools ?? [] }

    /// Allowed by the policy and not turned off by the gateway's own config.
    func allows(_ tool: ConnectorTool, of slug: String) -> Bool {
        let gatewayOff = app(slug)?.row.gatewayDisabledTools.contains(tool.slug) ?? false
        if !gatewayOff, let choice = toolChanges.item(for: ToolChoice.id(tool.slug, of: slug)) { return choice.allowed }
        return !gatewayOff && (policy?.allows(tool: tool.slug, of: slug) ?? true)
    }

    /// Blocked above the person (organization or role), or by the gateway's config.
    func isLocked(_ tool: ConnectorTool, of slug: String) -> Bool {
        (app(slug)?.row.gatewayDisabledTools.contains(tool.slug) ?? false)
            || (policy?.lockedByOrganization(tool: tool.slug, of: slug) ?? false)
    }

    func allowedCount(of slug: String) -> Int {
        tools(of: slug).filter { allows($0, of: slug) }.count
    }

    /// The switch moves at once; the policy in the answer settles it.
    func setTool(_ tool: ConnectorTool, of slug: String, allowed: Bool) async {
        guard let policy else { return }
        let choice = ToolChoice(id: ToolChoice.id(tool.slug, of: slug), allowed: allowed)
        await change(\.toolChanges, .update(choice), for: choice.id,
                     refused: allowed ? String(localized: "Couldn't allow \(tool.name)") : String(localized: "Couldn't turn off \(tool.name)")) { client in
            self.policy = try await client.setPolicy(policy) { current in
                var disabled = current.memberDisabledTools(of: slug).filter { $0 != tool.slug }
                if !allowed { disabled.append(tool.slug) }
                return .tools(connector: slug, disabled: disabled)
            }
        }
    }

    func refreshTools(of slug: String) async {
        await perform("tools:\(slug)") { client in
            self.toolLists[slug] = try await client.tools(of: slug, refresh: true)
        }
    }

    /// Connects an app, another account (`alias`) or repairs one (`reconnect`), through the browser.
    func connect(_ slug: String, alias: String? = nil, reconnect account: ConnectorAccount? = nil) async {
        guard let client else {
            message = String(localized: "\(gatewayName) isn't connected.")
            return
        }
        let isNewApp = app(slug) == nil
        signingIn = slug
        defer { signingIn = nil }
        do {
            var operation = try await client.connect(slug, alias: alias, reconnect: account != nil, connectionID: account?.connectionID)
            if let url = operation.signInTarget?.connectURL {
                let back = await BrowserSignIn.shared.open(url)
                // Back through hermes://connections/done: Hermes reads the accounts now. Closed
                // early: it may still have finished, so look for a few seconds.
                try? await client.wake(back?.connectionDoneOperation ?? operation.opID)
                operation = try await follow(operation, with: client, patience: back == nil ? 4 : 30)
            }
            if operation.succeeded {
                if isNewApp { await turnOffDestructiveTools(of: slug, with: client) }
            } else if let detail = operation.targets.first?.detail, !detail.isEmpty {
                message = detail
            }
        } catch {
            message = ConnectorErrorReason.line(for: error)
        }
        await loadApps(client)
    }

    /// Polls the operation until it settles or `patience` seconds pass.
    private func follow(_ start: ConnectionOperation, with client: ConnectionsClient, patience: Int) async throws -> ConnectionOperation {
        var operation = start
        for _ in 0..<patience where !operation.isFinished {
            if let next = try await client.operationStatus(operation.opID) {
                operation = operation.merged(with: next)
            }
            if operation.isFinished { break }
            try await Task.sleep(for: .seconds(1))
        }
        return operation
    }

    /// A new app's destructive tools start off (`docs/connections.md` §3).
    private func turnOffDestructiveTools(of slug: String, with client: ConnectionsClient) async {
        guard let tools = try? await client.tools(of: slug), let policy = try? await client.policy(),
              !policy.memberHasRule(for: slug) else { return }
        let destructive = tools.tools.filter { $0.facet == .destructive }.map(\.slug)
        guard !destructive.isEmpty else { return }
        self.policy = try? await client.setPolicy(policy) { _ in .tools(connector: slug, disabled: destructive) }
    }

    /// The new name shows at once.
    func rename(_ account: ConnectorAccount, to alias: String) async {
        guard var app = app(account.connector) else { return }
        app.accounts = app.accounts.map { $0.id == account.id ? $0.renamed(alias) : $0 }
        await change(\.appChanges, .update(app), for: app.id, refused: String(localized: "Couldn't rename \(account.label)")) { client in
            _ = try await client.rename(account: account.connectionID, alias: alias)
            await self.loadApps(client)
        }
    }

    /// The account goes at once.
    func remove(_ account: ConnectorAccount) async {
        guard var app = app(account.connector) else { return }
        app.accounts.removeAll { $0.id == account.id }
        await change(\.appChanges, .update(app), for: app.id, refused: String(localized: "Couldn't remove \(account.label)")) { client in
            try await client.remove(account: account.connectionID)
            await self.loadApps(client)
        }
    }

    /// Removes every account of the app: it leaves the list at once.
    func disconnect(_ app: ConnectedApp) async {
        await change(\.appChanges, .remove, for: app.id, refused: String(localized: "Couldn't disconnect \(app.name)")) { client in
            for account in app.accounts { try await client.remove(account: account.connectionID) }
            self.gatewayApps.removeAll { $0.id == app.id }
            await self.loadApps(client)
        }
    }

    // MARK: MCP servers

    func server(_ name: String) -> McpServer? { servers.first { $0.name == name } }

    /// The switch moves at once; the server list read after settles it.
    func setServer(_ server: McpServer, enabled: Bool) async {
        var changed = server
        changed.enabled = enabled
        await change(\.serverChanges, .update(changed), for: server.id,
                     refused: enabled ? String(localized: "Couldn't turn on \(server.name)") : String(localized: "Couldn't turn off \(server.name)")) { client in
            // Every switch as shown, this one and any still on their way.
            try await client.setEnabledServers(self.servers.filter(\.enabled).map(\.name))
            if let index = self.gatewayServers.firstIndex(where: { $0.id == server.id }) { self.gatewayServers[index].enabled = enabled }
            try? await client.reloadMCP()
            await self.loadServers(client)
        }
    }

    func test(_ server: String) async {
        await perform("server:\(server)") { client in
            self.serverTests[server] = try await client.testServer(server)
            await self.loadServers(client)
        }
    }

    /// A failed server says why only when tested: the status call carries no reason.
    func testIfFailed(_ server: McpServer) async {
        guard server.status == .failed, serverTests[server.name] == nil else { return }
        await test(server.name)
    }

    /// Writes a key, tests the server again and reloads open chats. The value isn't kept.
    func setKey(_ value: String, for server: McpServer, envVar: String?) async {
        await perform("server:\(server.name)") { client in
            try await client.setAPIKey(server: server.name, value: value, envVar: envVar)
            self.serverTests[server.name] = try await client.testServer(server.name)
            try? await client.reloadMCP()
            await self.loadServers(client)
        }
    }

    /// The server leaves the list at once.
    func remove(_ server: McpServer) async {
        await change(\.serverChanges, .remove, for: server.id, refused: String(localized: "Couldn't remove \(server.name)")) { client in
            try await client.removeServer(server.name)
            self.gatewayServers.removeAll { $0.id == server.id }
            self.serverTests[server.name] = nil
            try? await client.reloadMCP()
            await self.loadServers(client)
        }
    }

    /// Signs an OAuth server in: the browser opens Hermes's `auth_url`, which returns to the
    /// gateway, so the app polls and closes the browser when Hermes has the tokens. If the person
    /// closes the browser first, it keeps looking for a few seconds (they may have finished).
    func signIn(_ server: String) async -> Bool {
        guard let client else { return false }
        signingIn = server
        defer { signingIn = nil }
        do {
            let flow = try await client.startOAuth(server: server)
            let browser = BrowserClosed()
            Task { @MainActor in
                _ = await BrowserSignIn.shared.open(flow.authURL)
                browser.at = .now
            }
            defer { BrowserSignIn.shared.cancel() }
            while true {
                try await Task.sleep(for: .seconds(1))
                switch try await client.pollOAuth(server: server, flow: flow.sessionID) {
                case .pending:
                    if let closed = browser.at, Date.now.timeIntervalSince(closed) > 4 {
                        try? await client.cancelOAuth(server: server, flow: flow.sessionID)
                        return false
                    }
                case .approved:
                    try? await client.reloadMCP()
                    serverTests[server] = try? await client.testServer(server)
                    await loadServers(client)
                    return true
                case .failed(let reason):
                    message = reason
                    return false
                }
            }
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: Adding an MCP server

    /// Adds the server (once) and writes its keys, then tests it: the sheet's ✓ waits for a pass.
    /// Returns the test, or `nil` when the add itself failed (the reason is in `message`).
    func addAndTest(name: String, preset: String?, config: [String: JSONValue]?, keys: [String: String], alreadyAdded: Bool) async -> McpTestResult? {
        guard let client else {
            message = String(localized: "\(gatewayName) isn't connected.")
            return nil
        }
        busy.insert("add")
        defer { busy.remove("add") }
        do {
            if !alreadyAdded {
                try await client.addServer(name: name, preset: preset, config: config)
            }
            for (env, value) in keys where !value.isEmpty {
                try await client.setAPIKey(server: name, value: value, envVar: env)
            }
            let result = try await client.testServer(name)
            serverTests[name] = result
            return result
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// ✓: open chats pick the new server up.
    func finishAdding() async {
        guard let client else { return }
        try? await client.reloadMCP()
        await loadServers(client)
    }

    /// Cancel after a test added it: the server goes again.
    func abandon(_ name: String) async {
        guard let client else { return }
        try? await client.removeServer(name)
        serverTests[name] = nil
        await loadServers(client)
    }

    // MARK: Plugins

    func plugin(_ key: String) -> HermesPlugin? { plugins.first { $0.key == key } }

    /// The switch moves at once; the plugin list read after settles it.
    func setPlugin(_ plugin: HermesPlugin, enabled: Bool) async {
        var changed = plugin
        changed.status = enabled ? "enabled" : "not enabled"
        await change(\.pluginChanges, .update(changed), for: plugin.id,
                     refused: enabled ? String(localized: "Couldn't turn on \(plugin.name)") : String(localized: "Couldn't turn off \(plugin.name)")) { client in
            let result = try await client.togglePlugin(plugin.key, enable: enabled)
            if let index = self.gatewayPlugins.firstIndex(where: { $0.id == plugin.id }) { self.gatewayPlugins[index].status = changed.status }
            self.show(result, for: plugin.name)
            await self.loadPlugins(client)
        }
    }

    func install(catalogName: String, title: String) async {
        await perform("install:\(catalogName)") { client in
            let result = try await client.installPlugin(catalogName: catalogName)
            self.show(result, for: title, always: true)
            await self.loadPlugins(client)
            try? await client.reloadMCP()
            await self.loadServers(client)
        }
    }

    func install(repo: String, ref: String?) async -> Bool {
        var installed = false
        await perform("install:git") { client in
            let result = try await client.installPlugin(repo: repo, ref: ref)
            installed = result.ok
            self.show(result, for: result.plugin?.name ?? repo, always: true)
            await self.loadPlugins(client)
        }
        return installed
    }

    /// Updates; an update that asks for more access waits on the consent card.
    func update(_ plugin: HermesPlugin, accept: Bool = false) async {
        await perform("plugin:\(plugin.key)") { client in
            let result = try await client.updatePlugin(plugin.key, acceptCapabilities: accept)
            if result.consentRequired {
                self.consent = UpdateConsent(plugin: plugin, lines: result.deltaLines)
                return
            }
            self.consent = nil
            if !result.ok, let error = result.error { self.message = error }
            self.show(result, for: plugin.name)
            await self.loadPlugins(client)
        }
    }

    /// The plugin leaves the list at once.
    func remove(_ plugin: HermesPlugin) async {
        await change(\.pluginChanges, .remove, for: plugin.id, refused: String(localized: "Couldn't remove \(plugin.name)")) { client in
            _ = try await client.removePlugin(plugin.key)
            self.gatewayPlugins.removeAll { $0.id == plugin.id }
            await self.loadPlugins(client)
            try? await client.reloadMCP()
            await self.loadServers(client)
        }
    }

    /// The setting shows its new value at once; a refusal puts the old one back in its field.
    func saveSettings(_ plugin: HermesPlugin, values: [String: JSONValue]) async {
        let changed = plugin.withValues(values)
        await change(\.pluginChanges, .update(changed), for: plugin.id, refused: String(localized: "Couldn't change \(plugin.name)'s settings")) { client in
            _ = try await client.savePluginSettings(plugin.key, values: values)
            if let index = self.gatewayPlugins.firstIndex(where: { $0.id == plugin.id }) { self.gatewayPlugins[index] = changed }
            await self.loadPlugins(client)
        }
    }

    /// A secret setting goes to the gateway's `.env` (`PUT /api/env`); the app keeps nothing.
    func saveSecret(_ value: String, env: String, for plugin: HermesPlugin) async {
        guard let roster else { return }
        busy.insert("plugin:\(plugin.key)")
        defer { busy.remove("plugin:\(plugin.key)") }
        do {
            try await roster.setEnv(key: env, value: value, profile: profileName)
            if let client { await loadPlugins(client) }
        } catch {
            message = error.localizedDescription
        }
    }

    private func show(_ result: PluginActionResult, for name: String, always: Bool = false) {
        if result.hasNotes || (always && !(result.activation?.isEmpty ?? true)) {
            pluginNotes = PluginNotes(pluginName: name, result: result)
        }
    }

    // MARK: Built-in

    /// The switch moves at once; the toolset list read after settles it.
    func setToolset(_ toolset: BuiltInToolset, enabled: Bool) async {
        var changed = toolset
        changed.enabled = enabled
        await change(\.toolsetChanges, .update(changed), for: toolset.id,
                     refused: enabled ? String(localized: "Couldn't turn on \(toolset.name)") : String(localized: "Couldn't turn off \(toolset.name)")) { client in
            try await client.setToolsets([toolset.name], enabled: enabled)
            if let index = self.gatewayToolsets.firstIndex(where: { $0.id == toolset.id }) { self.gatewayToolsets[index].enabled = enabled }
            await self.loadToolsets(client)
        }
    }
}

/// A tool switch on its way to the policy (`setTool`).
nonisolated struct ToolChoice: Identifiable, Sendable {
    var id: String
    var allowed: Bool

    static func id(_ tool: String, of app: String) -> String { "\(app)/\(tool)" }
}

/// When the person closed the sign-in browser, if they did.
@MainActor
private final class BrowserClosed {
    var at: Date?
}
