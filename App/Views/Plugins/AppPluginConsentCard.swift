import HermesKit
import SwiftUI

/// "This update asks for more access" (`pluginUpdate`, `docs/plugins.md` §7) for one of the app's
/// own plugins: its new pin adds hooks, tools, a command, a platform or a network host, so keeping
/// current waits. One line per addition, in the review's words; Allow and Update is the consent.
struct AppPluginConsentCard: View {
    let model: AppPluginsModel
    let plugin: AppPlugin
    let added: PluginCapabilities

    /// The version it's at now, the oldest one there.
    private var current: String? {
        model.survey?.entries(for: plugin).compactMap { entry -> String? in
            if case .outdated(let version) = entry.state { version } else { nil }
        }.min { !AppPlugin.version($0, isAtLeast: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This update asks for more access")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("\(plugin.words.title) v\(plugin.version) can also:")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
            ForEach(CapabilityWords.consentLines(for: added, gateway: model.gatewayName)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: line.kind.symbol)
                        .foregroundStyle(line.kind == .reaches ? Theme.warning : Theme.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.words).font(.subheadline).foregroundStyle(Theme.primaryText)
                        Text(line.mono).font(.caption2.monospaced()).foregroundStyle(Theme.tertiaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Text("It stays at v\(current ?? "") until you allow it. The app updates it in Hermes and every Bot.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    Task { await model.acceptUpdate(plugin) }
                } label: {
                    if model.installing.contains(plugin.name) {
                        Spinner().tint(Theme.inkForeground)
                    } else {
                        Text("Allow and Update")
                    }
                }
                .inkFilledButton()
                .disabled(model.isBusy || !model.isOnline)
            }
            .padding(.top, 4)
        }
        .pluginRowCard()
        .accessibilityElement(children: .contain)
    }
}
