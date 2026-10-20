import HermesKit
import SwiftUI

/// One app plugin's page in Settings → Setup: its review while it's nowhere on the gateway (the
/// same offer as everywhere else), otherwise where it stands in Hermes and each Bot.
struct AppPluginSetupPage: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin

    var body: some View {
        let entries = workspace.plugins.survey?.entries(for: plugin) ?? []
        if !entries.isEmpty, entries.allSatisfy({ $0.state == .missing }) {
            AppPluginReviewView(workspace: workspace, plugin: plugin)
        } else {
            PluginProfilesView(workspace: workspace, plugin: plugin)
        }
    }
}

// MARK: - Presentation

/// The ask, on every window's root, for the gateway that has one, once setup is done.
struct AppPluginsPresentation: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?

    private var asking: BotWorkspace? {
        // Never during setup or the tour (no gateway yet), and never over another sheet: What's
        // New, or a call, which a sheet would close (`docs/voice.md` §4). The ask waits.
        guard app.setupGatewayID == nil, !app.isShowingWhatsNew, router?.sheet == nil, !TalkCenter.shared.isActive else { return nil }
        return app.bots.lazy.compactMap { app.workspaces[$0.id] }.first { $0.plugins.isAsking }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { asking.map { Target(id: $0.id) } }, set: { target in
                guard target == nil, let workspace = asking else { return }
                if workspace.plugins.consent == nil { workspace.plugins.decline() }
                workspace.plugins.isAsking = false
            })) { target in
                if let workspace = app.workspaces[target.id] {
                    PluginsAskSheet(workspace: workspace)
                }
            }
            #if DEBUG
            .task { await openDebugSheet() }
            #endif
    }

    private struct Target: Identifiable {
        let id: UUID
    }

    #if DEBUG
    /// `-HERMES_PLUGINS_ASK YES`: the ask for the current gateway once Bot Mode connects, whatever
    /// it finds and whatever was answered before (screenshots).
    private func openDebugSheet() async {
        // `-HERMES_PLUGINS_ASKED YES`: this device answered the ask before per-plugin answers
        // existed (an older app), so keeping current holds a pin that adds access.
        if UserDefaults.standard.bool(forKey: "HERMES_PLUGINS_ASKED"), let workspace = app.currentWorkspace {
            workspace.plugins.forget()
            workspace.plugins.consent = .install
        }
        // `-HERMES_PLUGINS_FORGET YES`: this device never answered (UI tests); the app decides.
        if UserDefaults.standard.bool(forKey: "HERMES_PLUGINS_FORGET"), let workspace = app.currentWorkspace {
            workspace.plugins.forget()
            workspace.pluginHub.forget()
        }
        guard UserDefaults.standard.bool(forKey: "HERMES_PLUGINS_ASK") else { return }
        for _ in 0..<60 {
            if let workspace = app.currentWorkspace, workspace.roster?.isConnected == true {
                workspace.plugins.forget()
                await workspace.plugins.check()
                workspace.plugins.isAsking = true
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
    #endif
}
