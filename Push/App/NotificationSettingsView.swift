import HermesKit
import HermesPush
import SwiftUI

/// Settings → Notifications (`settingsNotifications`, `settingsNotificationsOff`,
/// `macSettingsNotifications`). The gateway decides what to send, so changes sync to every gateway
/// this device is registered with.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @Bindable private var push = PushCenter.shared

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
                Text("Hermes is paused until someone answers these.")
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
                Toggle(isOn: $push.preferences.background) {
                    Text("Background work")
                    Text("Processes and side tasks that finish.")
                }
            }
            .disabled(push.isDenied)
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif

            #if os(iOS)
            Section {
                Toggle(isOn: $push.preferences.liveActivity) {
                    Text("Live Activity")
                    Text("Progress on the Lock Screen and in the Dynamic Island.")
                }
                Picker("Show details", selection: $push.preferences.showDetails) {
                    Text("Always").tag(PushPreferences.ShowDetails.always)
                    Text("When Unlocked").tag(PushPreferences.ShowDetails.unlocked)
                    Text("Never").tag(PushPreferences.ShowDetails.never)
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("When locked, notifications say only what kind of thing happened (“Needs your OK on \(sampleGateway)”).")
            }
            .disabled(push.isDenied)
            #endif

            Section {
                ForEach(app.bots) { bot in
                    GatewayPushRow(bot: bot, state: push.gatewayStates[bot.id] ?? .unknown) {
                        push.setupGateway = bot.id
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
        case .offline, .failed:
            StatusDot(color: Theme.danger)
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
            String(localized: "Needs the Hermes app plugin to send notifications.")
        case .needsBackend:
            String(localized: "Needs Bot Mode, so Hermes can reach the plugin.")
        case .offline:
            String(localized: "Offline")
        case .failed(let message):
            message
        case .checking, .unknown:
            String(localized: "Checking…")
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
