import HermesKit
import SwiftUI

// MARK: - Apps tab (`appsTab`)

struct AppsTabSections: View {
    let model: AppsAndToolsModel
    /// The Mac's "Add App, MCP Server or Plugin…": only what can be added.
    var addOnly = false

    var body: some View {
        if !model.appsAvailable {
            Section {
                NousSignInState(model: model)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        } else if let error = model.appsError, model.apps.isEmpty {
            Section {
                Text(error).foregroundStyle(Theme.secondaryText)
            }
        } else {
            if !model.apps.isEmpty, !addOnly {
                Section {
                    ForEach(model.apps) { app in
                        NavigationLink {
                            AppDetailView(model: model, slug: app.id)
                                .settingsPage(back: String(localized: "Apps & Tools"))
                        } label: {
                            AppRow(app: app)
                        }
                    }
                } header: {
                    countedHeader(String(localized: "Connected"), model.apps.count)
                } footer: {
                    Text("Signed in through your Nous account. Your passwords stay with each app; Hermes only gets the tools you allow.")
                }
            }
            Section {
                ForEach(model.addableApps.prefix(addOnly ? 6 : 3)) { entry in
                    CatalogAppRow(model: model, entry: entry)
                }
                NavigationLink {
                    BrowseAppsView(model: model)
                        .settingsPage(back: String(localized: "Apps & Tools"))
                } label: {
                    Text("Browse All Apps…").foregroundStyle(Theme.link)
                }
            } header: {
                SectionHeading(title: String(localized: "Add an App"))
            }
        }
    }
}

/// A connected app (`appRow*`): logo, name, its accounts and tool count, or "Sign-in expired".
struct AppRow: View {
    let app: AppsAndToolsModel.ConnectedApp

    private var detail: String {
        let names = app.accounts.map(\.label).joined(separator: ", ")
        guard !app.needsAttention, let count = app.toolCount else { return names }
        let tools = count == 1 ? String(localized: "1 tool") : String(localized: "\(count) tools")
        return names.isEmpty ? tools : "\(names) · \(tools)"
    }

