#if os(macOS)
import HermesKit
import HermesMacSupport
import SwiftUI

/// Settings on the Mac (`screens/mac/settings.elyx`): General, Gateways, Setup, Apps & Tools,
/// Memory, Chat, Voice & Audio, Developer and Notifications. Each pane sets its width, never
/// narrower than all the tabs need (`SettingsTabsFit`); the window follows the selected one.
struct MacSettingsView: View {
    let updater: Updater
    @State private var tabsFit = SettingsTabsFit(titles: MacSettingsView.tabTitles)

    /// The tabs' titles, in order, for `SettingsTabsFit`.
    static var tabTitles: [String] {
        var titles = [
            String(localized: "General"), String(localized: "Gateways"), String(localized: "Setup"),
            String(localized: "Apps & Tools"), String(localized: "Memory"), String(localized: "Chat"),
            String(localized: "Voice & Audio"), String(localized: "Developer"),
        ]
        #if HERMES_PUSH
        titles.append(String(localized: "Notifications"))
        #endif
        return titles
    }

    /// A pane's width: its own, or what the tabs need when that's more.
    private func width(_ own: CGFloat) -> CGFloat { max(own, tabsFit.width) }

    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    /// The tab shown; kept, so Settings opens where it was (and Skills can open Apps & Tools).
    @AppStorage(MacSettingsView.paneKey) private var pane = DebugFlags.appsAndTools != nil ? "apps" : "general"
    static let paneKey = "macSettings.pane"

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralPane(updater: updater)
                    .frame(width: width(480))
            }
            Tab("Gateways", systemImage: "server.rack", value: "gateways") {
                GatewaysPane()
                    .frame(width: width(480))
            }
            Tab("Setup", systemImage: "checklist", value: "setup") {
                MacSetupPane()
                    .frame(width: width(560), height: 620)
            }
            Tab("Apps & Tools", systemImage: "puzzlepiece.extension", value: "apps") {
                MacAppsAndToolsPane()
                    .frame(width: width(880), height: 580)
            }
            Tab("Memory", systemImage: "brain", value: "memory") {
                MacMemoryPane()
                    .frame(width: width(880), height: 600)
            }
            Tab("Chat", systemImage: "bubble.left", value: "chat") {
                ChatPane()
                    .frame(width: width(480))
            }
            Tab("Voice & Audio", systemImage: "waveform", value: "voice") {
                MacVoicePane()
                    .frame(width: width(520), height: 600)
            }
            Tab("Developer", systemImage: "hammer", value: "developer") {
                NavigationStack { Form { WidgetDeveloperSection() }.formStyle(.grouped) }
                    .frame(width: width(480), height: 300)
            }
            #if HERMES_PUSH
            Tab("Notifications", systemImage: "bell", value: "notifications") {
                NavigationStack { NotificationSettingsView() }
                    .frame(width: width(480))
            }
            #endif
        }
        .preferredColorScheme(appearance.colorScheme)
        .background(SettingsWindowProbe { tabsFit.check($0) })
        .onAppear {
            if DebugFlags.appsAndTools != nil { pane = "apps" }
            if DebugFlags.memory != nil { pane = "memory" }
            if DebugFlags.setup != nil { pane = "setup" }
        }
    }
}

/// Every Settings tab shows: none goes into the toolbar's » overflow, where the open tab has no
/// highlight. Panes are at least `width` wide, estimated from the tab titles as AppKit lays them
/// out (measured on macOS 26 and 27: labels in the 12 pt system font, each tab its label plus
/// 7 pt and at least 55 pt, 1 pt apart, 8 pt in from each edge). Then the toolbar itself is
/// checked after each layout: while it still clips a tab (a larger text size, a longer
/// translation), the width grows by what's clipped.
@MainActor
@Observable
final class SettingsTabsFit {
    private(set) var width: CGFloat

