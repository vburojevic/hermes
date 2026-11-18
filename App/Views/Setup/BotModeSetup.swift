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
            Spinner(size: .regular).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SetupMessage(
                status: status, symbol: symbol, headline: headline(status),
                check: workspace.roster.map { roster in { await roster.reconnectNow() } },
                fix: { router?.sheet = .editGateway(workspace.bot) }
            )
        }
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

    private var title: String {
        switch workspace.setup.facts.botMode {
        case .signInNeeded: String(localized: "Sign In…")
        case .refused: String(localized: "Edit Sign-In…")
        case .wrongServer: String(localized: "Edit Backend…")
        default: String(localized: "Link Bot Mode…")
        }
    }
}