    var body: some View {
        HStack(spacing: 12) {
            AppLogo(name: app.name, url: app.logoURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).foregroundStyle(Theme.primaryText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if app.needsAttention {
                TagLabel(title: String(localized: "Sign-in expired"), style: .warning)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An app to add (`catalogRow`): logo, name, what it does, Connect.
struct CatalogAppRow: View {
    let model: AppsAndToolsModel
    let entry: ConnectorCatalogEntry

    var body: some View {
        HStack(spacing: 12) {
            AppLogo(name: entry.name, url: entry.logoURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).foregroundStyle(Theme.primaryText)
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await model.connect(entry.slug) }
            } label: {
                ZStack {
                    Text("Connect").opacity(model.signingIn == entry.slug ? 0 : 1)
                    if model.signingIn == entry.slug { Spinner() }
                }
            }
            .buttonStyle(RowCapsuleButtonStyle())
            .disabled(model.signingIn != nil)
            .accessibilityLabel("Connect \(entry.name)")
        }
    }
}

/// `connectors.list available: false`: apps are turned off on the gateway, not in the Nous plan,
/// or need the person's Nous account (`docs/setup.md` §4.5). MCP and Built-in work anyway.
struct NousSignInState: View {
    let model: AppsAndToolsModel

    var body: some View {
        switch model.appsBlock {
        case .signIn: signIn
        case .turnedOff: turnedOff
        case .notIncluded: notIncluded
        }
    }

    private var turnedOff: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.connected.to.app.below.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.secondaryText)
            Text("Apps are turned off on \(model.gatewayName)")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text("Connected apps are off in Hermes's settings there. MCP servers, plugins and built-in tools work without them.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            InkButton(title: String(localized: "Turn On"), isWorking: model.isBusy("apps")) {
                Task { await model.turnOnApps() }
            }
            .frame(maxWidth: 280)
            .padding(.top, 4)
            SetupCommand(command: "hermes config set tools.connectors.enabled true")
                .frame(maxWidth: 360)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var notIncluded: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 34))
                .foregroundStyle(Theme.secondaryText)
            Text("Apps aren't in your Nous plan yet")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text("\(model.gatewayName) is signed in to Nous, but the account doesn't include connected apps yet. MCP servers, plugins and built-in tools work without them.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            SetupDocsLink(url: HermesDocs.page("user-guide/features/tool-gateway"))
                .font(.subheadline)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var signIn: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(Theme.secondaryText)
            Text("Sign in to Nous to connect apps")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("GitHub, Gmail, Linear and other apps connect through your Nous account. MCP servers, plugins and built-in tools work without it.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            InkButton(title: String(localized: "Sign In to Nous"), isWorking: model.signingIn == "nous") {
                Task { await model.signInToNous() }
            }
            .frame(maxWidth: 280)
            .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Every app in the catalog, searchable by name and category.
struct BrowseAppsView: View {
    let model: AppsAndToolsModel
    @State private var query = ""

    private var groups: [(String, [ConnectorCatalogEntry])] {
        let matches = model.addableApps.filter { entry in
            query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) || entry.category.localizedCaseInsensitiveContains(query)
        }
        return Dictionary(grouping: matches, by: { $0.category.isEmpty ? String(localized: "Other") : $0.category })
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { category, entries in
                Section(category) {
                    ForEach(entries) { entry in
                        CatalogAppRow(model: model, entry: entry)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, prompt: "Apps or categories")
        .navigationTitle("All Apps")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - App detail (`appDetail`, `appExpired`)

struct AppDetailView: View {
    let model: AppsAndToolsModel
    let slug: String
    /// The Mac's grouped form: a row header with Disconnect at its end.
    var macLayout = false

    @Environment(\.dismiss) private var dismiss
    @State private var showsAllTools = false
    @State private var confirmingDisconnect = false
    @State private var renaming: ConnectorAccount?
    @State private var removing: ConnectorAccount?
    @State private var switching: ConnectorAccount?
    @State private var newAlias = ""
    @State private var addingAccount = false
    @State private var anotherAlias = ""

    private var app: AppsAndToolsModel.ConnectedApp? { model.app(slug) }

    var body: some View {
        Group {
            if let app {
                form(app)
            } else {
                ContentUnavailableView("Not connected", systemImage: "app.connected.to.app.below.fill", description: Text("This app was disconnected."))
            }
        }
        .detailTitle(app?.name ?? "", shows: !macLayout)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func form(_ app: AppsAndToolsModel.ConnectedApp) -> some View {
        Form {
            Section {
                if macLayout {
                    HStack(spacing: 12) {
                        AppLogo(name: app.name, url: app.logoURL, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline).foregroundStyle(Theme.primaryText)
                            Text(app.description).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button(role: .destructive) { confirmingDisconnect = true } label: {
                            Text("Disconnect").foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(RowCapsuleButtonStyle())
                    }
                    .listRowBackground(Color.clear)
                } else {
                    AppHeader(app: app)
                        .listRowBackground(Color.clear)
                }
            }
            if app.needsAttention, let account = app.activeAccount {
                Section {
                    ExpiredCard(model: model, app: app, account: account)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            accounts(app)
            if !app.needsAttention {
                tools(app)
            }
            if !macLayout {
                Section {
                    DestructiveRowButton(title: String(localized: "Disconnect \(app.name)")) { confirmingDisconnect = true }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.isOnline)
        .task(id: slug) {
            if model.tools(of: slug).isEmpty { await model.refreshTools(of: slug) }
        }
        .alert("Disconnect \(app.name)?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await model.disconnect(app)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes loses its \(app.name) tools on \(model.gatewayName). Your \(app.name) account stays as it is.")
        }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("personal", text: $newAlias)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Rename") {
                if let account = renaming { Task { await model.rename(account, to: Self.alias(newAlias)) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A short name you can use in a chat, like \u{201C}use my work \(app.name)\u{201D}.")
        }
        .alert("Remove \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let account = removing { Task { await model.remove(account) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes stops using this \(app.name) account.")
        }
        // Hermes uses the account signed in to last, so switching is signing in to this one again.
        .alert("Use \(switching?.label ?? "")?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
            Button("Sign In") {
                if let account = switching { Task { await model.connect(slug, reconnect: account) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes uses the \(app.name) account you signed in to last. Sign in to this one again in the browser and Hermes switches to it.")
        }
        .alert("Add Another Account", isPresented: $addingAccount) {
            TextField("work", text: $anotherAlias)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button("Continue") {
                Task { await model.connect(slug, alias: Self.alias(anotherAlias)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Name it so you can pick it in a chat. Then sign in to the other \(app.name) account in the browser.")
        }
    }

    /// Aliases are lower case with dashes (`^[a-z0-9][a-z0-9-]{0,31}$`).
    static func alias(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32))
    }

    @ViewBuilder
    private func accounts(_ app: AppsAndToolsModel.ConnectedApp) -> some View {
        Section {
            ForEach(app.accounts) { account in
                AccountRow(account: account, app: app, isBusy: model.isBusy("account:\(account.id)")) { action in
                    switch action {
                    case .rename:
                        newAlias = account.alias ?? ""
                        renaming = account
                    case .use:
                        switching = account
                    case .signInAgain:
                        Task { await model.connect(slug, reconnect: account) }
                    case .remove:
                        removing = account
                    }
                }
            }
            if !app.needsAttention {
                Button {
                    anotherAlias = ""
                    addingAccount = true
                } label: {
                    Group {
                        if model.signingIn == slug { Spinner() } else { Text("Add Another Account") }
                    }
                    .underRowNames(42)
                }
                .disabled(model.signingIn != nil)
            }
        } header: {
            SectionHeading(title: String(localized: "Accounts"))
        } footer: {
            if app.accounts.count > 1 {
                Text("Hermes uses one account at a time; say \u{201C}use my \(app.accounts.compactMap(\.alias).last ?? "work") \(app.name)\u{201D} in a chat, or pick it here.")
            }
        }
    }

    @ViewBuilder
    private func tools(_ app: AppsAndToolsModel.ConnectedApp) -> some View {
        let tools = model.tools(of: slug)
        if !tools.isEmpty {
            Section {
                ForEach(showsAllTools ? tools : Array(tools.prefix(5))) { tool in
                    ToolSwitchRow(model: model, tool: tool, slug: slug)
                }
                if tools.count > 5 {
                    Button(showsAllTools ? String(localized: "Show Fewer") : String(localized: "Show All \(tools.count) Tools")) {
                        withAnimation(Theme.snappy) { showsAllTools.toggle() }
                    }
                }
            } header: {
                SectionHeading(title: String(localized: "Tools · \(model.allowedCount(of: slug)) of \(tools.count) allowed"))
            } footer: {
                Text("Hermes still asks before anything that writes, as set in Chat Permissions.")
            }
        } else if model.isBusy("tools:\(slug)") {
            Section("Tools") { SkeletonRows(count: 3, twoLines: false) }
        }
    }
}

/// Logo, name and what the app does.
private struct AppHeader: View {
    let app: AppsAndToolsModel.ConnectedApp

    var body: some View {
        VStack(spacing: 8) {
            AppLogo(name: app.name, url: app.logoURL, size: 60)
            Text(app.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
            if !app.description.isEmpty {
                Text(app.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Hermes was signed out (`appExpired`): what stopped and when, then Sign In Again.
private struct ExpiredCard: View {
    let model: AppsAndToolsModel
    let app: AppsAndToolsModel.ConnectedApp
    let account: ConnectorAccount

    private var when: String {
        guard let date = account.updatedAt else { return "" }
        return String(localized: "On \(date.formatted(.dateTime.day().month(.wide))). ")
    }

    var body: some View {
        let reason = account.statusReason ?? String(localized: "\(app.name) signed Hermes out")
        let tools = app.toolCount.map { $0 == 1 ? String(localized: "1 tool") : String(localized: "\($0) tools") } ?? String(localized: "tools")
        AttentionCard(
            tone: .warning,
            title: reason,
            detail: when + String(localized: "Hermes can't use \(app.name)'s \(tools) until you sign in again; chats that need it will ask.")
        ) {
            InkButton(title: String(localized: "Sign In Again"), isWorking: model.signingIn == app.id) {
                Task { await model.connect(app.id, reconnect: account) }
            }
        }
    }
}

/// One account (`accountRow*`) with its … menu (`accountMenu`).
struct AccountRow: View {
    enum Action { case use, rename, signInAgain, remove }

    let account: ConnectorAccount
    let app: AppsAndToolsModel.ConnectedApp
    var isBusy = false
    let perform: (Action) -> Void

    private var subtitle: String {
        if account.status.needsAttention, let date = account.updatedAt {
            return String(localized: "Signed out \(date.formatted(.dateTime.day().month(.abbreviated)))")
        }
        var parts: [String] = []
        if let alias = account.alias { parts.append(alias) }
        if account.active, app.accounts.count > 1 { parts.append(String(localized: "Hermes uses this one")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceRaised, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(account.label).foregroundStyle(Theme.primaryText)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isBusy {
                Spinner()
            } else {
                statusTag
            }
            Menu {
                // Checked on the account Hermes uses; choosing another one signs in to it again.
                if app.accounts.count > 1, !account.disabled {
                    Toggle("Use This Account", isOn: Binding(get: { account.active }, set: { if $0 { perform(.use) } }))
                }
                Button("Rename…", systemImage: "pencil") { perform(.rename) }
                Button("Sign In Again", systemImage: "arrow.clockwise") { perform(.signInAgain) }
                Divider()
                Button("Remove Account…", systemImage: "trash", role: .destructive) { perform(.remove) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Account options for \(account.label)")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusTag: some View {
        switch account.status {
        case .active: TagLabel(title: String(localized: "Active"), style: .success)
        case .expired, .revoked: TagLabel(title: String(localized: "Expired"), style: .warning)
        case .failed: TagLabel(title: String(localized: "Failed"), style: .danger)
        case .pending: TagLabel(title: String(localized: "Pending"))
        case .inactive: TagLabel(title: String(localized: "Inactive"))
        }
    }
}

/// One tool with its kind and a switch (`toolRow*`). Blocked by the organization: locked.
struct ToolSwitchRow: View {
    let model: AppsAndToolsModel
    let tool: ConnectorTool
    let slug: String

    var body: some View {
        let locked = model.isLocked(tool, of: slug)
        Toggle(isOn: Binding(
            get: { model.allows(tool, of: slug) },
            set: { allowed in Task { await model.setTool(tool, of: slug, allowed: allowed) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name).foregroundStyle(Theme.primaryText)
                    ToolKindTag(facet: tool.facet)
                }
                if locked {
                    Label("Turned off by your organization", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                } else if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
        
        .disabled(locked || model.isBusy("tool:\(tool.slug)"))
    }
}
