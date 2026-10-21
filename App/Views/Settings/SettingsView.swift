import HermesKit
import SwiftUI

/// Gateways, appearance and chat behaviour.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandAgentActivity = false
    @AppStorage(PreferenceKey.haptics) private var haptics = true
    @AppStorage(PreferenceKey.showUsage) private var showUsage = false
    @AppStorage(PreferenceKey.openChatsAt) private var openChatsAt = OpenChatsAt.firstUnread
    @AppStorage(PreferenceKey.chatSounds) private var chatSounds = false
    @State private var editing: BotConfiguration?
    @State private var isAddingBot = false
    /// `-HERMES_APPS_TOOLS <tab>[:<item>]` opens Apps and Tools (screenshots).
    @State private var opensAppsAndTools = DebugFlags.appsAndTools != nil
    /// `-HERMES_MEMORY …` opens Memory (screenshots).
    @State private var opensMemory = DebugFlags.memory != nil
    /// `-HERMES_SETTINGS_SETUP …` opens Setup (screenshots).
    @State private var opensSetup = DebugFlags.setup != nil
    /// `-HERMES_BROWSER …` opens Browser (screenshots).
    @State private var opensBrowser = DebugFlags.browser != nil
    /// `-HERMES_PASSWORDS …` opens Passwords (screenshots).
    @State private var opensPasswords = DebugFlags.passwords != nil
    /// A voice fallback note's Set Up… opens Voice & Audio.
    @State private var opensVoice = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(app.bots) { bot in
                        Button {
                            editing = bot
                        } label: {
                            HStack(spacing: 12) {
                                BotAvatar(bot: bot, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.name)
                                        .foregroundStyle(Theme.primaryText)
                                    Text(bot.displayAddress)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if let workspace = app.workspaces[bot.id] {
                                    ConnectionStatusLabel(workspace: workspace)
                                        .labelsHidden()
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Add Gateway…", systemImage: "plus") {
                        isAddingBot = true
                    }
                } header: {
                    Text("Hermes Gateways")
                } footer: {
                    Text("API keys are stored in the Keychain on this device.")
                }

                if let workspace = app.currentWorkspace {
                    Section("Hermes on \(workspace.bot.name)") {
                        SetupSettingsRow(workspace: workspace)
                        AppsAndToolsSettingsRow(model: workspace.appsAndTools)
                        MemorySettingsRow(workspace: workspace)
                        PasswordsSettingsRow(workspace: workspace)
                        BrowserSettingsRow(workspace: workspace)
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("Show agent steps while working", isOn: $expandAgentActivity)
                    FollowUpDefaultPicker()
                    Toggle("Show usage under replies", isOn: $showUsage)
                    Toggle("Send with Return", isOn: $sendWithReturn)
                    Picker("Open Chats At", selection: $openChatsAt) {
                        ForEach(OpenChatsAt.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    #if os(iOS)
                    Toggle("Haptics", isOn: $haptics)
                    #endif
                    Toggle("Sounds", isOn: $chatSounds)
                } header: {
                    Text("Chat")
                } footer: {
                    Text("A chat with new messages opens at the first one, or at the latest. With Send with Return on, Shift-Return starts a new line on a hardware keyboard.")
                }

                // Talk, voice messages, Listen and dictation (`docs/voice.md` §6).
                Section {
                    VoiceSettingsRow(workspace: app.currentWorkspace)
                }

                WidgetDeveloperSection()

                #if HERMES_PUSH && os(iOS)
                Section("Notifications") {
                    NotificationsSettingsRow()
                }
                #endif

                Section {
                    AboutVersionRow(version: Self.versionString)
                    Link(destination: URL(string: "https://github.com/vburojevic/hermes")!) {
                        Label("Source code on GitHub", systemImage: "swift")
                    }
                    Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) {
                        Label("Hermes Agent documentation", systemImage: "book")
                    }
                    Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent")!) {
                        Label("Hermes Agent on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("An independent app by Caffeinated Code for Hermes Agent, the open-source agent by Nous Research. Not affiliated with Nous Research.")
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if router?.pluginInstallRequest != nil || router?.opensAppsAndTools == true { opensAppsAndTools = true }
                router?.opensAppsAndTools = false
                if router?.opensVoiceSettings == true { opensVoice = true }
                router?.opensVoiceSettings = false
            }
            .navigationDestination(isPresented: $opensAppsAndTools) {
                if let workspace = app.currentWorkspace { AppsAndToolsView(model: workspace.appsAndTools) }
            }
            .navigationDestination(isPresented: $opensVoice) {
                VoiceSettingsView(workspace: app.currentWorkspace)
            }
            .navigationDestination(isPresented: $opensMemory) {
                if let workspace = app.currentWorkspace { DebugMemoryPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensBrowser) {
                if let workspace = app.currentWorkspace { DebugBrowserPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensPasswords) {
                if let workspace = app.currentWorkspace { DebugPasswordsPage(workspace: workspace) }
            }
            .navigationDestination(isPresented: $opensSetup) {
                if let workspace = app.currentWorkspace { SetupOverviewView(workspace: workspace) }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
            .sheet(isPresented: $isAddingBot) {
                NavigationStack {
                    BotEditorView(mode: .add) { isAddingBot = false }
                }
                #if os(macOS)
                .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
                #endif
            }
            .sheet(item: $editing) { bot in
                NavigationStack {
                    BotEditorView(mode: .edit(bot)) { editing = nil }
                }
                #if os(macOS)
                .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Settings → About's version row, tagged Beta while Hermes is in public beta. Drop the tag here
/// when it leaves the beta.
struct AboutVersionRow: View {
    let version: String

    var body: some View {
        LabeledContent("Version") {
            HStack(spacing: 6) {
                Text(version)
                TagLabel(title: String(localized: "Beta"))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Settings → Hermes on <gateway> → Apps and Tools: a count, plus "1 needs you" when something
/// expired or failed.
/// `-HERMES_MEMORY …`: Memory with a model of its own (screenshots).
private struct DebugMemoryPage: View {
    @State private var model: MemoryModel

    init(workspace: BotWorkspace) {
        let route = DebugFlags.memory ?? ""
        let scope: MemoryModel.Scope = route.hasPrefix("bot:") ? .bot(String(route.dropFirst(4))) : .hermes
        _model = State(initialValue: MemoryModel(workspace: workspace, scope: scope, newInChat: workspace.currentConversation.memorySaves))
    }

    var body: some View {
        MemoryView(model: model)
    }
}

/// Settings → Hermes on <gateway> → Memory: "6 things about you · 14 notes · 2 to review". The
/// page it opens shares this row's model, made when Settings opens and dropped with it.
struct MemorySettingsRow: View {
    let workspace: BotWorkspace
    var scope: MemoryModel.Scope = .hermes
    @State private var model: MemoryModel?

    private var title: String {
        if case .bot(let name) = scope, let bot = workspace.roster?.bot(named: name) {
            return String(localized: "What \(bot.title) Remembers")
        }
        return String(localized: "Memory")
    }

    var body: some View {
        NavigationLink {
            if let model { MemoryView(model: model).settingsPage(back: String(localized: "Back")) }
        } label: {
            HStack(spacing: 12) {
                if scope == .hermes {
                    GlyphTile(symbol: "brain", ink: true, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.primaryText)
                    Text(model?.summary ?? String(localized: "What Hermes knows about you"))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
        }
        .onAppear {
            if model == nil {
                // "New in this chat": what the open chat saved.
                let saves: [String] = switch scope {
                case .hermes: workspace.currentConversation.memorySaves
                case .bot(let name): workspace.roster?.conversation(for: name).memorySaves ?? []
                }
                let created = MemoryModel(workspace: workspace, scope: scope, newInChat: saves)
                model = created
                Task { await created.load(includingPending: scope == .hermes) }
            }
        }
        .onChange(of: workspace.roster?.isConnected) {
            if let model, model.isOnline, model.list == nil { Task { await model.load() } }
        }
        .accessibilityHint("What Hermes remembers about you and your setup")
    }
}

struct AppsAndToolsSettingsRow: View {
    let model: AppsAndToolsModel

    var body: some View {
        NavigationLink {
            AppsAndToolsView(model: model)
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: "puzzlepiece.extension", ink: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps and Tools").foregroundStyle(Theme.primaryText)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .task(id: model.isOnline) {
            if model.isOnline, !model.hasLoaded { await model.load() }
        }
        .accessibilityHint("What Hermes can reach on this gateway")
    }

    /// "4 apps · 4 MCP servers · 2 suggested": a suggestion is plain text, never a badge or ink
    /// (`docs/plugins.md` §3.2).
    private var summary: String {
        let suggested = model.workspace?.pluginHub.suggestedCount ?? 0
        guard model.hasLoaded, suggested > 0 else { return model.summary }
        return model.summary + " · " + String(localized: "\(suggested) suggested")
    }
}