    init(titles: [String]) {
        width = titles.map(Self.tabWidth).reduce(0, +) + CGFloat(max(titles.count - 1, 0)) + 16
        #if DEBUG
        // `-HERMES_SETTINGS_TABS_START <width>`: start too narrow, to watch the check widen it.
        let start = UserDefaults.standard.double(forKey: "HERMES_SETTINGS_TABS_START")
        if start > 0 { width = start }
        #endif
    }

    private static func tabWidth(_ title: String) -> CGFloat {
        let label = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return max(55, ceil(label) + 7)
    }

    func check(_ window: NSWindow) {
        guard let toolbar = window.toolbar, let visible = toolbar.visibleItems else { return }
        let clipped = toolbar.items.filter { item in !visible.contains { $0 === item } }
        guard !clipped.isEmpty else { return }
        let needed = window.frame.width + clipped.map { Self.tabWidth($0.label) + 1 }.reduce(0, +)
        if needed > width { width = needed }
    }
}

/// Hands `onLayout` the Settings window after it changes size (switching tabs resizes it).
private struct SettingsWindowProbe: NSViewRepresentable {
    let onLayout: (NSWindow) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onLayout: onLayout) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onLayout = onLayout }

    final class ProbeView: NSView {
        var onLayout: (NSWindow) -> Void
        private var observer: (any NSObjectProtocol)?

        init(onLayout: @escaping (NSWindow) -> Void) {
            self.onLayout = onLayout
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // After AppKit has laid the toolbar out for the new size.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            Task { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onLayout(window)
        }
    }
}

/// Setup for the current gateway (`docs/setup.md` §3).
private struct MacSetupPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            if let workspace = app.currentWorkspace {
                SetupOverviewView(workspace: workspace)
            } else {
                ContentUnavailableView("No Gateway", systemImage: "server.rack", description: Text("Add a gateway to see what it has set up."))
            }
        }
    }
}

