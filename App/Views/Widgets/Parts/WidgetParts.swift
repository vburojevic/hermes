import HermesKit
import SwiftUI

/// The one state badge in a header (`Parts.stateBadge`): glyph and word, never colour alone.
struct WidgetBadge: View {
    let tone: WidgetTone
    var word: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tone.symbol)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(word)
                .font(WidgetFont.badge)
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(tone.tint, in: Capsule())
        .overlay {
            if tone.isDashed {
                Capsule().strokeBorder(Theme.primaryText, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .fixedSize()
    }
}

/// A small tag on a row or card (`WidgetTag`): grey metadata, or a state with its glyph.
struct WidgetTagView: View {
    let tag: WidgetTag
    /// The one pill in ink: a compare's pick (`Content.compare`).
    var prominent = false

    /// `Parts.tag`: small neutral grey pills; colour only where it warns (late, failing).
    var body: some View {
        let tone = WidgetTone(tag.state)
        let warns = tone == .warning || tone == .critical
        Text(tag.label)
            .font(.caption2.weight(.semibold))
            .strikethrough(tag.state == .removed)
            .foregroundStyle(prominent ? Theme.inkForeground : warns ? tone.color : Theme.secondaryText)
            .padding(.horizontal, 7)
            // One line stays 20 pt tall; lines that wrap keep clear of the rounded edges.
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            .background(prominent ? Theme.ink : warns ? tone.tint : Theme.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if tone.isDashed {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.secondaryText, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            // Whole beside what it tags, but a value drawn as a tag (a details field, a table cell)
            // can be long: it wraps in its pill rather than widening the card and the reply.
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .accessibilityLabel(warns ? "\(tag.label), \(tone.word)" : tag.label)
    }
}

/// A change with its arrow, coloured by whether it's good (`Delta.good`), never by its sign.
struct DeltaLabel: View {
    let delta: WidgetDelta
    var showsPeriod = false
    var font: Font = WidgetFont.caption.weight(.semibold)

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        let text = formatter.delta(delta)
        HStack(spacing: 2) {
            Text(arrow(text.direction))
                .font(.system(size: 8))
                .accessibilityHidden(true)
            Text(text.text)
                .font(font.monospacedDigit())
            if showsPeriod, let period = delta.period {
                Text(period)
                    .font(WidgetFont.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(color(text.isGood))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
    }

    private func arrow(_ direction: WidgetFormatter.Direction) -> String {
        switch direction {
        case .up: "▲"
        case .down: "▼"
        case .flat: "="
        }
    }

    private func color(_ good: Bool?) -> Color {
        switch good {
        case true?: Theme.success
        case false?: Theme.danger
        case nil: Theme.secondaryText
        }
    }
}

/// A bar on a track: progress, a meter, a range (`Parts.meterBar`).
struct WidgetBar: View {
    /// 0…1.
    let fraction: Double
    var color: Color = Theme.ink
    /// A target marked on the track, 0…1.
    var marker: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.controlFill)
                Capsule().fill(color)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction <= 0 ? 0 : 1)
                if let marker {
                    Rectangle()
                        .fill(Theme.primaryText)
                        .frame(width: 2, height: height + 6)
                        .offset(x: proxy.size.width * min(max(marker, 0), 1) - 1)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A glyph from the payload (`icon`, `symbol`): the app's own when it can't draw that one.
struct WidgetGlyph: View {
    let name: String?
    let fallback: String
    var size: CGFloat = 15
    var color: Color = Theme.primaryText

    var body: some View {
        Image(systemName: WidgetSymbols.resolve(name) ?? fallback)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size + 6, height: size + 6)
            .accessibilityHidden(true)
    }
}

/// How a claim is known, under the row it supports (`Parts.evidence`). Evidence never colours a
/// row green by itself; a claim reads "Said by …".
struct EvidenceLine: View {
    let evidence: WidgetEvidence

    @Environment(\.widgetContext) private var context

    var body: some View {
        let label = evidence.kind == .claim ? String(localized: "Said by \(evidence.label)") : evidence.label
        Button {
            if let url = evidence.url { context?.open(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(label)
                    .font(WidgetFont.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Theme.tertiaryText)
        }
        .buttonStyle(.plain)
        .disabled(evidence.url == nil)
        .accessibilityLabel(String(localized: "Evidence: \(label)"))
    }

    private var symbol: String {
        switch evidence.kind {
        case .test: "checklist.checked"
        case .file: "doc.text"
        case .link: "link"
        case .data: "chart.bar"
        case .observation: "eye"
        case .claim: "quote.opening"
        }
    }
}

/// Show all / Show less (`Parts.showMore`): the first items, then all of them in place.
struct ShowAllButton: View {
    let total: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(isExpanded ? String(localized: "Show less") : String(localized: "Show all \(total)"))
                    .font(WidgetFont.label.weight(.medium))
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A well inside the card (`canvas`, radius 10): grouped rows, tiles.
struct WidgetWell: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.wellRadius, style: .continuous))
    }
}

extension View {
    func widgetWell(padding: CGFloat = 10) -> some View {
        modifier(WidgetWell(padding: padding))
    }
}

/// A row's leading visual (`Leading`): a symbol, a date tile, a rank, a Bot's face, initials.
/// Pictures from the web wait for a tap elsewhere; a row shows their initials or symbol.
struct WidgetLeadingView: View {
    let leading: WidgetLeading
    var size: CGFloat = 28

    @Environment(\.widgetFormatter) private var formatter

    var body: some View {
        Group {
            switch leading.kind {
            case .rank:
                Text(leading.rank.map(String.init) ?? "")
                    .font(WidgetFont.valueSmall.monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
            case .date:
                dateTile
            case .face:
                if let bot = leading.bot {
                    WidgetBotFace(handle: bot, size: size)
                } else {
                    symbolTile("person.fill")
                }
            case .avatar:
                Text(leading.initials ?? "")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: size, height: size)
                    .background(Theme.canvas, in: Circle())
            case .file:
                Text((leading.fileType ?? "").uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: size * 0.8, height: size)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline))
            case .map:
                symbolTile("mappin.and.ellipse")
            case .image, .logo:
                symbolTile(leading.kind == .logo ? "building.2.fill" : "photo")
            case .symbol:
                symbolTile(WidgetSymbols.resolve(leading.symbol) ?? "circle.fill")
            }
        }
        .frame(minWidth: size, minHeight: size)
        .accessibilityHidden(true)
    }

    private func symbolTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.primaryText)
            .frame(width: size, height: size)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
    }

    private var dateTile: some View {
        let parts = leading.date.flatMap(JSONSchemaValidator.parseDate)
        let month: String = {
            guard let parts, let month = parts.month else { return "" }
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = formatter.locale
            return calendar.shortMonthSymbols[month - 1].uppercased()
        }()
        return VStack(spacing: 0) {
            Text(month)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.danger)
            Text(parts?.day.map(String.init) ?? "")
                .font(.system(size: size * 0.45, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
        }
        .frame(width: size + 4, height: size + 4)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: WidgetDensity.tileRadius, style: .continuous))
    }
}

/// A Bot's face by its handle, from the gateway's roster; the Hermes mark when it isn't known.
struct WidgetBotFace: View {
    let handle: String
    var size: CGFloat = 20

    @Environment(\.references) private var references

    var body: some View {
        // A Bot this device doesn't know yet wears the face Hermes gives its name; Hermes itself
        // is the primary profile's.
        BotFace(appearance: references.appearance(handle: handle) ?? BotAppearance(profile: handle == "hermes" ? "default" : handle), size: size)
    }
}

extension EnvironmentValues {
    @Entry var widgetFormatter = WidgetFormatter()
}
