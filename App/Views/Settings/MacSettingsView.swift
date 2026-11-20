#if os(macOS)
import HermesKit
import HermesMacSupport
import SwiftUI

/// Settings on the Mac (`screens/mac/settings.elyx`): General, Gateways, Setup, Apps & Tools,
/// Passwords, Memory, Chat, Voice & Audio, Developer and Notifications. Each pane sets its width, never
/// narrower than all the tabs need (`SettingsTabsFit`); the window follows the selected one.
struct MacSettingsView: View {
    let updater: Updater
    @State private var tabsFit = SettingsTabsFit(titles: MacSettingsView.tabTitles)

    /// The tabs' titles, in order, for `SettingsTabsFit`.
    static var tabTitles: [String] {
        var titles = [
            String(localized: "General"), String(localized: "Gateways"), String(localized: "Setup"),
            String(localized: "Apps & Tools"), String(localized: "Passwords"), String(localized: "Memory"), String(localized: "Chat"),
            String(localized: "Voice & Audio"), String(localized: "Developer"),
        ]
        #if HERMES_PUSH
        titles.append(String(localized: "Notifications"))
        #endif
        return titles
    }

    /// The drawn width of every pane but Apps & Tools, Passwords and Memory, which keep their own.
    static let paneWidth: CGFloat = 680

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
                    .frame(width: width(Self.paneWidth))
            }
            Tab("Gateways", systemImage: "server.rack", value: "gateways") {
                GatewaysPane()
                    .frame(width: width(Self.paneWidth))
            }
            Tab("Setup", systemImage: "checklist", value: "setup") {
                MacSetupPane()
                    .frame(width: width(Self.paneWidth), height: 620)
            }
            Tab("Apps & Tools", systemImage: "puzzlepiece.extension", value: "apps") {
                MacAppsAndToolsPane()
                    .frame(width: width(880), height: 580)
            }
            Tab("Passwords", systemImage: "key", value: "passwords") {
                MacPasswordsPane()
                    .frame(width: width(880), height: 600)
            }
            Tab("Memory", systemImage: "brain", value: "memory") {
                MacMemoryPane()
                    .frame(width: width(880), height: 600)
            }
            Tab("Chat", systemImage: "bubble.left", value: "chat") {
                ChatPane()
                    .frame(width: width(Self.paneWidth))
            }
            Tab("Voice & Audio", systemImage: "waveform", value: "voice") {
                MacVoicePane()
                    .frame(width: width(Self.paneWidth), height: 600)
            }
            Tab("Developer", systemImage: "hammer", value: "developer") {
                // As tall as its one section (`macSettingsDeveloper`); the gallery it opens in
                // Debug builds scrolls inside that.
                NavigationStack {
                    Form { WidgetDeveloperSection() }
                        .formStyle(.grouped)
                        .scrollDisabled(true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: width(Self.paneWidth))
            }
            #if HERMES_PUSH
            Tab("Notifications", systemImage: "bell", value: "notifications") {
                // As tall as `macSettingsNotifications` draws it, scrolling when its gateways or
                // larger text need more; without a height it kept the previous tab's.
                NavigationStack { NotificationSettingsView() }
                    .frame(width: width(Self.paneWidth), height: 750)
            }
            #endif
        }
        .preferredColorScheme(appearance.colorScheme)
        .background(SettingsWindowProbe { tabsFit.check($0) })
        .onAppear {
            if DebugFlags.appsAndTools != nil { pane = "apps" }
            if DebugFlags.memory != nil { pane = "memory" }
            if DebugFlags.setup != nil { pane = "setup" }
            if DebugFlags.passwords != nil { pane = "passwords" }
            if DebugFlags.browser != nil { pane = "apps" }
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
    /// Whether the Setup tab is the one shown, so ⌘R is Check Again only there.
    @State private var shown = false

    var body: some View {
        NavigationStack {
            if let workspace = app.currentWorkspace {
                SetupOverviewView(workspace: workspace)
            } else {
                ContentUnavailableView("No Gateway", systemImage: "server.rack", description: Text("Add a gateway to see what it has set up."))
            }
        }
        .onAppear { shown = true }
        .onDisappear { shown = false }
        // ⌘R is the Chat menu's, and the Settings window would hand it to the chat behind, so the
        // menu item becomes Check Again while Setup is shown, the list or a feature's page pushed
        // on it (`docs/setup.md` §2).
        .focusedSceneValue(\.tryAgain, shown ? checkAgain : nil)
    }

    private var checkAgain: TryAgainAction? {
        guard let setup = app.currentWorkspace?.setup else { return nil }
        return TryAgainAction(title: String(localized: "Check Again"), isEnabled: setup.checkPhase.canCheck) {
            Task { await setup.check() }
        }
    }
}

/// `macSettingsGeneral`: appearance, version and updates, links.
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

