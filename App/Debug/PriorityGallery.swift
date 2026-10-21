#if DEBUG
import HermesKit
import SwiftUI

/// The priority notices for the gateway the app is connected to (`docs/setup.md` §4.17), where
/// off-Space captures can see them (the main window's bars don't draw there): the sidebar's footer
/// at its width, then an update's result. `-HERMES_GALLERY priority` with the mock's
/// `priority-here` or `throttled`; `priority:update` also updates Hermes once Bot Mode is up, and
/// `priority:update:fix` then runs Run at Full Priority (on this Mac) once the notice shows.
struct PriorityPage: View {
    let page: String
    @Environment(AppModel.self) private var app

    var body: some View {
        if let workspace = app.currentWorkspace {
            VStack(alignment: .leading, spacing: 24) {
                SidebarFooter(workspace: workspace)
                    .frame(width: 280)
                    .background(Theme.sidebar)
                if let job = workspace.setup.currentJob(.update) {
                    GatewayJobCard(job: job, setup: workspace.setup)
                }
            }
            .task {
                workspace.keepConnected()
                if !workspace.connection.isOnline { await workspace.connect() }
                guard page.contains(":update") else { return }
                for _ in 0..<80 where workspace.roster?.isConnected != true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                workspace.setup.updateHermes()
                #if os(macOS)
                guard page.hasSuffix(":fix") else { return }
                for _ in 0..<240 where workspace.setup.priorityNotice == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                workspace.setup.runAtFullPriority()
                #endif
            }
        } else {
            Text("No gateway")
        }
    }
}
#endif
