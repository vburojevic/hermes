import HermesKit
import HermesPush
import SwiftUI
#if os(iOS)
import ActivityKit
#endif

/// Settings → Notifications (`settingsNotifications`, `settingsNotificationsOff`,
/// `macSettingsNotifications`). The gateway decides what to send, so changes sync to every gateway
/// this device is registered with.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @Bindable private var push = PushCenter.shared
    /// Set Up Push, presented here: this page is often inside a sheet already (Settings on iPhone).
    @State private var setupGateway: SetupGateway?

    private static var badgeTitle: LocalizedStringKey {
        #if os(macOS)
        "Dock Badge"
        #else
        "App Icon Badge"
        #endif
    }

    struct SetupGateway: Identifiable {
        let id: UUID
    }

    var body: some View {
        Form {
            if push.isDenied {
                Section { deniedCard }
            } else if push.authorization == .notDetermined {
                Section {
                    Button("Turn On Notifications") {
                        Task { await push.requestAuthorization() }
                    }
                    .inkFilledButton()
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("Hermes asks when it first needs you. You can also turn notifications on here.")
                }
            }

            Section {
                Toggle(isOn: $push.preferences.approvals) {
                    Text("Approvals and questions")
                    Text("Time Sensitive, so they reach you through a Focus.")
                }
                Toggle("Passwords and sign-ins", isOn: $push.preferences.passwords)
            } header: {
                Text("Needs you")
            } footer: {
                if push.timeSensitive == .disabled {
                    // `docs/setup.md` §4.13: off in the system, so a Focus holds them back.
                    Text("Hermes is paused until someone answers these. Time Sensitive is off for Hermes in \(Self.systemSettingsName), so a Focus holds them back.")
                } else {
                    Text("Hermes is paused until someone answers these.")
                }
            }
            .disabled(push.isDenied)

            Section("While you’re away") {
                Toggle(isOn: $push.preferences.replies) {
                    Text("Replies")
                    #if os(macOS)
                    Text("When a turn that ran over 30 seconds finishes, and Hermes isn’t the active window.")
                    #else
                    Text("When a turn that ran over 30 seconds finishes, or one you started and then left.")
                    #endif
                }
                Picker("Scheduled tasks", selection: $push.preferences.tasks) {
                    Text("All").tag(PushPreferences.Tasks.all)
                    Text("Failures Only").tag(PushPreferences.Tasks.failures)
                    Text("Off").tag(PushPreferences.Tasks.off)
                }
                Picker("Bots and group chats", selection: $push.preferences.bots) {
                    Text("All").tag(PushPreferences.Bots.all)
                    Text("Mentions").tag(PushPreferences.Bots.mentions)
                    Text("Off").tag(PushPreferences.Bots.off)
                }
            }
            .disabled(push.isDenied)
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif

            #if os(iOS)
            Section {
                Toggle(isOn: $push.preferences.showsText) {
                    Text("Show Message Text")
                    Text("The reply, question or command itself. Off, a notification says only what happened (“Reply ready on \(sampleGateway)”).")
                }
                Toggle(isOn: $push.preferences.liveActivity) {
                    Text("Live Activity")
                    Text("Progress on the Lock Screen and in the Dynamic Island.")
                }
            } header: {
                Text("Lock Screen")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("While iPhone is locked, the text waits for Face ID when Show Previews is set to When Unlocked.")
                    if push.preferences.liveActivity, !ActivityAuthorizationInfo().areActivitiesEnabled {
                        Text("Live Activities are off for Hermes in iOS Settings, so none show.")
                    } else if let error = push.activityError {
                        Text("The last Live Activity didn't start: \(error)")
                    }
                    if let settings = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Link("Notification Settings", destination: settings)
                            .font(.footnote.weight(.medium))
                    }
                }
            }
            .disabled(push.isDenied)
            #endif

            Section {
                Picker(Self.badgeTitle, selection: $push.badgeMode) {
                    Text("Unread Chats").tag(PushShared.BadgeMode.unreadChats)
                    Text("Needs You").tag(PushShared.BadgeMode.needsYou)
                }
            } footer: {
                Text("Unread Chats counts the chats with new messages, muted ones left out, and what Hermes is waiting on you for. Needs You counts only what Hermes is waiting on you for.")
            }

            Section {
                ForEach(app.bots) { bot in
                    let state = push.gatewayStates[bot.id] ?? .unknown
                    if state.isOn {
                        NavigationLink {
                            GatewayPushDetail(bot: bot)
                                .settingsPage(back: String(localized: "Notifications"))
                        } label: {
                            GatewayPushRow(bot: bot, state: state) {}
                        }
                    } else {
                        GatewayPushRow(bot: bot, state: state) { setupGateway = SetupGateway(id: bot.id) }
                    }
                }
            } header: {
                Text("Gateways")
            } footer: {
                #if os(macOS)
                Text("Notifications are encrypted on the gateway; only your devices can read them. While Hermes is open, the Mac gets them over the live connection.")
                #else
                Text("Each gateway sends its own notifications through the Hermes app plugin. They are encrypted on the gateway; only this device can read them, and they reach Apple through our relay.")
                #endif
            }
        }
        .formStyle(.grouped)
        .sheet(item: $setupGateway) { target in
            PushSetupSheet(gatewayID: target.id)
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await push.refreshAuthorization()
            for workspace in app.workspaces.values { await push.check(workspace) }
        }
    }

    private var sampleGateway: String {
        app.bots.first?.name ?? "Home Server"
    }

    private var deniedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.warning, in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are off")
                        .foregroundStyle(Theme.primaryText)
                    Text("Hermes can’t reach you when it needs an answer. Turn them on in \(Self.systemSettingsName).")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Divider()
            Button("Open \(Self.systemSettingsName)") { push.openSystemSettings() }
                .foregroundStyle(Theme.link)
        }
        .padding(.vertical, 4)
    }

    static var systemSettingsName: String {
        #if os(macOS)
        String(localized: "System Settings")
        #else
        String(localized: "iOS Settings")
        #endif
    }
}

