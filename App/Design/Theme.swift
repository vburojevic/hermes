import SwiftUI

/// Hermes' visual language: a monochrome canvas where content, not chrome, carries the colour.
nonisolated enum Theme {
    // MARK: Colours
    //
    // The values come from the Elyx design tokens (Palette.swift, generated). These are the
    // names the views use.

    /// The app canvas: pure white or pure black, like ink on paper.
    static let canvas = Palette.canvas
    /// Sidebar and drawer background, a half-step off the canvas.
    static let sidebar = Palette.sidebar
    /// User bubbles, code blocks, chips, cards in the transcript.
    static let surface = Palette.surface
    /// Pressed rows and nested surfaces.
    static let surfaceRaised = Palette.surfaceRaised
    /// A selected sidebar row: a quiet wash that reads on the opaque drawer and the vibrant
    /// Mac and iPad sidebars alike (the design's surface-raised over the sidebar).
    static let rowSelected = Color(
        light: .black.opacity(0.075), dark: .white.opacity(0.11),
        increasedContrastLight: .black.opacity(0.16), increasedContrastDark: .white.opacity(0.22)
    )
    /// A sidebar row under the pointer.
    static let rowHover = Color(light: .black.opacity(0.035), dark: .white.opacity(0.05))
    static let hairline = Palette.hairline
    static let separator = Palette.separator
    static let primaryText = Palette.textPrimary
    // Both greys clear WCAG AA (4.5:1) on every surface, light and dark, and keep their order:
    // secondary stronger than tertiary.
    static let secondaryText = Palette.textSecondary
    static let tertiaryText = Palette.textTertiary
    /// Placeholders and disabled glyphs.
    static let placeholderText = Palette.textPlaceholder
    /// The monochrome action colour: the one primary action in a group. Not the app's accent;
    /// links and selection stay system blue.
    static let ink = Palette.ink
    static let inkForeground = Palette.onInk
    static let inkForegroundSecondary = Palette.onInkSecondary
    static let success = Palette.success
    static let warning = Palette.warning
    static let danger = Palette.danger
    static let link = Palette.link
    static let controlFill = Palette.controlFill
    static let groupedBackground = Palette.groupedBackground
    static let groupedCell = Palette.groupedCell
    static let sheetBackground = Palette.sheetBackground
    static let sheetCell = Palette.sheetCell
    static let scrim = Palette.scrim
    static let shadow = Palette.shadow
    static let thinkingShimmer = Palette.thinkingShimmer
    static let mediaDim = Palette.mediaDim
    static let successTint = Palette.successTint
    static let successHalo = Palette.successHalo
    static let warningTint = Palette.warningTint
    static let warningHalo = Palette.warningHalo
    static let dangerTint = Palette.dangerTint
    static let dangerWash = Palette.dangerWash
    static let dangerBorder = Palette.dangerBorder
    static let dangerHalo = Palette.dangerHalo
    /// The unread dot on Bot rows and the Bots segment (system blue).
    static let unread = Palette.Faces.unread
    /// "Active now" on Bots.
    static let active = Palette.Faces.active

    // MARK: Code syntax tints (Xcode's themes; 4.5:1 on code blocks, 7:1 with Increase Contrast)

    enum Syntax {
        static let plain = Palette.Syntax.plain
        static let keyword = Palette.Syntax.keyword
        static let type = Palette.Syntax.type
        static let string = Palette.Syntax.string
        static let number = Palette.Syntax.number
        static let comment = Palette.Syntax.comment
        static let function = Palette.Syntax.function
        static let property = Palette.Syntax.function
        static let meta = Palette.Syntax.meta
        static let inserted = Palette.Syntax.inserted
        static let deleted = Palette.Syntax.deleted
    }

    // MARK: Typography

    /// Reading sizes for transcripts. macOS has no Dynamic Type and a 13 pt body,
    /// which is too small for long-form chat, so it gets its own scale.
    enum Typography {
        #if os(macOS)
        static let message = Font.system(size: 15)
        static let compactMessage = Font.system(size: 13)
        static let messageLineSpacing: CGFloat = 4
        static let code = Font.system(size: 12.5, design: .monospaced)
        static let inlineCode = Font.system(size: 13, design: .monospaced)
        static let caption = Font.system(size: 12)
        static func heading(_ level: Int) -> Font {
            switch level {
            case 1: .system(size: 22, weight: .bold)
            case 2: .system(size: 19, weight: .semibold)
            case 3: .system(size: 16.5, weight: .semibold)
            default: .system(size: 15, weight: .semibold)
            }
        }
        #else
        static let message = Font.body
        static let compactMessage = Font.subheadline
        static let messageLineSpacing: CGFloat = 3
        static let code = Font.system(.footnote, design: .monospaced)
        static let inlineCode = Font.system(.subheadline, design: .monospaced)
        static let caption = Font.caption
        static func heading(_ level: Int) -> Font {
            switch level {
            case 1: .title2.bold()
            case 2: .title3.weight(.semibold)
            case 3: .headline
            default: .subheadline.weight(.semibold)
            }
        }
        #endif
    }

    // MARK: Metrics

    enum Radius {
        static let bubble: CGFloat = 22
        static let composer: CGFloat = 28
        static let card: CGFloat = 18
        static let code: CGFloat = 14
        static let row: CGFloat = 12
    }

    /// Comfortable reading width for transcripts on wide screens.
    static let readableWidth: CGFloat = 760

    // MARK: Motion

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.9)
    static let gentle = Animation.easeInOut(duration: 0.24)
    /// A request or approval card rising out of the composer, or sinking back into it.
    static let cardMotion = Animation.spring(duration: 0.42, bounce: 0.16)
}

