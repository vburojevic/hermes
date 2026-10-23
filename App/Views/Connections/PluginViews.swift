import HermesKit
import SwiftUI

// MARK: - Plugins (`pluginRow`, `pluginUpdate`)

/// One plugin (`pluginRow*`): name and tier, version and what it adds, a switch; a problem or an
/// update underneath.
struct PluginRow: View {
    let model: AppsAndToolsModel
    let plugin: HermesPlugin

    private var adds: String {
        let addsValue = model.pluginAdds[plugin.key] ?? .init()
        var parts = plugin.version.isEmpty ? [] : ["v\(plugin.version)"]
        if !addsValue.tools.isEmpty { parts.append(addsValue.tools.count == 1 ? String(localized: "1 tool") : String(localized: "\(addsValue.tools.count) tools")) }
        if !addsValue.skills.isEmpty { parts.append(addsValue.skills.count == 1 ? String(localized: "1 skill") : String(localized: "\(addsValue.skills.count) skills")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            GlyphTile(symbol: "puzzlepiece.extension")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name).foregroundStyle(Theme.primaryText).lineLimit(1)
                    PluginTierTag(tier: plugin.tier)
                }
                if !adds.isEmpty {
                    Text(adds).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if plugin.isEnabled, let problem = plugin.problem {
                    Text(problem).font(.caption).foregroundStyle(Theme.warning)
                } else if plugin.updateAvailable, let version = plugin.catalogVersion {
                    Text("Update available · v\(version)").font(.caption.weight(.medium)).foregroundStyle(Theme.primaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy("plugin:\(plugin.key)") {
                Spinner()
            }
            Toggle("On", isOn: Binding(
                get: { plugin.isEnabled },
                set: { on in Task { await model.setPlugin(plugin, enabled: on) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// "This update asks for more access" (`pluginUpdate`): nothing changes until the person allows it.
struct UpdateConsentCard: View {
    let model: AppsAndToolsModel
    let consent: AppsAndToolsModel.UpdateConsent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This update asks for more access")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("\(consent.plugin.name) v\(consent.plugin.catalogVersion ?? "") can also:")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            ForEach(consent.lines, id: \.self) { line in
                ConsentLine(text: line)
            }
            PairedButtons(
                secondary: String(localized: "Keep v\(consent.plugin.version)"),
                onSecondary: { model.consent = nil },
                primary: String(localized: "Allow and Update"),
                primaryEnabled: !model.isBusy("plugin:\(consent.plugin.key)")
            ) {
                Task { await model.update(consent.plugin, accept: true) }
            }
            .padding(.top, 4)
        }
        .pluginRowCard()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - One plugin (`pluginDetail`)

struct PluginDetailView: View {
    let model: AppsAndToolsModel
    let key: String
    var macLayout = false

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false
    @State private var editingSecret: PluginSettingField?

    private var plugin: HermesPlugin? { model.plugin(key) }

    var body: some View {
        Group {
            if let plugin {
                form(plugin)
            } else {
                ContentUnavailableView("Plugin removed", systemImage: "puzzlepiece.extension")
            }
        }
        .detailTitle(String(localized: "Plugin"), shows: !macLayout)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func form(_ plugin: HermesPlugin) -> some View {
        let adds = model.pluginAdds[plugin.key] ?? .init()
        return Form {
            Section {
                VStack(spacing: 8) {
                    GlyphTile(symbol: "puzzlepiece.extension", size: 60)
                    Text(plugin.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.primaryText)
                    Text([plugin.tier?.capitalized, plugin.version.isEmpty ? nil : "v\(plugin.version)", plugin.description.isEmpty ? nil : plugin.description]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .combine)
            }
            // Pulled from the catalog (Hermes's kill list): why and when, and Remove. It can't be
            // turned back on: Hermes would refuse to load it (`docs/plugins.md` §7).
            if let removal = model.workspace?.pluginHub.pulled(plugin) {
                Section {
                    AttentionCard(tone: .danger, title: String(localized: "Pulled from the catalog"),
                                  detail: removal.reason + (removal.date.isEmpty ? "" : " " + String(localized: "Pulled on \(removal.date).")),
                                  mono: plugin.catalogName) {
                        Button(String(localized: "Remove \(plugin.name)…"), role: .destructive) { confirmingRemove = true }
                            .cardButton()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let consent = model.consent, consent.plugin.key == plugin.key {
                Section {
                    UpdateConsentCard(model: model, consent: consent)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            if plugin.isEnabled, let problem = plugin.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            if !adds.tools.isEmpty || !adds.skills.isEmpty {
                Section {
                    if !adds.tools.isEmpty {
                        NameTags(title: adds.tools.count == 1 ? String(localized: "1 tool") : String(localized: "\(adds.tools.count) tools"), names: adds.tools)
                    }
                    if !adds.skills.isEmpty {
                        NameTags(title: adds.skills.count == 1 ? String(localized: "1 skill") : String(localized: "\(adds.skills.count) skills"), names: adds.skills)
                    }
                } header: {
                    SectionHeading(title: String(localized: "What it adds"))
                } footer: {
                    Text("Its MCP tools and skills work in every open chat from the next turn; the chats get a note. Python tools and prompt changes start with the next chat.")
                }
            }
            Section {
                ForEach(plugin.settings) { field in
                    PluginSettingRow(field: field, gateway: model.gatewayName) { value in
                        Task { await model.saveSettings(plugin, values: [field.key: value]) }
                    } onSecret: {
                        editingSecret = field
                    }
                }
                Toggle("On", isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { on in Task { await model.setPlugin(plugin, enabled: on) } }
                ))
                .toggleStyle(.switch)
                .disabled(!plugin.isEnabled && model.workspace?.pluginHub.pulled(plugin) != nil)
            } header: {
                SectionHeading(title: String(localized: "Settings"))
            } footer: {
                if plugin.settings.contains(where: { $0.kind == .secret }) {
                    Text("Secret settings live in \(model.gatewayName)'s .env; the app shows only whether they're set.")
                }
            }
            Section(header: SectionHeading(title: String(localized: "Source"))) {
                if let catalog = plugin.catalogName {
                    LabeledContent("Catalog", value: catalog)
                }
                LabeledContent("Installed", value: plugin.isBundled ? String(localized: "With Hermes") : (plugin.source == "git" ? String(localized: "From git") : String(localized: "By you")))
                if let sha = plugin.pinnedSHA ?? plugin.installedSHA {
                    LabeledContent("Pinned to") {
                        Text(String(sha.prefix(7))).font(.footnote.monospaced())
                    }
                }
                if plugin.updateAvailable, let version = plugin.catalogVersion {
                    Button {
                        Task { await model.update(plugin) }
                    } label: {
                        HStack {
                            Text("Update to v\(version)")
                            Spacer()
                            if model.isBusy("plugin:\(plugin.key)") { Spinner() }
                        }
                    }
                }
            }
            if plugin.canRemove {
                Section {
                    DestructiveRowButton(title: String(localized: "Remove Plugin")) { confirmingRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingSecret) { field in
            PluginSecretSheet(model: model, plugin: plugin, field: field)
        }
        .alert("Remove \(plugin.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                // It leaves the list at once; a refusal brings it back with a note.
                Task { await model.remove(plugin) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its tools, skills and MCP servers leave \(model.gatewayName).")
        }
    }
}

/// "12 tools" with the first names as tags and "+8 more".
private struct NameTags: View {
    let title: String
    let names: [String]
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
            FlowLayout(spacing: 6) {
                ForEach(showsAll ? names : Array(names.prefix(4)), id: \.self) { name in
                    Text(name)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                if names.count > 4, !showsAll {
                    Button("+\(names.count - 4) more") { showsAll = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.link)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One setting from the manifest schema: string, number, boolean, enum, json, or a secret.
private struct PluginSettingRow: View {
    let field: PluginSettingField
    let gateway: String
    let onSave: (JSONValue) -> Void
    let onSecret: () -> Void

    @State private var text = ""
    @State private var flag = false

    private var current: JSONValue? { field.value ?? field.defaultValue }

    var body: some View {
        Group {
            switch field.kind {
            case .secret:
                Button(action: onSecret) {
                    LabeledContent {
                        Text(field.hasValue ? String(localized: "Set") : String(localized: "Not set"))
                            .foregroundStyle(field.hasValue ? Theme.secondaryText : Theme.warning)
                    } label: {
                        Text(field.env ?? field.label).font(.footnote.monospaced())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sets a new value")
            case .boolean:
                Toggle(field.label, isOn: Binding(get: { flag }, set: { flag = $0; onSave(.bool($0)) }))
                    .toggleStyle(.switch)
                    
            case .enum:
                Picker(field.label, selection: Binding(get: { text }, set: { text = $0; onSave(.string($0)) })) {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                }
            case .number:
                LabeledContent(field.label) {
                    TextField(field.label, text: $text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onSubmit { if let number = Double(text) { onSave(.number(number)) } }
                }
            case .string, .json:
                LabeledContent(field.label) {
                    TextField(field.label, text: $text, prompt: Text(field.required ? "Required" : "Optional"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .font(field.kind == .json ? .footnote.monospaced() : .body)
                        .autocorrectionDisabled()
                        .onSubmit { onSave(field.kind == .json ? (JSONValue.parse(text) ?? .string(text)) : .string(text)) }
                }
            }
        }
        .onAppear(perform: fill)
        // A refusal puts the old value back in the model: the field follows it.
        .onChange(of: field.value) { fill() }
    }

    private func fill() {
        switch current {
        case .string(let value)?: text = value
        case .number(let value)?: text = value.formatted()
        case .bool(let value)?: flag = value
        case let other?: text = other.displayText
        case nil: break
        }
        if field.kind == .enum, text.isEmpty { text = field.choices.first ?? "" }
    }
}

/// A plugin secret: written once to the gateway's `.env`, never read back.
private struct PluginSecretSheet: View {
    let model: AppsAndToolsModel
    let plugin: HermesPlugin
    let field: PluginSettingField
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecretField(label: field.env ?? field.key, value: $value, autofocus: true)
                } header: {
                    Text(field.label)
                } footer: {
                    Text(field.description.isEmpty
                         ? String(localized: "Stored in \(model.gatewayName)'s .env. The app never sees it again.")
                         : field.description + " " + String(localized: "Stored in \(model.gatewayName)'s .env."))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(field.hasValue ? "Replace \(field.label)" : "Set \(field.label)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let secret = value
                        value = ""
                        dismiss()
                        if let env = field.env { Task { await model.saveSecret(secret, env: env, for: plugin) } }
                    }
                    .disabled(value.isEmpty || field.env == nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 240)
        #endif
    }
}

/// Install from a git link (`install {repo, ref}`).
struct InstallFromGitSheet: View {
    let model: AppsAndToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var ref = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Git link", text: $repo, prompt: Text("https://github.com/owner/hermes-plugin"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("Branch, tag or commit", text: $ref, prompt: Text("Optional"))
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("Hermes on \(model.gatewayName) clones it and installs it with the access its manifest asks for. Plugins from outside the catalog aren't scanned.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Install from Git")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isBusy("install:git") {
                        Spinner()
                    } else {
                        Button("Install", systemImage: "checkmark") {
                            Task {
                                if await model.install(repo: repo.trimmingCharacters(in: .whitespaces), ref: ref.trimmingCharacters(in: .whitespaces)) {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(repo.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 260)
        #endif
    }
}

/// What Hermes said after an install, toggle or update: warnings, keys it still needs, known
/// issues, what works now and what waits, and a restart if one is needed.
struct PluginNotesSheet: View {
    let model: AppsAndToolsModel
    let notes: AppsAndToolsModel.PluginNotes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let result = notes.result
        NavigationStack {
            Form {
                if let activation = result.activation, !activation.isEmpty {
                    Section(header: SectionHeading(title: String(localized: "Ready"))) {
                        if !activation.liveTools.isEmpty || !activation.liveSkills.isEmpty {
                            Label("Its MCP tools and skills work in open chats from their next turn.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.primaryText)
                        }
                        if !activation.deferredTools.isEmpty || !activation.deferredPrompt.isEmpty {
                            Label("Its other tools start with the next chat.", systemImage: "clock")
                                .foregroundStyle(Theme.primaryText)
                        }
                    }
                }
                if !result.missingEnv.isEmpty {
                    Section {
                        ForEach(result.missingEnv, id: \.self) { env in
                            MissingKeyRow(model: model, env: env)
                        }
                    } header: {
                        SectionHeading(title: String(localized: "It still needs"))
                    } footer: {
                        Text("Stored in \(model.gatewayName)'s .env; the app never shows them again.")
                    }
                }
                if !result.warnings.isEmpty {
                    Section(header: SectionHeading(title: String(localized: "Warnings"))) {
                        ForEach(result.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
                    }
                }
                if !result.knownIssues.isEmpty {
                    Section(header: SectionHeading(title: String(localized: "Known issues"))) {
                        ForEach(result.knownIssues, id: \.self) { Text($0) }
                    }
                }
                if result.restartRequired {
                    Section {
                        Text("hermes gateway restart")
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        SectionHeading(title: String(localized: "Restart the gateway to finish"))
                    } footer: {
                        Text("Run it on \(model.gatewayName).")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(notes.pluginName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 460, height: 420)
        #endif
    }
}

/// A key a plugin still needs: written once, then just its name.
private struct MissingKeyRow: View {
    let model: AppsAndToolsModel
    let env: String
    @State private var value = ""
    @State private var saved = false

    var body: some View {
        if saved {
            LabeledContent {
                Text("Set").foregroundStyle(Theme.secondaryText)
            } label: {
                Text(env).font(.footnote.monospaced())
            }
        } else {
            HStack {
                SecretField(label: env, value: $value)
                Button("Save") {
                    let secret = value
                    value = ""
                    saved = true
                    Task {
                        guard let workspace = model.workspace, let roster = workspace.roster else { return }
                        try? await roster.setEnv(key: env, value: secret, profile: workspace.bot.profileName)
                        await model.load()
                    }
                }
                .disabled(value.isEmpty)
            }
        }
    }
}
