import HermesKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A login, card or address (`passwordDetail`): what Hermes knows about it, never the password.
/// Hermes's vault items can be removed here; a manager's are edited in the manager.
struct PasswordDetailView: View {
    let model: PasswordsModel
    let item: VaultItem
    /// Pushed on its own, the page takes the item's name as its title; beside the list (iPad
    /// landscape, the Mac tab) the page keeps "Passwords".
    var setsTitle = true
    @State private var confirmingRemove = false
    @State private var isRemoving = false
    @Environment(\.dismiss) private var dismiss

    private var sourceName: String { model.sourceName(of: item) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    tile
                    Text(item.label)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.center)
                    if let site = item.site {
                        Text(site)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
            }

            Section {
                switch item.kind {
                case .login:
                    LabeledContent("Username", value: item.identifier ?? String(localized: "None"))
                        .textSelection(.enabled)
                    LabeledContent("Password", value: String(localized: "Hermes can't show it"))
                    LabeledContent("One-time codes", value: oneTimeCodes)
                case .payment:
                    LabeledContent("Card", value: String(localized: "Hermes can't show it"))
                    LabeledContent("Filling", value: String(localized: "Asks you every time"))
                case .address:
                    LabeledContent("Address", value: String(localized: "Hermes can't show it"))
                }
                LabeledContent("Fills on", value: item.fillsOn ?? String(localized: "No site, so Hermes can't fill it"))
            }

            Section {
                LabeledContent("Source", value: sourceName)
                // TODO(docs/web.md §9): Last Used, once `vault.list` says when.
                if let created = item.createdAt {
                    LabeledContent("Added", value: created.formatted(date: .abbreviated, time: .omitted))
                }
                #if os(macOS)
                if let app = ManagerApp(source: item.backend) {
                    Button("Open \(app.name)") { app.open() }
                }
                #endif
            } header: {
                Text("Where it lives")
            } footer: {
                if !item.isInHermesVault {
                    Text("Edit or delete it in \(sourceName). Changes show up here the next time Hermes reads it.")
                }
            }

            if item.isInHermesVault {
                Section {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        HStack {
                            Text("Remove from Hermes's Vault")
                                .foregroundStyle(Theme.danger)
                            if isRemoving { Spacer(); Spinner() }
                        }
                    }
                    .disabled(isRemoving)
                }
            }

            Section {
                NeverSeesNote()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(setsTitle ? item.label : String(localized: "Passwords"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(String(localized: "Remove \(item.label) from Hermes's vault?"), isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                isRemoving = true
                Task {
                    let removed = await model.remove(item)
                    isRemoving = false
                    if removed { dismiss() }
                }
            }
        } message: {
            Text(removalMessage)
        }
    }

    @ViewBuilder
    private var tile: some View {
        switch item.kind {
        case .login: AppLogo(name: item.label, size: 60)
        case .payment: GlyphTile(symbol: "creditcard", size: 60)
        case .address: GlyphTile(symbol: "house", size: 60)
        }
    }

    /// "From 1Password", "From your authenticator key", or Hermes asks.
    private var oneTimeCodes: String {
        guard item.hasOneTimeCodes else { return String(localized: "Hermes asks you for them") }
        return item.isInHermesVault ? String(localized: "From your authenticator key") : String(localized: "From \(sourceName)")
    }

    private var removalMessage: String {
        guard let site = item.site else { return String(localized: "It's deleted from Hermes's vault on \(model.gatewayName).") }
        switch item.kind {
        case .login: return String(localized: "Hermes can't sign in to \(site) with it anymore.")
        case .payment, .address: return String(localized: "Hermes can't fill it on \(site) anymore.")
        }
    }
}

#if os(macOS)
// TODO(docs/web.md §9): open the item itself once its id names the account and vault.
/// A password manager's app on this Mac, for Open 1Password. The gateway's item ids don't say
/// which account or vault an item is in, so the app opens, not the item.
struct ManagerApp {
    let name: String
    let url: URL

