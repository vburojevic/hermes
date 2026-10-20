import HermesKit
import SwiftUI

/// Settings → Hermes on <gateway> → Apps and Tools (`appsTab`, `serversTab`, `pluginsTab`,
/// `builtInTab`): what Hermes on one gateway can reach, in four tabs. Pushed inside the Settings
/// sheet on iPhone and iPad; the Mac has its own tab (`MacAppsAndToolsPane`).
struct AppsAndToolsView: View {
    @Bindable var model: AppsAndToolsModel
    @Environment(WindowRouter.self) private var router: WindowRouter?
    /// The Add sheet opened by `-HERMES_APPS_TOOLS mcp:add` (screenshots).
    @State private var debugAddsServer = false

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    /// iPad landscape (`ipadAppsTools`): the tabs and list on the left, the selected item on the
    /// right. Portrait and iPhone push the detail.
    private var isWide: Bool {
        #if os(iOS)
        sizeClass == .regular && width >= 900
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 0) {
                    list
                        .formStyle(.grouped)
                        .frame(width: 440)
                    Divider()
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                list
                    .formStyle(.grouped)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Apps and Tools")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: model.isOnline) {
            if model.isOnline { await model.load() }
        }
        // The plugin hub (`docs/plugins.md` §4): read when its tab shows; what it showed as new
        // has been seen once it's left.
        .task(id: [model.tab == .plugins, model.isOnline]) {
            if model.tab == .plugins { await model.workspace?.pluginHub.loadForHub() }
        }
        .onChange(of: model.tab) { old, _ in
            if old == .plugins { model.workspace?.pluginHub.hubClosed() }
        }
        .onDisappear { model.workspace?.pluginHub.hubClosed() }
        .refreshable { await model.load() }
        .modifier(AppsAndToolsAlerts(model: model))
        .animation(Theme.snappy, value: model.tab)
        .navigationDestination(item: Binding(get: { isWide ? nil : model.route }, set: { model.route = $0 })) { route in
            routeView(route, wide: false)
        }
        .sheet(isPresented: $debugAddsServer) { AddServerSheet(model: model) }
        .sheet(isPresented: $model.installsFromGit) { InstallFromGitSheet(model: model) }
        .sheet(item: $model.pluginKeysFor) { plugin in
            if let hub = model.workspace?.pluginHub {
                PluginKeysSheet(hub: hub, title: plugin.name, envs: hub.missingKeys(plugin).compactMap(\.env), profiles: [model.scopeProfile])
            }
        }
        .task { await openDebugRoute() }
        .task { await takeInstallRequest() }
    }

    /// The scope line, the tabs and the selected tab's list.
    private var list: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if let workspace = model.workspace { GatewayScopeLine(workspace: workspace) }
                    Picker("Show", selection: $model.tab) {
                        ForEach(AppsAndToolsModel.Tab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
            }
            if !model.isOnline {
                Section {
                    OfflineNote(model: model)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            Group {
                switch model.tab {
                case .apps: AppsTabSections(model: model)
                case .mcp: ServersTabSections(model: model)
                case .plugins:
                    if let workspace = model.workspace {
                        PluginsHubSections(model: model, hub: workspace.pluginHub, compact: isWide)
                    }
                case .builtIn: BuiltInTabSections(model: model)
                }
            }
            // Offline: the last known list, dimmed, every switch off limits.
            .disabled(!model.isOnline)
            .opacity(model.isOnline ? 1 : 0.55)
        }
    }

    /// A route's page: pushed on iPhone and iPad portrait, the right column on iPad landscape.
    private func routeView(_ route: AppsAndToolsModel.Route, wide: Bool) -> some View {
        AppsAndToolsRouteView(model: model, route: route, wide: wide)
    }

    /// The right column on iPad landscape: the chosen app, MCP server or plugin.
    @ViewBuilder
    private var detailColumn: some View {
        switch model.route ?? defaultRoute {
        case let route?:
            routeView(route, wide: true)
        case nil:
            ContentUnavailableView(model.tab == .builtIn ? "Built-in tools" : "Nothing chosen", systemImage: "puzzlepiece.extension",
                                   description: Text(model.tab == .builtIn ? "Switch them on the left." : "Pick an app, MCP server or plugin."))
        }
    }

    /// The first item of the tab, until one is picked.
    private var defaultRoute: AppsAndToolsModel.Route? {
        switch model.tab {
        case .apps: model.apps.first.map { .app($0.id) }
        case .mcp: model.servers.first.map { .server($0.name) }
        case .plugins: (model.workspace?.pluginHub.suggestions.first).map { .review($0.isAppPlugin ? .app($0.name) : .catalog($0.name)) }
            ?? model.installedPlugins.first.map { .plugin($0.key) }
        case .builtIn: nil
        }
    }

    /// A `plugin/install?catalog=` link: resolve it in the catalog and ask before installing.
    private func takeInstallRequest() async {
        guard let name = router?.pluginInstallRequest else { return }
        router?.pluginInstallRequest = nil
        model.tab = .plugins
        for _ in 0..<40 where !model.hasLoaded { try? await Task.sleep(for: .milliseconds(250)) }
        // The review is the consent (`docs/plugins.md` §5): the link opens it, never installs.
        if let workspace = model.workspace, let found = await workspace.pluginHub.lookUp(name) {
            model.route = .review(.catalog(found))
        } else {
            model.message = String(localized: "\(name) isn't in the Hermes catalog.")
        }
    }

    /// `plugins:catalog`, `plugins:hidden`, `plugins:review:<catalog name>`, `plugins:app:<name>`
    /// (the app's plugin's review), `plugins:profiles:<name>` (its per-Bot page).
    static func debugPluginRoute(_ item: String) -> AppsAndToolsModel.Route? {
        let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts[0], parts.count > 1 ? parts[1] : nil) {
        case ("catalog", nil): return .pluginCatalog
        case ("hidden", nil): return .hiddenSuggestions
        case ("installed", nil): return .installedPlugins
        case ("review", let name?): return .review(.catalog(name))
        case ("app", let name?): return .review(.app(name))
        case ("profiles", let name?): return .appPlugin(name)
        default: return nil
        }
    }

    /// `-HERMES_APPS_TOOLS apps|mcp|plugins|builtin[:<slug, server, plugin key or "add">]`.
    private func openDebugRoute() async {
        guard let route = DebugFlags.appsAndTools else { return }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        model.tab = switch parts[0] {
        case "mcp": .mcp
        case "plugins": .plugins
        case "builtin": .builtIn
        default: .apps
        }
        guard parts.count > 1 else { return }
        for _ in 0..<40 where !model.hasLoaded { try? await Task.sleep(for: .milliseconds(250)) }
        if parts[1] == "add" {
            debugAddsServer = true
        } else if parts[1] == "update", let plugin = model.installedPlugins.first(where: \.updateAvailable) {
            await model.update(plugin)
        } else if model.tab == .plugins, let route = Self.debugPluginRoute(parts[1]) {
            model.route = route
        } else {
            model.route = switch model.tab {
            case .mcp: .server(parts[1])
            case .plugins: .plugin(parts[1])
            default: .app(parts[1])
            }
        }
    }
}

