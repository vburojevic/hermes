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
                    .font(.subheadline.weight(.semibold))
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

/// What the line above the Mac's connection says, if anything (`docs/setup.md` §4.17).
enum MacPriorityLine {
    case notice(PriorityNotice, isRestarting: Bool)
    /// Fix… just put Hermes back at full priority.
    case restored

    init?(_ setup: SetupCenter) {
        if let notice = setup.priorityNotice {
            self = .notice(notice, isRestarting: setup.isRaisingPriority)
        } else if setup.priorityPutBack {
            self = .restored
        } else {
            return nil
        }
    }
}

/// `macPriorityNotice`: one line in the sidebar's footer, above the connection, while Hermes runs
/// at background priority on its Mac. It never wraps, so it can't change the window's layout at
/// any width or text size: the words truncate, and what they mean is the help and the fix's
/// confirmation. Fix… runs Run at Full Priority on this Mac and opens Settings → Setup's steps for
/// another; × (Not Now) puts it away until the gateway has been seen at full priority again.
/// Everything grows with the text size: the words and glyph are `.subheadline` (11 pt), × is
/// `.caption2` in a 20 pt square (`docs/setup.md` §4.17).
struct MacPriorityNotice: View {
    let setup: SetupCenter
    let notice: PriorityNotice
    /// Run at Full Priority is restarting Hermes's services (`macPriorityNoticeRestarting`).
    let isRestarting: Bool
    @State private var confirming = false
    @State private var closeHovered = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var closeSide: CGFloat = 20
    @ScaledMetric(relativeTo: .subheadline) private var spinnerSide: CGFloat = 13

    var body: some View {
        HStack(spacing: 6) {
            if isRestarting {
                restartingSpinner
                Text("Restarting Hermes's services")
                    .foregroundStyle(Theme.secondaryText)
                    .onAppear {
                        AccessibilityNotification.Announcement(String(localized: "Restarting Hermes's services")).post()
                    }
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
                .foregroundStyle(Theme.ink)
                .fontWeight(.semibold)
                .fixedSize()
                .help(notice.canFixHere ? String(localized: "Run at Full Priority…") : String(localized: "Show the steps in Settings → Setup"))
                .accessibilityHint(notice.canFixHere ? String(localized: "Runs Hermes at full priority, after asking.") : String(localized: "Opens the steps in Settings."))
                Button {
                    setup.dismissPriorityNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundStyle(closeHovered ? Theme.secondaryText : Theme.tertiaryText)
                        .frame(width: closeSide, height: closeSide)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { closeHovered = $0 }
                .help("Not Now")
                .accessibilityLabel("Not Now")
            }
        }
        .modifier(MacPriorityLineStyle())
        .accessibilityElement(children: .contain)
        // `macPriorityConfirm`: Fix… asks first, as replies in progress stop.
        .confirmationDialog(SetupConfirmation.runAtFullPriority.title, isPresented: $confirming, titleVisibility: .visible) {
            Button(SetupConfirmation.runAtFullPriority.action) { setup.runAtFullPriority() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SetupConfirmation.runAtFullPriority.message)
        }
    }

    /// `macPriorityNoticeRestarting`: the app's own wait, which the person started, so the
    /// `Spinner` (after 0.5 s), drawn 13 pt where the system's small one is 16. With Reduce Motion
    /// it holds still, as drawn, and the words carry the state.
    private var restartingSpinner: some View {
        Group {
            if reduceMotion {
                MacPriorityStillSpinner(side: spinnerSide)
            } else {
                Spinner()
                    .scaleEffect(spinnerSide / 16)
            }
        }
        .frame(width: spinnerSide, height: spinnerSide)
        .accessibilityHidden(true)
    }
}

/// The restarting line's spinner with Reduce Motion: the same glyph, still, after the same 0.5 s.
/// Only here: elsewhere the design keeps the `Spinner` turning, as the system's does.
private struct MacPriorityStillSpinner: View {
    let side: CGFloat
    @State private var shows = false

    var body: some View {
        Image(systemName: "progress.indicator")
            .font(.system(size: side * 0.92, weight: .regular))
            .foregroundStyle(Theme.secondaryText)
            .opacity(shows ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                shows = true
            }
    }
}

/// `macPriorityNoticeRestored`: for 4 s after Fix… put Hermes back at full priority, the notice's
/// place says so, still, then goes. At large text sizes it truncates; its help is the sentence.
struct MacPriorityPutBack: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text("Put Hermes back at full priority, as it was")
                .foregroundStyle(Theme.secondaryText)
                .truncationMode(.tail)
                .help("Put Hermes back at full priority, as it was")
            Spacer(minLength: 0)
        }
        .modifier(MacPriorityLineStyle())
        .accessibilityElement(children: .combine)
    }
}

/// The notice's one line: `.subheadline`, never wrapping, inset like the connection under it and
/// 9 pt from the footer's hairline (`macPriorityNotice`).
private struct MacPriorityLineStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline)
            .lineLimit(1)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }
}
#endif
