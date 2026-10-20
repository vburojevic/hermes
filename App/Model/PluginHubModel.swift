import Foundation
import HermesKit
import Observation
import os

/// Apps and Tools → Plugins on one gateway: the hub (`docs/plugins.md` §4). It reads the catalog
/// feed (display only), the gateway's machine (`GET /api/system/stats`), what's offered and what the
/// person answered (Not Now, Hidden, what this device has seen), and installs catalog plugins into
/// the profiles the person picked, the root first. The app's own plugins are `AppPluginsModel`'s;
/// installed rows and catalog updates are `AppsAndToolsModel`'s.
@MainActor
@Observable
final class PluginHubModel {
    /// A catalog install the person started: one profile at a time, the root first.
    struct Run: Equatable {
        let name: String
        let profiles: [String]
        /// The profile being installed into, by index; nil once it's done.
        var current: Int?
        var failures: [String: String] = [:]
        /// The root's answer (or the first profile's), for the result screen.
        var result: PluginActionResult?

        var isDone: Bool { current == nil }
    }

    @ObservationIgnored weak var workspace: BotWorkspace?
    private let gatewayID: UUID
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "plugins")

    private(set) var catalog: PluginCatalog?
    /// The feed was asked for at least once (nil catalog after that: it couldn't be read).
    private(set) var catalogChecked = false
    private(set) var system: GatewaySystem?
    private(set) var answers: PluginAnswers
    private(set) var runs: [String: Run] = [:]
    /// Catalog entries' state on the gateway, for their reviews.
    private(set) var presence: [String: CatalogPresence] = [:]
    /// Catalog names that are new here, as of when the hub opened.
    private(set) var newNames: [String] = []

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        gatewayID = workspace.id
        var answers = (UserDefaults.standard.data(forKey: "plugins.answers.\(workspace.id.uuidString)"))
            .flatMap { try? JSONDecoder().decode(PluginAnswers.self, from: $0) } ?? PluginAnswers()
        // This device's copy; once they sync, `load()` adds the gateway's shared one.
        answers.hidden = Self.hiddenStore.hidden(gateway: workspace.id.uuidString)
        self.answers = answers
    }

    // MARK: Where things come from

    /// The feed, cached on this device for every gateway. Debug builds can point it at the mock
    /// (`-HERMES_PLUGIN_CATALOG_URL`), so tests never reach the network.
    static let catalogStore: PluginCatalogStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = DebugFlags.pluginCatalogURL ?? PluginCatalogStore.feed
        let file = caches?.appending(path: url == PluginCatalogStore.feed ? "plugin-catalog.json" : "plugin-catalog-debug.json")
        let session = URLSession(configuration: .ephemeral)
        return PluginCatalogStore(url: url, cacheFile: file) { url in
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }()

    /// Hidden names stay on this device until the app has iCloud key-value storage
    /// (`HermesICloudKeyValueSync` in Info.plist); then every device agrees.
    static let hiddenStore: any HiddenSuggestionStore = syncsHidden ? CloudHiddenSuggestions() : LocalHiddenSuggestions()

    static var syncsHidden: Bool {
        Bundle.main.object(forInfoDictionaryKey: "HermesICloudKeyValueSync") as? Bool == true
    }

    /// Hidden names are kept by gateway: this device's id for it, or, when they sync, the
    /// gateway's hostname, which every device sees the same.
    private var hiddenKey: String {
        guard Self.syncsHidden, let host = system?.hostname, !host.isEmpty else { return gatewayID.uuidString }
        return host.lowercased()
    }

    private var roster: BotRoster? { workspace?.roster }
    var needsBotMode: Bool { roster == nil }
    var isOnline: Bool { roster?.isConnected ?? false }
    var gatewayName: String { workspace?.bot.name ?? "" }
    private var tools: AppsAndToolsModel? { workspace?.appsAndTools }
    private var appPlugins: AppPluginsModel? { workspace?.plugins }

    /// Reads the feed and the gateway's machine; the hub calls it when it appears.
    func load() async {
        async let feed = Self.catalogStore.catalog()
        if system == nil, let backend = roster?.backendClient, isOnline {
            system = try? await backend.system()
            if Self.syncsHidden, system != nil {
                answers.hidden.merge(Self.hiddenStore.hidden(gateway: hiddenKey)) { mine, _ in mine }
            }
        }
        catalog = await feed
        catalogChecked = true
        if let catalog { newNames = answers.unseen(in: catalog.entries.map(\.name)); save() }
    }

    /// The hub went away: what it showed as new has been seen.
    func hubClosed() {
        guard !newNames.isEmpty else { return }
        answers.markSeen(newNames)
        save()
    }

    // MARK: Offers

    /// Suggested (`docs/plugins.md` §3.2): the app's plugins first, then Hermes's curated ones,
    /// five at most.
    var suggestions: [PluginSuggestion] {
        let survey = appPlugins?.survey
        let app = AppPlugin.all.map { plugin -> (plugin: AppPlugin, presence: AppPluginPresence?) in
            (plugin, survey.map { AppPluginPresence($0.entries(for: plugin)) })
        }
        return PluginOffers.suggested(
            app: app, curated: tools?.catalogPlugins ?? [], installed: tools?.plugins ?? [], catalog: catalog,
            gatewayOS: system?.os, hermesVersion: system?.hermesVersion, hidden: Set(answers.hidden.keys)
        )
    }

    /// The app's plugins whose pin adds access, waiting on the consent card.
    var heldAppUpdates: [AppPlugin] {
        let held = appPlugins?.heldUpdates ?? [:]
        return AppPlugin.all.filter { held[$0] != nil }
    }

    /// Catalog plugins with a newer reviewed commit.
    var catalogUpdates: [HermesPlugin] {
        (tools?.installedPlugins ?? []).filter { $0.updateAvailable && !isAppPlugin($0) }
    }

    var updateCount: Int { heldAppUpdates.count + catalogUpdates.count }

    /// Installed plugins (not Hermes's own bundled ones), the app's included.
    var installed: [HermesPlugin] { tools?.installedPlugins ?? [] }

    func isAppPlugin(_ plugin: HermesPlugin) -> Bool { AppPlugin.named(plugin.key) != nil || AppPlugin.named(plugin.name) != nil }

    /// New in the Catalog: entries this device hasn't shown for this gateway, not installed.
    var newEntries: [PluginCatalogEntry] {
        let installed = Set(installed.compactMap(\.catalogName))
        return newNames.compactMap { catalog?.entry(named: $0) }.filter { !installed.contains($0.name) }
    }

    /// "· 2 suggested" for the Settings row: plain text, never a badge.
    var suggestedCount: Int { needsBotMode ? 0 : suggestions.count }

    // MARK: Rows

    /// Why an installed plugin was pulled from the catalog, and when.
    func pulled(_ plugin: HermesPlugin) -> PluginCatalog.Removal? {
        catalog?.removal(name: plugin.name, catalogName: plugin.catalogName)
    }

    /// Secret keys its manifest says it needs that aren't set.
    func missingKeys(_ plugin: HermesPlugin) -> [PluginSettingField] {
        plugin.settings.filter { $0.kind == .secret && $0.required && !$0.hasValue }
    }

    /// Why a catalog entry can't install here, or nil.
    func unavailable(_ entry: PluginCatalogEntry) -> String? {
        if needsBotMode { return String(localized: "Needs Bot Mode") }
        let state = presence[entry.name]
        return PluginOffers.unavailable(entry, gateway: gatewayName, gatewayOS: system?.os, hermesVersion: system?.hermesVersion,
                                        appState: state?.state, sentence: state?.sentence)
    }

    /// An installed catalog plugin with this name.
    func installedRow(catalogName name: String) -> HermesPlugin? {
        installed.first { $0.catalogName == name || $0.key == name }
    }

    // MARK: Answers

    func hide(_ name: String) {
        answers.hide(name)
        storeHidden()
    }

    func showAgain(_ name: String) {
        answers.showAgain(name)
        storeHidden()
    }

    /// Under this device's id, and under the gateway's shared key when they sync, so the next
    /// launch reads the same names either way.
    private func storeHidden() {
        Self.hiddenStore.setHidden(answers.hidden, gateway: gatewayID.uuidString)
        if hiddenKey != gatewayID.uuidString { Self.hiddenStore.setHidden(answers.hidden, gateway: hiddenKey) }
        save()
    }

    func notNow(_ name: String, at moment: AppPlugin.Moment) {
        answers.notNow(name, at: moment.rawValue)
        save()
    }

    /// Whether `moment` may offer `plugin` (never hidden; a Not Now comes back once after 14 days).
    func mayOffer(_ name: String, at moment: AppPlugin.Moment) -> Bool {
        answers.mayOffer(name, at: moment.rawValue)
    }

    func offered(_ name: String, at moment: AppPlugin.Moment) {
        answers.offered(name, at: moment.rawValue)
        save()
    }

    private func save() {
        var stored = answers
        stored.hidden = [:]
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: "plugins.answers.\(gatewayID.uuidString)")
        }
    }

    func forget() {
        answers = PluginAnswers()
        newNames = []
        UserDefaults.standard.removeObject(forKey: "plugins.answers.\(gatewayID.uuidString)")
        Self.hiddenStore.setHidden([:], gateway: hiddenKey)
        if hiddenKey != gatewayID.uuidString { Self.hiddenStore.setHidden([:], gateway: gatewayID.uuidString) }
    }

    /// Entries known only from `plugins.catalog.lookup`, when the feed can't be read.
    private(set) var lookedUp: [String: PluginCatalogEntry] = [:]

    /// A catalog entry by name: from the feed, or from the gateway's lookup.
    func entry(named name: String) -> PluginCatalogEntry? {
        catalog?.entry(named: name) ?? lookedUp[name]
    }

    /// `hermesapp://plugin/install?catalog=<name>` and a feed that couldn't be read: the gateway
    /// says whether the name is in the catalog it uses. Returns the canonical name, or nil.
    func lookUp(_ name: String) async -> String? {
        if catalog == nil, !catalogChecked { await load() }
        if let known = catalog?.entry(named: name) { return known.name }
        guard let client = client(profile: nil), case .found(let found, let repo) = try? await client.lookupPlugin(name) else { return nil }
        if catalog?.entry(named: found) == nil {
            lookedUp[found] = PluginCatalogEntry(name: found, title: found, repo: repo, capabilitiesKnown: false)
        }
        return found
    }

    // MARK: Presence

    /// The entry's app on the gateway and the catalog's disclosure, for its review.
    func readPresence(_ name: String) async {
        guard let client = client(profile: nil),
              let row = try? await client.presence(of: [name]).first else { return }
        presence[name] = row
    }

    // MARK: Installing

    /// Profiles to offer in Installs Into: Hermes, then each Bot.
    var profiles: [String] { AppPluginsModel.profiles(roster?.profiles.map(\.name) ?? []) }

    func title(of profile: String) -> String { appPlugins?.title(of: profile) ?? profile }

    func isInstalling(_ name: String) -> Bool { runs[name].map { !$0.isDone } ?? false }

    /// Installs a catalog plugin by its catalog name (so the gateway's pin and kill list apply)
    /// into each chosen profile, the root first. The person's tap is the dependency consent.
    func install(_ entry: PluginCatalogEntry, into chosen: [String]) async {
        guard isOnline, !isInstalling(entry.name) else { return }
        let ordered = chosen.sorted { ($0 == "default" ? 0 : 1, profiles.firstIndex(of: $0) ?? 0) < ($1 == "default" ? 0 : 1, profiles.firstIndex(of: $1) ?? 0) }
        var run = Run(name: entry.name, profiles: ordered, current: 0)
        runs[entry.name] = run
        for (index, profile) in ordered.enumerated() {
            run.current = index
            runs[entry.name] = run
            do {
                guard let client = client(profile: profile) else { throw HermesError.invalidResponse(String(localized: "\(gatewayName) isn't connected.")) }
                let result = try await client.installPlugin(catalogName: entry.name)
                if result.ok {
                    if run.result == nil || profile == "default" { run.result = result }
                } else {
                    run.failures[profile] = result.error ?? String(localized: "Hermes didn't install it.")
                }
            } catch {
                run.failures[profile] = error.localizedDescription
            }
        }
        run.current = nil
        runs[entry.name] = run
        Self.log.notice("plugins: catalog install into \(ordered.count, privacy: .public) profiles, \(run.failures.count, privacy: .public) failed")
        await tools?.load()
    }

    func clearRun(_ name: String) { runs[name] = nil }

    /// Keys a plugin still needs: each written once with `PUT /api/env` into every profile it went
    /// into, then `reload.env`. The values are never kept, logged or read back.
    func saveKeys(_ values: [String: String], into profiles: [String]) async throws {
        guard let roster else { return }
        for (env, value) in values where !value.isEmpty {
            for profile in profiles {
                try await roster.setEnv(key: env, value: value, profile: profile == "default" ? nil : profile)
            }
        }
        _ = try? await client(profile: nil)?.reloadEnv()
        await tools?.load()
    }

    private func client(profile: String?) -> ConnectionsClient? {
        guard let roster, roster.isConnected else { return nil }
        return ConnectionsClient(profile: profile) { [weak roster] method, params in
            guard let roster else { throw GatewaySocket.Failure.notConnected }
            return try await roster.request(method, params, timeout: .seconds(180))
        }
    }
}
