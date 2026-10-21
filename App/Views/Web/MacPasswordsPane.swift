#if os(macOS)
import HermesKit
import SwiftUI

/// Settings → Passwords on the Mac (`macSettingsPasswords`): search, sources, logins, cards and
/// addresses on the left; the chosen one on the right. Add and Lock All sit under the list, since
/// a Settings tab has no toolbar of its own.
struct MacPasswordsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.currentWorkspace {
            MacPasswordsContent(workspace: workspace)
                .id(workspace.id)
        } else {
            ContentUnavailableView("No gateway", systemImage: "server.rack", description: Text("Add a gateway to see the logins Hermes can use."))
        }
    }
}

private struct MacPasswordsContent: View {
    @State private var model: PasswordsModel
    @State private var selection: VaultItem.ID?
    @State private var adding: VaultItem.Kind?
    @State private var unlocking: VaultSource?

    init(workspace: BotWorkspace) {
        _model = State(initialValue: PasswordsModel(workspace: workspace))
    }

    private var selected: VaultItem? { model.items.first { $0.id == selection } }

    var body: some View {
        Group {
            if model.needsBotMode || model.workspace.botModeIsDown {
                BotModeSetupMessage(workspace: model.workspace, feature: GatewaySetup.ID.passwords, title: String(localized: "Passwords"), symbol: "key")
            } else if model.needsNewerHermes {
                SetupMessage(status: model.newerHermesStatus, symbol: "key", check: { await model.load() })
            } else {
                HStack(alignment: .top, spacing: 16) {
                    sidebar
                        .frame(width: 290)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(20)
            }
        }
        .task {
            await model.load()
            switch PasswordsDebugRoute.current {
            case .add(let kind)?: adding = kind
            case .unlock(let name)?: unlocking = model.source(named: name)
            case .item(let id)?: selection = id
            case nil: break
            }
        }
        .onChange(of: model.workspace.roster?.isConnected) {
            if model.isOnline { Task { await model.load() } }
        }
        .onChange(of: model.items) {
            if selection == nil || selected == nil { selection = model.logins.first?.id }
        }
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            VaultSearchField(text: $model.search, prompt: String(localized: "Search \(VaultSummary.logins(model.loginCount))"))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(8)
            List(selection: $selection) {
                if !model.hasLoaded {
                    if let error = model.loadError {
                        Text(error).foregroundStyle(Theme.secondaryText)
                        Button("Try Again") { Task { await model.load() } }
                    } else {
                        SkeletonRows(count: 4)
                    }
                } else {
                    Section("Sources") {
                        ForEach(model.sources) { source in
                            MacSourceRow(source: source, count: model.items(in: source).count, gatewayName: model.gatewayName,
                                         isBusy: model.busySources.contains(source.name),
                                         onUnlock: { unlocking = source },
                                         onLock: { Task { await model.lock(source) } },
                                         onEnable: { on in Task { await model.setEnabled(source, on) } })
                                .selectionDisabled()
                        }
                    }
                    Section("Logins · \(model.logins.count)") {
                        ForEach(model.logins) { item in
                            VaultItemRow(item: item, sourceName: model.sourceName(of: item), showsSourceTag: false)
                                .tag(item.id)
                        }
                    }
                    if !model.cards.isEmpty || !model.addresses.isEmpty {
                        Section("Cards and addresses") {
                            ForEach(model.cards + model.addresses) { item in
                                VaultItemRow(item: item, sourceName: model.sourceName(of: item), showsSourceTag: false)
                                    .tag(item.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 10) {
                Menu {
                    Button("Add Login…") { adding = .login }
                    Button("Add Card…") { adding = .payment }
                    Button("Add Address…") { adding = .address }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Add")
                .disabled(!model.hasLoaded)
                Spacer()
                if model.hasManagers {
                    Button("Lock All") { Task { await model.lockAll() } }
                        .buttonStyle(.borderless)
                        .disabled(!model.hasUnlockedManagers)
                        .help("Lock All Password Managers: Hermes asks for a master password again the next time it needs a login.")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            PasswordDetailView(model: model, item: selected, setsTitle: false)
                .id(selected.id)
        } else if model.hasLoaded {
            VStack(spacing: 14) {
                ContentUnavailableView("Choose a login", systemImage: "key", description: Text("What Hermes knows about it shows here."))
                NeverSeesNote().frame(maxWidth: 360)
            }
        }
    }
}

/// A source in the Mac list: the state in a line, and a lock to lock or unlock it.
private struct MacSourceRow: View {
    let source: VaultSource
    let count: Int
    let gatewayName: String
    let isBusy: Bool
    let onUnlock: () -> Void
    let onLock: () -> Void
    let onEnable: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if source.state == .vault {
                GlyphTile(symbol: "key.fill", ink: true, size: 26)
            } else {
                AppLogo(name: source.displayName, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if isBusy {
                Spinner()
            } else {
                switch source.state {
                case .unlocked:
                    Button(action: onLock) { Image(systemName: "lock.open") }
                        .buttonStyle(.borderless)
                        .help("Lock \(source.displayName)")
                        .accessibilityLabel("Lock \(source.displayName)")
                case .locked:
                    Button(action: onUnlock) { Image(systemName: "lock.fill") }
                        .buttonStyle(.borderless)
                        .help("Unlock \(source.displayName)…")
                        .accessibilityLabel("Unlock \(source.displayName)")
                case .off:
                    Toggle("Use \(source.displayName)", isOn: Binding(get: { false }, set: { onEnable($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                case .vault, .notInstalled:
                    EmptyView()
                }
            }
        }
        .opacity(source.state == .notInstalled ? 0.5 : 1)
        .contextMenu {
            if source.state == .unlocked || source.state == .locked {
                Button("Turn Off \(source.displayName)") { onEnable(false) }
            }
        }
    }

    private var detail: String {
        switch source.state {
        case .vault: String(localized: "On \(gatewayName) · \(VaultSummary.items(count))")
        case .unlocked: String(localized: "Unlocked · \(VaultSummary.logins(count))")
        case .locked: String(localized: "Locked")
        case .off: String(localized: "Off")
        case .notInstalled: String(localized: "Not on \(gatewayName) · needs its CLI (\(source.cli ?? source.name))")
        }
    }
}
#endif
