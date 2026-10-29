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
    /// The connection check in flight; Cancel stops it before anything is saved.
    @State private var submitTask: Task<Void, Never>?
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
        return editingBot != nil || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isInsecure: Bool {
        guard let url = normalizedURL else { return false }
        return url.scheme == "http" && !BotConfiguration.looksLocal(url.host() ?? "")
    }

    var body: some View {
        Form {
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
                TextField("Backend", text: $backendAddress, prompt: Text("127.0.0.1:9119"))
                    .focused($focusedField, equals: .backend)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Sign in", selection: $signIn) {
                    #if os(macOS)
                    Text("Automatic (this Mac)").tag(BackendLink.SignIn.automatic)
                    #else
                    Text("Automatic").tag(BackendLink.SignIn.automatic)
                    #endif
                    Text("Session token").tag(BackendLink.SignIn.token)
                    Text("Username & password").tag(BackendLink.SignIn.password)
                }
                switch signIn {
                case .automatic:
                    EmptyView()
                case .token:
                    SecureField("Session token", text: $backendToken, prompt: Text(keepsBackendCredentialPrompt))
                        .focused($focusedField, equals: .backendSecret)
                        .autocorrectionDisabled()
                case .password:
                    TextField("Username", text: $backendUsername, prompt: Text("admin"))
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $backendPassword, prompt: Text(keepsBackendCredentialPrompt))
                        .focused($focusedField, equals: .backendSecret)
                        .textContentType(.password)
                        .onSubmit(submit)
                }
            }
        } header: {
            Text("Bots")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bot Mode shows the Bots on your Hermes backend (`hermes serve`, the server Hermes Desktop uses): each with a face, one forever chat, @mentions and routines.")
                if botMode {
                    switch signIn {
                    case .automatic:
                        Text("Reads the session token from a backend on the same machine, like Hermes Desktop does. For another computer, use a token or a password.")
                    case .token:
                        Text("The token the backend was started with: `HERMES_DASHBOARD_SESSION_TOKEN=<token> hermes serve`. Without it, the token changes every time it starts.")
                    case .password:
                        Text("The dashboard login of a backend started with a password: `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `…_PASSWORD` and `…_SECRET` in `~/.hermes/.env`.")
                    }
                    if let url = backendURL, url.scheme == "http", !BotConfiguration.looksLocal(url.host() ?? "") {
                        Label("Plain HTTP over the internet sends your sign-in unencrypted. Use HTTPS or a private network.", systemImage: "exclamationmark.shield")
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .onChange(of: botMode) { _, enabled in
            guard enabled, backendAddress.isEmpty, let gateway = normalizedURL,
                  let suggested = BackendLink.suggestedURL(forGateway: gateway)
            else { return }
            backendAddress = Self.shortAddress(suggested)
            let link = BackendLink(url: suggested, signIn: .automatic)
            signIn = link.isLoopback ? .automatic : .password
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
    }

    private func submit() {
        guard canSubmit, let url = normalizedURL else { return }
        focusedField = nil // reveal the result, which sits under the fields
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typedKey.isEmpty ? (editingBot.flatMap { app.apiKey(for: $0) } ?? "") : typedKey
        phase = .checking
        submitTask = Task {
            do {
                let result = try await AppModel.probe(baseURL: url, apiKey: key)
                let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? (result.agentName.map(Self.prettyName) ?? "Hermes")
                    : name.trimmingCharacters(in: .whitespaces)
                var detail = result.version.map { "Connected to Hermes \($0)" } ?? "Connected"

                var link: BackendLink?
                var credential: BackendCredential?
                if botMode, let backendURL {
                    let candidate = BackendLink(url: backendURL, signIn: signIn, username: signIn == .password ? backendUsername : nil)
                    let existing = keepsBackendCredential ? editingBot.flatMap { app.backendCredential(for: $0) } : nil
                    do {
                        let probe = try await AppModel.probeBackend(
                            url: backendURL, signIn: signIn, token: backendToken.trimmingCharacters(in: .whitespacesAndNewlines),
                            username: backendUsername, password: backendPassword, existing: existing
                        )
                        link = candidate
                        credential = keepsBackendCredential ? nil : probe.credential
                        detail += probe.botCount == 1 ? " · 1 Bot" : " · \(probe.botCount) Bots"
                    } catch {
                        phase = .failed(
                            String(localized: "Bot Mode: \(BotRoster.describe(error))"),
                            suggestion: String(localized: "Check that `hermes serve` (or Hermes Desktop) is running and reachable at \(backendURL.absoluteString).")
                        )
                        return
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
                    try app.updateBot(bot, apiKey: typedKey.isEmpty ? nil : typedKey, backendCredential: credential, editing: editingBot)
                } else {
                    added = try app.addBot(name: finalName, baseURL: url, apiKey: key, accent: accent, backend: link, backendCredential: credential)
                }
                try? await Task.sleep(for: .milliseconds(450))
                if let added, let onAdded {
                    onAdded(added)
                } else {
                    onDone()
                }
            } catch let error as HermesError {
                guard !Task.isCancelled else { return }
                phase = .failed(error.errorDescription ?? "Couldn't connect.", suggestion: error.recoverySuggestion)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription, suggestion: nil)
            }
        }
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
