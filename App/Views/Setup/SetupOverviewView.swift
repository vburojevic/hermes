import HermesKit
import SwiftUI

/// Settings → Setup (`docs/setup.md` §3): every feature that needs something configured on this
/// gateway or this device, with its state. Each row opens the feature's own page, or its setup
/// page with the fix and the steps.
struct SetupOverviewView: View {
    let workspace: BotWorkspace
    @State private var device = DeviceSetup.shared
    /// `-HERMES_SETTINGS_SETUP <id>` opens one feature (screenshots).
    @State private var opened: String? = DebugFlags.setupFeature

    private var setup: SetupCenter { workspace.setup }

    var body: some View {
        Form {
            #if os(macOS)
            // In the page: in the window's toolbar it would sit among the Settings tabs.
            Section {
                HStack {
                    Text(setup.hasChecked ? setup.summary : String(localized: "Checking…"))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    SetupCheckButton(check: { await setup.check() }, style: .card)
                }
            }
            #endif
            Section {
                ForEach(setup.hermesStatuses) { row($0) }
            } header: {
                Text("Hermes on \(workspace.bot.name)")
            }
            Section("Features") {
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
            ToolbarItem(placement: .primaryAction) {
                if setup.isChecking {
                    Spinner()
                } else {
                    Button("Check Again", systemImage: "arrow.clockwise") {
                        Task { await setup.check() }
                    }
                }
            }
        }
        #endif
        // Again when Bot Mode connects or drops: most reads go through it.
        .task(id: workspace.roster?.isConnected) { await setup.check() }
        #if os(iOS)
        .refreshable { await setup.check() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings: a permission may have changed.
            device.refresh()
        }
        #endif
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

    private func row(_ status: SetupStatus) -> some View {
        SetupRow(status, symbol: Self.symbol(for: status.id)) {
            destination(status)
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
        case GatewaySetup.ID.botMode: "person.2"
        case GatewaySetup.ID.hermes: "server.rack"
        case GatewaySetup.ID.priority: "gauge.with.dots.needle.67percent"
        case GatewaySetup.ID.models: "cpu"
        case GatewaySetup.ID.memory: "brain"
        case GatewaySetup.ID.search: "magnifyingglass"
        case GatewaySetup.ID.checkpoints: "arrow.uturn.backward"
        case GatewaySetup.ID.tasks: "clock"
        case GatewaySetup.ID.projects: "folder"
        case GatewaySetup.ID.board: "rectangle.split.3x1"
        case GatewaySetup.ID.groupChats: "bubble.left.and.bubble.right"
        case GatewaySetup.ID.botReplies: "arrowshape.turn.up.left.2"
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
        case DeviceSetup.ID.deviceOwner: "faceid"
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

    var body: some View {
        Form {
            if let status {
                SetupSection(status, showsTitle: false, check: { await setup.check() }, fix: fix(for: status), confirm: confirmation(for: status)) {
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
                        GatewayJobView(job: job)
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

    private func confirmation(for status: SetupStatus) -> SetupConfirmation? {
        switch status.id {
        case GatewaySetup.ID.groupChats:
            .turnOffIsolation
        case GatewaySetup.ID.priority:
            SetupConfirmation(
                title: String(localized: "Run Hermes at full priority?"),
                message: String(localized: "Hermes's services on this Mac restart to run like apps do, so a busy Mac no longer slows them down. Replies in progress stop; the app reconnects by itself."),
                action: String(localized: "Run at Full Priority")
            )
        case GatewaySetup.ID.hermes, GatewaySetup.ID.botReplies:
            SetupConfirmation(
                title: String(localized: "Update Hermes on \(workspace.bot.name)?"),
                message: String(localized: "Hermes updates itself, then restarts once running chats and tasks finish. The app reconnects by itself."),
                action: String(localized: "Update")
            )
        default:
            nil
        }
    }

    private func fix(for status: SetupStatus) -> (() -> Void)? {
        guard let fix = status.fix else { return nil }
        switch fix.action {
        case .linkBotMode, .signIn:
            return { editing = workspace.bot }
        case .openSettings:
            return DeviceSetup.shared.fix(for: status.id) ?? { DeviceSetup.openSettings(.app) }
        default:
            switch status.id {
            case GatewaySetup.ID.models: return { choosingProvider = true }
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
                    Text(workspace.setup.hasChecked ? workspace.setup.summary : String(localized: "Checking…"))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .task(id: workspace.roster?.isConnected) { await workspace.setup.check() }
        .accessibilityHint("What on this gateway and this device needs setting up")
    }
}
