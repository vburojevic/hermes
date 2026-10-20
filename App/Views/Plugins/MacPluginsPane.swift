#if os(macOS)
import HermesKit
import SwiftUI

/// Settings → Apps & Tools → Plugins → Suggested on the Mac (`macPluginsSuggested`): what's offered,
/// updates, what's new in the catalog, Browse the Catalog… and Hidden Suggestions…. A row opens its
/// review in the pane (`macPluginReview`), with Install on <gateway> as the default button.
struct MacPluginsSuggestedPane: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel

    var body: some View {
        NavigationStack(path: Binding(get: { model.route.map { [$0] } ?? [] }, set: { model.route = $0.last })) {
            Form {
                Section {
                } header: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggested for \(hub.gatewayName)")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.primaryText)
                            Text("Plugins that unlock something in this app or use an app on \(hub.gatewayName). Nothing installs until you review it.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Button(String(localized: "Browse the Catalog…")) { model.route = .pluginCatalog }
                            .buttonBorderShape(.capsule)
                    }
                    .textCase(nil)
                }
                PluginsHubSections(model: model, hub: hub, macPane: true)
            }
            .formStyle(.grouped)
            .navigationDestination(for: AppsAndToolsModel.Route.self) { route in
                AppsAndToolsRouteView(model: model, route: route, back: String(localized: "Suggested"))
            }
        }
    }
}

/// The review's head in the Mac pane: the tile, the name, one line of facts, and Install on
/// <gateway> as the default button.
struct PaneReviewHeader: View {
    let tile: PluginTile
    let name: String
    let facts: String
    var actionTitle: String?
    var busy: String?
    var isEnabled = true
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            PluginTile(symbol: tile.symbol, ink: tile.ink, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(Theme.primaryText)
                Text(facts).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            Spacer()
            if let busy {
                Spinner()
                Text(busy).font(.callout).foregroundStyle(Theme.secondaryText)
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .inkDefaultButton()
                    .buttonBorderShape(.capsule)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isEnabled)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }
}
#endif