/// The page a route opens: an app, an MCP server, a plugin's detail or review, the per-Bot page of
/// one of the app's plugins, or one of the hub's lists. `back` names the page it goes back to in a
/// Mac Settings tab (`docs/design-to-swiftui.md` §6).
struct AppsAndToolsRouteView: View {
    let model: AppsAndToolsModel
    let route: AppsAndToolsModel.Route
    var wide = false
    var back: String?

    var body: some View {
        #if os(macOS)
        if let back {
            page.settingsPage(back: back)
        } else {
            page
        }
        #else
        page
        #endif
    }

    @ViewBuilder private var page: some View {
        switch route {
        case .app(let slug): AppDetailView(model: model, slug: slug, macLayout: wide).id(slug)
        case .server(let name): ServerDetailView(model: model, name: name, macLayout: wide).id(name)
        case .plugin(let key): PluginDetailView(model: model, key: key, macLayout: wide).id(key)
        case .review(let subject):
            if let workspace = model.workspace {
                PluginReview(workspace: workspace, subject: subject, inPane: isMac, inColumn: wide).id(subject)
                    .environment(\.pluginReviewExit, wide ? PluginReviewExit { model.route = nil } : nil)
            }
        case .appPlugin(let name):
            if let workspace = model.workspace, let plugin = AppPlugin.named(name) { PluginProfilesView(workspace: workspace, plugin: plugin) }
        case .pluginCatalog:
            if let workspace = model.workspace { PluginsCatalogView(model: model, hub: workspace.pluginHub) }
        case .hiddenSuggestions:
            if let workspace = model.workspace { PluginsHiddenView(model: model, hub: workspace.pluginHub) }
        case .installedPlugins:
            if let workspace = model.workspace { InstalledPluginsView(model: model, hub: workspace.pluginHub) }
        }
    }

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// Launch flags for screenshots (Debug builds read them; Release never sets them).
enum DebugFlags {
    static var appsAndTools: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_APPS_TOOLS")
        #else
        nil
        #endif
    }

