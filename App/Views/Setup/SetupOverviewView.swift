import HermesKit
import SwiftUI

/// Settings → Setup (`docs/setup.md` §3): every feature that needs something configured on this
/// gateway or this device, with its state. Each row opens the feature's own page, or its setup
/// page with the fix and the steps; on the Mac a row also offers its fix.
struct SetupOverviewView: View {
    let workspace: BotWorkspace
    @State private var device = DeviceSetup.shared
    /// `-HERMES_SETTINGS_SETUP <id>` opens one feature (screenshots).
    @State private var opened: String? = DebugFlags.setupFeature
    @State private var editing: BotConfiguration?
    @State private var choosingProvider = false
    /// Whether this page is the one in front: a pushed feature page shows a failed fix itself.
    @State private var inFront = false

    private var setup: SetupCenter { workspace.setup }

    private var fixes: SetupFixes {
        SetupFixes(workspace: workspace, editGateway: { editing = workspace.bot }, chooseProvider: { choosingProvider = true })
    }

    var body: some View {
        Form {
            #if os(macOS)
            // In the page: in the window's toolbar it would sit among the Settings tabs.
            Section {
                HStack {
                    Text(setup.summary)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    checkAgain
                }
            }
            #endif
            Section {
                ForEach(setup.hermesStatuses) { row($0) }
            } header: {
                Text("Hermes on \(workspace.bot.name)")
            }
            Section("Features") {
                // Bot Mode stopped trying (`botModeRefused`, `botModeWrongServer`): why, above its row.
                if let problem = BotModeWarning.stopped(setup.facts.botMode) {
                    BotModeWarningCard(problem: problem, check: checkBotMode) {
                        editing = workspace.bot
                    }
                    .listRowBackground(Theme.warningTint)
                }
                ForEach(setup.featureStatuses) { row($0) }
            }
            Section {
                ForEach(setup.deviceReachStatuses) { row($0) }
            } header: {
                Text("Reaching You")
            }
            Section("Voice & Audio") {
                ForEach(workspace.voiceSetup.setupStatuses) { row($0) }
            }
            Section {
                ForEach(device.statuses) { row($0) }
            } header: {
                Text("On This Device")
            } footer: {
                Text("Hermes asks for each permission the first time a feature needs it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { checkAgain }
        }
        #endif
        .onAppear { inFront = true }
        .onDisappear { inFront = false }
        // Again when Bot Mode connects or drops: most reads go through it.
        .task(id: workspace.roster?.isConnected) { await setup.check() }
        #if os(iOS)
        .refreshable { await setup.check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings: a permission may have changed.
            device.refresh()
        }
        #endif
        .sheet(item: $editing) { bot in
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { editing = nil }
            }
            #if os(macOS)
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
            #endif
        }
        .sheet(isPresented: $choosingProvider) {
            SetupFlowView(workspace: workspace, startAt: .model, modelOnly: true) {
                choosingProvider = false
                Task { await setup.check() }
            }
            #if os(macOS)
            .frame(width: 560, height: 680)
            #endif
        }
        .alert("Couldn't Change It", isPresented: Binding(get: { inFront && setup.fixError != nil }, set: { if !$0 { setup.fixError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(setup.fixError ?? "")
        }
        .navigationDestination(item: $opened) { id in
            // Its back button even while the row isn't there (yet, or any more): the system one
            // would squeeze the Mac's Settings tabs. Not an empty Group, which takes no modifiers.
            ZStack {
                Color.clear
                if let status = setup.allStatuses.first(where: { $0.id == id }) {
                    page(status)
                }
            }
            .settingsPage(back: String(localized: "Setup"))
        }
    }

    /// Check Again on a stopped Bot Mode: one more try, which lifts the stop, then the rows.
    private func checkBotMode() async {
        await workspace.roster?.reconnectNow()
        await setup.check()
    }

    /// Check Again (⌘R on the Mac): dimmed through the first check, when every row already says
    /// Checking…; a later check shows the spinner in its place (`docs/setup.md` §3).
    @ViewBuilder
    private var checkAgain: some View {
        let spinning = setup.checkPhase.showsSpinner
        let button = Button("Check Again", systemImage: "arrow.clockwise") {
            Task { await setup.check() }
        }
        .disabled(!setup.checkPhase.canCheck)
        #if os(macOS)
        // The button keeps its place under the spinner, so the summary row keeps its height.
        button
            .cardButton()
            .keyboardShortcut("r", modifiers: .command)
            .help("Check everything again (⌘R)")
            .opacity(spinning ? 0 : 1)
            .accessibilityHidden(spinning)
            .overlay {
                if spinning {
                    Spinner()
                        .accessibilityLabel("Checking")
                }
            }
        #else
        if spinning {
            Spinner()
                .accessibilityLabel("Checking")
        } else {
            button
        }
        #endif
    }

    private func row(_ status: SetupStatus) -> some View {
        SetupRow(
            status, symbol: Self.symbol(for: status.id), fix: rowFix(for: status),
            confirm: fixes.confirmation(for: status), open: { opened = status.id }
        ) {
            destination(status)
        }
    }

    /// The fix a row offers: the one the app makes itself, or, where the feature's own page
    /// makes it (notifications, widgets, voice), that page. Transcription's key and switch live
    /// with Voice & Audio, so its row offers none and its page shows the steps.
    private func rowFix(for status: SetupStatus) -> (() -> Void)? {
        if status.id == VoiceSetupRules.id("transcription", profile: nil) { return nil }
        if let fix = fixes.action(for: status) { return fix }
        switch status.id {
        case SetupCenter.notificationsID, SetupCenter.widgetsID:
            return { opened = status.id }
        case let id where id.hasPrefix(VoiceSetupRules.prefix):
            return { opened = status.id }
        default:
            return nil
        }
    }

    private func destination(_ status: SetupStatus) -> some View {
        page(status).settingsPage(back: String(localized: "Setup"))
    }

    @ViewBuilder
    private func page(_ status: SetupStatus) -> some View {
        switch status.id {
        #if HERMES_PUSH
        case SetupCenter.notificationsID:
            NotificationSettingsView()
        #endif
        case SetupCenter.widgetsID:
            AppPluginSetupPage(workspace: workspace, plugin: .widgets)
        case let id where id.hasPrefix(VoiceSetupRules.prefix):
            VoiceSettingsView(workspace: workspace)
        default:
            SetupFeaturePage(workspace: workspace, id: status.id)
        }
    }

    static func symbol(for id: String) -> String {
        switch id {
        case GatewaySetup.ID.access: "lock.shield"
        case GatewaySetup.ID.botMode: "person.2"
        case GatewaySetup.ID.hermes: "server.rack"
        case GatewaySetup.ID.priority: "gauge.with.dots.needle.67percent"
        case GatewaySetup.ID.models: "cpu"
        case GatewaySetup.ID.memory: "brain"
        case GatewaySetup.ID.passwords: "key"
        case GatewaySetup.ID.browser: "safari"
        case GatewaySetup.ID.search: "magnifyingglass"
        case GatewaySetup.ID.checkpoints: "arrow.uturn.backward"
        case GatewaySetup.ID.tasks: "clock"
        case GatewaySetup.ID.projects: "folder"
        case GatewaySetup.ID.board: "rectangle.split.3x1"
        case GatewaySetup.ID.groupChats: "bubble.left.and.bubble.right"
        case GatewaySetup.ID.botReplies: "arrowshape.turn.up.left.2"
        case GatewaySetup.ID.botScreen: "desktopcomputer"
        case GatewaySetup.ID.learned: "sparkles"
        case SetupCenter.notificationsID: "bell.badge"
        case SetupCenter.widgetsID: "square.grid.2x2"
        case VoiceSetupRules.id("talk", profile: nil): "waveform"
        case VoiceSetupRules.id("listen", profile: nil): "speaker.wave.2"
        case VoiceSetupRules.id("messages", profile: nil): "waveform.and.mic"
        case VoiceSetupRules.id("transcription", profile: nil): "captions.bubble"
        case VoiceSetupRules.id("wake", profile: nil): "ear"
        case DeviceSetup.ID.microphone: "mic"
        case DeviceSetup.ID.camera: "camera"
        case DeviceSetup.ID.photos: "photo.on.rectangle"
        case DeviceSetup.ID.deviceOwner: "faceid"
        case DeviceSetup.ID.hiddenSuggestions: "icloud"
        default: "gearshape"
        }
    }
}

/// One feature's setup page: its section, with the fix wired to what the app can do for it.
/// It reads the status live, so the page follows a fix or a reconnect.
private struct SetupFeaturePage: View {
    let workspace: BotWorkspace
    let id: String
    @State private var editing: BotConfiguration?
    @State private var choosingProvider = false

    private var setup: SetupCenter { workspace.setup }
    private var status: SetupStatus? { setup.allStatuses.first { $0.id == id } }

    private var fixes: SetupFixes {
        SetupFixes(workspace: workspace, editGateway: { editing = workspace.bot }, chooseProvider: { choosingProvider = true })
    }

    var body: some View {
        Form {
            if let status {
                SetupSection(status, showsTitle: false, check: { await setup.check() }, fix: fixes.action(for: status), confirm: fixes.confirmation(for: status)) {
                    if status.id == GatewaySetup.ID.memory, workspace.roster?.isConnected == true {
                        #if os(macOS)
                        // The Mac has a Memory tab; the phone's Memory screen would add its menu
                        // to the Settings tabs' toolbar.
                        Button("Open the Memory Tab") {
                            UserDefaults.standard.set("memory", forKey: MacSettingsView.paneKey)
                        }
                        #else
                        MemorySettingsRow(workspace: workspace)
                        #endif
                    }
                    if status.id == GatewaySetup.ID.passwords, workspace.roster?.isConnected == true {
                        #if os(macOS)
                        Button("Open the Passwords Tab") {
                            UserDefaults.standard.set("passwords", forKey: MacSettingsView.paneKey)
                        }
                        #else
                        PasswordsSettingsRow(workspace: workspace)
                        #endif
                    }
                    if status.id == GatewaySetup.ID.browser, workspace.roster?.isConnected == true {
                        #if os(macOS)
                        Button("Open Apps & Tools") {
                            UserDefaults.standard.set("apps", forKey: MacSettingsView.paneKey)
                        }
                        #else
                        BrowserSettingsRow(workspace: workspace)
                        #endif
                    }
                    #if os(macOS)
                    if status.id == GatewaySetup.ID.priority, setup.isRaisingPriority {
                        Label {
                            Text("Restarting Hermes's services")
                        } icon: {
                            Spinner()
                        }
                    }
                    #endif
                    if status.id == GatewaySetup.ID.hermes || status.id == GatewaySetup.ID.botReplies,
                       let job = setup.currentJob(.update) {
                        GatewayJobView(job: job, setup: setup,
                                       sectionShowsRefusal: status.id == GatewaySetup.ID.hermes)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(status?.title ?? "")
        // Its own check too: a page opened straight away (or left open) follows Bot Mode coming up.
        .task(id: workspace.roster?.isConnected) { await setup.check() }
        .alert("Couldn't Change It", isPresented: Binding(get: { setup.fixError != nil }, set: { if !$0 { setup.fixError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(setup.fixError ?? "")
        }
        .sheet(item: $editing) { bot in
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { editing = nil }
            }
            #if os(macOS)
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
            #endif
        }
        .sheet(isPresented: $choosingProvider) {
            SetupFlowView(workspace: workspace, startAt: .model, modelOnly: true) {
                choosingProvider = false
                Task { await setup.check() }
            }
            #if os(macOS)
            .frame(width: 560, height: 680)
            #endif
        }
    }
}

/// The fixes Setup makes itself (`docs/setup.md` §1.2), for the overview's rows and the
/// feature pages alike. The views that hold the sheets say how to open them.
struct SetupFixes {
    let workspace: BotWorkspace
    let editGateway: () -> Void
    let chooseProvider: () -> Void

    private var setup: SetupCenter { workspace.setup }

    func confirmation(for status: SetupStatus) -> SetupConfirmation? {
        switch status.id {
        case GatewaySetup.ID.groupChats:
            .turnOffIsolation
        case GatewaySetup.ID.priority:
            .runAtFullPriority
        case GatewaySetup.ID.hermes, GatewaySetup.ID.botReplies:
            // On a Mac it says the update resets priority, and that the app offers it back.
            SetupConfirmation(
                title: String(localized: "Update Hermes on \(workspace.bot.name)?"),
                message: GatewaySetup.updateConfirmation(setup.facts),
                action: String(localized: "Update")
            )
        default:
            nil
        }
    }

    func action(for status: SetupStatus) -> (() -> Void)? {
        guard let fix = status.fix else { return nil }
        switch fix.action {
        case .linkBotMode, .signIn, .editAccess:
            return editGateway
        case .openSettings:
            return DeviceSetup.shared.fix(for: status.id) ?? { DeviceSetup.openSettings(.app) }
        default:
            switch status.id {
            case GatewaySetup.ID.models: return chooseProvider
            case GatewaySetup.ID.checkpoints: return { Task { await setup.turnOnCheckpoints() } }
            case GatewaySetup.ID.board: return { Task { await setup.turnOnBoard() } }
            case GatewaySetup.ID.learned: return { Task { await setup.turnOnTidying() } }
            case GatewaySetup.ID.groupChats: return { Task { await setup.turnOffTurnIsolation() } }
            case GatewaySetup.ID.hermes, GatewaySetup.ID.botReplies:
                return {
                    if setup.updateHermes() == nil { setup.fixError = SetupCenter.needsBotModeToUpdate }
                }
            #if os(macOS)
            case GatewaySetup.ID.priority: return { setup.runAtFullPriority() }
            #endif
            default: return nil
            }
        }
    }
}

/// Settings → Hermes on <gateway> → Setup: "2 things to set up".
struct SetupSettingsRow: View {
    let workspace: BotWorkspace

    var body: some View {
        NavigationLink {
            SetupOverviewView(workspace: workspace)
        } label: {
            HStack(spacing: 12) {
                GlyphTile(symbol: "checklist", ink: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup").foregroundStyle(Theme.primaryText)
                    Text(workspace.setup.summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .task(id: workspace.roster?.isConnected) { await workspace.setup.check() }
        .accessibilityHint("What on this gateway and this device needs setting up")
    }
}