/// `macSettingsGeneral`: appearance, privacy, version and updates, links.
private struct GeneralPane: View {
    @Bindable var updater: Updater
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Privacy")
                    Text("Hermes talks only to your own gateways. No accounts, no analytics.")
                }
            }
            Section {
                AboutVersionRow(version: Self.versionString)
                Toggle(isOn: $updater.checksAutomatically) {
                    Text("Check for updates automatically")
                    Text(updater.isAvailable ? String(localized: "Updates with Sparkle.") : String(localized: "This build doesn't update itself."))
                }
                .disabled(!updater.isAvailable)
                Link(destination: URL(string: "https://github.com/vburojevic/hermes")!) {
                    LabeledContent("Source code on GitHub") { Image(systemName: "arrow.up.right") }
                        .foregroundStyle(Theme.primaryText)
                }
                Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) {
                    LabeledContent("Hermes Agent documentation") { Image(systemName: "arrow.up.right") }
                        .foregroundStyle(Theme.primaryText)
                }
                Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent")!) {
                    LabeledContent("Hermes Agent on GitHub") { Image(systemName: "arrow.up.right") }
                        .foregroundStyle(Theme.primaryText)
                }
            } footer: {
                Text("An independent app by Caffeinated Code for Hermes Agent, the open-source agent by Nous Research. Not affiliated with Nous Research.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// `macSettingsGateways`: the gateways with their status, + and −, Pair a Device…, Edit….
private struct GatewaysPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var isAdding = false
    @State private var editing: BotConfiguration?
    @State private var pairing: UUID?
    @State private var removing: BotConfiguration?
    @State private var removeError: String?

    private var selected: BotConfiguration? {
        app.bots.first { $0.id == (selection ?? app.bots.first?.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $selection) {
                ForEach(app.bots) { bot in
                    HStack(spacing: 10) {
                        BotAvatar(bot: bot, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bot.name)
                                .foregroundStyle(Theme.primaryText)
                            Text(subtitle(for: bot))
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Circle()
                            .fill(statusColor(for: bot))
                            .frame(width: 8, height: 8)
                            .padding(3)
                            .background(Circle().fill(statusColor(for: bot).opacity(0.18)))
                            .accessibilityLabel(statusText(for: bot))
                    }
                    .padding(.vertical, 4)
                    .tag(bot.id)
                    .contextMenu {
                        Button("Edit…") { editing = bot }
                        Button("Pair a Device…") { pairing = bot.id }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = bot }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))

            HStack(spacing: 6) {
                Button { isAdding = true } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .help("Add Gateway…")
                Button { removing = selected } label: { Image(systemName: "minus").frame(width: 14, height: 14) }
                    .disabled(selected == nil)
                    .help("Remove Gateway…")
                Spacer()
                Button("Pair a Device…") { pairing = selected?.id }
                    .disabled(selected == nil)
                Button("Edit…") { editing = selected }
                    .disabled(selected == nil)
            }
            .controlSize(.regular)

            Text("API keys are stored in the Keychain on this Mac.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(20)
        .onAppear { if selection == nil { selection = app.bots.first?.id } }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                BotEditorView(mode: .add) { isAdding = false }
            }
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
        }
        .sheet(item: $editing) { bot in
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { editing = nil }
            }
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
        }
        .sheet(item: Binding(get: { pairing.map(PairingTarget.init) }, set: { pairing = $0?.id })) { target in
            PairingSheet(botID: target.id)
        }
        .alert(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                guard let bot = removing else { return }
                do {
                    try app.removeBot(bot.id)
                    selection = nil
                } catch {
                    removeError = error.localizedDescription
                }
            }
        } message: {
            Text("Its chats stay on the gateway. Its API key is removed from this Mac.")
        }
        .alert("Couldn't Remove", isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removeError ?? "")
        }
    }

    private struct PairingTarget: Identifiable {
        let id: UUID
    }

    private func subtitle(for bot: BotConfiguration) -> String {
        var parts = [bot.displayAddress]
        if bot.backend != nil { parts.append(String(localized: "Bot Mode")) }
        if case .failed = app.workspaces[bot.id]?.connection { parts.append(String(localized: "Offline")) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(for bot: BotConfiguration) -> Color {
        switch app.workspaces[bot.id]?.connection {
        case .online?: Theme.success
        case .connecting?: Theme.warning
        case .failed?: Theme.danger
        default: Theme.tertiaryText
        }
    }

    private func statusText(for bot: BotConfiguration) -> String {
        switch app.workspaces[bot.id]?.connection {
        case .online?: String(localized: "Connected")
        case .connecting?: String(localized: "Connecting")
        case .failed?: String(localized: "Offline")
        default: String(localized: "Not connected")
        }
    }
}

/// `macSettingsChat`: how chats behave.
private struct ChatPane: View {
    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandAgentActivity = false
    @AppStorage(PreferenceKey.showUsage) private var showUsage = false
    @AppStorage(PreferenceKey.openChatsAt) private var openChatsAt = OpenChatsAt.firstUnread
    @AppStorage(PreferenceKey.chatSounds) private var chatSounds = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $openChatsAt) {
                    ForEach(OpenChatsAt.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Text("Open Chats At")
                    Text("A chat with new messages opens at the first one, or at the latest.")
                }
                Toggle(isOn: $chatSounds) {
                    Text("Sounds")
                    Text("A soft sound when you send and when a reply arrives.")
                }
            }
            Section {
                Toggle(isOn: $expandAgentActivity) {
                    Text("Show agent steps while working")
                    Text("Tool calls and thinking appear in the transcript as they happen.")
                }
                FollowUpDefaultPicker()
            }
            Section {
                Toggle(isOn: $sendWithReturn) {
                    Text("Send with Return")
                    Text("With Send with Return on, Shift-Return starts a new line.")
                }
            }
            Section {
                Toggle(isOn: $showUsage) {
                    Text("Show usage under replies")
                    Text("Tokens, cost and how full the context is, under each reply.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
