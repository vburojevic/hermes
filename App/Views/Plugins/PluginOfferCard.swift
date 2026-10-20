import HermesKit
import SwiftUI

/// An offer in context (`pluginOffer`, `pluginOfferWidgets`, `pluginOfferTurnOn`;
/// `docs/plugins.md` §3.3): one of the app's plugins where a feature needs it. Set Up opens its
/// review (the consent); Turn On turns an installed copy back on; Not Now answers this moment for
/// this gateway on this device; the … menu hides it. Content, never glass.
struct PluginOfferCard: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    let moment: AppPlugin.Moment
    /// Set Up: the caller shows the review.
    let review: () -> Void
    @State private var answered = false

    private var hub: PluginHubModel { workspace.pluginHub }
    private var plugins: AppPluginsModel { workspace.plugins }
    private var gateway: String { workspace.bot.name }

    /// Installed but off everywhere: Turn On, not Set Up.
    private var isOff: Bool {
        plugins.survey.map { AppPluginPresence($0.entries(for: plugin)) } == .off
    }

    /// Whether the card belongs here now: the plugin is missing or off on this gateway, Bot Mode
    /// can reach it, and this moment may offer it (never hidden; Not Now comes back once after
    /// 14 days).
    static func shows(_ plugin: AppPlugin, at moment: AppPlugin.Moment, in workspace: BotWorkspace) -> Bool {
        guard plugin.moments.contains(moment), let survey = workspace.plugins.survey else { return false }
        return AppPluginPresence(survey.entries(for: plugin)) != .on && workspace.pluginHub.mayOffer(plugin.name, at: moment)
    }

    var body: some View {
        if !answered {
            let offer = isOff ? plugin.words.offerOff(gateway) : plugin.words.offer(gateway)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    PluginTile(symbol: plugin.words.symbol, ink: true, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plugin for \(gateway)".uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                        Text(offer.title)
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button(String(localized: "Don’t Suggest Again"), systemImage: "eye.slash") {
                            hub.hide(plugin.name)
                            withAnimation(Theme.gentle) { answered = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "More"))
                }
                Text(offer.body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                PairedButtons(
                    secondary: String(localized: "Not Now"),
                    onSecondary: {
                        hub.notNow(plugin.name, at: moment)
                        withAnimation(Theme.gentle) { answered = true }
                    },
                    primary: isOff ? String(localized: "Turn On") : String(localized: "Set Up"),
                    primaryEnabled: plugins.isOnline && !plugins.isBusy
                ) {
                    // A copy whose update adds access goes through its review, never a quiet Turn On.
                    if isOff, plugins.heldUpdates[plugin] == nil {
                        Task { await plugins.install(only: [plugin.name]) }
                        withAnimation(Theme.gentle) { answered = true }
                    } else {
                        review()
                    }
                }
                Text("Always in Settings → Apps and Tools → Plugins.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(16)
            .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .contain)
            .onAppear { hub.offered(plugin.name, at: moment) }
        }
    }
}

/// A plugin's review in its own sheet, for offers outside Settings (What's New, the checklist,
/// Set Up Push): a close button, and the sheet closes once the plugin answers.
struct AppPluginReviewSheet: View {
    let workspace: BotWorkspace
    let plugin: AppPlugin
    var offersTerminal = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AppPluginReviewView(workspace: workspace, plugin: plugin, offersTerminal: offersTerminal)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close"), systemImage: "xmark") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #else
        .presentationDetents([.large])
        #endif
    }
}
