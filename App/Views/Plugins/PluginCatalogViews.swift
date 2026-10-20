import HermesKit
import SwiftUI

/// `pluginsCatalog`: every plugin in Hermes's catalog, searchable, with chips (All, For This App,
/// Official, then the catalog's categories) and shelves. Installed ones say so.
struct PluginsCatalogView: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel
    @State private var query = ""
    @State private var chip = Chip.all
    /// A plugin opened from here goes on top of the catalog, so Back keeps the search.
    @State private var opened: AppsAndToolsModel.Route?

    enum Chip: Hashable {
        case all, forThisApp, official
        case category(String)
    }

    /// The catalog's categories, in the order the designs list them.
    static let categories = ["memory", "desktop", "platform", "web", "tools", "voice", "automation", "models", "general"]

    static func title(of category: String) -> String {
        switch category {
        case "memory": String(localized: "Memory")
        case "desktop": String(localized: "Desktop")
        case "platform": String(localized: "Platforms")
        case "web": String(localized: "Web")
        case "tools": String(localized: "Tools")
        case "voice": String(localized: "Voice")
        case "automation": String(localized: "Automation")
        case "models": String(localized: "Models")
        default: String(localized: "General")
        }
    }

    private var entries: [PluginCatalogEntry] {
        let all = hub.catalog?.entries ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
            || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var appPlugins: [AppPlugin] {
        AppPlugin.all.filter { query.isEmpty || $0.words.title.localizedCaseInsensitiveContains(query) || $0.words.summary.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chipButton(String(localized: "All"), .all)
                        chipButton(String(localized: "For This App"), .forThisApp)
                        chipButton(String(localized: "Official"), .official)
                        ForEach(Self.categories.filter { category in (hub.catalog?.entries ?? []).contains { $0.category == category } }, id: \.self) { category in
                            chipButton(Self.title(of: category), .category(category))
                        }
                    }
                    #if os(macOS)
                    .padding(.horizontal, 4)
                    #endif
                }
                #if os(iOS)
                // The chips start at the cards' edge and run on to the screen's (`pluginsCatalog`):
                // the section has no side margins, so its cell doesn't clip them at the inset.
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            #if os(iOS)
            .listSectionMargins(.horizontal, 0)
            // Edge to edge, a section draws hairlines above and below it.
            .listSectionSeparator(.hidden)
            #endif
            if chip == .all || chip == .forThisApp, !appPlugins.isEmpty {
                Section {
                    ForEach(appPlugins) { plugin in
                        let on = model.workspace?.plugins.survey.map { AppPluginPresence($0.entries(for: plugin)) } == .on
                        PluginOfferRow(tile: plugin.tile, name: plugin.words.title, forThisApp: true, line: plugin.words.tagline + ".",
                                       trailing: on ? .installed : .action(String(localized: "Install"))) {
                            opened = .review(.app(plugin.name))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { opened = on ? .appPlugin(plugin.name) : .review(.app(plugin.name)) }
                    }
                } header: {
                    countedHeader(String(localized: "For This App"), appPlugins.count)
                }
            }
            ForEach(shelves, id: \.title) { shelf in
                Section {
                    ForEach(shelf.entries) { entry in
                        CatalogEntryRow(hub: hub, entry: entry) { opened = .review(.catalog(entry.name)) }
                    }
                } header: {
                    countedHeader(shelf.title, shelf.entries.count)
                }
            }
            Section {
            } footer: {
                if let catalog = hub.catalog {
                    Text("\(catalog.entries.count) plugins, each pinned to a commit a person reviewed. Check what one can do before you install it.")
                } else if hub.catalogChecked {
                    Text("The catalog couldn’t be read just now. Check Again later; links to a plugin still open its install.")
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        // The chips sit right under the search field, not a section's gap below it.
        .contentMargins(.top, 0, for: .scrollContent)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: searchPrompt)
        #else
        .searchable(text: $query, prompt: searchPrompt)
        #endif
        .navigationTitle(String(localized: "Plugin Catalog"))
        .overlay {
            if !query.isEmpty, entries.isEmpty, appPlugins.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .task { if hub.catalog == nil { await hub.load() } }
        .navigationDestination(item: $opened) { route in
            AppsAndToolsRouteView(model: model, route: route, back: String(localized: "Plugin Catalog"))
        }
    }

    private var searchPrompt: Text {
        Text(hub.catalog.map { String(localized: "Search \($0.entries.count) plugins") } ?? String(localized: "Search plugins"))
    }

    private struct Shelf {
        let title: String
        let entries: [PluginCatalogEntry]
    }

    /// All: Official, then Community. A category: its entries, Official first.
    private var shelves: [Shelf] {
        switch chip {
        case .forThisApp:
            return []
        case .all:
            return [Shelf(title: String(localized: "Official"), entries: entries.filter(\.isOfficial)),
                    Shelf(title: String(localized: "Community"), entries: entries.filter { !$0.isOfficial })].filter { !$0.entries.isEmpty }
        case .official:
            return [Shelf(title: String(localized: "Official"), entries: entries.filter(\.isOfficial))].filter { !$0.entries.isEmpty }
        case .category(let category):
            let matching = entries.filter { $0.category == category }.sorted { $0.isOfficial && !$1.isOfficial }
            return [Shelf(title: Self.title(of: category), entries: matching)].filter { !$0.entries.isEmpty }
        }
    }

    private func chipButton(_ title: String, _ value: Chip) -> some View {
        Button {
            chip = value
        } label: {
            ChipLabel(title: title, isActive: chip == value)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chip == value ? .isSelected : [])
    }
}

/// `pluginsHidden`: suggestions the person hid, with Show Again. They stay in the catalog.
struct PluginsHiddenView: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel
    @State private var opened: AppsAndToolsModel.Route?

    var body: some View {
        Form {
            Section {
                ForEach(hub.answers.hidden.sorted { $0.value > $1.value }, id: \.key) { name, date in
                    row(name: name, date: date)
                }
            } header: {
                countedHeader(String(localized: "Hidden"), hub.answers.hidden.count)
            } footer: {
                Text("Hidden suggestions stay here and in the catalog, so you can install one whenever you like.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Hidden Suggestions"))
        .navigationDestination(item: $opened) { route in
            AppsAndToolsRouteView(model: model, route: route, back: String(localized: "Hidden Suggestions"))
        }
        .overlay {
            if hub.answers.hidden.isEmpty {
                ContentUnavailableView(String(localized: "No Hidden Suggestions"), systemImage: "eye.slash",
                                       description: Text("Don’t Suggest Again on a suggestion puts it here."))
            }
        }
    }

    private func row(name: String, date: Date) -> some View {
        let app = AppPlugin.named(name)
        let entry = hub.catalog?.entry(named: name)
        let line = String(localized: "Hidden on \(date.formatted(.dateTime.day().month())). It won’t be suggested in chats or Settings.")
        return PluginOfferRow(tile: app?.tile ?? PluginTile(symbol: "puzzlepiece.extension"),
                              name: app?.words.title ?? entry?.title ?? name, forThisApp: app != nil, tier: entry?.tier,
                              line: line, trailing: .action(String(localized: "Show Again"))) {
            hub.showAgain(name)
        }
        .contentShape(Rectangle())
        .onTapGesture { opened = .review(app != nil ? .app(name) : .catalog(name)) }
    }
}

/// `pluginInstalledKeys`: the keys a plugin still needs, one secure field each. Written once with
/// `PUT /api/env` into each profile it went into, then `reload.env`; never shown or read back.
struct PluginKeysSheet: View {
    let hub: PluginHubModel
    let title: String
    let envs: [String]
    let profiles: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            PluginKeysForm(hub: hub, title: title, envs: envs, values: $values, error: error)
                .safeAreaBar(edge: .bottom) {
                    InstallBar(title: String(localized: "Save Keys"), busy: saving ? String(localized: "Saving…") : nil,
                               caption: String(localized: "\(title) starts from the next turn."),
                               isEnabled: envs.allSatisfy { !(values[$0] ?? "").isEmpty }) { save() }
                        .frame(maxWidth: 560)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel"), systemImage: "xmark") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #else
        .presentationDetents([.large])
        #endif
    }

    private func save() {
        let secrets = values
        values = [:]
        saving = true
        Task {
            do {
                try await hub.saveKeys(secrets, into: profiles)
                dismiss()
            } catch {
                // Hermes's words; the value itself is never in them.
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// The key fields themselves, in a sheet or on the result page.
struct PluginKeysForm: View {
    let hub: PluginHubModel
    let title: String
    let envs: [String]
    @Binding var values: [String: String]
    var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 8) {
                    PluginTile(symbol: "puzzlepiece.extension", size: 68)
                    Text("\(title) Is Installed")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text("One more step: add its keys")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                PluginSection(title: envs.count == 1 ? String(localized: "Needs 1 key") : String(localized: "Needs \(envs.count) keys"),
                              footer: String(localized: "Saved in \(hub.gatewayName)’s .env. The app never shows them again; you can replace them later.")) {
                    ForEach(envs, id: \.self) { env in
                        SecretField(label: env, value: Binding(get: { values[env] ?? "" }, set: { values[env] = $0 }))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.sheetBackground)
    }
}
