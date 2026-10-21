import HermesKit
import SwiftUI

/// Settings → Hermes on <gateway> → Browser: "A clean browser on Studio Mac", the place new chats
/// use. The page it opens shares this row's model.
struct BrowserSettingsRow: View {
    let workspace: BotWorkspace
    @State private var model: BrowserSettingsModel?

    var body: some View {
        NavigationLink {
            if let model { BrowserSettingsView(model: model).settingsPage(back: String(localized: "Back")) }
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: "safari", ink: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browser").foregroundStyle(Theme.primaryText)
                    Text(model?.summary ?? String(localized: "Where Hermes browses"))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .onAppear {
            if model == nil {
                let created = BrowserSettingsModel(workspace: workspace)
                model = created
                Task { await created.load() }
            }
        }
        .onChange(of: workspace.roster?.isConnected) {
            if let model, model.isOnline, !model.hasLoaded { Task { await model.load() } }
        }
        .accessibilityHint("Where Hermes browses the web for new chats")
    }
}

/// The Browser page (`browserPage`, `browserPageMore`; Mac `macSettingsBrowser`): where Hermes
/// browses, then what it's using now, then the advanced switches. Everything applies to new chats.
struct BrowserSettingsView: View {
    let model: BrowserSettingsModel
    @State private var consenting = false
    @State private var choosingCloud = false
    /// The cloud provider when the provider sheet opened: only a save changes it.
    @State private var cloudBefore: String?

