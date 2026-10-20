#if os(macOS)
import HermesKit
import SwiftUI

/// Settings → Apps & Tools on the Mac (`macSettingsConnections`): the list on the left (Apps,
/// MCP Servers, Plugins, Built-in, and Add…), the selected item on the right as a grouped form.
/// Orange dots mark what needs attention. Same data and calls as the iPhone page.
struct MacAppsAndToolsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.currentWorkspace {
            MacAppsAndToolsContent(model: workspace.appsAndTools)
                .id(workspace.id)
        } else {
            ContentUnavailableView("No gateway", systemImage: "server.rack", description: Text("Add a gateway to see what Hermes can reach."))
        }
    }
}

private struct MacAppsAndToolsContent: View {
    @Bindable var model: AppsAndToolsModel

    enum Selection: Hashable {
        case app(String), server(String), plugin(String), builtIn, add
        /// Suggested at the head of the Plugins list (`macPluginsSuggested`).
        case suggested
    }

    @State private var selection: Selection?
    @State private var installingFromGit = false

    /// `-HERMES_APPS_TOOLS apps:github|mcp:sentry|plugins:xcode|builtin|add` (screenshots).
    private static var debugSelection: Selection? {
        guard let route = DebugFlags.appsAndTools else { return nil }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let item = parts.count > 1 ? parts[1] : nil
        switch (parts[0], item) {
        case ("builtin", _): return .builtIn
        case (_, "add"?): return .add
        case ("mcp", let name?): return .server(name)
        case ("plugins", "suggested"?): return .suggested
        case ("plugins", let key?): return .plugin(key)
        case ("apps", let slug?): return .app(slug)
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
            Divider()
            NavigationStack {
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.isOnline) {
            if model.isOnline { await model.load() }
            if selection == nil { selection = Self.debugSelection ?? model.apps.first.map { .app($0.id) } ?? .builtIn }
            // `-HERMES_APPS_TOOLS plugins:review:<name>|app:<name>|catalog|hidden`: that page in the Suggested pane.
            if let route = DebugFlags.appsAndTools, route.hasPrefix("plugins:"),
               let page = AppsAndToolsView.debugPluginRoute(String(route.dropFirst("plugins:".count))) {
                selection = .suggested
                model.route = page
            }
        }
        .modifier(AppsAndToolsAlerts(model: model))
        .sheet(isPresented: $installingFromGit) { InstallFromGitSheet(model: model) }
    }

    /// "3 to install · 1 update".
    private func suggestedDetail(_ hub: PluginHubModel) -> String {
        var parts: [String] = []
        let count = hub.suggestedCount
        if count > 0 { parts.append(String(localized: "\(count) to install")) }
        if hub.updateCount > 0 {
            parts.append(hub.updateCount == 1 ? String(localized: "1 update") : String(localized: "\(hub.updateCount) updates"))
        }
        return parts.joined(separator: " · ")
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !model.isOnline {
                OfflineNote(model: model)
                    .listRowSeparator(.hidden)
            }
            Section("Apps") {
                if model.appsAvailable {
                    ForEach(model.apps) { app in
                        ToolsListRow(title: app.name, detail: appDetail(app), needsAttention: app.needsAttention) {
                            AppLogo(name: app.name, url: app.logoURL, size: 24)
                        }
                        .tag(Selection.app(app.id))
                    }
                } else {
                    Text("Sign in to Nous to connect apps")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .tag(Selection.add)
                }
            }
            Section("MCP Servers") {
                ForEach(model.servers) { server in
                    ToolsListRow(title: server.name, mono: true, detail: shortStatus(server), needsAttention: server.enabled && server.status == .failed) {
                        GlyphTile(symbol: server.usesURL ? "globe" : "terminal", size: 24)
                    }
                    .tag(Selection.server(server.name))
                }
            }
            Section("Plugins") {
                if let hub = model.workspace?.pluginHub {
                    ToolsListRow(title: String(localized: "Suggested"), detail: suggestedDetail(hub), needsAttention: false) {
                        GlyphTile(symbol: "sparkles", ink: true, size: 24)
                    }
                    .tag(Selection.suggested)
                }
                ForEach(model.installedPlugins) { plugin in
                    ToolsListRow(title: plugin.name, detail: pluginDetail(plugin), needsAttention: plugin.updateAvailable || (plugin.isEnabled && plugin.problem != nil)) {
                        GlyphTile(symbol: "puzzlepiece.extension", size: 24)
                    }
                    .tag(Selection.plugin(plugin.key))
                }
            }
            Section("Built-in") {
                ToolsListRow(title: builtInTitle, detail: builtInDetail, needsAttention: false) {
                    GlyphTile(symbol: "terminal", ink: true, size: 24)
                }
                .tag(Selection.builtIn)
            }
            Label("Add App, MCP Server or Plugin…", systemImage: "plus")
                .foregroundStyle(Theme.secondaryText)
                .tag(Selection.add)
        }
        .listStyle(.sidebar)
        .disabled(!model.isOnline && !model.hasLoaded)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .app(let slug)?:
            AppDetailView(model: model, slug: slug, macLayout: true)
                .id(slug)
        case .server(let name)?:
            ServerDetailView(model: model, name: name, macLayout: true)
                .id(name)
        case .plugin(let key)?:
            PluginDetailView(model: model, key: key, macLayout: true)
                .id(key)
        case .suggested?:
            if let hub = model.workspace?.pluginHub {
                MacPluginsSuggestedPane(model: model, hub: hub)
                    .task(id: model.isOnline) { await hub.loadForHub() }
                    .onDisappear { hub.hubClosed() }
            }
        case .builtIn?:
            Form { BuiltInTabSections(model: model) }
                .formStyle(.grouped)
                .disabled(!model.isOnline)
        case .add?:
            Form {
                AppsTabSections(model: model, addOnly: true)
                ServersTabSections(model: model, addOnly: true)
                Section {
                    Button(String(localized: "Browse the Plugin Catalog…")) {
                        model.route = .pluginCatalog
                        selection = .suggested
                    }
                    Button(String(localized: "Install from a Git Link…")) { installingFromGit = true }
                } header: {
                    SectionHeading(title: String(localized: "Plugins"))
                } footer: {
                    Text("Each plugin opens its review first: what it can do on \(model.gatewayName), and where it comes from.")
                }
            }
            .formStyle(.grouped)
            .disabled(!model.isOnline)
        case nil:
            ContentUnavailableView("Apps & Tools", systemImage: "puzzlepiece.extension", description: Text("Pick an app, MCP server or plugin."))
        }
    }

    private var builtIn: [BuiltInToolset] {
        BuiltInToolsetInfo.main.compactMap { name in model.toolsets.first { $0.name == name } }
    }

    private var builtInTitle: String {
        let names = builtIn.prefix(4).compactMap { BuiltInToolsetInfo.info($0.name, gateway: model.gatewayName)?.title }
        return names.joined(separator: ", ") + (builtIn.count > 4 ? "…" : "")
    }

    private var builtInDetail: String {
        String(localized: "\(builtIn.filter(\.enabled).count) of \(builtIn.count) on")
    }

    private func appDetail(_ app: AppsAndToolsModel.ConnectedApp) -> String {
        if app.needsAttention { return String(localized: "Sign-in expired") }
        var parts: [String] = []
        if app.accounts.count > 1 { parts.append(String(localized: "\(app.accounts.count) accounts")) }
        if let count = app.toolCount { parts.append(count == 1 ? String(localized: "1 tool") : String(localized: "\(count) tools")) }
        return parts.joined(separator: " · ")
    }

    private func shortStatus(_ server: McpServer) -> String {
        guard server.enabled else { return String(localized: "Off") }
        switch server.status {
        case .connected: return server.toolCount.map { String(localized: "Connected · \($0) tools") } ?? String(localized: "Connected")
        case .failed: return String(localized: "Couldn't connect")
        case .lazy: return String(localized: "Starts when needed")
        default: return String(localized: "Not tested yet")
        }
    }

    private func pluginDetail(_ plugin: HermesPlugin) -> String {
        if plugin.updateAvailable { return String(localized: "Update available") }
        if plugin.isEnabled, plugin.problem != nil { return String(localized: "Needs attention") }
        let adds = model.pluginAdds[plugin.key] ?? .init()
        var parts: [String] = []
        if let tier = plugin.tier { parts.append(tier.capitalized) }
        if !adds.tools.isEmpty { parts.append(String(localized: "\(adds.tools.count) tools")) }
        if !adds.skills.isEmpty { parts.append(String(localized: "\(adds.skills.count) skills")) }
        return parts.joined(separator: " · ")
    }
}

/// One row of the list: a tile, a name, a line, and an orange dot when it needs attention.
private struct ToolsListRow<Tile: View>: View {
    let title: String
    var mono = false
    let detail: String
    let needsAttention: Bool
    @ViewBuilder let tile: Tile

    var body: some View {
        HStack(spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(mono ? .body.monospaced() : .body)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if needsAttention {
                Circle()
                    .fill(Theme.warning)
                    .frame(width: 8, height: 8)
                    .padding(3)
                    .background(Theme.warning.opacity(0.2), in: Circle())
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
