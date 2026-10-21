import HermesKit
import SwiftUI

// MARK: - Built-in tab (`builtInTab`)

/// How the app names Hermes's own toolsets. `toolsets.list` returns every toolset the gateway
/// knows (platform bundles, MCP servers, plugins) with no "built-in" flag, so the built-in ones are
/// the keys `hermes_cli/tools_config.py` lists as configurable: the eight in the design first, then
/// the rest under More.
enum BuiltInToolsetInfo {
    struct Info {
        let title: String
        let symbol: String
        /// What it allows on the gateway; `%@` is the gateway's name.
        let blurb: String
    }

    static let main = ["terminal", "file", "web", "browser", "vision", "image_gen", "memory", "delegation"]
    static let more = ["code_execution", "video", "video_gen", "x_search", "tts", "stt", "skills", "todo", "kanban",
                       "context_engine", "session_search", "connections", "clarify", "cronjob", "computer_use", "discord",
                       "discord_admin", "yuanbao"]

    static func info(_ name: String, gateway: String) -> Info? {
        switch name {
        case "terminal": Info(title: String(localized: "Terminal"), symbol: "terminal", blurb: String(localized: "Run commands on \(gateway)"))
        case "file": Info(title: String(localized: "Files"), symbol: "doc.text", blurb: String(localized: "Read and edit files"))
        case "web": Info(title: String(localized: "Web search"), symbol: "magnifyingglass", blurb: String(localized: "Search and read pages"))
        case "browser": Info(title: String(localized: "Browser"), symbol: "safari", blurb: String(localized: "Drive a real browser"))
        case "vision": Info(title: String(localized: "Vision"), symbol: "eye", blurb: String(localized: "Look at images and screenshots"))
        case "image_gen": Info(title: String(localized: "Image generation"), symbol: "photo", blurb: String(localized: "Make images"))
        case "memory": Info(title: String(localized: "Memory"), symbol: "brain", blurb: String(localized: "Remember things between chats"))
        case "delegation": Info(title: String(localized: "Helpers"), symbol: "person.2", blurb: String(localized: "Split work across parallel helpers"))
        case "code_execution": Info(title: String(localized: "Code execution"), symbol: "chevron.left.forwardslash.chevron.right", blurb: String(localized: "Run code in a sandbox"))
        case "video": Info(title: String(localized: "Video"), symbol: "film", blurb: String(localized: "Watch and describe videos"))
        case "video_gen": Info(title: String(localized: "Video generation"), symbol: "video", blurb: String(localized: "Make videos"))
        case "x_search": Info(title: String(localized: "X search"), symbol: "magnifyingglass.circle", blurb: String(localized: "Search posts on X"))
        case "tts": Info(title: String(localized: "Speech"), symbol: "speaker.wave.2", blurb: String(localized: "Read replies aloud"))
        case "stt": Info(title: String(localized: "Transcription"), symbol: "waveform", blurb: String(localized: "Turn voice into text"))
        case "skills": Info(title: String(localized: "Skills"), symbol: "book", blurb: String(localized: "Use and manage skills"))
        case "todo": Info(title: String(localized: "Planning"), symbol: "checklist", blurb: String(localized: "Keep a task list"))
        case "kanban": Info(title: String(localized: "Kanban"), symbol: "rectangle.split.3x1", blurb: String(localized: "Work through a board's cards"))
        case "context_engine": Info(title: String(localized: "Context engine"), symbol: "square.stack.3d.up", blurb: String(localized: "Tools from the context engine"))
        case "session_search": Info(title: String(localized: "Chat search"), symbol: "text.magnifyingglass", blurb: String(localized: "Search past conversations"))
        case "connections": Info(title: String(localized: "Connections"), symbol: "app.connected.to.app.below.fill", blurb: String(localized: "Ask to connect apps mid-chat"))
        case "clarify": Info(title: String(localized: "Questions"), symbol: "questionmark.bubble", blurb: String(localized: "Ask you to choose"))
        case "cronjob": Info(title: String(localized: "Tasks"), symbol: "clock", blurb: String(localized: "Create and run scheduled tasks"))
        case "computer_use": Info(title: String(localized: "Computer use"), symbol: "cursorarrow.click.2", blurb: String(localized: "Use apps on \(gateway)"))
        case "discord": Info(title: String(localized: "Discord"), symbol: "bubble.left.and.bubble.right", blurb: String(localized: "Read and post in Discord"))
        case "discord_admin": Info(title: String(localized: "Discord admin"), symbol: "shield", blurb: String(localized: "Manage a Discord server"))
        case "yuanbao": Info(title: String(localized: "Yuanbao"), symbol: "bubble.left", blurb: String(localized: "Groups and DMs in Yuanbao"))
        default: nil
        }
    }