// MARK: - Dynamic colours

nonisolated extension Color {
    /// A colour that resolves differently in light and dark appearances.
    ///
    /// The provider must not be main-actor isolated: SwiftUI resolves colours on its
    /// render thread too.
    /// With Increase Contrast on, the `increasedContrast…` colours are used when given.
    init(light: Color, dark: Color, increasedContrastLight: Color? = nil, increasedContrastDark: Color? = nil) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { @Sendable appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isHigh = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            let color = isHigh ? (isDark ? increasedContrastDark ?? dark : increasedContrastLight ?? light) : (isDark ? dark : light)
            return NSColor(color)
        })
        #else
        self.init(uiColor: UIColor { @Sendable traits in
            let isDark = traits.userInterfaceStyle == .dark
            let color = traits.accessibilityContrast == .high
                ? (isDark ? increasedContrastDark ?? dark : increasedContrastLight ?? light)
                : (isDark ? dark : light)
            return UIColor(color)
        })
        #endif
    }
}

// MARK: - Bot accents

/// The small palette a bot's avatar can wear. Everything else stays monochrome.
nonisolated enum BotAccent: String, CaseIterable, Codable, Sendable, Identifiable {
    case graphite, gold, ember, rose, violet, ocean, mint, lime

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .graphite: Palette.Accents.graphite
        case .gold: Palette.Accents.gold
        case .ember: Palette.Accents.ember
        case .rose: Palette.Accents.rose
        case .violet: Palette.Accents.violet
        case .ocean: Palette.Accents.ocean
        case .mint: Palette.Accents.mint
        case .lime: Palette.Accents.lime
        }
    }

    /// The bottom stop of the avatar's gradient.
    var deep: Color {
        switch self {
        case .graphite: Palette.Accents.graphiteDeep
        case .gold: Palette.Accents.goldDeep
        case .ember: Palette.Accents.emberDeep
        case .rose: Palette.Accents.roseDeep
        case .violet: Palette.Accents.violetDeep
        case .ocean: Palette.Accents.oceanDeep
        case .mint: Palette.Accents.mintDeep
        case .lime: Palette.Accents.limeDeep
        }
    }

    var name: String { rawValue.capitalized }
}
