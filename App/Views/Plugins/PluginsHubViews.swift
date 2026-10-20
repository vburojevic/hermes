import HermesKit
import SwiftUI

/// Apps and Tools → Plugins: the hub (`pluginsHub`, `pluginsHubMore`, `docs/plugins.md` §4).
/// Suggested, Updates, Installed (on, off, needs a key, a problem, pulled), New in the Catalog,
/// Browse All, Hidden Suggestions. Without Bot Mode (`pluginsNeedsBotMode`): the card, and the
/// suggestions dimmed. `compact` (iPad landscape's left column) folds Installed and the catalog into
/// rows that open them.
struct PluginsHubSections: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel
    var compact = false
    /// The Mac's Suggested pane: installed plugins are in its sidebar already.
    var macPane = false
    @State private var showsBundled = false

    private var gateway: String { hub.gatewayName }

    /// Its sections go straight into the page's Form; the page loads the hub (`load(_:)`).
    @ViewBuilder var body: some View {
        if hub.needsBotMode {
            needsBotMode
        } else {
            if let consent = model.consent {
                Section {
                    UpdateConsentCard(model: model, consent: consent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            suggested
            updates
            if compact {
                Section {
                    folder(String(localized: "Installed"), symbol: "puzzlepiece.extension.fill", count: hub.installed.count, route: .installedPlugins)
                    folder(String(localized: "Plugin Catalog"), symbol: "square.grid.2x2", count: hub.catalog?.entries.count, route: .pluginCatalog)
                    if !hub.answers.hidden.isEmpty {
                        folder(String(localized: "Hidden Suggestions"), symbol: "eye.slash", count: hub.answers.hidden.count, route: .hiddenSuggestions)
                    }
                }
            } else if macPane {
                newInCatalog
                hidden
            } else {
                installed
                newInCatalog
                hidden
                bundled
            }
        }
    }

    // MARK: Without Bot Mode

    @ViewBuilder private var needsBotMode: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    PluginTile(symbol: "puzzlepiece.extension", size: 40)
                    Text("Plugins need Bot Mode")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                }
                Text("The app installs and manages plugins through Hermes’s backend (hermes serve). Link Bot Mode for \(gateway) to see what’s installed and add more.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let workspace = model.workspace {
                    BotModeLinkButton(workspace: workspace)
                }
            }
            .padding(.vertical, 6)
        }
        Section {
            ForEach(AppPlugin.all.filter { !hub.answers.isHidden($0.name) }) { plugin in
                PluginOfferRow(tile: plugin.tile, name: plugin.words.title, forThisApp: true, line: plugin.words.summary,
                               note: String(localized: "Needs Bot Mode"), dimmed: true)
            }
        } header: {
            countedHeader(String(localized: "Suggested"), AppPlugin.all.count)
        } footer: {
            Text("In Terminal instead: Set Up Push shows the commands.")
        }
    }

    // MARK: Suggested

    @ViewBuilder private var suggested: some View {
        let suggestions = hub.suggestions
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            } header: {
                // The Mac's pane has its own title over them.
                if !macPane { countedHeader(String(localized: "Suggested"), suggestions.count) }
            } footer: {
                Text("Picked because they unlock something in this app or use an app on \(gateway). Nothing installs until you review it and tap Install.")
            }
        }
    }

    private func suggestionRow(_ suggestion: PluginSuggestion) -> some View {
        let subject: PluginSubject
        let row: PluginOfferRow
        switch suggestion.source {
        case .app(let plugin):
            subject = .app(plugin.name)
            let installing = model.workspace?.plugins.installing.contains(plugin.name) == true
            row = PluginOfferRow(
                tile: plugin.tile, name: plugin.words.title, forThisApp: true, line: plugin.words.summary,
                note: suggestion.action == .turnOn ? String(localized: "Installed on \(gateway), turned off.") : nil,
                noteTint: Theme.secondaryText,
                trailing: installing ? .installing : .action(suggestion.action == .turnOn ? String(localized: "Turn On") : String(localized: "Install"))
            ) {
                if model.workspace?.plugins.heldUpdates[plugin] != nil {
                    // Its copy is older and the pin adds access: the consent card decides.
                    model.route = .appPlugin(plugin.name)
                } else if suggestion.action == .turnOn {
                    Task { await model.workspace?.plugins.install(only: [plugin.name]) }
                } else {
                    model.route = .review(.app(plugin.name))
                }
            }
        case .curated(let entry, let catalogEntry):
            subject = .catalog(entry.name)
            let line = String(localized: "\(entry.title) is on \(gateway).") + " " + (catalogEntry?.summary ?? entry.description)
            row = PluginOfferRow(
                tile: PluginTile(symbol: "puzzlepiece.extension"), name: entry.title, tier: entry.tier, line: line,
                trailing: hub.isInstalling(entry.name) ? .installing
                    : .action(suggestion.action == .turnOn ? String(localized: "Turn On") : String(localized: "Install"))
            ) {
                if suggestion.action == .turnOn, let installed = hub.installedRow(catalogName: entry.name) {
                    Task { await model.setPlugin(installed, enabled: true) }
                } else {
                    model.route = .review(.catalog(entry.name))
                }
            }
        }
        return row
            .contentShape(Rectangle())
            .onTapGesture { model.route = .review(subject) }
            .accessibilityAddTraits(.isButton)
            .contextMenu {
                Button(String(localized: "Don’t Suggest Again"), systemImage: "eye.slash") { hub.hide(suggestion.name) }
            }
            .accessibilityAction(named: String(localized: "Don’t Suggest Again")) { hub.hide(suggestion.name) }
    }

    // MARK: Updates

    @ViewBuilder private var updates: some View {
        if hub.updateCount > 0, let apps = model.workspace?.plugins {
            Section {
                ForEach(hub.heldAppUpdates) { plugin in
                    AppPluginConsentCard(model: apps, plugin: plugin, added: apps.heldUpdates[plugin] ?? PluginCapabilities())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                ForEach(hub.catalogUpdates) { plugin in
                    PluginOfferRow(
                        tile: pluginTile(for: plugin), name: plugin.name, tier: plugin.tier,
                        line: String(localized: "v\(plugin.version) → v\(plugin.catalogVersion ?? ""), reviewed for the catalog"),
                        note: model.consent?.plugin.key == plugin.key ? String(localized: "Asks for more access") : nil,
                        trailing: model.isBusy("plugin:\(plugin.key)") ? .installing : .action(String(localized: "Update"))
                    ) {
                        Task { await model.update(plugin) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.route = .plugin(plugin.key) }
                }
            } header: {
                countedHeader(String(localized: "Updates"), hub.updateCount)
            }
        }
    }

    // MARK: Installed

    @ViewBuilder private var installed: some View {
        Section {
            if let error = model.pluginsError, model.plugins.isEmpty {
                Text(error).foregroundStyle(Theme.secondaryText)
            }
            ForEach(hub.installed) { plugin in
                InstalledPluginRow(model: model, hub: hub, plugin: plugin) { model.pluginKeysFor = plugin }
            }
            Button {
                model.installsFromGit = true
            } label: {
                Text("Install from a Git Link…")
                    .foregroundStyle(Theme.link)
                    .underRowNames(52)
            }
        } header: {
            countedHeader(String(localized: "Installed"), hub.installed.count)
        } footer: {
            Text("They run on \(gateway) with the access they list. Turn one off to pause it without removing it.")
        }
    }

    // MARK: The catalog

    @ViewBuilder private var newInCatalog: some View {
        Section {
            ForEach(hub.newEntries.prefix(3)) { entry in
                CatalogEntryRow(hub: hub, entry: entry) { model.route = .review(.catalog(entry.name)) }
            }
            if !macPane {
                Button {
                    model.route = .pluginCatalog
                } label: {
                    Text(hub.catalog.map { String(localized: "Browse All \($0.entries.count) Plugins…") } ?? String(localized: "Browse the Catalog…"))
                        .foregroundStyle(Theme.link)
                }
            }
        } header: {
            if !hub.newEntries.isEmpty { SectionHeading(title: String(localized: "New in the Catalog")) }
        }
    }

    @ViewBuilder private var hidden: some View {
        if !hub.answers.hidden.isEmpty {
            if macPane {
                Section {
                } footer: {
                    HStack {
                        Text("Hidden suggestions stay in the catalog and come back with Show Again.")
                        Spacer()
                        Button(String(localized: "Hidden Suggestions (\(hub.answers.hidden.count))…")) { model.route = .hiddenSuggestions }
                            .buttonBorderShape(.capsule)
                    }
                }
            } else {
                Section {
                    folder(String(localized: "Hidden Suggestions"), symbol: "eye.slash", count: hub.answers.hidden.count, route: .hiddenSuggestions)
                }
            }
        }
    }

    @ViewBuilder private var bundled: some View {
        if !model.bundledPlugins.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsBundled) {
                    ForEach(model.bundledPlugins) { plugin in
                        PluginRow(model: model, plugin: plugin)
                    }
                } label: {
                    Text("Built into Hermes · \(model.bundledPlugins.count)")
                        .foregroundStyle(Theme.primaryText)
                }
            } footer: {
                Text("These come with Hermes. They can be turned off, not removed.")
            }
        }
    }

    /// A row that opens a list: an ink tile, a name, a count, a chevron.
    private func folder(_ title: String, symbol: String, count: Int?, route: AppsAndToolsModel.Route) -> some View {
        Button {
            model.route = route
        } label: {
            HStack(spacing: 12) {
                PluginTile(symbol: symbol, ink: true, size: 30)
                Text(title).foregroundStyle(Theme.primaryText)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(Theme.secondaryText) }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One installed plugin (`pluginRow*`): on with a switch, off, needs keys, a problem in orange, or
/// pulled from the catalog in red with its switch locked.
struct InstalledPluginRow: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel
    let plugin: HermesPlugin
    let addKeys: () -> Void
    /// Where its detail opens: the page's route unless the list pushes its own.
    var onOpen: ((AppsAndToolsModel.Route) -> Void)?

    private var pulled: PluginCatalog.Removal? { hub.pulled(plugin) }
    private var missingKeys: Int { hub.missingKeys(plugin).count }

    private var line: String {
        let adds = model.pluginAdds[plugin.key] ?? .init()
        var parts: [String] = []
        if !plugin.isEnabled { parts.append(String(localized: "Off")) }
        if !plugin.version.isEmpty { parts.append("v\(plugin.version)") }
        if !adds.tools.isEmpty {
            parts.append(adds.tools.count == 1 ? String(localized: "1 tool") : String(localized: "\(adds.tools.count) tools"))
        } else if !plugin.description.isEmpty {
            parts.append(plugin.description.split(separator: ".").first.map { String($0).lowercasedFirst } ?? "")
        }
        return parts.joined(separator: " · ")
    }

    private var note: (String, Color)? {
        if pulled != nil { return (String(localized: "Pulled from the catalog · tap for why"), Theme.danger) }
        if let app = AppPlugin.named(plugin.key) ?? AppPlugin.named(plugin.name), let apps = model.workspace?.plugins {
            // The app's own: what its per-Bot page would fix first.
            switch apps.status(for: app) {
            case .missing, .outdated, .off, .restartPending, .failed:
                return (AppPluginsModel.line(for: apps.status(for: app), title: apps.title(of:)), Theme.warning)
            case .needsBotMode, .offline, .checking, .current:
                break
            }
        }
        if missingKeys > 0 {
            return (missingKeys == 1 ? String(localized: "Needs 1 key · tap to add it") : String(localized: "Needs \(missingKeys) keys · tap to add them"), Theme.warning)
        }
        if plugin.isEnabled, let problem = plugin.problem { return (problem, Theme.warning) }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            PluginOfferRow(tile: pluginTile(for: plugin), name: plugin.name, forThisApp: hub.isAppPlugin(plugin), tier: plugin.tier,
                           line: line, note: note?.0, noteTint: note?.1 ?? Theme.warning)
            if model.isBusy("plugin:\(plugin.key)") {
                Spinner()
            }
            Toggle(String(localized: "On"), isOn: Binding(
                get: { plugin.isEnabled },
                set: { on in Task { await model.setPlugin(plugin, enabled: on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
            // A pulled plugin can't be turned on (Hermes's toggle would say ok and load nothing).
            .disabled(pulled != nil && !plugin.isEnabled)
            .accessibilityLabel(Text("\(plugin.name) on"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if missingKeys > 0, pulled == nil { addKeys() } else { open() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: String(localized: "Open")) { open() }
    }

    private func open() {
        let route: AppsAndToolsModel.Route
        if let app = AppPlugin.named(plugin.key) ?? AppPlugin.named(plugin.name) {
            route = .appPlugin(app.name)
        } else {
            route = .plugin(plugin.key)
        }
        if let onOpen { onOpen(route) } else { model.route = route }
    }
}

/// A catalog entry in a list: Install, or "Installed" when it's here.
struct CatalogEntryRow: View {
    let hub: PluginHubModel
    let entry: PluginCatalogEntry
    let open: () -> Void

    var body: some View {
        let installed = hub.installedRow(catalogName: entry.name) != nil
        let reason = hub.unavailable(entry)
        PluginOfferRow(tile: entry.tile, name: entry.title, tier: entry.tier, line: entry.summary, note: reason,
                       trailing: hub.isInstalling(entry.name) ? .installing : installed ? .installed : .action(String(localized: "Install")),
                       dimmed: reason != nil, onAction: open)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

extension PluginHubModel {
    /// What the hub shows: the feed, the gateway's machine, and the app's plugins in each profile.
    func loadForHub() async {
        await load()
        if let plugins = workspace?.plugins, plugins.survey == nil { await plugins.check() }
    }
}
