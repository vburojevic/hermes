#if DEBUG
import HermesKit
import SwiftUI

/// The priority notices for the gateway the app is connected to (`docs/setup.md` §4.17), where
/// off-Space captures can see them (the main window's bars don't draw there): the sidebar's footer
/// at its narrowest and its usual width, and with large text, then an update's result.
/// `-HERMES_GALLERY priority` with the mock's `priority-here` or `throttled`; `priority:update` also
/// updates Hermes once Bot Mode is up, and `priority:update:fix` then runs Run at Full Priority (on
/// this Mac) once the notice shows; `priority:restart` restarts the gateway as Plugins' Restart
/// Gateway does. `priority:states` draws each of the Mac line's states (`macPriorityNotice` and
/// its variants) from sample reads instead, with no Bot Mode. `-appearance light` or `dark` picks
/// the look; `-HERMES_GALLERY_LOOK light+contrast` or `dark+contrast` adds Increase Contrast, and
/// `+reducemotion` Reduce Motion.
struct PriorityPage: View {
    let page: String
    @Environment(AppModel.self) private var app
    /// `-appearance light` or `dark`, as Settings sets it, so both can be captured on one Mac.
    @AppStorage(PreferenceKey.appearance) private var appearance: AppearancePreference = .system
    /// `-HERMES_GALLERY_LOOK …+reducemotion`, as `IndicatorsGallery` reads it.
    private static let reduceMotion = UserDefaults.standard.string(forKey: "HERMES_GALLERY_LOOK")?.contains("reducemotion") == true

    /// The sidebar's narrowest and usual widths (`RootView`), and large text at the narrowest.
    private static let footers: [(width: CGFloat, type: DynamicTypeSize)] = [(240, .large), (290, .large), (240, .xxxLarge), (240, .accessibility2)]

    var body: some View {
        if let workspace = app.currentWorkspace {
            Group {
                #if os(macOS)
                if page.hasPrefix("priority:states") {
                    states(workspace)
                } else {
                    live(workspace)
                }
                #else
                live(workspace)
                #endif
            }
            .preferredColorScheme(appearance.colorScheme)
            // The public key is read-only; the underscored one is what previews set.
            .environment(\._accessibilityReduceMotion, Self.reduceMotion)
            .onAppear { WidgetGalleryLook.apply() }
            .task {
                workspace.keepConnected()
                if !workspace.connection.isOnline { await workspace.connect() }
            }
        } else {
            Text("No gateway")
        }
    }

    #if os(macOS)
    /// Each state at the narrowest and usual widths, then larger text at the narrowest.
    private func states(_ workspace: BotWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.lines.indices, id: \.self) { index in
                let line = Self.lines[index]
                VStack(alignment: .leading, spacing: 6) {
                    Text(line.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.tertiaryText)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(Self.footers.indices, id: \.self) { footerIndex in
                            let footer = Self.footers[footerIndex]
                            SidebarFooter(workspace: workspace, galleryPriorityLine: line.line)
                                .frame(width: footer.width)
                                .background(Theme.sidebar)
                                .dynamicTypeSize(footer.type)
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    /// The drawn states, from the same reads the app makes: the gateway on this Mac, throttled or
    /// losing its priority at its next start.
    private static let lines: [(title: String, line: MacPriorityLine?)] = {
        func notice(nextStart: Bool) -> PriorityNotice? {
            let gateway = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "",
                                                spawnType: nextStart ? "interactive" : "daemon")
            var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: .online)
            facts.hostPriority = .report(GatewayHostReport(os: "darwin", jobs: [gateway]))
            facts.hostIsThisMac = true
            return GatewaySetup.priorityNotice(facts)
        }
        let throttled = notice(nextStart: false)
        return [
            ("macPriorityNotice", throttled.map { .notice($0, isRestarting: false) }),
            ("macPriorityNoticeNextStart", notice(nextStart: true).map { .notice($0, isRestarting: false) }),
            ("macPriorityNoticeRestarting", throttled.map { .notice($0, isRestarting: true) }),
            ("macPriorityNoticeRestored", .restored),
            ("Connection only", nil),
        ]
    }()
    #endif

    private func live(_ workspace: BotWorkspace) -> some View {
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
        .task {
            guard page.contains(":update") || page.contains(":restart") else { return }
            for _ in 0..<80 where workspace.roster?.isConnected != true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if page.contains(":restart") {
                // Apps and Tools → Plugins' Restart Gateway, which has no result of its own.
                await workspace.plugins.restartGateway()
                return
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
    }
}
#endif