    init?(source: String) {
        let ids: [String: (String, String)] = [
            "onepassword": ("1Password", "com.1password.1password"),
            "bitwarden": ("Bitwarden", "com.bitwarden.desktop"),
        ]
        guard let (name, bundleID) = ids[source],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        self.name = name
        self.url = url
    }

    func open() {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
#endif

// MARK: - Add

/// Add Login, Add Card, Add Address (`passwordAdd`): written to Hermes's vault on the gateway with
/// `vault.add`, once, and never read back. The secret fields are cleared the moment the call goes
/// out; if it fails, they're typed again.
struct PasswordAddSheet: View {
    let model: PasswordsModel
    @State private var draft: VaultDraft
    @State private var error: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(model: PasswordsModel, kind: VaultItem.Kind) {
        self.model = model
        _draft = State(initialValue: VaultDraft(kind: kind))
    }

    private var title: String {
        switch draft.kind {
        case .login: String(localized: "Add Login")
        case .payment: String(localized: "Add Card")
        case .address: String(localized: "Add Address")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $draft.kind) {
                        Text("Login").tag(VaultItem.Kind.login)
                        Text("Card").tag(VaultItem.Kind.payment)
                        Text("Address").tag(VaultItem.Kind.address)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    field("Website", text: $draft.website, prompt: draft.kind == .login ? "github.com" : "amazon.com", url: true)
                    switch draft.kind {
                    case .login:
                        field("Username", text: $draft.username, prompt: String(localized: "Email or username"))
                        VaultSecretField(title: String(localized: "Password"), text: $draft.password)
                        field("Name", text: $draft.label, prompt: String(localized: "Optional"))
                        VaultSecretField(title: String(localized: "Authenticator key"), text: $draft.authenticatorKey,
                                    prompt: String(localized: "Optional: a key or otpauth:// link"))
                    case .payment:
                        field("Name", text: $draft.label, prompt: String(localized: "Personal Visa"))
                        VaultSecretField(title: String(localized: "Card number"), text: $draft.cardNumber, digits: true)
                        field("Name on card", text: $draft.nameOnCard, prompt: String(localized: "Optional"))
                        LabeledContent("Expiry") {
                            HStack(spacing: 6) {
                                TextField("Expiry month", text: $draft.expiryMonth, prompt: Text(verbatim: "MM"))
                                    .frame(maxWidth: 44)
                                Text(verbatim: "/").foregroundStyle(Theme.tertiaryText)
                                TextField("Expiry year", text: $draft.expiryYear, prompt: Text(verbatim: "YYYY"))
                                    .frame(maxWidth: 64)
                            }
                            .labelsHidden()
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        }
                        VaultSecretField(title: String(localized: "Security code"), text: $draft.securityCode, prompt: "CVC", digits: true)
                        field("Postal code", text: $draft.billingPostalCode, prompt: String(localized: "Optional"))
                    case .address:
                        field("Name", text: $draft.label, prompt: String(localized: "Home"))
                        field("Address", text: $draft.addressLine1, prompt: String(localized: "Street and number"))
                        field("Line 2", text: $draft.addressLine2, prompt: String(localized: "Optional"))
                        field("City", text: $draft.city, prompt: "")
                        field("State", text: $draft.state, prompt: String(localized: "Optional"))
                        field("Postal code", text: $draft.postalCode, prompt: "")
                        field("Country", text: $draft.country, prompt: String(localized: "United States"))
                    }
                } footer: {
                    Text(footer)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        Spinner()
                    } else {
                        Button("Save", systemImage: "checkmark", action: save)
                            .disabled(draft.problem != nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        #if os(macOS)
        .frame(width: 480, height: 540)
        #endif
    }

    /// "Saved encrypted on Studio Mac. Hermes fills it only on github.com and never sees it."
    private var footer: String {
        let site = VaultOrigin.normalize(draft.website).flatMap(VaultOrigin.site) ?? String(localized: "that site")
        switch draft.kind {
        case .login:
            return String(localized: "Saved encrypted in Hermes's vault on \(model.gatewayName). Hermes fills it only on \(site) and never sees it. With an authenticator key, it enters 2FA codes by itself.")
        case .payment:
            return String(localized: "Saved encrypted in Hermes's vault on \(model.gatewayName). Hermes sees the name, never the number, and asks you every time before it fills the card on \(site).")
        case .address:
            return String(localized: "Saved encrypted in Hermes's vault on \(model.gatewayName). Hermes fills it only on \(site).")
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, url: Bool = false, digits: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(url ? .never : .words)
                .keyboardType(url ? .URL : (digits ? .numberPad : .default))
                #endif
        }
    }

    private func save() {
        if let problem = draft.problem {
            error = VaultCopy.problem(problem, kind: draft.kind)
            return
        }
        // The only copy goes into the call; the fields that hold a secret are emptied now.
        let sending = draft
        draft.password = ""
        draft.authenticatorKey = ""
        draft.cardNumber = ""
        draft.securityCode = ""
        error = nil
        isSaving = true
        Task {
            let failure = await model.add(sending)
            isSaving = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}

/// A masked field with Show (`MaskedField`'s eye), for the Add sheet's form rows. Never filled
/// by the system's password AutoFill or offered for saving: what's typed goes to Hermes's vault.
private struct VaultSecretField: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var digits = false
    @State private var revealed = false
    /// Hidden again as the app leaves the screen, so the app switcher's picture never shows it.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Group {
                    if revealed, scenePhase == .active {
                        TextField(title, text: $text, prompt: Text(prompt))
                    } else {
                        SecureField(title, text: $text, prompt: Text(prompt))
                    }
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .privacySensitive()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(digits ? .numberPad : .default)
                #endif
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? String(localized: "Hide \(title)") : String(localized: "Show \(title)"))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }
}

// MARK: - Unlock

/// Unlock a password manager from Passwords (`passwordsUnlock`): the chat's unlock card as a
/// partial sheet. The master password goes straight to the manager's CLI on the gateway; the
/// field is emptied as it's sent.
struct VaultUnlockSheet: View {
    let model: PasswordsModel
    let source: VaultSource
    @State private var password = ""
    @State private var error: String?
    @State private var isUnlocking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RequestHeader(symbol: "lock.shield.fill", title: String(localized: "Unlock \(source.displayName)"),
                          subtitle: String(localized: "Hermes · \(model.gatewayName)"))
            Text("Hermes can use your \(source.displayName) logins, each only on its own site, until it locks: after 30 minutes idle, or when you lock it.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            MaskedField(placeholder: String(localized: "Master password"), text: $password, symbol: "lock", isPassword: true, allowsPaste: false, onSubmit: unlock)
                .privacySensitive()
                .disabled(isUnlocking)
            if isUnlocking {
                HStack(spacing: 8) {
                    Spinner()
                    Text("Unlocking \(source.displayName) on \(model.gatewayName)…")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FinePrint(text: String(localized: "Goes straight to \(source.displayName) on \(model.gatewayName). Only a session token stays there, until it locks."))
            CardFooter(secondary: String(localized: "Keep Locked"), onSecondary: { dismiss() },
                       primary: String(localized: "Unlock"), primaryEnabled: !password.isEmpty && !isUnlocking, onPrimary: unlock)
        }
        .padding(20)
        #if os(iOS)
        .presentationDetents([.height(400), .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 420)
        #endif
        .interactiveDismissDisabled(isUnlocking)
    }

    private func unlock() {
        guard !password.isEmpty, !isUnlocking else { return }
        let typed = password
        password = ""
        error = nil
        isUnlocking = true
        Task {
            let failure = await model.unlock(source, masterPassword: typed)
            isUnlocking = false
            if let failure {
                error = failure
            } else {
                dismiss()
            }
        }
    }
}