    /// `-HERMES_PLUGIN_CATALOG_URL <url>`: the catalog feed to read instead of Hermes's (the mock's
    /// `/docs/api/plugin-catalog.json`), so screenshots and UI tests never reach the network.
    static var pluginCatalogURL: URL? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_PLUGIN_CATALOG_URL").flatMap(URL.init(string:))
        #else
        nil
        #endif
    }

    /// `-HERMES_SETTINGS_SETUP YES|<feature id>` opens Settings → Setup, or one feature's page
    /// there (`docs/setup.md` §5).
    static var setup: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_SETTINGS_SETUP")
        #else
        nil
        #endif
    }

    /// The feature `-HERMES_SETTINGS_SETUP` names, if it names one.
    static var setupFeature: String? {
        setup.flatMap { $0 == "YES" ? nil : $0 }
    }

    /// `-HERMES_MEMORY about|notes|options|edit:<n>|notes-edit:<n>|reset|bot:<profile>` opens Memory.
    static var memory: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_MEMORY")
        #else
        nil
        #endif
    }
}

/// The gateway can't be reached, or has no Bot Mode (Apps and Tools speak its gateway protocol).
struct OfflineNote: View {
    let model: AppsAndToolsModel

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.needsBotMode ? "Turn on Bot Mode for \(model.gatewayName)" : "\(model.gatewayName) is offline")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(model.needsBotMode
                     ? String(localized: "Apps and Tools are managed over Bot Mode's connection.")
                     : (model.hasLoaded ? String(localized: "Showing what it had last. Changes wait until it's back.") : String(localized: "Its apps and tools show when it's back.")))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                if model.needsBotMode, let workspace = model.workspace {
                    // `docs/setup.md` §4.1.
                    BotModeLinkButton(workspace: workspace)
                        .padding(.top, 6)
                }
            }
        } icon: {
            Image(systemName: model.needsBotMode ? "server.rack" : "wifi.slash")
                .foregroundStyle(Theme.warning)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Alerts and cards every tab shares: errors, what a plugin action said.
struct AppsAndToolsAlerts: ViewModifier {
    @Bindable var model: AppsAndToolsModel

    func body(content: Content) -> some View {
        content
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $model.pluginNotes) { notes in
                PluginNotesSheet(model: model, notes: notes)
            }
            // Here, on the page: a sheet on a Form's sections is repeated for every row.
            .sheet(item: $model.addingKeyFor) { toolset in
                ToolsetKeySheet(model: model, toolset: toolset)
            }
    }
}
