import HermesKit
import SwiftUI

/// Add or edit a Hermes gateway, checking the connection before saving.
struct BotEditorView: View {
    enum Mode: Equatable {
        case add
        case edit(BotConfiguration)
    }

    let mode: Mode
    /// Called instead of `onDone` once a new gateway is saved, so the window can show what's next.
    var onAdded: ((BotConfiguration) -> Void)?
    let onDone: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @State private var name = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var revealsKey = false
    @State private var accent = BotAccent.gold
    @State private var phase = Phase.idle
    @State private var confirmingDelete = false
    @State private var showsSetupHelp = false
    @State private var botMode = false
    @State private var backendAddress = ""
    @State private var signIn = BackendLink.SignIn.automatic
    @State private var backendToken = ""
    @State private var backendUsername = ""
    @State private var backendPassword = ""
    @State private var revealsBackendSecret = false
    /// What the backend address answered (`docs/setup.md` §4.1), nil until it has.
    @State private var backendCheck: BackendCheck?
    /// The address being checked right now, for the Checking row.
    @State private var checkingBackend: URL?
    /// Bumped by every check, so one that wakes to a newer address or a toggle gives up.
    @State private var backendCheckGeneration = 0
    /// Access settings on screen (`docs/connecting-and-voice.md` §11.1), and what checking them found.
    @State private var access = GatewayAccessDraft()
    @State private var importsCertificate = false
    @State private var accessCheck: AccessCheck?
    /// The access gateway's sign-in page is open (`docs/connecting-and-voice.md` §11.10).
    @State private var signsIn = false
    /// The address the browser sign-in on screen belongs to. Its cookies never go anywhere else,
    /// so a new address drops it.
    @State private var sessionAddress: URL?
    /// The connection check in flight; Cancel stops it before anything is saved.
    @State private var submitTask: Task<Void, Never>?
    /// The fields hold the saved gateway already. Coming back from the Access page appears the
    /// form again, and filling it again would drop what was changed there, a new sign-in included.
    @State private var populated = false
    @FocusState private var focusedField: Field?

    enum Field { case name, address, key, backend, backendSecret }

    enum Phase: Equatable {
        case idle
        case checking
        case failed(String, suggestion: String?)
        case connected(String)
    }

    private var editingBot: BotConfiguration? {
        if case .edit(let bot) = mode { bot } else { nil }
    }

    private var normalizedURL: URL? {
        BotConfiguration.normalizedURL(from: address)
    }

    private var backendURL: URL? {
        BackendLink.normalizedURL(from: backendAddress)
    }

    /// Whether the saved Bot Mode sign-in can be kept as it is.
    private var keepsBackendCredential: Bool {
        guard let link = editingBot?.backend else { return false }
        return link.url == backendURL && link.signIn == signIn && backendToken.isEmpty && backendPassword.isEmpty
    }

    private var canSubmit: Bool {
        guard normalizedURL != nil, phase != .checking else { return false }
        if botMode, backendURL == nil { return false }
        if access.method == .serviceToken,
           access.clientID.trimmingCharacters(in: .whitespaces).isEmpty || (access.typedSecret == nil && !access.hasSavedSecret) {
            return false
        }
        return editingBot != nil || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isInsecure: Bool {
        guard let url = normalizedURL else { return false }
        return url.scheme == "http" && !BotConfiguration.looksLocal(url.host() ?? "")
    }

    /// The host an access gateway answers for, named on the status card.
    private var accessHost: String {
        normalizedURL?.host() ?? ""
    }

    /// The gateway's name, as the status card says it.
    private var accessName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? editingBot?.name ?? "Hermes" : typed
    }

