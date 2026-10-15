import HermesKit
import SwiftUI

// Parts of Apps and Tools (`blocks/connections.elyx`).

/// An app's logo on a white tile, untinted (`appLogo`). The first letter stands in until
/// `logo_url` loads, or when there is none.
struct AppLogo: View {
    let name: String
    var url: URL?
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.white)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.16)
                    } else {
                        letter
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var letter: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.44, weight: .bold))
            // The tile stays white in dark mode, so the letter stays dark.
            .foregroundStyle(Color.black)
    }
}

/// Reads / Writes / Destructive (`toolRow*`).
struct ToolKindTag: View {
    let facet: ToolFacet

    var body: some View {
        switch facet {
        case .read: TagLabel(title: String(localized: "Reads"))
        case .write: TagLabel(title: String(localized: "Writes"), style: .warning)
        case .destructive: TagLabel(title: String(localized: "Destructive"), style: .danger)
        case .unclassified: EmptyView()
        }
    }
}

/// Official (seal) or Community (people).
struct PluginTierTag: View {
    let tier: String?

    var body: some View {
        switch tier {
        case "official": TagLabel(title: String(localized: "Official"), symbol: "checkmark.seal.fill")
        case "community": TagLabel(title: String(localized: "Community"), symbol: "person.2")
        default: EmptyView()
        }
    }
}

/// A grey tile with a glyph: MCP servers (terminal or globe) and plugins.
struct GlyphTile: View {
    let symbol: String
    var ink = false
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(ink ? Theme.inkForeground : Theme.secondaryText)
            .frame(width: size, height: size)
            .background(ink ? Theme.ink : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An MCP server's live state as a dot and a line (`serverRow*`).
struct ServerStatusLine: View {
    let server: McpServer

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(2.5)
                .background(color.opacity(0.18), in: Circle())
            Text(text)
                .foregroundStyle(server.status == .failed && server.enabled ? Theme.danger : Theme.secondaryText)
        }
        .font(.caption)
    }

    private var color: Color {
        guard server.enabled else { return Theme.tertiaryText }
        switch server.status {
        case .connected: return Theme.success
        case .failed: return Theme.danger
        case .connecting: return Theme.warning
        default: return Theme.tertiaryText
        }
    }

    /// "Connected · command · 14 tools", "Couldn't connect · tap to fix", "Starts when needed · command".
    var text: String {
        let how = server.isFromPlugin ? String(localized: "plugin") : (server.usesURL ? String(localized: "URL") : String(localized: "command"))
        guard server.enabled else { return String(localized: "Off · \(how)") }
        switch server.status {
        case .connected:
            let tools = server.toolCount.map { $0 == 1 ? String(localized: "1 tool") : String(localized: "\($0) tools") }
            return [String(localized: "Connected"), how, tools].compactMap { $0 }.joined(separator: " · ")
        case .failed: return String(localized: "Couldn't connect · tap to fix")
        case .connecting: return String(localized: "Connecting · \(how)")
        case .lazy: return String(localized: "Starts when needed · \(how)")
        default: return String(localized: "Not tested yet · \(how)")
        }
    }
}

/// One thing an update would add (`capabilityLine`).
struct CapabilityLine: View {
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.primaryText)
        } icon: {
            Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.warning)
        }
        .font(.subheadline)
    }
}

/// A tinted card that says something stopped (`appExpired`, `serverFailed`).
struct AttentionCard<Actions: View>: View {
    enum Tone { case warning, danger }

    let tone: Tone
    let title: String
    let detail: String
    var mono: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.headline).foregroundStyle(Theme.primaryText)
            } icon: {
                Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                    .foregroundStyle(tone == .warning ? Theme.warning : Theme.danger)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let mono {
                Text(mono)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone == .warning ? Theme.warningTint : Theme.dangerTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Paired card buttons: secondary on the left, primary (ink) on the right, equal widths.
struct PairedButtons: View {
    let secondary: String
    let onSecondary: () -> Void
    let primary: String
    var primaryEnabled = true
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSecondary) {
                Text(secondary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.controlFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            Button(action: onPrimary) {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.ink, in: Capsule())
                    .contentShape(Capsule())
                    .opacity(primaryEnabled ? 1 : 0.4)
            }
            .buttonStyle(PressableStyle())
            .disabled(!primaryEnabled)
        }
    }
}

/// One ink button across the card.
struct InkButton: View {
    let title: String
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.small).tint(Theme.inkForeground) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.inkForeground)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Theme.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(isWorking)
    }
}

/// A whole-width destructive button at the end of a detail ("Disconnect Linear", "Remove MCP
/// Server"): a grey capsule with a red label, outside the cells.
struct DestructiveRowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.controlFill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

extension View {
    /// A text button that ends a list section: under the names above it on iPhone and iPad, a
    /// centred push button on the Mac.
    @ViewBuilder
    func underRowNames(_ indent: CGFloat = 44) -> some View {
        #if os(iOS)
        padding(.leading, indent).frame(maxWidth: .infinity, alignment: .leading)
        #else
        frame(maxWidth: .infinity)
        #endif
    }

    /// A detail's title on a pushed page; in the Mac's Settings pane the window keeps "Apps & Tools".
    @ViewBuilder
    func detailTitle(_ title: String, shows: Bool) -> some View {
        if shows { navigationTitle(title) } else { self }
    }
}

/// The line under the tabs: which gateway this page manages.
struct GatewayScopeLine: View {
    let workspace: BotWorkspace

    var body: some View {
        HStack(spacing: 8) {
            BotAvatar(bot: workspace.bot, size: 20)
            Text("What Hermes on \(workspace.bot.name) can use")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Section headers in the designs: "Connected · 4", small and grey.
func countedHeader(_ title: String, _ count: Int) -> some View {
    SectionHeading(title: "\(title) · \(count)")
}

/// A section header as the designs draw it.
struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .textCase(nil)
    }
}

/// The small grey capsule on a row: Connect, Add, Install (`catalogRow`).
struct RowCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Theme.controlFill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