/// One gateway's push status: on, not set up (Set Up…), or why not.
struct GatewayPushRow: View {
    let bot: BotConfiguration
    let state: PushCenter.GatewayState
    let setUp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            BotAvatar(bot: bot, size: 34)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .foregroundStyle(Theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .on:
            #if os(macOS)
            Text("Push on").foregroundStyle(Theme.secondaryText)
            #else
            StatusDot(color: Theme.success)
            #endif
        case .notInstalled, .needsBackend:
            Button("Set Up…", action: setUp)
                #if os(macOS)
                .buttonStyle(.bordered)
                #else
                .cardButton()
                #endif
        case .checking, .unknown:
            ProgressView().controlSize(.small)
        case .offline, .failed, .notRegistered:
            // Never a dead end (`docs/setup.md` §4.13).
            Button("Check Again") {
                Task { await PushCenter.shared.recheck(bot.id) }
            }
            #if os(macOS)
            .buttonStyle(.bordered)
            #else
            .cardButton()
            #endif
        }
    }

    private var detail: String? {
        switch state {
        case .on(let relay?):
            String(localized: "Push on · the relay isn’t answering: \(relay)")
        case .on:
            #if os(macOS)
            nil
            #else
            String(localized: "Push on")
            #endif
        case .notInstalled:
            #if os(macOS)
            // The Mac notifies while it runs, plugin or not; the plugin is for iPhone and iPad.
            String(localized: "Notifies this Mac while Hermes is open. The Hermes app plugin also reaches your iPhone and iPad.")
            #else
            String(localized: "Needs the Hermes app plugin to send notifications.")
            #endif
        case .needsBackend:
            String(localized: "Needs Bot Mode, so Hermes can reach the plugin.")
        case .notRegistered(let reason):
            reason
        case .offline:
            String(localized: "Offline")
        case .failed(let message):
            message
        case .checking, .unknown:
            String(localized: "Checking…")
        }
    }
}

/// One gateway with push on: its status, a test notification, and turning it off for this device.
struct GatewayPushDetail: View {
    let bot: BotConfiguration
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var testing: TestState = .idle
    @State private var confirmingOff = false

    enum TestState: Equatable {
        case idle, sending, sent, failed(String)
    }

    private var push: PushCenter { .shared }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: status)
                if let installation = push.installationID(for: bot.id) {
                    LabeledContent("Gateway ID", value: installation)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Notices from \(bot.name) are encrypted on the gateway for this device, then passed through our relay to Apple.")
            }
            Section {
                Button {
                    sendTest()
                } label: {
                    HStack {
                        Text("Send a Test Notification")
                        Spacer()
                        switch testing {
                        case .sending: ProgressView().controlSize(.small)
                        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        case .idle: EmptyView()
                        }
                    }
                }
                .disabled(testing == .sending)
                if case .failed(let message) = testing {
                    Text(message).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            Section {
                Button("Stop Notifications from \(bot.name)", role: .destructive) { confirmingOff = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bot.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Stop notifications from \(bot.name)?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Stop Notifications", role: .destructive) {
                if let workspace = app.workspaces[bot.id] { push.forget(workspace) }
                dismiss()
            }
        } message: {
            Text("This device leaves the gateway's list. Turn it back on with Set Up… here.")
        }
    }

    private var status: String {
        switch push.gatewayStates[bot.id] {
        case .on(let relay?): String(localized: "On · relay problem: \(relay)")
        case .on: String(localized: "On")
        default: String(localized: "Not set up")
        }
    }

    private func sendTest() {
        guard let roster = app.workspaces[bot.id]?.roster else { return }
        testing = .sending
        let deviceID = push.shared.deviceID
        Task {
            do {
                try await AppPushClient { try await roster.request($0, $1) }.test(deviceID: deviceID)
                testing = .sent
            } catch {
                testing = .failed(error.localizedDescription)
            }
        }
    }
}

/// The Settings row (`settings` → Notifications): "Approvals, replies, tasks · 2 of 3 gateways".
struct NotificationsSettingsRow: View {
    @Environment(AppModel.self) private var app
    private let push = PushCenter.shared

    var body: some View {
        NavigationLink {
            NotificationSettingsView()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                        .foregroundStyle(Theme.primaryText)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            } icon: {
                Image(systemName: "bell")
                    .foregroundStyle(Theme.primaryText)
            }
        }
    }

    private var summary: String {
        if push.isDenied { return String(localized: "Off in \(NotificationSettingsView.systemSettingsName)") }
        let prefs = push.preferences
        var kinds: [String] = []
        if prefs.approvals { kinds.append(String(localized: "Approvals")) }
        if prefs.replies { kinds.append(kinds.isEmpty ? String(localized: "Replies") : String(localized: "replies")) }
        if prefs.tasks != .off { kinds.append(kinds.isEmpty ? String(localized: "Tasks") : String(localized: "tasks")) }
        let what = kinds.isEmpty ? String(localized: "Nothing") : kinds.joined(separator: ", ")
        return String(localized: "\(what) · \(push.enabledGatewayCount) of \(app.bots.count) gateways")
    }
}
