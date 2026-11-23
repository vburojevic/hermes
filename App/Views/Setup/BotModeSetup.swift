import HermesKit
import SwiftUI

/// A page whose feature runs on Bot Mode, while Bot Mode isn't working (`docs/setup.md` §4.1):
/// what's needed and the way to it, instead of an endless spinner or a sentence with no button.
/// Link Bot Mode and Sign In open Edit Gateway; Check Again reconnects.
struct BotModeSetupMessage: View {
    let workspace: BotWorkspace
    /// The feature's setup id (`GatewaySetup.ID`).
    let feature: String
    /// The feature's name: "What Hermes Learned".
    let title: String
    let symbol: String
    @Environment(WindowRouter.self) private var router: WindowRouter?

    var body: some View {
        let status = GatewaySetup.needsBotMode(id: feature, title: title, workspace.setup.facts)
        if status.state == .checking {
            checking
        } else {
            SetupMessage(
                status: status, symbol: symbol, headline: headline(status),
                check: workspace.roster.map { roster in { await roster.reconnectNow() } },
                fix: { router?.sheet = .editGateway(workspace.bot) }
            )
        }
    }

    /// While the app asks Bot Mode how it is: the feature's name and one Checking… line that says
    /// where, in `SetupMessage`'s place, never a bare full-page spinner. The words show at once;
    /// only the spinner waits its half second (`docs/setup.md` §4.1).
    private var checking: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.bottom, 4)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Spinner()
                        .accessibilityHidden(true)
                    Text("Checking Bot Mode on \(workspace.bot.name)…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
    }

    private func headline(_ status: SetupStatus) -> String {
        switch workspace.setup.facts.botMode {
        case .signInNeeded: String(localized: "Sign in to Bot Mode")
        case .refused: String(localized: "The backend refused Bot Mode's sign-in")
        case .wrongServer: String(localized: "Bot Mode's address is the gateway, not its backend")
        case .unreachable: String(localized: "Bot Mode isn't answering")
        default: String(localized: "\(title) needs Bot Mode")
        }
    }
}

extension BotWorkspace {
    /// Bot Mode isn't working for this gateway: not linked, waiting for a sign-in, stopped
    /// after a refusal, or not answering. Connecting doesn't count.
    var botModeIsDown: Bool {
        switch setup.facts.botMode {
        case .notLinked, .signInNeeded, .refused, .wrongServer, .unreachable: true
        case .connecting, .online: false
        }
    }

    /// Settings' line for a gateway whose backend refused Bot Mode's sign-in, in place of its
    /// address; nil otherwise (`docs/setup.md` §4.1).
    var botModeStopLine: String? {
        roster?.stop == .refused ? String(localized: "Bot Mode can't sign in") : nil
    }
}

/// Link Bot Mode… (or Sign In…, Edit Sign-In…, Edit Backend…): Edit Gateway, presented from the
/// button itself, so it works inside Settings too (`docs/setup.md` §4.1).
struct BotModeLinkButton: View {
    let workspace: BotWorkspace
    @State private var editing = false

    var body: some View {
        Button(title) { editing = true }
        .cardButton()
        .controlSize(.small)
        .sheet(isPresented: $editing) {
            NavigationStack {
                BotEditorView(mode: .edit(workspace.bot)) { editing = false }
            }
            #if os(macOS)
            .frame(width: 520).frame(minHeight: 420, idealHeight: 540)
            #endif
        }
    }

    private var title: String { Self.title(for: workspace) }

    /// What linking Bot Mode is called for this gateway now; a file a reply sent offers it too.
    static func title(for workspace: BotWorkspace) -> String {
        switch workspace.setup.facts.botMode {
        case .signInNeeded: String(localized: "Sign In…")
        case .refused: String(localized: "Edit Sign-In…")
        case .wrongServer: String(localized: "Edit Backend…")
        default: String(localized: "Link Bot Mode…")
        }
    }
}
