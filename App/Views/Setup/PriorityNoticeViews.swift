import HermesKit
import SwiftUI

// Hermes at background priority on its Mac, said beyond Settings → Setup (`docs/setup.md` §4.17):
// on the result of an update or restart the app ran, which is what writes the gateway's plist
// again, and on the Mac in the sidebar's footer, one line above the connection.

extension SetupConfirmation {
    /// Run at Full Priority asks first: replies in progress stop.
    static var runAtFullPriority: SetupConfirmation {
        SetupConfirmation(
            title: String(localized: "Run Hermes at full priority?"),
            message: String(localized: "Hermes's services on this Mac restart to run like apps do, so a busy Mac no longer slows them down. Replies in progress stop; the app reconnects by itself."),
            action: String(localized: "Run at Full Priority")
        )
    }
}

/// Under an update's or restart's result: it put Hermes at background priority, in one line with
/// Run at Full Priority… on the gateway's own Mac, or with the Terminal steps anywhere else. What
/// it means is the confirmation's and the line's help.
struct PriorityResetView: View {
    let notice: PriorityNotice
    let setup: SetupCenter?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Not a Label: in a Form row its icon takes the list's icon size.
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(notice.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(notice.detail + " " + PriorityNotice.cause)
                    .accessibilityHint(notice.detail)
                #if os(macOS)
                if notice.canFixHere, let setup {
                    Spacer(minLength: 8)
                    RunAtFullPriorityButton(setup: setup)
                        .fixedSize()
                }
                #endif
            }
            if !notice.steps.isEmpty {
                SetupSteps(steps: notice.steps)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Under an update's or restart's result: the app put the gateway back at full priority by itself
/// (`docs/setup.md` §4.17), or is doing so.
struct PriorityRestoreView: View {
    let restore: GatewayJob.PriorityRestore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch restore {
            case .restoring:
                Spinner()
                    .accessibilityHidden(true)
                Text("Putting Hermes back at full priority")
            case .restored:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .accessibilityHidden(true)
                Text("Put Hermes back at full priority, as it was")
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

#if os(macOS)
/// Run at Full Priority…, with the same confirmation as Settings → Setup → Priority, and what it's
/// doing while Hermes's services restart.
struct RunAtFullPriorityButton: View {
    let setup: SetupCenter
    @State private var confirming = false

    var body: some View {
        if setup.isRaisingPriority {
            Label {
                Text("Restarting Hermes's services")
            } icon: {
                Spinner()
            }
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
        } else {
            let confirmation = SetupConfirmation.runAtFullPriority
            Button("Run at Full Priority…") { confirming = true }
                .cardButton()
                .controlSize(.small)
                .confirmationDialog(confirmation.title, isPresented: $confirming, titleVisibility: .visible) {
                    Button(confirmation.action) { setup.runAtFullPriority() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(confirmation.message)
                }
        }
    }
}

/// `macPriorityNotice`: one line in the sidebar's footer, above the connection, while Hermes runs
/// at background priority on its Mac. It never wraps, so it can't change the window's layout at
/// any width or text size: the words truncate, and what they mean is the help and the fix's
/// confirmation. Fix… runs Run at Full Priority on this Mac and opens Settings → Setup's steps for
/// another; × (Not Now) puts it away until the gateway has been seen at full priority again.
struct MacPriorityNotice: View {
    let setup: SetupCenter
    let notice: PriorityNotice
    @State private var confirming = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 6) {
            if setup.isRaisingPriority {
                Spinner()
                    .accessibilityHidden(true)
                Text("Restarting Hermes's services")
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(notice.label)
                    .foregroundStyle(Theme.primaryText)
                    .truncationMode(.tail)
                    .help(notice.headline + ". " + notice.detail + " " + PriorityNotice.cause)
                    .accessibilityLabel(notice.headline)
                    .accessibilityHint(notice.detail)
                Spacer(minLength: 4)
                Button("Fix…") {
                    if notice.canFixHere {
                        confirming = true
                    } else {
                        // Another Mac: its steps are on the Priority page.
                        UserDefaults.standard.set("setup", forKey: MacSettingsView.paneKey)
                        openSettings()
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.link)
                .fontWeight(.medium)
                .fixedSize()
                .help(notice.canFixHere ? String(localized: "Run at Full Priority…") : String(localized: "Show the steps in Settings → Setup"))
                .accessibilityHint(notice.canFixHere ? String(localized: "Runs Hermes at full priority, after asking.") : String(localized: "Opens the steps in Settings."))
                Button {
                    setup.dismissPriorityNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Not Now")
                .accessibilityLabel("Not Now")
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 9)
        .accessibilityElement(children: .contain)
        .confirmationDialog(SetupConfirmation.runAtFullPriority.title, isPresented: $confirming, titleVisibility: .visible) {
            Button(SetupConfirmation.runAtFullPriority.action) { setup.runAtFullPriority() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SetupConfirmation.runAtFullPriority.message)
        }
    }
}
#endif
