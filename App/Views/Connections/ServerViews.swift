import HermesKit
import SwiftUI

// MARK: - MCP tab (`serversTab`)

struct ServersTabSections: View {
    let model: AppsAndToolsModel
    var addOnly = false
    @State private var adding = false

    var body: some View {
        Section {
            if let error = model.serversError, model.servers.isEmpty {
                Text(error).foregroundStyle(Theme.secondaryText)
            }
            if !addOnly {
                ForEach(model.servers) { server in
                    ServerRow(model: model, server: server)
                        .contentShape(Rectangle())
                        .onTapGesture { model.route = .server(server.name) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction(named: "Open") { model.route = .server(server.name) }
                }
            }
            Button {
                adding = true
            } label: {
                Text("Add MCP Server…")
                    .underRowNames()
            }
        } header: {
            if addOnly { SectionHeading(title: String(localized: "MCP Servers")) } else { countedHeader(String(localized: "MCP Servers"), model.servers.count) }
        } footer: {
            Text("MCP servers run on \(model.gatewayName). Turning one off removes its tools from new chats; open chats reload them.")
        }
        .sheet(isPresented: $adding) {
            AddServerSheet(model: model)
        }
    }
}

/// One MCP server (`serverRow*`): glyph, name in mono, its live state, a switch.
struct ServerRow: View {
    let model: AppsAndToolsModel
    let server: McpServer