    var body: some View {
        Form {
            #if os(macOS)
            // The Mac shows Access inline, its status leading the sheet (`macAccess`).
            if let accessCheck {
                AccessStatusSection(
                    check: accessCheck, host: accessHost, name: accessName, checkAgain: checkAccess, settings: access,
                    importCertificate: { importsCertificate = true }, signIn: { signsIn = true }
                )
            }
            #endif

            Section {
                HStack(spacing: 14) {
                    BotAvatar(bot: BotConfiguration(name: name, baseURL: URL(string: "http://localhost")!, accent: accent.rawValue), size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(editingBot == nil ? "Connect a Hermes gateway" : "Edit gateway")
                            .font(.headline)
                        Text("Hermes Agent's API server, from `hermes gateway`.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            }

            #if os(iOS)
            if editingBot == nil {
                Section {
                    Button {
                        router?.sheet = .scanner
                    } label: {
                        Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("On a Mac running Hermes, choose Pair a Device from the gateway menu.")
                }
            }
            #endif

            Section {
                TextField("Address", text: $address, prompt: Text("mac-mini.local:8642 or https://…"))
                    .focused($focusedField, equals: .address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { focusedField = .key }
                HStack {
                    Group {
                        if revealsKey {
                            TextField("API key", text: $apiKey, prompt: Text(editingBot == nil ? "API_SERVER_KEY" : "Unchanged"))
                        } else {
                            SecureField("API key", text: $apiKey, prompt: Text(editingBot == nil ? "API_SERVER_KEY" : "Unchanged"))
                        }
                    }
                    .focused($focusedField, equals: .key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(submit)
                    Button {
                        revealsKey.toggle()
                    } label: {
                        Image(systemName: revealsKey ? "eye.slash" : "eye")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealsKey ? "Hide key" : "Show key")
                }
            } header: {
                Text("Connection")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let url = normalizedURL, !address.isEmpty {
                        Text("Connects to \(url.absoluteString)")
                    }
                    if isInsecure {
                        Label("Plain HTTP over the internet sends your key unencrypted. Use HTTPS or a private network such as Tailscale.", systemImage: "exclamationmark.shield")
                            .foregroundStyle(Theme.warning)
                    }
                }
            }

            #if os(macOS)
            GatewayAccessSections(draft: $access, signIn: { signsIn = true }) { importsCertificate = true }
            #else
            GatewayAccessRow(
                draft: $access, check: accessCheck, host: accessHost, gateway: normalizedURL, name: accessName,
                checkAgain: checkAccess
            )
            #endif

            botModeSection

            statusSection

            Section("Appearance") {
                TextField("Name", text: $name, prompt: Text("Hermes"))
                    .focused($focusedField, equals: .name)
                HStack(spacing: 12) {
                    ForEach(BotAccent.allCases) { option in
                        Button {
                            accent = option
                        } label: {
                            Circle()
                                .fill(option.color.gradient)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    if option == accent {
                                        Circle().strokeBorder(Theme.primaryText, lineWidth: 2).padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(option == accent ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                DisclosureGroup("Setting up the API server", isExpanded: $showsSetupHelp) {
                    SetupInstructions()
                }
            }

            if let bot = editingBot {
                Section {
                    Button("Remove Gateway", role: .destructive) {
                        confirmingDelete = true
                    }
                } footer: {
                    Text("Removes it from this device. Conversations stay on the gateway.")
                }
                .confirmationDialog("Remove \(bot.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) {
                        try? app.removeBot(bot.id)
                        onDone()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .certificateImport(isPresented: $importsCertificate, draft: $access)
        .accessSignIn(isPresented: $signsIn, gateway: normalizedURL, draft: $access, checkAgain: checkAccess)
        .onChange(of: access.session) { _, session in
            if session != nil, sessionAddress != normalizedURL { sessionAddress = normalizedURL }
        }
        .onChange(of: normalizedURL) { _, url in
            // The sign-in belongs to the address it was made for: a new one signs in again.
            if access.session != nil, url != sessionAddress { access.session = nil }
        }
        .navigationTitle(editingBot == nil ? "Add Gateway" : "Edit Gateway")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    submitTask?.cancel()
                    onDone()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if phase == .checking {
                    Spinner()
                } else {
                    Button(editingBot == nil ? "Connect" : "Save", action: submit)
                        .disabled(!canSubmit)
                }
            }
        }
        .onAppear(perform: populate)
        .onDisappear { submitTask?.cancel() }
        .onChange(of: address) { if case .failed = phase { phase = .idle } }
        .onChange(of: apiKey) { if case .failed = phase { phase = .idle } }
        .onChange(of: backendAddress) { if case .failed = phase { phase = .idle } }
        .onChange(of: backendPassword) { if case .failed = phase { phase = .idle } }
        .interactiveDismissDisabled(phase == .checking)
    }

    private var botModeSection: some View {
        Section {
            Toggle("Bot Mode", isOn: $botMode.animation(Theme.spring))
            if botMode {
                if let problem = backendProblem {
                    BotModeWarningCard(problem: problem, inset: true, check: { await checkBackend(debounce: false) })
                        .listRowSeparator(.hidden)
                }
                TextField("Backend", text: $backendAddress, prompt: Text("127.0.0.1:9119"))
                    .focused($focusedField, equals: .backend)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                if let checking = checkingBackend {
                    HStack(spacing: 10) {
                        Spinner()
                        Text("Checking \(BackendLink(url: checking, signIn: .automatic).displayAddress)…")
                            .foregroundStyle(Theme.secondaryText)
                    }
                } else if showsSignIn {
                    signInChoice
                    signInFields
                }
            }
        } header: {
            Text("Bots")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let footer = signInFooter {
                    Text(footer)
                } else {
                    Text("Bot Mode shows the Bots on your Hermes backend (`hermes serve`, the server Hermes Desktop uses): each with a face, one forever chat, @mentions and routines.")
                }
                if botMode, let url = backendURL, url.scheme == "http", !BotConfiguration.looksLocal(url.host() ?? "") {
                    Label("Plain HTTP over the internet sends your sign-in unencrypted. Use HTTPS or a private network.", systemImage: "exclamationmark.shield")
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .onChange(of: botMode) { _, enabled in
            guard enabled, backendAddress.isEmpty, let gateway = normalizedURL,
                  let suggested = BackendLink.suggestedURL(forGateway: gateway)
            else { return }
            // The sign-in waits for the check: a password only where the backend has one.
            backendAddress = Self.shortAddress(suggested)
            signIn = .automatic
        }
        // On the toggle and on every new address, a moment after typing stops.
        .task(id: botMode ? backendURL : nil) { await checkBackend(debounce: true) }
    }

    /// The sign-ins on offer: every one until the address answered, then only those it takes.
    private var offeredSignIns: [BackendLink.SignIn] {
        backendCheck?.offeredSignIns ?? BackendLink.SignIn.allCases
    }

    private var showsSignIn: Bool { !offeredSignIns.isEmpty }

    /// Why Bot Mode can't use the address on screen (`botModeNotBackend`, `botModeUnsupported`).
    private var backendProblem: BotModeWarning? {
        guard checkingBackend == nil, let backendCheck, let url = backendURL else { return nil }
        return BotModeWarning.check(backendCheck, address: BackendLink(url: url, signIn: .automatic).displayAddress)
    }

    /// The backend answered, needs a sign-in and has no password one.
    private var hasNoPassword: Bool {
        if case .backend(let signIns, _)? = backendCheck {
            return !signIns.contains(.password) && !signIns.contains(.automatic)
        }
        return false
    }

    private func signInTitle(_ option: BackendLink.SignIn) -> String {
        switch option {
        #if os(macOS)
        case .automatic: String(localized: "Automatic (this Mac)")
        case .password: String(localized: "Username & password")
        #else
        case .automatic: String(localized: "Automatic")
        case .password: String(localized: "Password")
        #endif
        case .token: String(localized: "Session token")
        }
    }

    @ViewBuilder
    private var signInChoice: some View {
        let offered = offeredSignIns
        #if os(macOS)
        Picker("Sign in", selection: $signIn) {
            ForEach(offered, id: \.self) { Text(signInTitle($0)).tag($0) }
        }
        if hasNoPassword {
            Text("This backend has no password sign-in.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        #else
        if offered.count == 1, let only = offered.first {
            VStack(alignment: .leading, spacing: 4) {
                Text(only == .token ? String(localized: "Signs in with a session token") : signInTitle(only))
                if hasNoPassword {
                    Text("This backend has no password sign-in.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
        } else if offered.count == 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in")
                Picker("Sign in", selection: $signIn) {
                    ForEach(offered, id: \.self) { Text(signInTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } else {
            Picker("Sign in", selection: $signIn) {
                ForEach(offered, id: \.self) { Text(signInTitle($0)).tag($0) }
            }
        }
        #endif
    }

    @ViewBuilder
    private var signInFields: some View {
        switch signIn {
        case .automatic:
            EmptyView()
        case .token:
            secretField(String(localized: "Session token"))
        case .password:
            TextField("Username", text: $backendUsername, prompt: Text("admin"))
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            secretField(String(localized: "Password"))
        }
    }

    /// The session token or password, with its eye.
    private func secretField(_ title: String) -> some View {
        let text = signIn == .token ? $backendToken : $backendPassword
        return HStack {
            Group {
                if revealsBackendSecret {
                    TextField(title, text: text, prompt: Text(keepsBackendCredentialPrompt))
                } else {
                    SecureField(title, text: text, prompt: Text(keepsBackendCredentialPrompt))
                }
            }
            .focused($focusedField, equals: .backendSecret)
            .textContentType(signIn == .password ? .password : nil)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit(submit)
            Button {
                revealsBackendSecret.toggle()
            } label: {
                Image(systemName: revealsBackendSecret ? "eye.slash" : "eye")
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealsBackendSecret ? String(localized: "Hide \(title)") : String(localized: "Show \(title)"))
        }
    }

    /// What the chosen sign-in needs, while the sign-in is on screen.
    private var signInFooter: LocalizedStringKey? {
        guard botMode, checkingBackend == nil, showsSignIn else { return nil }
        switch signIn {
        case .automatic:
            return "Reads the session token from a backend on the same machine, like Hermes Desktop does. For another computer, use a token or a password."
        case .token where hasNoPassword:
            return "Bot Mode uses this backend's session token, the value of `HERMES_DASHBOARD_SESSION_TOKEN` on the computer running it."
        case .token:
            return "The token the backend was started with: `HERMES_DASHBOARD_SESSION_TOKEN=<token> hermes serve`. Without it, the token changes every time it starts."
        case .password:
            return "The dashboard login of a backend started with a password: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `…_PASSWORD` and `…_SECRET` in `~/.hermes/.env`."
        }
    }

    /// Reads what the backend address is (`GET /api/status`) and offers only the sign-ins it
    /// takes. Through the Access settings on screen, like the connection check.
    private func checkBackend(debounce: Bool) async {
        backendCheckGeneration += 1
        let generation = backendCheckGeneration
        guard botMode, let url = backendURL else {
            backendCheck = nil
            checkingBackend = nil
            return
        }
        // Says Checking at once, so the sign-ins of the last address never stand for this one.
        checkingBackend = url
        if debounce {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        }
        guard generation == backendCheckGeneration else { return }
        if let result = await readBackend(url) {
            guard generation == backendCheckGeneration else { return }
            apply(result)
        }
        if generation == backendCheckGeneration { checkingBackend = nil }
    }

    /// The check itself, nil when cancelled.
    private func readBackend(_ url: URL) async -> BackendCheck? {
        let trial = normalizedURL.map(accessTrial(gateway:))
        do {
            return try await GatewayAccessRegistry.shared.trying(trial?.credentials, at: trial?.addresses ?? [url]) {
                try await BackendClient(baseURL: url, credential: nil).check()
            }
        } catch {
            return nil
        }
    }

    private func apply(_ result: BackendCheck) {
        withAnimation(Theme.spring) {
            backendCheck = result
            if let preferred = result.preferredSignIn(current: signIn) { signIn = preferred }
        }
    }

    private var keepsBackendCredentialPrompt: String {
        editingBot?.backend != nil ? String(localized: "Unchanged") : ""
    }

    /// `http://127.0.0.1:9119` → `127.0.0.1:9119`; HTTPS addresses stay as they are.
    static func shortAddress(_ url: URL) -> String {
        guard url.scheme == "http" else { return url.absoluteString }
        var text = url.host() ?? ""
        if let port = url.port { text += ":\(port)" }
        return text + url.path(percentEncoded: false)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .checking:
            Section {
                HStack(spacing: 10) {
                    Spinner()
                    Text("Checking the connection…")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        case .failed where accessCheck != nil:
            // The access gateway's refusal shows as its status card: on the Mac at the top of the
            // sheet, here under the fields with the Access row above it.
            #if os(iOS)
            if let accessCheck {
                AccessStatusSection(
                    check: accessCheck, host: accessHost, name: accessName, checkAgain: checkAccess, settings: access,
                    importCertificate: { importsCertificate = true }, signIn: { signsIn = true }
                )
            }
            #endif
        case .failed(let message, let suggestion):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                    if let suggestion {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.vertical, 2)
            }
        case .connected(let detail):
            Section {
                Label(detail, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }
        }
    }

    private func populate() {
        guard !populated else { return }
        populated = true
        guard let bot = editingBot else {
            focusedField = .address
            return
        }
        name = bot.name
        address = bot.baseURL.absoluteString
        accent = BotAccent(rawValue: bot.accent) ?? .gold
        if let link = bot.backend {
            botMode = true
            backendAddress = Self.shortAddress(link.url)
            signIn = link.signIn
            backendUsername = link.username ?? ""
        }
        access = GatewayAccessDraft(
            bot.access, hasSavedSecret: app.accessSecret(for: bot) != nil, identity: app.clientIdentity(for: bot),
            session: app.accessSession(for: bot)
        )
        sessionAddress = bot.baseURL
    }

    /// What a check sends past the access gateway: the settings on screen, with the saved secret
    /// unless a new one was typed; and the addresses they go to.
    private func accessTrial(gateway url: URL) -> (credentials: GatewayAccessRegistry.Credentials?, addresses: [URL]) {
        let addresses = [url] + (botMode ? backendURL.map { [$0] } ?? [] : [])
        return (access.credentials(savedSecret: savedAccessSecret), addresses)
    }

    /// The saved service token secret, when no new one was typed.
    private var savedAccessSecret: String? {
        access.typedSecret == nil ? editingBot.flatMap { app.accessSecret(for: $0) } : nil
    }

    /// What a refusal or a pass says about the Access settings.
    private func noteAccess(_ error: (any Error)?) {
        if let refusal = (error as? HermesError)?.accessRefusal {
            accessCheck = .refused(refusal, host: accessHost)
        } else {
            accessCheck = error == nil && access.method != .none ? .passed : nil
        }
    }

    /// Check Again on the Access status card: checks the settings on screen, saving nothing.
    private func checkAccess() async {
        guard let url = normalizedURL else { return }
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typedKey.isEmpty ? (editingBot.flatMap { app.apiKey(for: $0) } ?? "") : typedKey
        let trial = accessTrial(gateway: url)
        do {
            _ = try await GatewayAccessRegistry.shared.trying(trial.credentials, at: trial.addresses) {
                try await AppModel.probe(baseURL: url, apiKey: key)
            }
            noteAccess(nil)
            if case .failed = phase { phase = .idle }
        } catch {
            noteAccess(error)
            if accessCheck == nil, let error = error as? HermesError {
                phase = .failed(error.errorDescription ?? "Couldn't connect.", suggestion: error.recoverySuggestion)
            }
        }
    }

    private func submit() {
        guard canSubmit, let url = normalizedURL else { return }
        focusedField = nil // reveal the result, which sits under the fields
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typedKey.isEmpty ? (editingBot.flatMap { app.apiKey(for: $0) } ?? "") : typedKey
        let trial = accessTrial(gateway: url)
        if access.method == .serviceToken, trial.credentials == nil {
            let problem = access.problem(savedSecret: savedAccessSecret)
            phase = .failed(problem ?? String(localized: "Check the service token in Access."), suggestion: nil)
            return
        }
        phase = .checking
        submitTask = Task {
            do {
                // Checked with the Access settings on screen, before anything is saved.
                let registry = GatewayAccessRegistry.shared
                let result = try await registry.trying(trial.credentials, at: trial.addresses) {
                    try await AppModel.probe(baseURL: url, apiKey: key)
                }
                noteAccess(nil)
                let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? (result.agentName.map(Self.prettyName) ?? "Hermes")
                    : name.trimmingCharacters(in: .whitespaces)
                var detail = result.version.map { "Connected to Hermes \($0)" } ?? "Connected"

                var link: BackendLink?
                var credential: BackendCredential?
                var botModeStop: BotModeStop?
                if botMode, let backendURL {
                    // Read again on Save: the address may have changed since. Save never waits on
                    // Bot Mode: an address or sign-in that can't work is saved as typed, and Bot
                    // Mode starts stopped instead of asking again (`docs/setup.md` §4.1).
                    backendCheckGeneration += 1
                    let generation = backendCheckGeneration
                    let typed = BackendLink(url: backendURL, signIn: signIn, username: signIn == .password ? backendUsername : nil)
                    let answer = await readBackend(backendURL)
                    guard !Task.isCancelled else { return }
                    let check = generation == backendCheckGeneration ? answer : nil
                    if let check { withAnimation(Theme.spring) { backendCheck = check } }
                    var save = BotModeSave(link: typed, typedToken: backendToken, check: check, signInRefused: false)
                    if save.stop == nil, check?.acceptsBotMode != false {
                        let existing = keepsBackendCredential ? editingBot.flatMap { app.backendCredential(for: $0) } : nil
                        do {
                            let probe = try await registry.trying(trial.credentials, at: trial.addresses) {
                                try await AppModel.probeBackend(
                                    url: backendURL, signIn: signIn, token: backendToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                    username: backendUsername, password: backendPassword, existing: existing
                                )
                            }
                            link = typed
                            credential = keepsBackendCredential ? nil : probe.credential
                            detail += probe.botCount == 1 ? " · 1 Bot" : " · \(probe.botCount) Bots"
                        } catch where Self.refusesSignIn(error) {
                            save = BotModeSave(link: typed, typedToken: backendToken, check: check, signInRefused: true)
                        } catch {
                            phase = .failed(
                                String(localized: "Bot Mode: \(BotRoster.describe(error))"),
                                suggestion: String(localized: "Check that `hermes serve` (or Hermes Desktop) is running and reachable at \(backendURL.absoluteString).")
                            )
                            return
                        }
                    }
                    if link == nil {
                        link = save.link
                        credential = keepsBackendCredential ? nil : save.credential
                        botModeStop = save.stop
                    }
                }
                // Cancelled while checking: the person backed out, so nothing is saved.
                guard !Task.isCancelled else { return }
                phase = .connected(detail)
                var added: BotConfiguration?
                if var bot = editingBot {
                    bot.name = finalName
                    bot.baseURL = url
                    bot.accent = accent.rawValue
                    bot.backend = link
                    bot.access = access.access
                    try app.updateBot(
                        bot, apiKey: typedKey.isEmpty ? nil : typedKey, backendCredential: credential,
                        accessSecret: access.typedSecret, certificate: access.identity,
                        accessSession: .set(access.savedSession), editing: editingBot, botModeStop: botModeStop
                    )
                } else {
                    added = try app.addBot(
                        name: finalName, baseURL: url, apiKey: key, accent: accent, backend: link, backendCredential: credential,
                        access: access.access, accessSecret: access.typedSecret, certificate: access.identity,
                        accessSession: access.savedSession
                    )
                    if let botModeStop, let added { app.workspaces[added.id]?.roster?.stayStopped(botModeStop) }
                }
                try? await Task.sleep(for: .milliseconds(450))
                if let added, let onAdded {
                    onAdded(added)
                } else {
                    onDone()
                }
            } catch let error as HermesError {
                guard !Task.isCancelled else { return }
                noteAccess(error)
                phase = .failed(error.errorDescription ?? "Couldn't connect.", suggestion: error.recoverySuggestion)
            } catch {
                guard !Task.isCancelled else { return }
                noteAccess(error)
                phase = .failed(error.localizedDescription, suggestion: nil)
            }
        }
    }

    /// The backend turned down the sign-in itself, rather than failing to answer.
    private static func refusesSignIn(_ error: any Error) -> Bool {
        if let failure = error as? BackendClient.Failure { return failure == .signInRequired || failure == .invalidCredentials }
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure { return reason.contains("sign-in") }
        return false
    }

    /// `hermes-agent` → `Hermes`, `research` → `Research`.
    static func prettyName(_ agent: String) -> String {
        agent == "hermes-agent" ? "Hermes" : agent.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

/// How to enable the API server on the machine running Hermes.
private struct SetupInstructions: View {
    @State private var generatedKey = Self.randomKey()
    @State private var copied = false

    private var snippet: String {
        """
        API_SERVER_ENABLED=true
        API_SERVER_KEY=\(generatedKey)
        API_SERVER_HOST=0.0.0.0
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Add this to `~/.hermes/.env` on the machine running Hermes:")
            Text(snippet)
                .font(Theme.Typography.code)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(radius: 10)
            HStack {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Pasteboard.copySecret(snippet)
                    copied = true
                }
                Button("New Key", systemImage: "arrow.triangle.2.circlepath") {
                    generatedKey = Self.randomKey()
                    copied = false
                }
            }
            .glassButton()
            .controlSize(.small)
            Text("2. Restart it with `hermes gateway restart` (or start it with `hermes gateway`).")
            Text("3. Enter the machine's address with port 8642 and the key above. `API_SERVER_HOST=0.0.0.0` lets other devices on your network connect; keep it on a trusted network or put HTTPS in front of it.")
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .padding(.vertical, 6)
    }

    static func randomKey() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<40).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
