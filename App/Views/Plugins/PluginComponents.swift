import HermesKit
import SwiftUI

// The pieces every plugin screen shares (`blocks/plugins.elyx`, `docs/plugins.md`): the tile,
// the hero, a capability line, the disclosure, an info row, cards of rows, and the install bar.
// Offers and rows are content (sheet cells), never glass; only the bar's progress capsule is.

/// `pluginTile`, `pluginTileApp`: the app's own plugins wear their feature glyph on ink, catalog
/// ones a plain plugin glyph on a grey tile.
struct PluginTile: View {
    let symbol: String
    var ink = false
    var size: CGFloat = 40
    var dimmed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(ink ? Theme.inkForeground : Theme.primaryText)
            .frame(width: size, height: size)
            .background(ink ? Theme.ink : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .opacity(dimmed ? 0.5 : 1)
            .accessibilityHidden(true)
    }
}

extension AppPlugin {
    var tile: PluginTile { PluginTile(symbol: words.symbol, ink: true) }
}

/// The app's icon, as it ships: the one ask is about setting the gateway up for this app.
struct AppIconArt: View {
    var size: CGFloat = 68

    var body: some View {
        Image("AppIconArt")
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The tags under a plugin's name: "For This App" or its tier, its maker, its version.
struct PluginTags: View {
    var forThisApp = false
    var tier: String?
    var maker: String?
    var version: String?

    var body: some View {
        HStack(spacing: 6) {
            if forThisApp {
                TagLabel(title: String(localized: "For This App"))
            } else {
                PluginTierTag(tier: tier)
            }
            if let maker, !maker.isEmpty { TagLabel(title: maker) }
            if let version, !version.isEmpty { TagLabel(title: "v\(version)") }
        }
    }
}

/// `pluginHero`: the tile, the name, one line, the tags.
struct PluginHero: View {
    let tile: PluginTile
    let name: String
    let line: String
    let tags: PluginTags

    var body: some View {
        VStack(spacing: 8) {
            PluginTile(symbol: tile.symbol, ink: tile.ink, size: 68)
            Text(name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            if !line.isEmpty {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            tags
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}

/// `capabilityRow` and its variants: plain words, the manifest's names in mono, a glyph that
/// says how far it reaches (an orange shield when it can change or block something).
struct CapabilityRowView: View {
    let line: CapabilityLine

    private var tint: Color {
        switch line.kind {
        case .reaches: Theme.warning
        case .safe: Theme.success
        default: Theme.secondaryText
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: line.kind.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.words)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !line.names.isEmpty {
                    Text(line.mono)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.kind == .reaches ? String(localized: "Can change things: \(line.words)") : line.words)
    }
}

/// A "What you get" line: the feature's glyph and the words.
struct BenefitRow: View {
    let benefit: AppPlugin.Benefit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: benefit.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(benefit.words)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// `disclosureNote`: the catalog's disclosure, or the app's own promise, quoted.
struct DisclosureNote: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// `pluginInfoRow`: a label, a value, an optional glyph before it and a chevron after.
struct PluginInfoRow: View {
    let label: String
    let value: String
    var symbol: String?
    var symbolTint: Color = Theme.success
    var mono = false
    var chevron = false
    var valueTint: Color = Theme.secondaryText

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(symbolTint)
                    .accessibilityHidden(true)
            }
            Text(label)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .foregroundStyle(valueTint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .accessibilityElement(children: .combine)
    }
}

/// Rows in one card with hairlines between them (sheet cells; grouped cells on the Mac's pane).
struct PluginCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                    subview
                }
            }
        }
        .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A card with its title above and an optional footer below (`formSectionTitle`).
struct PluginSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionHeading(title: title)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 7)
                    .accessibilityAddTraits(.isHeader)
            }
            PluginCard { content }
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `installBar`, `installBarBusy`: Install on <gateway> as an ink capsule, or the glass progress
/// capsule while it installs, with a caption and an optional quieter link under it. Placed with
/// `safeAreaBar`, so the page scrolls under it behind the system's scroll-edge effect.
struct InstallBar: View {
    let title: String
    var busy: String?
    let caption: String
    var isEnabled = true
    var link: String?
    var onLink: (() -> Void)?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let busy {
                HStack(spacing: 10) {
                    Spinner()
                    Text(busy)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .glassEffect(.regular, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            } else {
                Button(action: action) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .inkFilledButton()
                .disabled(!isEnabled)
                #if os(macOS)
                .keyboardShortcut(.defaultAction)
                #endif
            }
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let link, let onLink {
                Button(link, action: onLink)
                    .font(.body)
                    .foregroundStyle(Theme.link)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

extension Theme {
    /// Plugin rows and cards: sheet cells in a sheet (`sheet-cell`).
    static let pluginCell = Theme.sheetCell
}

extension View {
    /// A card that is a Form row of its own (its row background cleared): on iOS it draws its
    /// cell; the Mac's grouped Form draws the row whatever its background, so there the row is
    /// the card and a second one would sit inside it.
    func pluginRowCard() -> some View {
        #if os(iOS)
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.pluginCell, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        #else
        padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}
