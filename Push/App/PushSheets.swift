import HermesKit
import HermesPush
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Asking in context (`permissionPrime`): after the first approval or a turn over 30 s, never at
/// launch. Shows what a notification will look like before the system asks.
struct PermissionPrimeSheet: View {
    let reason: PushCenter.PrimeReason
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false

    var body: some View {
        VStack(spacing: 20) {
            SampleNotification()
            VStack(spacing: 8) {
                Text("Know when Hermes needs you")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                Text("Hermes keeps working after you leave the app. Notifications bring you back when it matters.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                ReasonRow(symbol: "hand.raised", title: "Approvals and questions", detail: "Answer from the Lock Screen, even mid-task.")
                ReasonRow(symbol: "bubble.left.and.text.bubble.right", title: "Replies while you’re away", detail: "When a long answer finishes.")
                ReasonRow(symbol: "calendar.badge.clock", title: "Tasks and Bots", detail: "Scheduled results, and Bots that mention you.")
            }
            .padding(.horizontal, 6)
            VStack(spacing: 6) {
                Button {
                    asking = true
                    Task {
                        await PushCenter.shared.requestAuthorization()
                        dismiss()
                    }
                } label: {
                    Text("Turn On Notifications")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .inkFilledButton()
                .disabled(asking)
                Button("Not Now") {
                    PushCenter.shared.notNow()
                    dismiss()
                }
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        #if os(iOS)
        .presentationDetents([.height(640), .large])
        .presentationCornerRadius(46)
        #else
        .frame(width: 420)
        #endif
        .interactiveDismissDisabled(asking)
    }
}

/// The notification the sheet shows as an example (`notificationApproval`).
private struct SampleNotification: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.black)
                .frame(width: 38, height: 38)
                .overlay { HermesMark().fill(.white).padding(9) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Label("TIME SENSITIVE", systemImage: "clock")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                HStack(alignment: .firstTextBaseline) {
                    Text("Hermes needs your OK").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("now").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Text("Disk cleanup on the NAS").font(.subheadline.weight(.semibold))
                Text("Run rm -rf ~/snapshots/2026-0[1-8]-* on Home Server?")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.primaryText)
        }
        .padding(14)
        .background(Theme.surfaceRaised, in: .rect(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.shadow, radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example: Hermes needs your OK. Disk cleanup on the NAS. Run a command on Home Server?")
    }
}

private struct ReasonRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Theme.primaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.primaryText)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Set Up Push (`pushSetup`): a gateway without the plugin. Two commands to copy, or Ask Hermes to
/// Set It Up, which starts a chat on that gateway. The sheet polls the gateway and closes with a
/// check mark once the plugin answers.
struct PushSetupSheet: View {
    let gatewayID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    @State private var isDone = false

    /// Where people get the plugin.
    static let pluginSource = "vburojevic/hermes-app-push"
    static let installCommand = "hermes plugins install \(pluginSource) --enable"
    static let restartCommand = "hermes gateway restart"

    private var bot: BotConfiguration? { app.bots.first { $0.id == gatewayID } }
    private var state: PushCenter.GatewayState { PushCenter.shared.gatewayStates[gatewayID] ?? .unknown }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if state == .needsBackend {
                        needsBackend
                    } else {
                        steps
                        actions
                    }
                    Text("The relay and Apple see only that something happened, never the command or the reply. No account needed.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Set Up Push")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .task { await poll() }
        #if os(macOS)
        .frame(width: 460, height: 580)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let bot {
                ZStack {
                    BotAvatar(bot: bot, size: 56)
                    if isDone {
                        Circle().fill(Theme.success).frame(width: 56, height: 56)
                        Image(systemName: "checkmark").font(.title2.bold()).foregroundStyle(.white)
                    }
                }
                .animation(Theme.spring, value: isDone)
                .padding(.top, 8)
            }
            Text(isDone ? String(localized: "Push is on for \(bot?.name ?? "")") : String(localized: "Push for \(bot?.name ?? "this gateway")"))
                .font(.title2.bold())
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            Text("Hermes Agent can’t reach your \(Self.deviceName) by itself. A small plugin on the gateway sends encrypted notices through our relay to Apple.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, "Install the plugin on the gateway", command: Self.installCommand)
            Divider().padding(.leading, 16)
            step(2, "Restart the gateway", command: Self.restartCommand)
            Divider().padding(.leading, 16)
            HStack(spacing: 10) {
                if isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Text("\(bot?.name ?? "The gateway") checked in.")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(bot?.name ?? "the gateway") to check in…")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
            .padding(16)
            .accessibilityElement(children: .combine)
        }
        .background(Theme.groupedCell, in: .rect(cornerRadius: 24))
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, command: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 22, height: 22)
                    .background(Theme.ink, in: .circle)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Theme.primaryText)
            }
            HStack(alignment: .top) {
                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copy(command)
                } label: {
                    Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied == command ? "Copied" : "Copy command")
            }
            .padding(12)
            .background(Theme.controlFill, in: .rect(cornerRadius: 12))
        }
        .padding(16)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                askHermes()
            } label: {
                Text("Ask Hermes to Set It Up")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .inkFilledButton()
            .disabled(isDone)
            Button {
                copy(Self.installCommand + "\n" + Self.restartCommand)
            } label: {
                Text(copied?.contains("\n") == true ? "Copied" : "Copy Both Commands")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .cardButton()
        }
    }

    private var needsBackend: some View {
        VStack(spacing: 12) {
            Text("The app reaches the plugin through the gateway’s Hermes backend (`hermes serve`). Link Bot Mode for \(bot?.name ?? "this gateway") first, then set up push.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(Theme.groupedCell, in: .rect(cornerRadius: 24))
    }

    /// Starts a chat on that gateway asking Hermes to install and enable the plugin, then restart.
    /// Hermes asks for approval as usual before running anything.
    private func askHermes() {
        guard let workspace = app.workspaces[gatewayID] else { return }
        app.select(gatewayID)
        workspace.sidebarMode = .chats
        workspace.startNewChat()
        let conversation = workspace.currentConversation
        conversation.draft = String(localized: """
        Please set up push notifications for the Hermes app on this machine: install and enable the \
        hermes-app-push plugin with `\(Self.installCommand)`, then restart the gateway with \
        `\(Self.restartCommand)` so it loads. Tell me when it's done.
        """)
        conversation.send()
        dismiss()
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = text
    }

    /// Asks the gateway every few seconds; closes with a check mark when the plugin answers.
    private func poll() async {
        while !Task.isCancelled {
            await PushCenter.shared.recheck(gatewayID)
            if state.isOn {
                isDone = true
                try? await Task.sleep(for: .seconds(1.6))
                dismiss()
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private static var deviceName: String {
        #if os(macOS)
        String(localized: "Mac")
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "iPad") : String(localized: "iPhone")
        #endif
    }
}
