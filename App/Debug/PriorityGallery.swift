#if DEBUG
import HermesKit
import SwiftUI

/// The priority notices for the gateway the app is connected to (`docs/setup.md` §4.17), where
/// off-Space captures can see them (the main window's bars don't draw there): the sidebar's footer
/// at its narrowest and its usual width, and with large text, then an update's result.
/// `-HERMES_GALLERY priority` with the mock's `priority-here` or `throttled`; `priority:update` also
/// updates Hermes once Bot Mode is up, and `priority:update:fix` then runs Run at Full Priority (on
/// this Mac) once the notice shows. `-appearance light` or `dark` picks the look.
struct PriorityPage: View {
    let page: String
    @Environment(AppModel.self) private var app
    /// `-appearance light` or `dark`, as Settings sets it, so both can be captured on one Mac.
    @AppStorage(PreferenceKey.appearance) private var appearance: AppearancePreference = .system

    /// The sidebar's narrowest and usual widths (`RootView`), and large text at the narrowest.
    private static let footers: [(width: CGFloat, type: DynamicTypeSize)] = [(240, .large), (290, .large), (240, .xxxLarge), (240, .accessibility2)]

    var body: some View {
        if let workspace = app.currentWorkspace {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Self.footers.indices, id: \.self) { index in
                    let footer = Self.footers[index]
                    SidebarFooter(workspace: workspace)
                        .frame(width: footer.width)
                        .background(Theme.sidebar)
                        .dynamicTypeSize(footer.type)
                }
                if let job = workspace.setup.currentJob(.update) {
                    GatewayJobCard(job: job, setup: workspace.setup)
                }
            }
            .preferredColorScheme(appearance.colorScheme)
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
