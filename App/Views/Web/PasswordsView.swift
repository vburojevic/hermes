import HermesKit
import SwiftUI

/// Settings → Hermes on <gateway> → Passwords: "Hermes vault and 1Password · 50 logins". The page
/// it opens shares this row's model, made when Settings opens and dropped with it.
struct PasswordsSettingsRow: View {
    let workspace: BotWorkspace
    @State private var model: PasswordsModel?

    var body: some View {
        NavigationLink {
            if let model { PasswordsView(model: model).settingsPage(back: String(localized: "Back")) }
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: "key.fill", ink: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passwords").foregroundStyle(Theme.primaryText)
                    Text(model?.summary ?? String(localized: "Logins Hermes can use"))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .onAppear {
            if model == nil {
                let created = PasswordsModel(workspace: workspace)
                model = created
                Task { await created.load() }
            }
        }
        .onChange(of: workspace.roster?.isConnected) {
            if let model, model.isOnline, !model.hasLoaded { Task { await model.load() } }
        }
        .accessibilityHint("Where Hermes finds logins, cards and addresses")
    }
}

/// Passwords (`passwordsPage`, `passwordsPageMore`; iPad landscape `ipadPasswords`): sources,
/// then the logins, cards and addresses Hermes can fill, then Add and Lock All. Two columns when
/// there's room (an iPad in landscape), else a detail pushes in.
struct PasswordsView: View {
    let model: PasswordsModel
    @State private var width: CGFloat = 0
    @State private var selection: VaultItem.ID?
    @State private var adding: VaultItem.Kind?
    @State private var unlocking: VaultSource?
    /// A detail opened by `-HERMES_PASSWORDS item:<id>` on a narrow page.
    @State private var pushed: VaultItem?

