import HermesKit
import HermesPush
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Asking in context (`permissionPrime`): after the first approval, a turn over 30 s, or leaving
/// while one runs (then on the way back), never at launch. Shows what a notification will look
/// like before the system asks.
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
                    guard !asking else { return }
                    asking = true
                    Task {
                        await PushCenter.shared.requestAuthorization()
                        dismiss()
                    }
                } label: {
                    ZStack {
                        Text("Turn On Notifications")
                            .font(.body.weight(.semibold))
                            .opacity(asking ? 0 : 1)
                        if asking { ProgressView().tint(Theme.inkForeground) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .inkFilledButton()
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

/// Set Up Push (`pushSetup`): push's review (`pluginReviewPush`, `docs/plugins.md` §2.1): what
/// it can do, the promise, the source, Install on <gateway> (Hermes and every Bot), and Set Up in
/// Terminal Instead. Without Bot Mode, the way to link it and the commands. The sheet polls the
/// gateway and closes with a check mark once the plugin answers, however it got there.
struct PushSetupSheet: View {
    let gatewayID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isDone = false

    /// Where people get the plugin.
    static let pluginSource = "vburojevic/hermes-app-push"
    static let installCommand = "hermes plugins install \(pluginSource) --enable"
    /// Each Bot is a profile with its own plugins.
    static let profilesCommand = "for p in $(ls ~/.hermes/profiles 2>/dev/null); do hermes -p \"$p\" plugins install \(pluginSource) --enable; done"
    static let restartCommand = "hermes gateway restart"
    static let allCommands = [installCommand, profilesCommand, restartCommand].joined(separator: "\n")

    private var bot: BotConfiguration? { app.bots.first { $0.id == gatewayID } }
    private var state: PushCenter.GatewayState { PushCenter.shared.gatewayStates[gatewayID] ?? .unknown }

    var body: some View {
        NavigationStack {
            Group {
                if isDone {
                    done
                } else if state == .needsBackend || app.workspaces[gatewayID]?.roster == nil {
                    ScrollView {
                        VStack(spacing: 20) {
                            needsBackend
                            steps
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .navigationTitle("Set Up Push")
                } else if let workspace = app.workspaces[gatewayID] {
                    AppPluginReviewView(workspace: workspace, plugin: .push, offersTerminal: true)
                }
            }
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
        .frame(width: 520, height: 640)
        #else
        .presentationDetents([.large])
        #endif
    }

    private var done: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.success).frame(width: 68, height: 68)
                Image(systemName: "checkmark").font(.title.bold()).foregroundStyle(.white)
            }
            Text("Push is on for \(bot?.name ?? "")")
                .font(.title2.bold())
                .foregroundStyle(Theme.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The commands, for a gateway the app can't install on (no Bot Mode).
    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, "Install it in Hermes and every Bot", command: Self.installCommand + "\n" + Self.profilesCommand)
            Divider().padding(.leading, 16)
            step(2, "Restart the gateway", command: Self.restartCommand)
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
            SetupCommand(command: command)
        }
        .padding(16)
    }

    private var needsBackend: some View {
        VStack(spacing: 12) {
            Text("The app reaches the plugin through the gateway’s Hermes backend (`hermes serve`). Link Bot Mode for \(bot?.name ?? "this gateway") first, then set up push.")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            // The way there, not just the sentence (`docs/setup.md` §4.1); the sheet goes on
            // once Bot Mode answers.
            if let workspace = app.workspaces[gatewayID] {
                BotModeLinkButton(workspace: workspace)
            }
            SetupDocsLink(url: GatewaySetup.Docs.botMode)
                .font(.footnote)
        }
        .padding(16)
        .background(Theme.groupedCell, in: .rect(cornerRadius: 24))
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
}