    var body: some View {
        content
            #if os(iOS)
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { if !model.hasLoaded { await model.load() } }
            .onChange(of: model.workspace.roster?.isConnected) {
                if model.isOnline { Task { await model.load() } }
            }
            .sheet(isPresented: $consenting) {
                BrowserProfileConsentSheet(gateway: model.gatewayName) {
                    model.recordConsent()
                    Task { await model.choose(.withYourLogins) }
                }
            }
            .sheet(isPresented: $choosingCloud, onDismiss: {
                Task {
                    await model.load()
                    // Cancel changes nothing; a saved provider becomes the place new chats use.
                    if let cloud = model.settings?.cloud, cloud != cloudBefore {
                        await model.choseCloud()
                    }
                }
            }) {
                ToolsetKeySheet(model: model.workspace.appsAndTools, toolset: BuiltInToolset(name: "browser"))
            }
            .alert(String(localized: "Browser"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(([model.message ?? ""] + model.connectNotes).joined(separator: "\n\n"))
            }
            .task {
                #if DEBUG
                if DebugFlags.browser == "consent" { consenting = true }
                #endif
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.needsBotMode || model.workspace.botModeIsDown {
            BotModeSetupMessage(workspace: model.workspace, feature: GatewaySetup.ID.browser, title: String(localized: "Browser"), symbol: "safari")
        } else {
            Form {
                Section {
                    Label {
                        Text("Where Hermes browses for \(model.gatewayName)")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    } icon: {
                        HermesMarkView(color: Theme.inkForeground)
                            .padding(4)
                            .frame(width: 20, height: 20)
                            .background(Theme.ink, in: Circle())
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
                if let settings = model.settings {
                    places(settings)
                    now(settings)
                    advanced(settings)
                } else if let error = model.loadError {
                    Section {
                        Text(error).foregroundStyle(Theme.secondaryText)
                        Button("Try Again") { Task { await model.load() } }
                    }
                } else {
                    Section { SkeletonRows(count: 4) }
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            .refreshable { await model.load() }
            #endif
        }
    }

    // MARK: Places

    private func places(_ settings: BrowserSettings) -> some View {
        Section {
            ForEach(BrowserPlace.allCases) { place in
                Button {
                    pick(place)
                } label: {
                    BrowserPlaceRow(place: place, gateway: model.gatewayName, isSelected: model.place == place,
                                    isBusy: model.busy.contains(place.id))
                }
                .buttonStyle(.plain)
                .disabled(!model.busy.isEmpty)
            }
        } header: {
            Text("Where Hermes browses")
        } footer: {
            Text("Applies to new chats. The chats you have open keep the browser they started with.")
        }
    }

    private func pick(_ place: BrowserPlace) {
        switch place {
        case .cloud where model.settings?.cloud != nil && model.place != .cloud:
            // A provider is set up already: it becomes the place. In use, the row changes provider.
            Task { await model.choseCloud() }
        case .cloud:
            cloudBefore = model.settings?.cloud
            choosingCloud = true
        case .withYourLogins where model.needsConsent(for: place):
            consenting = true
        default:
            Task { await model.choose(place) }
        }
    }

    // MARK: Now

    private func now(_ settings: BrowserSettings) -> some View {
        Section {
            if let place = model.place {
                LabeledContent("Using", value: BrowserCopy.summary(place, settings: settings, gateway: model.gatewayName))
            }
            if let browserUse = model.connection?.browserUse {
                LabeledContent("Engine") {
                    HStack(spacing: 6) {
                        if model.busy.contains("engine") { Spinner() }
                        Menu(browserUse ? String(localized: "Browser Use") : String(localized: "Built-in tools")) {
                            Button("Browser Use") { Task { await model.setBrowserUse(true) } }
                            Button("Built-in tools") { Task { await model.setBrowserUse(false) } }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                    }
                }
            }
            LabeledContent("Status", value: status)
        } header: {
            Text("Now")
        } footer: {
            if model.changedThisVisit {
                Text("New chats use this. The chats you have open keep the browser they started with.")
            } else if model.place != .window {
                Text("Hermes browses out of sight; you'll see each step in the chat.")
            }
        }
    }

    private var status: String {
        if let connection = model.connection, connection.connected {
            return String(localized: "Attached to the window at \(connection.address ?? "") until Hermes restarts")
        }
        return model.connection == nil ? String(localized: "Hermes didn't say") : String(localized: "Ready")
    }

    // MARK: Advanced

    private func advanced(_ settings: BrowserSettings) -> some View {
        Section {
            switchRow(String(localized: "Fast text-only browser"), detail: String(localized: "Lightpanda: quicker, but no screenshots"),
                      isOn: settings.fastTextOnly, busy: "fast") { on in await model.setFastTextOnly(on) }
            switchRow(String(localized: "Local browser for private addresses"), detail: String(localized: "Sites on your network open on \(model.gatewayName)"),
                      isOn: settings.localForPrivateAddresses, busy: "private") { on in await model.setLocalForPrivateAddresses(on) }
            switchRow(String(localized: "Record browser sessions"), detail: String(localized: "Saved as videos on \(model.gatewayName)"),
                      isOn: settings.recordSessions, busy: "record") { on in await model.setRecordSessions(on) }
            NavigationLink {
                BlockedSitesView(model: model).settingsPage(back: String(localized: "Browser"))
            } label: {
                HStack(spacing: 12) {
                    GlyphTile(symbol: "nosign", ink: true, size: 28)
                    Text("Blocked sites").foregroundStyle(Theme.primaryText)
                    Spacer()
                    Text(settings.blocklistEnabled ? "\(settings.blockedDomains.count)" : String(localized: "Off"))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Hermes never opens a blocked site, and always refuses addresses that would expose a key or a cloud server's metadata.")
        }
    }

    private func switchRow(_ title: String, detail: String, isOn: Bool, busy: String, set: @escaping (Bool) async -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in Task { await set(on) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .disabled(model.busy.contains(busy))
    }
}

/// `browserOption` (+ `Selected`): a place, what it means for the person's logins and whether
/// they can watch, and a check when it's the one in use.
struct BrowserPlaceRow: View {
    let place: BrowserPlace
    let gateway: String
    let isSelected: Bool
    var isBusy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GlyphTile(symbol: BrowserCopy.symbol(place), size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(BrowserCopy.title(place, gateway: gateway))
                    .foregroundStyle(Theme.primaryText)
                Text(BrowserCopy.detail(place, gateway: gateway))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    ForEach(BrowserCopy.tags(place, gateway: gateway), id: \.self) { tag in
                        TagLabel(title: tag)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isBusy {
                    Spinner()
                } else if place == .cloud, !isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.primaryText : Theme.tertiaryText)
                }
            }
            .frame(width: 24)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// `browserProfileConsent`: asked the first time someone picks "With your logins", in the desktop
/// app's words. Turning it off later deletes the copy.
struct BrowserProfileConsentSheet: View {
    let gateway: String
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 28))
                .foregroundStyle(Theme.primaryText)
                .accessibilityHidden(true)
            Text("Stay signed in to your sites.")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                line("doc.on.doc", String(localized: "Your cookies and logins are copied into a snapshot on \(gateway)."))
                line("eye.slash", String(localized: "Your own Chrome profile is never opened."))
                line("lock.shield", String(localized: "Nothing leaves \(gateway). Turning this off deletes the copy."))
                line("info.circle", String(localized: "Needs Chrome, Edge, Brave or Chromium as the default browser on \(gateway). Firefox and beta versions can't be used."))
            }
            CardFooter(secondary: String(localized: "Not Now"), onSecondary: { dismiss() }, primary: String(localized: "Use My Profile")) {
                dismiss()
                onUse()
            }
        }
        .padding(22)
        #if os(iOS)
        .presentationDetents([.height(440), .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 420)
        #endif
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22)
        }
    }
}

/// Blocked sites (`security.website_blocklist`): Hermes never opens them. The whole list is written
/// each time (a list in Hermes's config is replaced, never merged).
struct BlockedSitesView: View {
    let model: BrowserSettingsModel
    @State private var newSite = ""

    private var settings: BrowserSettings { model.settings ?? BrowserSettings() }

    var body: some View {
        Form {
            Section {
                Toggle("Block these sites", isOn: Binding(get: { settings.blocklistEnabled }, set: { on in
                    Task { await model.setBlocklist(enabled: on, domains: settings.blockedDomains) }
                }))
            } footer: {
                Text("A site blocks its subdomains too; *.example.com blocks only the subdomains.")
            }
            Section {
                ForEach(settings.blockedDomains, id: \.self) { domain in
                    HStack {
                        Text(domain).font(.body.monospaced())
                        Spacer()
                        Button {
                            remove(domain)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(domain)")
                    }
                }
                HStack {
                    TextField("Add a site", text: $newSite, prompt: Text(verbatim: "example.com"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(BrowserSettings.blockedDomain(newSite) == nil)
                }
            } header: {
                Text("Sites · \(settings.blockedDomains.count)")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("Blocked sites")
        #endif
        .disabled(model.busy.contains("blocklist"))
    }

    private func add() {
        guard let domain = BrowserSettings.blockedDomain(newSite) else { return }
        newSite = ""
        guard !settings.blockedDomains.contains(domain) else { return }
        Task { await model.setBlocklist(enabled: true, domains: settings.blockedDomains + [domain]) }
    }

    private func remove(_ domain: String) {
        Task { await model.setBlocklist(enabled: settings.blocklistEnabled, domains: settings.blockedDomains.filter { $0 != domain }) }
    }
}
