import HermesKit
import SwiftUI

// Hermes at background priority on its Mac, said beyond Settings → Setup (`docs/setup.md` §4.17):
// on the result of an update or restart the app ran, which is what writes the gateway's plist
// again, and on the Mac beside Settings at the bottom of the sidebar.

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

/// Under an update's or restart's result: it put Hermes at background priority. Run at Full
/// Priority… on the gateway's own Mac, the Terminal steps anywhere else.
struct PriorityResetView: View {
    let notice: PriorityNotice
    let setup: SetupCenter?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Not a Label: in a Form row its icon takes the list's icon size.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(notice.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(notice.detail)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            if notice.canFixHere, let setup {
                RunAtFullPriorityButton(setup: setup)
            }
            #endif
            if !notice.steps.isEmpty {
                SetupSteps(steps: notice.steps)
            }
        }
        .accessibilityElement(children: .contain)
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

/// `macPriorityNotice`: at the bottom of the sidebar, beside Settings, while Hermes runs at
/// background priority on its Mac. Not Now puts it away until the gateway has been seen at full
/// priority again; Settings → Setup → Priority keeps saying so either way.
struct MacPriorityNotice: View {
    let setup: SetupCenter
    let notice: PriorityNotice
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(notice.headline)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(notice.detail)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                VStack(alignment: .leading, spacing: 6) { actions }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        if notice.canFixHere {
            RunAtFullPriorityButton(setup: setup)
        } else {
            // Another Mac: its steps are on the Priority page.
            Button("Show Steps") {
                UserDefaults.standard.set("setup", forKey: MacSettingsView.paneKey)
                openSettings()
            }
            .cardButton()
            .controlSize(.small)
        }
        if !setup.isRaisingPriority {
            Button("Not Now") { setup.dismissPriorityNotice() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
#endif