    var body: some View {
        HStack(spacing: 12) {
            GlyphTile(symbol: server.usesURL ? "globe" : "terminal")
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.primaryText)
                ServerStatusLine(server: server)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy("server:\(server.name)") {
                ProgressView().controlSize(.small)
            }
            Toggle("On", isOn: Binding(
                get: { server.enabled },
                set: { on in Task { await model.setServer(server, enabled: on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(server.name), \(ServerStatusLine(server: server).text)")
    }
}

// MARK: - One MCP server (`serverFailed`)

struct ServerDetailView: View {
    let model: AppsAndToolsModel
    let name: String
    var macLayout = false

    @Environment(\.dismiss) private var dismiss
    @State private var editingKey = false
    @State private var confirmingRemove = false

    private var server: McpServer? { model.server(name) }

    var body: some View {
        Group {
            if let server {
                form(server)
            } else {
                ContentUnavailableView("MCP server removed", systemImage: "server.rack")
            }
        }
        .detailTitle(String(localized: "MCP Server"), shows: !macLayout)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func form(_ server: McpServer) -> some View {
        let test = model.serverTests[server.name]
        return Form {
            Section {
                VStack(spacing: 8) {
                    GlyphTile(symbol: server.usesURL ? "globe" : "terminal", size: 60)
                    Text(server.name)
                        .font(.title2.weight(.bold).monospaced())
                        .foregroundStyle(Theme.primaryText)
                    Text(server.isFromPlugin ? String(localized: "MCP server · from the \(server.plugin ?? "") plugin")
                         : (server.usesURL ? String(localized: "MCP server · URL") : String(localized: "MCP server · command")))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            if server.enabled, server.status == .failed || test?.ok == false {
                Section {
                    AttentionCard(
                        tone: .danger,
                        title: String(localized: "Couldn't connect"),
                        detail: test.map { _ in "" } ?? String(localized: "Testing to find out why…"),
                        mono: test?.error.map { "\($0)\n(last tried \(test.map { $0.testedAt.formatted(.relative(presentation: .named)) } ?? ""))" }
                    ) {
                        if server.isFromPlugin {
                            InkButton(title: String(localized: "Test Again"), isWorking: model.isBusy("server:\(server.name)")) {
                                Task { await model.test(server.name) }
                            }
                        } else if test?.oauthNeeded == true || server.auth == "oauth" {
                            PairedButtons(secondary: String(localized: "Test Again"), onSecondary: { Task { await model.test(server.name) } },
                                          primary: String(localized: "Sign In")) {
                                Task { _ = await model.signIn(server.name) }
                            }
                        } else {
                            PairedButtons(secondary: String(localized: "Update API Key"), onSecondary: { editingKey = true },
                                          primary: String(localized: "Test Again"), primaryEnabled: !model.isBusy("server:\(server.name)")) {
                                Task { await model.test(server.name) }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else if let test, test.ok {
                Section {
                    TestResultRow(result: test, gateway: model.gatewayName)
                }
            }
            Section {
                LabeledContent("Connects by", value: server.usesURL ? String(localized: "URL") : String(localized: "Command"))
                LabeledContent(server.usesURL ? String(localized: "Address") : String(localized: "Command")) {
                    Text(server.address)
                        .font(.footnote.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ForEach(server.envKeys, id: \.self) { key in
                    Button {
                        if !server.isFromPlugin { editingKey = true }
                    } label: {
                        LabeledContent(String(localized: "API key")) {
                            // Never the value: its name, and that it's set.
                            Text("\(key) ••••")
                                .font(.footnote.monospaced())
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(server.isFromPlugin ? "" : "Replaces the key")
                }
                if server.auth == "oauth" {
                    LabeledContent("Sign-in", value: server.oauthTokensPresent == true ? String(localized: "Signed in") : String(localized: "Not signed in"))
                }
                Toggle("On", isOn: Binding(
                    get: { server.enabled },
                    set: { on in Task { await model.setServer(server, enabled: on) } }
                ))
                .toggleStyle(.switch)
            } header: {
                SectionHeading(title: String(localized: "Setup"))
            } footer: {
                if !server.envKeys.isEmpty {
                    Text("The key is stored in \(model.gatewayName)'s .env; the app never sees it after you save it.")
                }
            }
            if !server.isFromPlugin {
                Section {
                    DestructiveRowButton(title: String(localized: "Remove MCP Server")) { confirmingRemove = true }
                }
            } else {
                Section {
                    Text("This MCP server comes with the \(server.plugin ?? "") plugin. Turn it off here, or remove the plugin.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: server.status) { await model.testIfFailed(server) }
        .sheet(isPresented: $editingKey) {
            APIKeySheet(model: model, server: server)
        }
        .alert("Remove \(server.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.remove(server)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes loses its tools on \(model.gatewayName). Open chats reload theirs.")
        }
    }
}

/// "Connected · 22 tools · Tested on Studio Mac just now".
struct TestResultRow: View {
    let result: McpTestResult
    let gateway: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.ok ? "checkmark" : "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(result.ok ? Theme.success : Theme.danger)
                .frame(width: 30, height: 30)
                .background(result.ok ? Theme.successTint : Theme.dangerTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.ok
                     ? (result.tools.count == 1 ? String(localized: "Connected · 1 tool") : String(localized: "Connected · \(result.tools.count) tools"))
                     : String(localized: "Couldn't connect"))
                    .foregroundStyle(Theme.primaryText)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Tested on \(gateway) \(result.testedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                if !result.ok, let error = result.error {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Replaces a server's key. Write-only: the field starts empty and nothing is read back.
struct APIKeySheet: View {
    let model: AppsAndToolsModel
    let server: McpServer
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    private var envVar: String? { server.envKeys.first }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecretField(label: envVar ?? String(localized: "API key"), value: $value, autofocus: true)
                } footer: {
                    Text("Stored in \(model.gatewayName)'s .env. The app never sees it again, and Hermes tests the MCP server with it right away.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Update API Key")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let key = value
                        value = ""
                        dismiss()
                        Task { await model.setKey(key, for: server, envVar: envVar) }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 220)
        #endif
    }
}

/// A secret: its env name and a masked field with an eye. Never pre-filled.
struct SecretField: View {
    let label: String
    @Binding var value: String
    /// Takes the keyboard when it appears (a sheet that asks only for this).
    var autofocus = false
    @State private var reveals = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .layoutPriority(1)
            Group {
                if reveals {
                    TextField("value", text: $value)
                } else {
                    SecureField("value", text: $value)
                }
            }
            .textContentType(.password)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { if autofocus { focused = true } }
            Button {
                reveals.toggle()
            } label: {
                Image(systemName: reveals ? "eye" : "eye.slash")
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveals ? "Hide" : "Show")
        }
    }
}

// MARK: - Add MCP Server (`addServer`)

/// Full-height sheet: catalog presets or a custom MCP server. ✓ adds it, and only after a test passed.
struct AddServerSheet: View {
    let model: AppsAndToolsModel

    enum Mode: String, CaseIterable { case command, url }

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var preset: McpPreset?
    @State private var mode = Mode.command
    @State private var name = ""
    @State private var address = ""
    @State private var keyName = ""
    @State private var keys: [String: String] = [:]
    /// Added on the gateway by a test, so Cancel removes it again.
    @State private var addedName: String?
    @State private var result: McpTestResult?
    @State private var isTesting = false
    @State private var isSigningIn = false

    private var suggestions: [McpPreset] {
        model.presets.filter { !$0.installed && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)) }
    }

    private var serverName: String {
        (preset?.name ?? name).trimmingCharacters(in: .whitespaces)
    }

    /// The env keys to ask for: a preset's, or the one the person named.
    private var keyFields: [String] {
        if let preset { return preset.requires }
        let key = keyName.trimmingCharacters(in: .whitespaces).uppercased()
        return key.isEmpty ? [] : [key]
    }

    private var canTest: Bool {
        !serverName.isEmpty && (preset != nil || !address.trimmingCharacters(in: .whitespaces).isEmpty)
            && keyFields.allSatisfy { !(keys[$0] ?? "").isEmpty || addedName != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if preset == nil {
                    Section {
                        ForEach(suggestions.prefix(query.isEmpty ? 3 : 20)) { preset in
                            PresetRow(preset: preset) { choose(preset) }
                        }
                    } header: {
                        SectionHeading(title: String(localized: "Suggested"))
                    } footer: {
                        Text("From the Hermes catalog. Adding asks for any keys it needs, then tests the connection.")
                    }
                }
                Section {
                    if let preset {
                        HStack(spacing: 12) {
                            AppLogo(name: preset.name, url: nil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PresetRow.title(preset.name)).foregroundStyle(Theme.primaryText)
                                Text(preset.description).font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button("Change") { reset() }
                                .disabled(addedName != nil)
                        }
                    } else {
                        Picker("Connects by", selection: $mode) {
                            Text("Command").tag(Mode.command)
                            Text("URL").tag(Mode.url)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        TextField("Name", text: $name, prompt: Text("linear-local"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        TextField(mode == .command ? "Command" : "URL", text: $address,
                                  prompt: Text(mode == .command ? "npx -y @linear/mcp-server" : "https://mcp.example.com/mcp"))
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(mode == .url ? .URL : .default)
                            #endif
                        TextField("Key name", text: $keyName, prompt: Text("LINEAR_API_KEY (if it needs one)"))
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.characters)
                            #endif
                    }
                    ForEach(keyFields, id: \.self) { key in
                        SecretField(label: key, value: Binding(get: { keys[key] ?? "" }, set: { keys[key] = $0; result = nil }))
                    }
                    if let result {
                        TestResultRow(result: result, gateway: model.gatewayName)
                        if result.oauthNeeded {
                            Button {
                                Task {
                                    isSigningIn = true
                                    if await model.signIn(serverName) { await test() }
                                    isSigningIn = false
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isSigningIn { ProgressView().controlSize(.small) } else { Text("Sign In") }
                                    Spacer()
                                }
                            }
                        }
                    }
                    if result?.ok != true {
                        Button {
                            Task { await test() }
                        } label: {
                            HStack {
                                Spacer()
                                if isTesting { ProgressView().controlSize(.small) } else { Text(result == nil ? "Test Connection" : "Test Again") }
                                Spacer()
                            }
                        }
                        .disabled(!canTest || isTesting)
                    }
                } header: {
                    SectionHeading(title: preset == nil ? String(localized: "Custom MCP Server") : String(localized: "Set Up"))
                } footer: {
                    Text(mode == .command && preset == nil
                         ? String(localized: "The command runs on \(model.gatewayName), not on this device.")
                         : String(localized: "Keys go to \(model.gatewayName)'s .env and aren't shown again."))
                }
            }
            .formStyle(.grouped)
            #if os(iOS)
            // Sheets keep search at the top.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the catalog")
            #else
            .searchable(text: $query, prompt: "Search the catalog")
            #endif
            .navigationTitle("Add MCP Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        if let addedName { Task { await model.abandon(addedName) } }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", systemImage: "checkmark") {
                        Task {
                            await model.finishAdding()
                            dismiss()
                        }
                    }
                    // Only a server that passed its test.
                    .disabled(result?.ok != true)
                }
            }
            .interactiveDismissDisabled(addedName != nil)
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }

    private func choose(_ preset: McpPreset) {
        self.preset = preset
        keys = [:]
        result = nil
        // No keys to ask for: test at once.
        if preset.requires.isEmpty { Task { await test() } }
    }

    private func reset() {
        preset = nil
        keys = [:]
        result = nil
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        var config: [String: JSONValue]?
        if preset == nil {
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            if mode == .url {
                config = ["url": .string(trimmed)]
            } else {
                let parts = trimmed.split(separator: " ").map(String.init)
                config = ["command": .string(parts.first ?? ""), "args": .array(parts.dropFirst().map(JSONValue.string))]
            }
            // `set_api_key` with the key's name adds the reference to the config itself.
        }
        let typed = keys
        // The values leave the sheet once written; a second test needs no re-typing.
        keys = keys.mapValues { _ in "" }
        guard let outcome = await model.addAndTest(name: serverName, preset: preset?.name, config: config, keys: typed, alreadyAdded: addedName != nil) else { return }
        addedName = serverName
        result = outcome
    }
}

/// A catalog preset (`addServer` Suggested): what it is and what it needs, then Add.
struct PresetRow: View {
    let preset: McpPreset
    let add: () -> Void

    /// The catalog names presets by id (`brave-search`): "Brave Search", "PostgreSQL".
    static func title(_ id: String) -> String {
        let known = ["postgresql": "PostgreSQL", "github": "GitHub", "gitlab": "GitLab", "mongodb": "MongoDB", "mysql": "MySQL",
                     "sqlite": "SQLite", "hubspot": "HubSpot", "youtube": "YouTube", "openai": "OpenAI", "aws": "AWS"]
        if let name = known[id] { return name }
        return id.split(separator: "-").map { known[String($0)] ?? $0.capitalized }.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 12) {
            AppLogo(name: preset.name, url: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(preset.name)).foregroundStyle(Theme.primaryText)
                Text([preset.description, preset.requires.isEmpty ? String(localized: "no key") : String(localized: "needs \(preset.requires.joined(separator: ", "))")]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add", action: add)
                .buttonStyle(RowCapsuleButtonStyle())
                .accessibilityLabel("Add \(preset.name)")
        }
    }
}