/// `macSettingsGateways`: a native list of the gateways in a box with + and − attached below it,
/// then Pair a Device… and Edit…. Return or a double-click edits, Delete asks to remove, and a
/// right-click shows the menu.
private struct GatewaysPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection: UUID?
    @State private var isAdding = false
    @State private var editing: BotConfiguration?
    @State private var pairing: UUID?
    @State private var removing: BotConfiguration?
    @State private var removeError: String?
    /// The tallest row as drawn (40 pt at the default size), so the list is as tall as its rows.
    @State private var rowHeight: CGFloat = 40

    /// The rows shown before the list scrolls.
    private static let visibleRows = 6

    private var selected: BotConfiguration? {
        app.bots.first { $0.id == (selection ?? app.bots.first?.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(app.bots) { bot in
                        GatewayListRow(bot: bot, workspace: app.workspaces[bot.id])
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                if height > rowHeight { rowHeight = height }
                            }
                            .tag(bot.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let bot = bot(in: ids) {
                        Button("Edit…") { editing = bot }
                        Button("Pair a Device…") { pairing = bot.id }
                        Divider()
                        Button("Remove…", role: .destructive) { removing = bot }
                    }
                } primaryAction: { ids in
                    editing = bot(in: ids)
                }
                .onDeleteCommand { removing = app.bots.first { $0.id == selection } }
                .frame(height: CGFloat(min(max(app.bots.count, 1), Self.visibleRows)) * rowHeight + 10)

                Divider()
                HStack(spacing: 0) {
                    Button { isAdding = true } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .help("Add Gateway…")
                    .accessibilityLabel("Add Gateway…")
                    Divider().frame(height: 14)
                    Button { removing = selected } label: {
                        Image(systemName: "minus").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .disabled(selected == nil)
                    .help("Remove Gateway…")
                    .accessibilityLabel("Remove Gateway…")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
            }
            .background(Theme.sheetCell)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            HStack(spacing: 8) {
                Spacer()
                Button("Pair a Device…") { pairing = selected?.id }
                    .disabled(selected == nil)
                Button("Edit…") { editing = selected }
                    .disabled(selected == nil)
            }
            .buttonStyle(.bordered)

            Text("API keys are stored in the Keychain on this Mac.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheetBackground)
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

    /// The gateway a right-click or a double-click is about (the list selects one at a time).
    private func bot(in ids: Set<UUID>) -> BotConfiguration? {
        guard let id = ids.first else { return nil }
        return app.bots.first { $0.id == id }
    }
}

/// One gateway in the Mac list: avatar, name, address, and its state as a word beside the dot,
/// never colour alone. Hover shows the state on the dot and a truncated address in full.
private struct GatewayListRow: View {
    let bot: BotConfiguration
    let workspace: BotWorkspace?

    var body: some View {
        let status = workspace.map { ConnectionStatus($0) }
        let color = status?.color ?? Theme.placeholderText
        let title = status?.title ?? String(localized: "Not connected")
        // Bot Mode's sign-in was refused: that, after the address, until it's fixed
        // (`docs/setup.md` §4.1).
        let stopped = workspace?.botModeStopLine
        let address = stopped.map { "\(bot.displayAddress) · \($0)" } ?? subtitle
        HStack(spacing: 10) {
            BotAvatar(bot: bot, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .foregroundStyle(Theme.primaryText)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(stopped == nil ? Theme.secondaryText : Theme.warning)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(address)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                StatusDot(color: color)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(color.opacity(0.22)))
            }
            .help(title)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([bot.name, stopped ?? title, status?.detail].compactMap { $0 }.joined(separator: ", "))
    }

    /// The address, and Bot Mode when the gateway has it on. The state is beside the dot.
    private var subtitle: String {
        var parts = [bot.displayAddress]
        if bot.backend != nil { parts.append(String(localized: "Bot Mode")) }
        return parts.joined(separator: " · ")
    }
}

/// `macSettingsChat`: how chats behave.
private struct ChatPane: View {
    @AppStorage(PreferenceKey.sendWithReturn) private var sendWithReturn = true
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandAgentActivity = false
    @AppStorage(PreferenceKey.showUsage) private var showUsage = false
    @AppStorage(PreferenceKey.openChatsAt) private var openChatsAt = OpenChatsAt.firstUnread
    @AppStorage(PreferenceKey.chatSounds) private var chatSounds = false
    @AppStorage(PreferenceKey.keepChatAtBottom) private var keepChatAtBottom = SendScroll.keepsAtBottomByDefault

    var body: some View {
        Form {
            Section {
                Picker(selection: $openChatsAt) {
                    ForEach(OpenChatsAt.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    Text("Open chats at")
                    Text("A chat with new messages opens at the first one, or at the latest.")
                }
                Toggle(isOn: $keepChatAtBottom) {
                    Text("Keep chat at bottom when sending")
                    Text("The message you send stays at the bottom and the reply fills in below it, instead of moving to the top.")
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
