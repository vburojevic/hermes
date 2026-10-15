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
    @State private var editing: BotConfiguration?
    @State private var isAddingBot = false
    /// `-HERMES_APPS_TOOLS <tab>[:<item>]` opens Apps and Tools (screenshots).
    @State private var opensAppsAndTools = DebugFlags.appsAndTools != nil

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
                        AppsAndToolsSettingsRow(model: workspace.appsAndTools)
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
                    #if os(iOS)
                    Toggle("Haptics", isOn: $haptics)
                    #endif
                } header: {
                    Text("Chat")
                } footer: {
                    Text("With Send with Return on, Shift-Return starts a new line on a hardware keyboard.")
                }

                #if HERMES_PUSH && os(iOS)
                Section("Notifications") {
                    NotificationsSettingsRow()
                }
                #endif

                Section("About") {
                    LabeledContent("Version", value: Self.versionString)
                    Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) {
                        Label("Hermes Agent documentation", systemImage: "book")
                    }
                    Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent")!) {
                        Label("Hermes Agent on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if router?.pluginInstallRequest != nil || router?.opensAppsAndTools == true { opensAppsAndTools = true }
                router?.opensAppsAndTools = false
            }
            .navigationDestination(isPresented: $opensAppsAndTools) {
                if let workspace = app.currentWorkspace { AppsAndToolsView(model: workspace.appsAndTools) }
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

/// Settings → Hermes on <gateway> → Apps and Tools: a count, plus "1 needs you" when something
/// expired or failed.
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
                    Text(model.summary)
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
}
