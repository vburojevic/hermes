import HermesKit
import SwiftUI

/// What the "/" menu shows: names matching what's typed after "/", or the values of a command
/// waiting for its argument (`/model`, `/reasoning`).
enum SlashQuery: Equatable {
    case names(String)
    case values(command: String, query: String)
}

/// One row the menu can choose.
enum SlashChoice: Identifiable, Hashable {
    case entry(SlashCatalog.Entry)
    case value(command: String, SlashCatalog.Value)
    /// A file or folder on the gateway for an `@path` reference (`complete.path`).
    case path(PathCompletion)
    /// A Bot for an `@handle` (`composerMention`).
    case bot(BotProfile, BotAppearance)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .value(let command, let value): "\(command)=\(value.id)"
        case .path(let item): "path=\(item.text)"
        case .bot(let bot, _): "bot=\(bot.name)"
        }
    }

    /// Why a command can't run from the app: listed greyed with the reason, and choosing it does
    /// nothing.
    var unavailable: String? {
        if case .entry(let entry) = self { entry.unavailable } else { nil }
    }
}

/// One `complete.path` item: what goes in the field, how it reads, and a note ("dir", a size).
struct PathCompletion: Hashable {
    var text: String
    var display: String
    var meta: String?

    var isFolder: Bool { text.hasSuffix("/") || meta == "dir" || text.hasPrefix("@folder:") }
}

/// Where the top bar ends, in the window's coordinates: menus that grow up from the composer stop
/// short of it (`docs/composer.md` §1). Set by the chat screens; `nil` leaves a menu its own cap.
extension EnvironmentValues {
    @Entry var composerCeiling: CGFloat?
}

/// Finds where a screen's top bar ends (`composerCeiling`): it fills the screen's safe area, so its
/// top is the bar's bottom edge, and any banner's under it. (A frame's top plus its safe-area inset
/// counted the bar twice where the screen's own frame already starts below it.)
struct CeilingMarker: View {
    @Binding var ceiling: CGFloat?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { top in
                ceiling = top
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("MENULOG ceiling \(top)") }
                #endif
            }
    }
}

/// The composer panel's top edge in the window's coordinates. Measured into this object rather
/// than the composer's state, so the keyboard moving redraws only the menu that reads it.
@MainActor
@Observable
final class ComposerTop {
    var y: CGFloat?

    func update(_ value: CGFloat) {
        let rounded = value.rounded()
        if y != rounded { y = rounded }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("MENULOG composer top \(rounded)") }
        #endif
    }
}

/// The "/" menu above the composer (`blocks/slash.elyx` `slashMenu`, `slashMenuFiltered`,
/// `slashMenuArgs`): skills first, then commands by group; arrow keys move, Return chooses,
/// Tab completes, Escape closes. It's never taller than the room between the composer and the
/// top bar (`ComposerMenuRoom`); what doesn't fit scrolls inside it.
struct SlashMenu: View {
    let sections: [Section]
    let selection: SlashChoice.ID?
    var showsKeyHints: Bool
    var hiddenSkillCount = 0
    /// The composer under it, for the room it has (`nil`: its own cap).
    var composerTop: ComposerTop?
    /// The gap between it and the composer.
    var spacing: CGFloat = 8
    let onChoose: (SlashChoice) -> Void
    var onShowAllSkills: () -> Void = {}

    @Environment(\.composerCeiling) private var ceiling

    struct Section: Identifiable {
        var id: String { title }
        var title: String
        var choices: [SlashChoice]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.choices) { choice in
                                SlashRow(choice: choice, isSelected: choice.id == selection, showsKeyHint: showsKeyHints)
                                    .id(choice.id)
                                    .onTapGesture { onChoose(choice) }
                                    .accessibilityAddTraits(choice.unavailable == nil ? .isButton : [])
                                    .accessibilityAction { onChoose(choice) }
                            }
                            if section.title.hasPrefix(String(localized: "Skills")), hiddenSkillCount > 0 {
                                Button(action: onShowAllSkills) {
                                    Text("Show all \(hiddenSkillCount + section.choices.count) skills")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.link)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
            if showsKeyHints {
                Divider().padding(.horizontal, 4)
                HStack(spacing: 16) {
                    Label("Move", systemImage: "arrow.up.arrow.down")
                    Label("Choose", systemImage: "return.left")
                    Label("Complete · esc Close", systemImage: "arrow.right.to.line")
                }
                .labelStyle(KeyHintLabelStyle())
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
            }
        }
        .padding(6)
        .frame(maxHeight: ComposerMenuRoom.height(ceiling: ceiling, panelTop: composerTop?.y, spacing: spacing))
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands and skills")
    }
}

private struct KeyHintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// One entry (`slashRow`, `skillRow`): glyph tile, /name, argument, description, tag or key hint.
private struct SlashRow: View {
    let choice: SlashChoice
    let isSelected: Bool
    let showsKeyHint: Bool

    var body: some View {
        HStack(spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(unavailable == nil ? Theme.primaryText : Theme.secondaryText)
                        .lineLimit(1)
                    if let argument {
                        Text(argument)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSkill {
                TagLabel(title: String(localized: "Skill"))
            }
            if isSelected, showsKeyHint {
                Text("↩")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 26, height: 20)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 50)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceRaised)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isSkill: Bool {
        if case .entry(let entry) = choice { return entry.kind == .skill }
        return false
    }

    /// Why this command can't run from the app, in place of what it does.
    private var unavailable: String? {
        if case .entry(let entry) = choice { return entry.unavailable }
        return nil
    }

    private var title: String {
        switch choice {
        case .entry(let entry): "/" + entry.name
        case .value(_, let value): value.title
        case .path(let item): item.display
        case .bot(let bot, _): bot.title
        }
    }

    private var argument: String? {
        switch choice {
        case .entry(let entry): entry.argument
        case .bot(let bot, _): "@" + bot.mentionTag
        default: nil
        }
    }

    private var detail: String? {
        switch choice {
        case .entry(let entry): entry.unavailable ?? entry.summary
        case .value(_, let value): value.detail
        case .path(let item): item.meta
        case .bot(let bot, _): bot.role
        }
    }

    private var symbol: String {
        switch choice {
        case .entry(let entry): entry.symbol
        case .value(_, let value): value.symbol
        case .path(let item): item.isFolder ? "folder" : "doc.text"
        case .bot: "at"
        }
    }

    @ViewBuilder
    private var tile: some View {
        if case .bot(_, let appearance) = choice {
            BotFace(appearance: appearance, size: 30)
        } else {
            glyphTile
        }
    }

    private var glyphTile: some View {
        glyph
            .opacity(unavailable == nil ? 1 : 0.5)
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isSkill ? Theme.inkForeground : Theme.primaryText)
            .frame(width: 30, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSkill ? Theme.ink : Theme.surface)
            }
            .overlay {
                if !isSkill {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline)
                }
            }
    }
}

