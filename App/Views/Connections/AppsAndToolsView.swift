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
        .refreshable { await model.load() }
        .modifier(AppsAndToolsAlerts(model: model))
        .animation(Theme.snappy, value: model.tab)
        .navigationDestination(item: Binding(get: { isWide ? nil : model.route }, set: { model.route = $0 })) { route in
            switch route {
            case .app(let slug): AppDetailView(model: model, slug: slug)
            case .server(let name): ServerDetailView(model: model, name: name)
            case .plugin(let key): PluginDetailView(model: model, key: key)
            }
        }
        .sheet(isPresented: $debugAddsServer) { AddServerSheet(model: model) }
        .task { await openDebugRoute() }
        .task { await takeInstallRequest() }
        .alert(String(localized: "Install \(model.installOffer?.title ?? "")?"),
               isPresented: Binding(get: { model.installOffer != nil }, set: { if !$0 { model.installOffer = nil } })) {
            Button("Install") {
                if let offer = model.installOffer { Task { await model.install(catalogName: offer.name, title: offer.title) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "From the Hermes catalog. It runs on \(model.gatewayName) with the access its manifest asks for."))
        }
    }

    /// The scope line, the tabs and the selected tab's list.
    private var list: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    GatewayScopeLine(workspace: model.workspace)
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
                case .plugins: PluginsTabSections(model: model)
                case .builtIn: BuiltInTabSections(model: model)
                }
            }
            // Offline: the last known list, dimmed, every switch off limits.
            .disabled(!model.isOnline)
            .opacity(model.isOnline ? 1 : 0.55)
        }
    }

    /// The right column on iPad landscape: the chosen app, MCP server or plugin.
    @ViewBuilder
    private var detailColumn: some View {
        switch model.route ?? defaultRoute {
        case .app(let slug)?:
            AppDetailView(model: model, slug: slug, macLayout: true).id(slug)
        case .server(let name)?:
            ServerDetailView(model: model, name: name, macLayout: true).id(name)
        case .plugin(let key)?:
            PluginDetailView(model: model, key: key, macLayout: true).id(key)
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
        case .plugins: model.installedPlugins.first.map { .plugin($0.key) }
        case .builtIn: nil
        }
    }

    /// A `plugin/install?catalog=` link: resolve it in the catalog and ask before installing.
    private func takeInstallRequest() async {
        guard let name = router?.pluginInstallRequest else { return }
        router?.pluginInstallRequest = nil
        model.tab = .plugins
        for _ in 0..<40 where !model.hasLoaded { try? await Task.sleep(for: .milliseconds(250)) }
        if let entry = await model.lookUp(catalogName: name) {
            model.installOffer = entry
        } else {
            model.message = String(localized: "\(name) isn't in the Hermes catalog.")
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
        } else {
            model.route = switch model.tab {
            case .mcp: .server(parts[1])
            case .plugins: .plugin(parts[1])
            default: .app(parts[1])
            }
        }
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
    }
}