    /// Turning these off takes something basic away: confirm first.
    static func confirmation(_ name: String, gateway: String) -> String? {
        switch name {
        case "terminal": String(localized: "Hermes won't be able to run commands on \(gateway).")
        case "file": String(localized: "Hermes won't be able to edit files on \(gateway).")
        default: nil
        }
    }
}

struct BuiltInTabSections: View {
    let model: AppsAndToolsModel
    @State private var showsMore = false
    @State private var confirming: BuiltInToolset?

    private func rows(_ names: [String]) -> [BuiltInToolset] {
        names.compactMap { name in model.toolsets.first { $0.name == name } }
    }

    var body: some View {
        let main = rows(BuiltInToolsetInfo.main)
        let more = rows(BuiltInToolsetInfo.more)
        Section {
            if let error = model.toolsetsError, model.toolsets.isEmpty {
                Text(error).foregroundStyle(Theme.secondaryText)
            }
            ForEach(main) { toolset in
                row(toolset)
            }
        } header: {
            countedHeader(String(localized: "Built-in"), main.count)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Changes apply to new chats on \(model.gatewayName); open chats reload their tools.")
                if !model.toolsetsWithoutKeys.isEmpty {
                    // `docs/setup.md` §4.5: on, but left out until a key is set.
                    Text("Hermes leaves out the tools of a toolset that needs a key until it has one.")
                    SetupCommand(command: "hermes tools")
                    SetupDocsLink(url: HermesDocs.page("user-guide/features/tools"))
                }
            }
        }
        .alert(String(localized: "Turn Off \(confirming.flatMap { BuiltInToolsetInfo.info($0.name, gateway: model.gatewayName)?.title } ?? "")?"),
               isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Turn Off", role: .destructive) {
                if let toolset = confirming { Task { await model.setToolset(toolset, enabled: false) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming.flatMap { BuiltInToolsetInfo.confirmation($0.name, gateway: model.gatewayName) } ?? "")
        }
        if !more.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $showsMore) {
                    ForEach(more) { toolset in
                        row(toolset)
                    }
                } label: {
                    Text("More · \(more.count)").foregroundStyle(Theme.primaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ toolset: BuiltInToolset) -> some View {
        ToolsetRow(model: model, toolset: toolset) { on in
            if !on, BuiltInToolsetInfo.confirmation(toolset.name, gateway: model.gatewayName) != nil {
                confirming = toolset
            } else {
                Task { await model.setToolset(toolset, enabled: on) }
            }
        }
        #if os(iOS)
        // Where Hermes browses (`docs/web.md` §2): the same page as Settings → Browser. The Mac lists
        // it in the Apps & Tools sidebar.
        if toolset.name == "browser", toolset.enabled, let workspace = model.workspace {
            BrowserSettingsRow(workspace: workspace)
        }
        #endif
        if toolset.enabled, model.toolsetsWithoutKeys.contains(toolset.name), model.isOnline {
            // Hermes takes the key over REST (`docs/setup.md` §4.5).
            Button("Add a Key for \(BuiltInToolsetInfo.info(toolset.name, gateway: model.gatewayName)?.title ?? toolset.name)…") {
                model.addingKeyFor = toolset
            }
        }
    }
}

/// One built-in toolset (`toolsetRow`): ink tile, name, what it allows, tool count, a switch.
private struct ToolsetRow: View {
    let model: AppsAndToolsModel
    let toolset: BuiltInToolset
    let set: (Bool) -> Void

