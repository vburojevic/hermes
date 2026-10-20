import HermesKit
import SwiftUI

/// A project's colour (Elyx `blocks/projects.elyx` → `projectTile*`): the gateway accents, stored
/// on the gateway by name. Another Hermes client may have written something else (the desktop
/// app writes `hsl(…)` swatches); those draw as graphite.
nonisolated enum ProjectAccent: String, CaseIterable, Identifiable, Sendable {
    case ocean, mint, ember, violet, gold, rose, graphite

    var id: String { rawValue }

    init(stored: String?) {
        self = stored.flatMap { ProjectAccent(rawValue: $0.lowercased()) } ?? .graphite
    }

    var name: String {
        switch self {
        case .ocean: String(localized: "Ocean")
        case .mint: String(localized: "Mint")
        case .ember: String(localized: "Ember")
        case .violet: String(localized: "Violet")
        case .gold: String(localized: "Gold")
        case .rose: String(localized: "Rose")
        case .graphite: String(localized: "Graphite")
        }
    }

    /// The swatch in the editor.
    var swatch: Color {
        switch self {
        case .ocean: Palette.Accents.ocean
        case .mint: Palette.Accents.mint
        case .ember: Palette.Accents.ember
        case .violet: Palette.Accents.violet
        case .gold: Palette.Accents.gold
        case .rose: Palette.Accents.rose
        case .graphite: Palette.Accents.graphite
        }
    }

    // The tile's gradient. The accents' top stops are too light under a white glyph for mint,
    // ember and gold (2.2–3:1), and dark-mode graphite is light grey, so a tile starts part-way
    // to the deep stop: the glyph clears 3.2:1 on every tile (4.5:1 with Increase Contrast where
    // the hue allows; gold and mint reach 3.6 and 4.3).

    var top: Color {
        switch self {
        case .ocean: Color(light: Self.c(0.2000, 0.5490, 0.9490), dark: Self.c(0.2000, 0.5490, 0.9490), increasedContrastLight: Self.c(0.1500, 0.4590, 0.8570), increasedContrastDark: Self.c(0.1500, 0.4590, 0.8570))
        case .mint: Color(light: Self.c(0.1385, 0.6326, 0.5186), dark: Self.c(0.1385, 0.6326, 0.5186), increasedContrastLight: Self.c(0.0902, 0.5412, 0.4392), increasedContrastDark: Self.c(0.0902, 0.5412, 0.4392))
        case .ember: Color(light: Self.c(0.9274, 0.4022, 0.1882), dark: Self.c(0.9274, 0.4022, 0.1882), increasedContrastLight: Self.c(0.8011, 0.3006, 0.1196), increasedContrastDark: Self.c(0.8011, 0.3006, 0.1196))
        case .violet: Color(light: Self.c(0.5490, 0.4196, 0.9490), dark: Self.c(0.5490, 0.4196, 0.9490), increasedContrastLight: Self.c(0.4949, 0.3678, 0.9102), increasedContrastDark: Self.c(0.4949, 0.3678, 0.9102))
        case .gold: Color(light: Self.c(0.7273, 0.5273, 0.1322), dark: Self.c(0.7273, 0.5273, 0.1322), increasedContrastLight: Self.c(0.6902, 0.4902, 0.1020), increasedContrastDark: Self.c(0.6902, 0.4902, 0.1020))
        case .rose: Color(light: Self.c(0.9294, 0.3294, 0.4784), dark: Self.c(0.9294, 0.3294, 0.4784), increasedContrastLight: Self.c(0.8299, 0.2461, 0.3789), increasedContrastDark: Self.c(0.8299, 0.2461, 0.3789))
        // Dark mode: system grey, not the gateway avatar's near-white.
        case .graphite: Color(light: Self.c(0.2000, 0.2000, 0.2000), dark: Self.c(0.4314, 0.4314, 0.4510), increasedContrastLight: Self.c(0.1400, 0.1400, 0.1400), increasedContrastDark: Self.c(0.3600, 0.3600, 0.3800))
        }
    }

    var deep: Color {
        switch self {
        case .ocean: Color(light: Self.c(0.1020, 0.3725, 0.7686), dark: Self.c(0.1020, 0.3725, 0.7686), increasedContrastLight: Self.c(0.0836, 0.3054, 0.6303), increasedContrastDark: Self.c(0.0836, 0.3054, 0.6303))
        case .mint: Color(light: Self.c(0.0902, 0.5412, 0.4392), dark: Self.c(0.0902, 0.5412, 0.4392), increasedContrastLight: Self.c(0.0740, 0.4438, 0.3601), increasedContrastDark: Self.c(0.0740, 0.4438, 0.3601))
        case .ember: Color(light: Self.c(0.7686, 0.2745, 0.1020), dark: Self.c(0.7686, 0.2745, 0.1020), increasedContrastLight: Self.c(0.6303, 0.2251, 0.0836), increasedContrastDark: Self.c(0.6303, 0.2251, 0.0836))
        case .violet: Color(light: Self.c(0.3686, 0.2471, 0.8196), dark: Self.c(0.3686, 0.2471, 0.8196), increasedContrastLight: Self.c(0.3023, 0.2026, 0.6721), increasedContrastDark: Self.c(0.3023, 0.2026, 0.6721))
        case .gold: Color(light: Self.c(0.6902, 0.4902, 0.1020), dark: Self.c(0.6902, 0.4902, 0.1020), increasedContrastLight: Self.c(0.5660, 0.4020, 0.0836), increasedContrastDark: Self.c(0.5660, 0.4020, 0.0836))
        case .rose: Color(light: Self.c(0.7608, 0.1882, 0.3098), dark: Self.c(0.7608, 0.1882, 0.3098), increasedContrastLight: Self.c(0.6239, 0.1543, 0.2540), increasedContrastDark: Self.c(0.6239, 0.1543, 0.2540))
        case .graphite: Color(light: Self.c(0.0588, 0.0588, 0.0588), dark: Self.c(0.2824, 0.2824, 0.2902), increasedContrastLight: Self.c(0.0300, 0.0300, 0.0300), increasedContrastDark: Self.c(0.2200, 0.2200, 0.2300))
        }
    }

    private static func c(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}

/// A project's glyph: one of eight SF Symbols, stored by symbol name. Anything else (the desktop
/// app writes codicon names) draws as the code glyph.
nonisolated enum ProjectGlyph: String, CaseIterable, Identifiable, Sendable {
    case code = "chevron.left.forwardslash.chevron.right"
    case server = "server.rack"
    case writing = "pencil.line"
    case chip = "cpu"
    case terminal = "terminal"
    case web = "globe"
    case tools = "hammer"
    case ideas = "sparkles"

    var id: String { rawValue }

    init(stored: String?) {
        self = stored.flatMap(ProjectGlyph.init(rawValue:)) ?? .code
    }

    var name: String {
        switch self {
        case .code: String(localized: "Code")
        case .server: String(localized: "Server")
        case .writing: String(localized: "Writing")
        case .chip: String(localized: "Chip")
        case .terminal: String(localized: "Terminal")
        case .web: String(localized: "Web")
        case .tools: String(localized: "Tools")
        case .ideas: String(localized: "Ideas")
        }
    }
}

/// What a project looks like: colour and glyph, read from what the gateway stores.
struct ProjectAppearance: Hashable {
    var accent: ProjectAccent
    var glyph: ProjectGlyph

    init(accent: ProjectAccent = .ocean, glyph: ProjectGlyph = .code) {
        self.accent = accent
        self.glyph = glyph
    }

    init(color: String?, icon: String?) {
        accent = ProjectAccent(stored: color)
        glyph = ProjectGlyph(stored: icon)
    }

    init(_ project: HermesProject) {
        self.init(color: project.color, icon: project.icon)
    }

    init(_ node: ProjectNode) {
        self.init(color: node.color, icon: node.icon)
    }
}

/// The project tile: the accent's gradient in a continuous rounded square with a white glyph.
struct ProjectTile: View {
    let appearance: ProjectAppearance
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(LinearGradient(colors: [appearance.accent.top, appearance.accent.deep], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: appearance.glyph.rawValue)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(Palette.Accents.wing)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The outline tile for No Project and All Projects.
struct OutlineTile: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .regular))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Counts as the project screens say them ("1 chat", "9 chats").
enum ProjectCount {
    static func chats(_ count: Int) -> String {
        count == 1 ? String(localized: "1 chat") : String(localized: "\(count) chats")
    }

    /// Chats in card worktrees (the Board's runs): never "tasks", which are scheduled jobs.
    static func cards(_ count: Int) -> String {
        count == 1 ? String(localized: "1 card") : String(localized: "\(count) cards")
    }

    static func branches(_ count: Int) -> String {
        count == 1 ? String(localized: "1 branch") : String(localized: "\(count) branches")
    }
}