    private var isTwoColumn: Bool { width >= 760 }

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .navigationTitle("Passwords")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                if !model.hasLoaded { await model.load() }
                openDebugRoute()
            }
            .navigationDestination(item: $pushed) { item in
                PasswordDetailView(model: model, item: item)
            }
            .onChange(of: model.workspace.roster?.isConnected) {
                if model.isOnline { Task { await model.load() } }
            }
            // Two columns never leave the right one empty while there's something to show.
            .onChange(of: model.items, initial: true) { selectFirstIfNeeded() }
            .onChange(of: isTwoColumn) { selectFirstIfNeeded() }
            .sheet(item: $adding) { kind in
                PasswordAddSheet(model: model, kind: kind)
            }
            .sheet(item: $unlocking) { source in
                VaultUnlockSheet(model: model, source: source)
            }
            .alert(String(localized: "Passwords"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
    }

    private func selectFirstIfNeeded() {
        guard isTwoColumn, !model.items.contains(where: { $0.id == selection }) else { return }
        selection = (model.logins + model.cards + model.addresses).first?.id
    }

    private func openDebugRoute() {
        switch PasswordsDebugRoute.current {
        case .add(let kind)?: adding = kind
        case .unlock(let name)?: unlocking = model.source(named: name)
        case .item(let id)?:
            if isTwoColumn { selection = id } else { pushed = model.items.first { $0.id == id } }
        case nil: break
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.needsBotMode || model.workspace.botModeIsDown {
            BotModeSetupMessage(workspace: model.workspace, feature: GatewaySetup.ID.passwords, title: String(localized: "Passwords"), symbol: "key")
        } else if model.needsNewerHermes {
            SetupMessage(status: model.newerHermesStatus, symbol: "key",
                         check: { await model.load() })
        } else if isTwoColumn {
            HStack(spacing: 0) {
                list.frame(width: 440)
                Divider()
                Group {
                    if let item = model.items.first(where: { $0.id == selection }) {
                        PasswordDetailView(model: model, item: item, setsTitle: false)
                    } else {
                        ContentUnavailableView("Choose a login", systemImage: "key", description: Text("What Hermes knows about it shows here."))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            list
        }
    }

    private var list: some View {
        Form {
            Section {
                Label {
                    Text("Logins Hermes can use on \(model.gatewayName)")
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

            if !model.hasLoaded {
                Section {
                    if let error = model.loadError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(Theme.secondaryText)
                            Button("Try Again") { Task { await model.load() } }
                        }
                    } else if model.isOnline {
                        SkeletonRows(count: 3)
                    } else {
                        Text("Passwords show when \(model.gatewayName) is online.")
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                sources
                items
                actions
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .refreshable { await model.load() }
        #endif
    }

    // MARK: Sources

    private var sources: some View {
        Section {
            ForEach(model.sources) { source in
                VaultSourceRow(source: source, itemCount: model.items(in: source).count, gatewayName: model.gatewayName,
                               isBusy: model.busySources.contains(source.name),
                               onUnlock: { unlocking = source },
                               onLock: { Task { await model.lock(source) } },
                               onEnable: { on in Task { await model.setEnabled(source, on) } })
            }
        } header: {
            Text("Sources")
        } footer: {
            if model.hasManagers {
                Text("When Hermes needs a login from a locked manager, it asks for the master password in the chat. That goes straight to the manager; only a session token stays, for 30 minutes idle at most.")
            }
        }
    }

    // MARK: Items

    @ViewBuilder
    private var items: some View {
        Section {
            VaultSearchField(text: Bindable(model).search, prompt: String(localized: "Search \(VaultSummary.logins(model.loginCount))"))
            if model.logins.isEmpty {
                Text(model.search.isEmpty ? String(localized: "No logins yet. Add one, or Hermes asks to save one the first time it reaches a sign-in page.") : String(localized: "No logins match."))
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.logins) { row($0) }
        } header: {
            Text("Logins · \(model.logins.count)")
        }
        if !model.cards.isEmpty {
            Section {
                ForEach(model.cards) { row($0) }
            } header: {
                Text("Payment cards · \(model.cards.count)")
            } footer: {
                Text("Filling a card is always a request in the chat: the card, the page, and Fill Card or Don't Fill. Every time.")
            }
        }
        if !model.addresses.isEmpty {
            Section {
                ForEach(model.addresses) { row($0) }
            } header: {
                Text("Addresses · \(model.addresses.count)")
            }
        }
    }

    @ViewBuilder
    private func row(_ item: VaultItem) -> some View {
        let label = VaultItemRow(item: item, sourceName: model.sourceName(of: item))
        if isTwoColumn {
            Button { selection = item.id } label: {
                HStack {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selection == item.id ? Theme.surfaceRaised : nil)
        } else {
            NavigationLink {
                PasswordDetailView(model: model, item: item).settingsPage(back: String(localized: "Passwords"))
            } label: {
                label
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        Section {
            Button("Add Login…") { adding = .login }
            Button("Add Card…") { adding = .payment }
            Button("Add Address…") { adding = .address }
        }
        if model.hasManagers {
            Section {
                Button("Lock All Password Managers") { Task { await model.lockAll() } }
                    .foregroundStyle(Theme.primaryText)
                    .disabled(!model.hasUnlockedManagers)
            } footer: {
                Text("Hermes asks for a master password again the next time it needs a login.")
            }
        }
        Section {
            NeverSeesNote()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
    }
}

// MARK: - Rows

/// `sourceRow` and its states: the Hermes vault, Unlocked (Lock), Locked (Unlock), Off (a
/// switch), and not on the gateway (dimmed, with the CLI to install).
struct VaultSourceRow: View {
    let source: VaultSource
    let itemCount: Int
    let gatewayName: String
    var isBusy = false
    var onUnlock: () -> Void = {}
    var onLock: () -> Void = {}
    var onEnable: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName).foregroundStyle(Theme.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            trailing
        }
        .opacity(source.state == .notInstalled ? 0.5 : 1)
        .contextMenu {
            if source.state == .unlocked || source.state == .locked {
                Button("Turn Off \(source.displayName)", systemImage: "nosign") { onEnable(false) }
            }
        }
    }

    @ViewBuilder
    private var tile: some View {
        if source.state == .vault {
            GlyphTile(symbol: "key.fill", ink: true, size: 32)
        } else {
            AppLogo(name: source.displayName, size: 32)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            Spinner()
        } else {
            switch source.state {
            case .unlocked:
                Button("Lock", action: onLock)
                    .cardButton()
                    .controlSize(.small)
                    .accessibilityLabel("Lock \(source.displayName)")
            case .locked:
                Button("Unlock", action: onUnlock)
                    .cardButton()
                    .controlSize(.small)
                    .accessibilityLabel("Unlock \(source.displayName)")
            case .off:
                Toggle("Use \(source.displayName)", isOn: Binding(get: { false }, set: { onEnable($0) }))
                    .labelsHidden()
            case .vault, .notInstalled:
                EmptyView()
            }
        }
    }

    /// "Unlocked · locks after 30 min idle · 41 logins".
    private var detail: String {
        switch source.state {
        case .vault: String(localized: "Encrypted on \(gatewayName) · \(VaultSummary.items(itemCount))")
        case .unlocked: String(localized: "Unlocked · locks after 30 min idle · \(VaultSummary.logins(itemCount))")
        case .locked: String(localized: "Locked · Hermes asks when it needs a login")
        case .off: String(localized: "Off · Hermes doesn't use it")
        case .notInstalled:
            String(localized: "Not on \(gatewayName) · install the \(source.displayName) CLI (\(source.cli ?? source.name))")
        }
    }
}

/// `loginRow`, `cardRow`, `addressRow`: the site's letter on white, the name (with 2FA), what
/// Hermes types and where, and the source as a tag. VoiceOver: "GitHub, sam-k, in 1Password, 2FA".
struct VaultItemRow: View {
    let item: VaultItem
    let sourceName: String
    var showsSourceTag = true

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if item.hasOneTimeCodes {
                        TagLabel(title: String(localized: "2FA"), symbol: "number.square")
                    }
                }
                Text(secondLine)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if showsSourceTag {
                TagLabel(title: sourceName)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var tile: some View {
        switch item.kind {
        case .login: AppLogo(name: item.label, size: 32)
        case .payment: GlyphTile(symbol: "creditcard", size: 32)
        case .address: GlyphTile(symbol: "house", size: 32)
        }
    }

    /// "sam-k · github.com"; a card or address says its site.
    private var secondLine: String {
        let site = item.site
        switch item.kind {
        case .login:
            return [item.identifier, site].compactMap { $0 }.joined(separator: " · ")
        case .payment, .address:
            return site.map { String(localized: "For \($0)") } ?? String(localized: "No site, so Hermes can't fill it")
        }
    }

    private var accessibilityText: String {
        var parts = [item.label]
        if let identifier = item.identifier { parts.append(identifier) }
        if item.kind != .login, let site = item.site { parts.append(String(localized: "for \(site)")) }
        parts.append(String(localized: "in \(sourceName)"))
        if item.hasOneTimeCodes { parts.append(String(localized: "2FA")) }
        return parts.joined(separator: ", ")
    }
}

/// The promise (`neverSees`), under Passwords and each login.
struct NeverSeesNote: View {
    var body: some View {
        Label {
            Text("Hermes never sees a password. The gateway fills it into the site it belongs to, and only there.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(Theme.success)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Search over names and sites, at the top of Logins (`passwordsPage`).
struct VaultSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
    }
}
