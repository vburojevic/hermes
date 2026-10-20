import HermesKit
import SwiftUI

// What's New (`whatsNew`, `macWhatsNew`): once after an update that adds features, on its first
// launch, never on a first install. Four rows at most, from a list that ships with the app; a
// feature that needs one of the app's plugins has its offer card under it.
// Spec: docs/onboarding.md §5.

/// One feature in a release's What's New.
struct WhatsNewFeature: Identifiable {
    let symbol: String
    let title: String
    /// iPhone and iPad.
    let detail: String
    /// The Mac's, which names the shortcut or where it lives.
    let macDetail: String
    /// One of the app's plugins this feature needs: its offer card follows the row while it's
    /// missing or off on the gateway (`pluginWhatsNew`, `docs/plugins.md` §3.3).
    var plugin: AppPlugin?
    var id: String { title }
}

/// The releases that added features, newest first. A release without an entry shows nothing.
enum WhatsNewCatalog {
    struct Release: Identifiable {
        let id: String
        let features: [WhatsNewFeature]
    }

    static let releases: [Release] = [
        Release(id: "2026-10-plugins", features: [
            WhatsNewFeature(
                symbol: "widget.small", title: String(localized: "Cards in Replies"),
                detail: String(localized: "Hermes can answer with cards you can tap: the weather, a chart, a checklist, an approval."),
                macDetail: String(localized: "Hermes can answer with cards you can click: the weather, a chart, a checklist, an approval."),
                plugin: .widgets
            ),
            WhatsNewFeature(
                symbol: "puzzlepiece.extension", title: String(localized: "Plugins"),
                detail: String(localized: "Hermes’s reviewed catalog in Apps and Tools. See what each plugin can do, then install it in Hermes or any Bot."),
                macDetail: String(localized: "Hermes’s reviewed catalog, with what each plugin can do. Settings → Apps & Tools")
            ),
        ]),
        Release(id: "2026-10-onboarding", features: [
            WhatsNewFeature(
                symbol: "square.grid.2x2", title: String(localized: "The Board"),
                detail: String(localized: "Hand Hermes and your Bots cards to work through, each in its own worktree."),
                macDetail: String(localized: "Cards Hermes and your Bots work through, each in its own worktree. ⇧⌘B")
            ),
            WhatsNewFeature(
                symbol: "sidebar.right", title: String(localized: "The Inspector"),
                detail: String(localized: "Pages Hermes builds, files it changes and its own screen, right beside the chat."),
                macDetail: String(localized: "Pages Hermes builds, files it changes, its own screen, beside the chat. ⌥⌘I")
            ),
            WhatsNewFeature(
                symbol: "brain", title: String(localized: "Memory"),
                detail: String(localized: "See what Hermes remembers about you, and edit or forget any of it."),
                macDetail: String(localized: "What Hermes remembers about you; edit or forget any of it. Settings → Memory")
            ),
            WhatsNewFeature(
                symbol: "sparkles", title: String(localized: "What Hermes Learned"),
                detail: String(localized: "The skills it wrote, how they connect, and how it keeps them tidy."),
                macDetail: String(localized: "Skills it wrote, how they connect, how it keeps them tidy. Skills → Learned")
            ),
        ]),
    ]

    static var latest: Release? { releases.first }

    private static let seenKey = "whatsNew.seen"

    /// The release to show now, if any. A first install (no gateway yet, nothing seen) marks
    /// the current release seen and shows nothing; an update shows the newest release it
    /// hasn't seen, once.
    @MainActor
    static func releaseToShow(hasGateways: Bool, defaults: UserDefaults = .standard) -> Release? {
        guard let latest else { return nil }
        #if DEBUG
        // `-HERMES_WHATS_NEW YES` shows it regardless (screenshots); `NO` never (UI tests).
        if defaults.string(forKey: "HERMES_WHATS_NEW") == "NO" { return nil }
        if defaults.bool(forKey: "HERMES_WHATS_NEW") { return latest }
        #endif
        let seen = defaults.string(forKey: seenKey)
        if seen == nil, !hasGateways {
            defaults.set(latest.id, forKey: seenKey)
            return nil
        }
        guard seen != latest.id else { return nil }
        return latest
    }

    static func markSeen(_ release: Release, defaults: UserDefaults = .standard) {
        defaults.set(release.id, forKey: seenKey)
    }
}

/// The sheet: "What's New in Hermes", up to four features, Continue.
struct WhatsNewView: View {
    let release: WhatsNewCatalog.Release
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app: AppModel?
    @State private var reviewing: AppPlugin?
    /// Offer cards decided on once: showing one counts as its moment (`PluginAnswers.offered`), so
    /// re-asking while it's up would take it away.
    @State private var offering: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("What’s New in Hermes")
                        #if os(macOS)
                        .font(.title2.weight(.bold))
                        #else
                        .font(.largeTitle.weight(.bold))
                        #endif
                        .foregroundStyle(Theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 18)
                    ForEach(release.features.prefix(4)) { feature in
                        row(feature)
                        if let plugin = feature.plugin, let workspace = app?.currentWorkspace, offering.contains(plugin.name) {
                            PluginOfferCard(workspace: workspace, plugin: plugin, moment: .whatsNew) { reviewing = plugin }
                                .padding(.vertical, 8)
                        }
                    }
                }
                #if os(macOS)
                .padding(28)
                #else
                .padding(.horizontal, 28)
                .padding(.top, 40)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            #if os(macOS)
            HStack {
                Spacer()
                Button("Continue") { dismiss() }
                    .inkDefaultButton()
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 28)
            #else
            Button { dismiss() } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .inkFilledButton()
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            #endif
        }
        .background(Theme.groupedBackground)
        // Once the app knows where its plugins stand on the gateway.
        .task(id: app?.currentWorkspace?.plugins.survey != nil) {
            guard let workspace = app?.currentWorkspace else { return }
            for plugin in release.features.compactMap(\.plugin) where PluginOfferCard.shows(plugin, at: .whatsNew, in: workspace) {
                offering.insert(plugin.name)
            }
        }
        .sheet(item: $reviewing) { plugin in
            if let workspace = app?.currentWorkspace {
                AppPluginReviewSheet(workspace: workspace, plugin: plugin)
            }
        }
    }

    private func row(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 40, height: 40)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                #if os(macOS)
                Text(feature.macDetail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                #else
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                #endif
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Shows What's New over the main window once an update has settled (never during setup).
struct WhatsNewPresentation: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var release: WhatsNewCatalog.Release?

    func body(content: Content) -> some View {
        content
            .sheet(item: $release, onDismiss: { app.isShowingWhatsNew = false }) { release in
                WhatsNewView(release: release)
                    #if os(macOS)
                    .frame(width: 520, height: 470)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
            .task {
                try? await Task.sleep(for: .seconds(1))
                guard app.setupGatewayID == nil,
                      let next = WhatsNewCatalog.releaseToShow(hasGateways: !app.bots.isEmpty) else { return }
                // Seen once it's up: quitting with it open doesn't bring it back.
                WhatsNewCatalog.markSeen(next)
                app.isShowingWhatsNew = true
                release = next
            }
    }
}
