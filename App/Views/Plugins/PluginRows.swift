import HermesKit
import SwiftUI

/// What a plugin row or review is about: one of the app's own plugins, or a catalog entry.
enum PluginSubject: Hashable, Identifiable {
    case app(String)
    case catalog(String)

    var id: String {
        switch self {
        case .app(let name): "app:\(name)"
        case .catalog(let name): "catalog:\(name)"
        }
    }
}

/// `pluginOfferRow` and its states: a tile, the name with its tag, a line or two, and what a tap
/// on the trailing button does (Install, Turn On, Update, Show Again), a spinner while it installs,
/// or "Installed". Dimmed with the reason when it can't install here.
struct PluginOfferRow: View {
    enum Trailing: Equatable {
        case action(String)
        case installing
        case installed
        case none
    }

    let tile: PluginTile
    let name: String
    var forThisApp = false
    var tier: String?
    let line: String
    var note: String?
    var noteTint: Color = Theme.warning
    var trailing: Trailing = .none
    var dimmed = false
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // The tile and the words read as one element; the trailing button stays its own, since
            // it turns into a spinner (an AppKit accessibility tree that loses a combined child
            // crashed the Inspector).
            HStack(spacing: 12) {
                PluginTile(symbol: tile.symbol, ink: tile.ink, size: 40, dimmed: dimmed)
                VStack(alignment: .leading, spacing: 2) {
                    nameLine
                    if !line.isEmpty {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(dimmed ? Theme.tertiaryText : Theme.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note, !note.isEmpty {
                        Text(note)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(noteTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            trailingView
        }
        .padding(.vertical, 2)
    }

    /// The name and its tag (`pluginOfferRow`), laid out by `NameTagLine`.
    private var nameLine: some View {
        NameTagLine {
            nameText
                .minimumScaleFactor(NameTagLine.shrink)
            tag
        }
    }

    private var nameText: some View {
        Text(name)
            .font(.body)
            .foregroundStyle(dimmed ? Theme.tertiaryText : Theme.primaryText)
            .lineLimit(1)
    }

    @ViewBuilder private var tag: some View {
        if forThisApp {
            TagLabel(title: String(localized: "For This App"))
        } else {
            PluginTierTag(tier: tier)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .action(let title):
            Button(title, action: onAction)
                .buttonStyle(RowCapsuleButtonStyle())
                .disabled(dimmed)
        case .installing:
            Spinner()
        case .installed:
            Label(String(localized: "Installed"), systemImage: "checkmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(.titleAndIcon)
        case .none:
            EmptyView()
        }
    }

    /// Name, tier, state; then the action: what VoiceOver reads (`docs/plugins.md` §12).
    private var accessibilityText: String {
        var parts = [name, forThisApp ? String(localized: "For This App") : (tier == "official" ? String(localized: "Official") : tier == "community" ? String(localized: "Community") : "")]
        parts.append(line)
        if let note { parts.append(note) }
        // The action button follows as its own element.
        switch trailing {
        case .action: break
        case .installing: parts.append(String(localized: "Installing"))
        case .installed: parts.append(String(localized: "Installed"))
        case .none: break
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The name and its tag (`pluginOfferRow`): on one line when they fit with the name shrunk to no
/// less than `shrink` (its Text carries `minimumScaleFactor(NameTagLine.shrink)`; "Hermes App
/// Push" needs about 0.89 on an iPhone), otherwise the tag goes under the name, as the design does
/// for "Hermes App Widgets". Never truncated. Heights are whole points, so a List row's cells meet.
nonisolated struct NameTagLine: Layout {
    static let shrink: CGFloat = 0.85
    var spacing: CGFloat = 6

    private struct Plan {
        var inline: Bool
        var nameWidth: CGFloat
        var size: CGSize
    }

    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
        let width = proposal.width ?? .infinity
        guard let first = subviews.first else { return Plan(inline: true, nameWidth: 0, size: .zero) }
        let name = first.sizeThatFits(.unspecified)
        guard subviews.count > 1 else {
            let nameWidth = min(name.width, width)
            return Plan(inline: true, nameWidth: nameWidth, size: CGSize(width: nameWidth, height: name.height.rounded(.up)))
        }
        let tag = subviews[1].sizeThatFits(.unspecified)
        if name.width * Self.shrink + spacing + tag.width <= width {
            let nameWidth = min(name.width, width - spacing - tag.width)
            return Plan(inline: true, nameWidth: nameWidth,
                        size: CGSize(width: nameWidth + spacing + tag.width, height: max(name.height, tag.height).rounded(.up)))
        }
        let nameWidth = min(name.width, width)
        return Plan(inline: false, nameWidth: nameWidth,
                    size: CGSize(width: max(nameWidth, min(tag.width, width)), height: (name.height + spacing + tag.height).rounded(.up)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // From the proposal, like sizeThatFits, not from the bounds (rounded to pixels, a hair
        // narrower), so both decide the same way.
        let plan = plan(proposal, subviews)
        guard let first = subviews.first else { return }
        let name = first.sizeThatFits(.unspecified)
        if plan.inline {
            first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                        proposal: ProposedViewSize(width: plan.nameWidth, height: name.height))
            if subviews.count > 1 {
                let tag = subviews[1].sizeThatFits(.unspecified)
                subviews[1].place(at: CGPoint(x: bounds.minX + plan.nameWidth + spacing, y: bounds.midY), anchor: .leading,
                                  proposal: ProposedViewSize(tag))
            }
        } else {
            first.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: plan.nameWidth, height: name.height))
            let tag = subviews[1].sizeThatFits(.unspecified)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + name.height + spacing), proposal: ProposedViewSize(tag))
        }
    }
}

extension PluginCatalogEntry {
    var tile: PluginTile { PluginTile(symbol: "puzzlepiece.extension") }
}

/// The catalog tile for an installed plugin; the app's own wear their feature glyph.
func pluginTile(for plugin: HermesPlugin) -> PluginTile {
    if let app = AppPlugin.named(plugin.key) ?? AppPlugin.named(plugin.name) { return app.tile }
    return PluginTile(symbol: "puzzlepiece.extension")
}

extension String {
    /// Nil for an empty string, so `??` reaches the next choice.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// One review for every plugin (`docs/plugins.md` §5): the app's own, or a catalog entry.
struct PluginReview: View {
    let workspace: BotWorkspace
    let subject: PluginSubject
    var inPane = false
    /// iPad landscape's right column: the sheet keeps its own title.
    var inColumn = false

    private var name: String {
        switch subject {
        case .app(let name), .catalog(let name): name
        }
    }

    var body: some View {
        Group {
            switch subject {
            case .app(let name):
                if let plugin = AppPlugin.named(name) {
                    AppPluginReviewView(workspace: workspace, plugin: plugin, offersTerminal: plugin == .push, inPane: inPane, titled: !inColumn)
                }
            case .catalog(let name):
                CatalogPluginReviewView(workspace: workspace, name: name, inPane: inPane, titled: !inColumn)
            }
        }
        #if os(iOS)
        .toolbar {
            // The … menu: Don't Suggest Again moves it to Hidden Suggestions (`docs/plugins.md` §3.4).
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if workspace.pluginHub.answers.isHidden(name) {
                        Button(String(localized: "Show Again"), systemImage: "eye") { workspace.pluginHub.showAgain(name) }
                    } else {
                        Button(String(localized: "Don’t Suggest Again"), systemImage: "eye.slash") { workspace.pluginHub.hide(name) }
                    }
                } label: {
                    Label(String(localized: "More"), systemImage: "ellipsis")
                }
            }
        }
        #endif
    }
}

/// Installed plugins as their own list (iPad landscape's left column folds them into a row).
struct InstalledPluginsView: View {
    let model: AppsAndToolsModel
    let hub: PluginHubModel
    @State private var addingKeysTo: HermesPlugin?
    @State private var opened: AppsAndToolsModel.Route?

    var body: some View {
        Form {
            Section {
                ForEach(hub.installed) { plugin in
                    InstalledPluginRow(model: model, hub: hub, plugin: plugin, addKeys: { addingKeysTo = plugin }) { opened = $0 }
                }
            } footer: {
                Text("They run on \(hub.gatewayName) with the access they list. Turn one off to pause it without removing it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Installed"))
        .navigationDestination(item: $opened) { route in
            AppsAndToolsRouteView(model: model, route: route, back: String(localized: "Installed"))
        }
        .sheet(item: $addingKeysTo) { plugin in
            PluginKeysSheet(hub: hub, title: plugin.name, envs: hub.missingKeys(plugin).compactMap(\.env), profiles: [model.scopeProfile])
        }
    }
}

/// How a plugin page leaves when it's not pushed on its own: iPad landscape's right column clears
/// the selection instead of popping Apps and Tools.
struct PluginReviewExit {
    let close: () -> Void
}

extension EnvironmentValues {
    @Entry var pluginReviewExit: PluginReviewExit?
}