    var body: some View {
        let info = BuiltInToolsetInfo.info(toolset.name, gateway: model.gatewayName)
        let tools = toolset.toolCount == 1 ? String(localized: "1 tool") : String(localized: "\(toolset.toolCount) tools")
        HStack(spacing: 12) {
            GlyphTile(symbol: info?.symbol ?? "wrench.and.screwdriver", ink: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.title ?? toolset.name).foregroundStyle(Theme.primaryText)
                if toolset.enabled, model.toolsetsWithoutKeys.contains(toolset.name) {
                    Text("Needs a key on \(model.gatewayName)")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                } else {
                    Text("\(info?.blurb ?? toolset.description) · \(tools)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isBusy("toolset:\(toolset.name)") {
                Spinner()
            }
            Toggle(info?.title ?? toolset.name, isOn: Binding(get: { toolset.enabled }, set: { set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Add a Key for a built-in toolset (`docs/setup.md` §4.5): its providers that take a key, the
/// key fields of the one picked, Save. The keys go to the gateway's `.env` and nowhere else.
struct ToolsetKeySheet: View {
    let model: AppsAndToolsModel
    let toolset: BuiltInToolset
    @Environment(\.dismiss) private var dismiss
    @State private var options: ToolsetKeys?
    @State private var provider: String = ""
    @State private var values: [String: String] = [:]
    @State private var isSaving = false
    @State private var error: String?

    private var title: String { BuiltInToolsetInfo.info(toolset.name, gateway: model.gatewayName)?.title ?? toolset.name }
    private var picked: ToolsetKeys.Provider? { options?.takingKeys.first { $0.name == provider } }
    private var canSave: Bool {
        guard let picked, !isSaving else { return false }
        return picked.keys.contains { !$0.isSet } ? picked.keys.allSatisfy { $0.isSet || !(values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty } : true
    }

    var body: some View {
        NavigationStack {
            Form {
                if let options {
                    if options.takingKeys.isEmpty {
                        Section {
                            Text("\(title) has no provider that takes a key from here. On \(model.gatewayName), run:")
                            SetupCommand(command: "hermes tools")
                        }
                    } else {
                        Section {
                            Picker("Provider", selection: $provider) {
                                ForEach(options.takingKeys) { option in
                                    Text(option.badge.map { "\(option.name) · \($0)" } ?? option.name).tag(option.name)
                                }
                            }
                        }
                        if let picked {
                            Section {
                                ForEach(picked.keys) { key in
                                    SecureField(key.prompt, text: Binding(get: { values[key.name] ?? "" }, set: { values[key.name] = $0 }),
                                                prompt: Text(key.isSet ? String(localized: "Set · leave empty to keep") : key.prompt))
                                        .autocorrectionDisabled()
                                        #if os(iOS)
                                        .textInputAutocapitalization(.never)
                                        #endif
                                    if let url = key.url, WebLink.isWeb(url) {
                                        Link("Get a key for \(picked.name)", destination: url)
                                            .font(.footnote)
                                    }
                                }
                            } footer: {
                                Text("Saved in \(model.gatewayName)'s .env, where Hermes keeps its keys, and \(picked.name) becomes the provider \(title) uses. Not kept on this device.")
                            }
                        }
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(Theme.secondaryText) }
                } else {
                    Section { SkeletonRows(count: 2, twoLines: false) }
                }
                if let error, options != nil {
                    Section {
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Key for \(title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        Spinner()
                    } else {
                        Button("Save", action: save).disabled(!canSave)
                    }
                }
            }
            .task {
                do {
                    let loaded = try await model.toolsetKeys(toolset.name)
                    options = loaded
                    provider = loaded.takingKeys.first { $0.isActive }?.name ?? loaded.takingKeys.first?.name ?? ""
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        #if os(macOS)
        .frame(width: 460).frame(minHeight: 300)
        #endif
    }

    private func save() {
        guard let picked else { return }
        let keys = values.filter { key, value in
            picked.keys.contains { $0.name == key } && !value.trimmingCharacters(in: .whitespaces).isEmpty
        }.mapValues { $0.trimmingCharacters(in: .whitespaces) }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.saveToolsetKeys(toolset.name, provider: picked.name, keys: keys)
                values = [:]
                dismiss()
            } catch {
                self.error = ConnectorErrorReason.line(for: error)
            }
        }
    }
}
