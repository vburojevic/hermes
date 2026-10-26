// Generated from the Elyx design tokens (tokens/colors*.elyx) by
// Tools/elyx/generate_palette.py. Do not edit by hand: change the tokens and regenerate.

import SwiftUI

/// Every colour in the design, with its light, dark and Increase Contrast values.
nonisolated enum Palette {
    /// Glow behind the wing (white aura in Dark Mode).
    static let aura = Color(
        light: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.0706),
        dark: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.1804)
    )
    static let auraSoft = Color(
        light: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.0196),
        dark: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.0392)
    )
    /// App background (system background, base).
    static let canvas = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0)
    )
    /// Search fields, segmented tracks (tertiary system fill).
    static let controlFill = Color(
        light: Color(.sRGB, red: 0.4627, green: 0.4627, blue: 0.502, opacity: 0.1216),
        dark: Color(.sRGB, red: 0.4627, green: 0.4627, blue: 0.502, opacity: 0.2392),
        increasedContrastLight: Color(.sRGB, red: 0.4627, green: 0.4627, blue: 0.502, opacity: 0.2196),
        increasedContrastDark: Color(.sRGB, red: 0.4627, green: 0.4627, blue: 0.502, opacity: 0.3608)
    )
    /// System red (26 palette; text-legible light variant).
    static let danger = Color(
        light: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765),
        dark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706),
        increasedContrastLight: Color(.sRGB, red: 0.7216, green: 0, blue: 0.102),
        increasedContrastDark: Color(.sRGB, red: 1, green: 0.3804, blue: 0.3961)
    )
    static let dangerBorder = Color(
        light: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.2),
        dark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.251),
        increasedContrastLight: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.502),
        increasedContrastDark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.502)
    )
    static let dangerHalo = Color(
        light: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.2196),
        dark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.251)
    )
    static let dangerTint = Color(
        light: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.1216),
        dark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.1608),
        increasedContrastLight: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.2),
        increasedContrastDark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.251)
    )
    static let dangerWash = Color(
        light: Color(.sRGB, red: 0.9137, green: 0.0824, blue: 0.1765, opacity: 0.0706),
        dark: Color(.sRGB, red: 1, green: 0.2588, blue: 0.2706, opacity: 0.102)
    )
    /// Keyboard focus ring.
    static let focusRing = Color(
        light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588, opacity: 0.349),
        dark: Color(.sRGB, red: 0.9608, green: 0.9608, blue: 0.9608, opacity: 0.349),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0, blue: 0),
        increasedContrastDark: Color(.sRGB, red: 1, green: 1, blue: 1)
    )
    /// Full-screen grouped pages (base).
    static let groupedBackground = Color(
        light: Color(.sRGB, red: 0.949, green: 0.949, blue: 0.9686),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0)
    )
    /// Cells on grouped pages.
    static let groupedCell = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 0.1098, green: 0.1098, blue: 0.1176),
        increasedContrastDark: Color(.sRGB, red: 0.1412, green: 0.1412, blue: 0.149)
    )
    /// Borders (22% / 32% with Increase Contrast).
    static let hairline = Color(
        light: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.0784),
        dark: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.102),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.2196),
        increasedContrastDark: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.3216)
    )
    /// Info status (widgets: state info), the text-legible system blue.
    static let info = Color(
        light: Color(.sRGB, red: 0.1176, green: 0.4314, blue: 0.9569),
        dark: Color(.sRGB, red: 0, green: 0.5686, blue: 1),
        increasedContrastLight: Color(.sRGB, red: 0.0431, green: 0.3412, blue: 0.8157),
        increasedContrastDark: Color(.sRGB, red: 0.3608, green: 0.7216, blue: 1)
    )
    static let infoHalo = Color(
        light: Color(.sRGB, red: 0.1176, green: 0.4314, blue: 0.9569, opacity: 0.2196),
        dark: Color(.sRGB, red: 0, green: 0.5686, blue: 1, opacity: 0.251),
        increasedContrastDark: Color(.sRGB, red: 0.3608, green: 0.7216, blue: 1, opacity: 0.251)
    )
    static let infoTint = Color(
        light: Color(.sRGB, red: 0.1176, green: 0.4314, blue: 0.9569, opacity: 0.1216),
        dark: Color(.sRGB, red: 0, green: 0.5686, blue: 1, opacity: 0.1608),
        increasedContrastLight: Color(.sRGB, red: 0.0431, green: 0.3412, blue: 0.8157, opacity: 0.2),
        increasedContrastDark: Color(.sRGB, red: 0.3608, green: 0.7216, blue: 1, opacity: 0.251)
    )
    /// The monochrome accent: prominent glass tint, send, selection.
    static let ink = Color(
        light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588),
        dark: Color(.sRGB, red: 0.9608, green: 0.9608, blue: 0.9608),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0, blue: 0),
        increasedContrastDark: Color(.sRGB, red: 1, green: 1, blue: 1)
    )
    /// Links (system blue, legible variant).
    static let link = Color(
        light: Color(.sRGB, red: 0.1176, green: 0.4314, blue: 0.9569),
        dark: Color(.sRGB, red: 0, green: 0.5686, blue: 1),
        increasedContrastLight: Color(.sRGB, red: 0.0431, green: 0.3412, blue: 0.8157),
        increasedContrastDark: Color(.sRGB, red: 0.3608, green: 0.7216, blue: 1)
    )
    /// 35% dimming layer under clear glass over bright media.
    static let mediaDim = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.349)
    /// Labels on ink.
    static let onInk = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0)
    )
    static let onInkSecondary = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.702),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.702)
    )
    /// Dims content behind modals and drawers.
    static let scrim = Color(
        light: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.3216),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.502)
    )
    /// Selected segment in segmented controls (system: white in light, gray in dark).
    static let segmentSelected = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 0.3882, green: 0.3882, blue: 0.4),
        increasedContrastDark: Color(.sRGB, red: 0.4863, green: 0.4863, blue: 0.502)
    )
    /// List separators (system separator).
    static let separator = Color(
        light: Color(.sRGB, red: 0.2353, green: 0.2353, blue: 0.2627, opacity: 0.2902),
        dark: Color(.sRGB, red: 0.3294, green: 0.3294, blue: 0.3451, opacity: 0.6),
        increasedContrastLight: Color(.sRGB, red: 0.2353, green: 0.2353, blue: 0.2627, opacity: 0.502),
        increasedContrastDark: Color(.sRGB, red: 0.4863, green: 0.4863, blue: 0.502)
    )
    /// Elevation shadow.
    static let shadow = Color(
        light: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.1608),
        dark: Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.502)
    )
    /// Sheets, popovers, form sheets: the elevated background in Dark Mode.
    static let sheetBackground = Color(
        light: Color(.sRGB, red: 0.949, green: 0.949, blue: 0.9686),
        dark: Color(.sRGB, red: 0.1098, green: 0.1098, blue: 0.1176),
        increasedContrastDark: Color(.sRGB, red: 0.1255, green: 0.1255, blue: 0.1333)
    )
    /// Cells inside sheets (elevated).
    static let sheetCell = Color(
        light: Color(.sRGB, red: 1, green: 1, blue: 1),
        dark: Color(.sRGB, red: 0.1725, green: 0.1725, blue: 0.1804),
        increasedContrastDark: Color(.sRGB, red: 0.2118, green: 0.2118, blue: 0.2196)
    )
    /// Sidebar and drawer.
    static let sidebar = Color(
        light: Color(.sRGB, red: 0.9647, green: 0.9647, blue: 0.9647),
        dark: Color(.sRGB, red: 0.0549, green: 0.0549, blue: 0.0549),
        increasedContrastLight: Color(.sRGB, red: 0.9373, green: 0.9373, blue: 0.9373),
        increasedContrastDark: Color(.sRGB, red: 0.0784, green: 0.0784, blue: 0.0784)
    )
    /// Floating sidebar panel (iPad, Mac): Liquid Glass, more opaque on large surfaces.
    static let sidebarGlass = Color(
        light: Color(.sRGB, red: 0.9647, green: 0.9647, blue: 0.9647, opacity: 0.902),
        dark: Color(.sRGB, red: 0.1098, green: 0.1098, blue: 0.1176, opacity: 0.902),
        increasedContrastLight: Color(.sRGB, red: 0.9647, green: 0.9647, blue: 0.9647, opacity: 0.9804),
        increasedContrastDark: Color(.sRGB, red: 0.1098, green: 0.1098, blue: 0.1176, opacity: 0.9804)
    )
    /// System green (26 palette; text-legible light variant).
    static let success = Color(
        light: Color(.sRGB, red: 0, green: 0.5373, blue: 0.1961),
        dark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0.4196, blue: 0.1529),
        increasedContrastDark: Color(.sRGB, red: 0.2902, green: 0.851, blue: 0.4078)
    )
    static let successHalo = Color(
        light: Color(.sRGB, red: 0, green: 0.5373, blue: 0.1961, opacity: 0.2196),
        dark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451, opacity: 0.251)
    )
    /// Status tints for tags and tiles.
    static let successTint = Color(
        light: Color(.sRGB, red: 0, green: 0.5373, blue: 0.1961, opacity: 0.1412),
        dark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451, opacity: 0.1608),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0.5373, blue: 0.1961, opacity: 0.2196),
        increasedContrastDark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451, opacity: 0.251)
    )
    /// Content fills: user bubbles, code, chips, cards.
    static let surface = Color(
        light: Color(.sRGB, red: 0.9451, green: 0.9451, blue: 0.9451),
        dark: Color(.sRGB, red: 0.1098, green: 0.1098, blue: 0.1098),
        increasedContrastLight: Color(.sRGB, red: 0.902, green: 0.902, blue: 0.902),
        increasedContrastDark: Color(.sRGB, red: 0.149, green: 0.149, blue: 0.149)
    )
    /// Pressed / selected rows.
    static let surfaceRaised = Color(
        light: Color(.sRGB, red: 0.9059, green: 0.9059, blue: 0.9059),
        dark: Color(.sRGB, red: 0.1608, green: 0.1608, blue: 0.1608),
        increasedContrastLight: Color(.sRGB, red: 0.851, green: 0.851, blue: 0.851),
        increasedContrastDark: Color(.sRGB, red: 0.2196, green: 0.2196, blue: 0.2196)
    )
    /// Toggle off track.
    static let switchOff = Color(
        light: Color(.sRGB, red: 0.4706, green: 0.4706, blue: 0.502, opacity: 0.1608),
        dark: Color(.sRGB, red: 0.4706, green: 0.4706, blue: 0.502, opacity: 0.3216),
        increasedContrastLight: Color(.sRGB, red: 0.4706, green: 0.4706, blue: 0.502, opacity: 0.2784),
        increasedContrastDark: Color(.sRGB, red: 0.4706, green: 0.4706, blue: 0.502, opacity: 0.4196)
    )
    /// Toggle on (system green).
    static let switchOn = Color(
        light: Color(.sRGB, red: 0.2039, green: 0.7804, blue: 0.349),
        dark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0.5373, blue: 0.1961),
        increasedContrastDark: Color(.sRGB, red: 0.2902, green: 0.851, blue: 0.4078)
    )
    /// Placeholders, disabled glyphs.
    static let textPlaceholder = Color(
        light: Color(.sRGB, red: 0.6392, green: 0.6392, blue: 0.6392),
        dark: Color(.sRGB, red: 0.4196, green: 0.4196, blue: 0.4196),
        increasedContrastLight: Color(.sRGB, red: 0.4314, green: 0.4314, blue: 0.4314),
        increasedContrastDark: Color(.sRGB, red: 0.6196, green: 0.6196, blue: 0.6196)
    )
    /// Primary text.
    static let textPrimary = Color(
        light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588),
        dark: Color(.sRGB, red: 0.9608, green: 0.9608, blue: 0.9608),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0, blue: 0),
        increasedContrastDark: Color(.sRGB, red: 1, green: 1, blue: 1)
    )
    /// Secondary text (AA on every surface).
    static let textSecondary = Color(
        light: Color(.sRGB, red: 0.3294, green: 0.3294, blue: 0.3294),
        dark: Color(.sRGB, red: 0.6784, green: 0.6784, blue: 0.6784),
        increasedContrastLight: Color(.sRGB, red: 0.2, green: 0.2, blue: 0.2),
        increasedContrastDark: Color(.sRGB, red: 0.8196, green: 0.8196, blue: 0.8196)
    )
    /// Tertiary text.
    static let textTertiary = Color(
        light: Color(.sRGB, red: 0.4, green: 0.4, blue: 0.4),
        dark: Color(.sRGB, red: 0.5804, green: 0.5804, blue: 0.5804),
        increasedContrastLight: Color(.sRGB, red: 0.2588, green: 0.2588, blue: 0.2588),
        increasedContrastDark: Color(.sRGB, red: 0.749, green: 0.749, blue: 0.749)
    )
    /// Shimmer highlight on "Thinking…": the words' full ink, away from the background, passing over grey words.
    static let thinkingShimmer = Color(
        light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588),
        dark: Color(.sRGB, red: 0.9608, green: 0.9608, blue: 0.9608),
        increasedContrastLight: Color(.sRGB, red: 0, green: 0, blue: 0),
        increasedContrastDark: Color(.sRGB, red: 1, green: 1, blue: 1)
    )
    /// System orange (26 palette; text-legible light variant).
    static let warning = Color(
        light: Color(.sRGB, red: 0.7725, green: 0.3255, blue: 0),
        dark: Color(.sRGB, red: 1, green: 0.5725, blue: 0.1882),
        increasedContrastLight: Color(.sRGB, red: 0.6196, green: 0.2588, blue: 0),
        increasedContrastDark: Color(.sRGB, red: 1, green: 0.6275, blue: 0.3373)
    )
    static let warningHalo = Color(
        light: Color(.sRGB, red: 0.7725, green: 0.3255, blue: 0, opacity: 0.2196),
        dark: Color(.sRGB, red: 1, green: 0.5725, blue: 0.1882, opacity: 0.251)
    )
    static let warningTint = Color(
        light: Color(.sRGB, red: 0.7725, green: 0.3255, blue: 0, opacity: 0.1412),
        dark: Color(.sRGB, red: 1, green: 0.5725, blue: 0.1882, opacity: 0.1608),
        increasedContrastLight: Color(.sRGB, red: 0.7725, green: 0.3255, blue: 0, opacity: 0.2196),
        increasedContrastDark: Color(.sRGB, red: 1, green: 0.5725, blue: 0.1882, opacity: 0.251)
    )

    enum Accents {
        static let ember = Color(.sRGB, red: 0.949, green: 0.4196, blue: 0.2)
        static let emberDeep = Color(.sRGB, red: 0.7686, green: 0.2745, blue: 0.102)
        static let gold = Color(.sRGB, red: 0.8588, green: 0.6588, blue: 0.2392)
        static let goldDeep = Color(.sRGB, red: 0.6902, green: 0.4902, blue: 0.102)
        static let graphite = Color(
            light: Color(.sRGB, red: 0.2, green: 0.2, blue: 0.2),
            dark: Color(.sRGB, red: 0.851, green: 0.851, blue: 0.851)
        )
        static let graphiteDeep = Color(
            light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588),
            dark: Color(.sRGB, red: 0.549, green: 0.549, blue: 0.549)
        )
        static let lime = Color(.sRGB, red: 0.549, green: 0.7804, blue: 0.2)
        static let limeDeep = Color(.sRGB, red: 0.3686, green: 0.6, blue: 0.102)
        static let mint = Color(.sRGB, red: 0.2, green: 0.749, blue: 0.6196)
        static let mintDeep = Color(.sRGB, red: 0.0902, green: 0.5412, blue: 0.4392)
        static let ocean = Color(.sRGB, red: 0.2, green: 0.549, blue: 0.949)
        static let oceanDeep = Color(.sRGB, red: 0.102, green: 0.3725, blue: 0.7686)
        static let rose = Color(.sRGB, red: 0.9294, green: 0.3294, blue: 0.4784)
        static let roseDeep = Color(.sRGB, red: 0.7608, green: 0.1882, blue: 0.3098)
        static let violet = Color(.sRGB, red: 0.549, green: 0.4196, blue: 0.949)
        static let violetDeep = Color(.sRGB, red: 0.3686, green: 0.2471, blue: 0.8196)
        static let wing = Color(.sRGB, red: 1, green: 1, blue: 1)
    }

    enum Faces {
        static let active = Color(
            light: Color(.sRGB, red: 0.2039, green: 0.7804, blue: 0.349),
            dark: Color(.sRGB, red: 0.1882, green: 0.8196, blue: 0.3451)
        )
        static let blue = Color(.sRGB, red: 0.2941, green: 0.2941, blue: 0.8667)
        static let bodyClear = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0)
        static let bodyGloss = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.38)
        static let bodyLight = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.34)
        static let bodyShade = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.2)
        static let cyan = Color(.sRGB, red: 0.2941, green: 0.8667, blue: 0.8667)
        static let `default` = Color(.sRGB, red: 0.5451, green: 0.3608, blue: 0.9647)
        static let eyeOnDark = Color(.sRGB, red: 0.9098, green: 0.8588, blue: 0.7608, opacity: 0.949)
        static let eyeOnLight = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.851)
        static let green = Color(.sRGB, red: 0.2941, green: 0.8667, blue: 0.2941)
        static let lime = Color(.sRGB, red: 0.5804, green: 0.8667, blue: 0.2941)
        static let magenta = Color(.sRGB, red: 0.8667, green: 0.2941, blue: 0.8667)
        static let mint = Color(.sRGB, red: 0.2941, green: 0.8667, blue: 0.5804)
        static let orange = Color(.sRGB, red: 0.8667, green: 0.5804, blue: 0.2941)
        static let pink = Color(.sRGB, red: 0.8667, green: 0.2941, blue: 0.5804)
        static let red = Color(.sRGB, red: 0.8667, green: 0.2941, blue: 0.2941)
        static let sky = Color(.sRGB, red: 0.2941, green: 0.5804, blue: 0.8667)
        static let sparkleOnDark = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.6)
        static let sparkleOnLight = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.851)
        static let unread = Color(
            light: Color(.sRGB, red: 0, green: 0.5333, blue: 1),
            dark: Color(.sRGB, red: 0, green: 0.5686, blue: 1),
            increasedContrastLight: Color(.sRGB, red: 0.1176, green: 0.4314, blue: 0.9569),
            increasedContrastDark: Color(.sRGB, red: 0.3608, green: 0.7216, blue: 1)
        )
        static let violet = Color(.sRGB, red: 0.5804, green: 0.2941, blue: 0.8667)
        static let yellow = Color(.sRGB, red: 0.8667, green: 0.8667, blue: 0.2941)
    }

    enum Syntax {
        static let comment = Color(
            light: Color(.sRGB, red: 0.3647, green: 0.4235, blue: 0.4745),
            dark: Color(.sRGB, red: 0.498, green: 0.549, blue: 0.6),
            increasedContrastLight: Color(.sRGB, red: 0.2549, green: 0.2941, blue: 0.3294),
            increasedContrastDark: Color(.sRGB, red: 0.6667, green: 0.702, blue: 0.7333)
        )
        static let deleted = Color(
            light: Color(.sRGB, red: 0.7686, green: 0.1686, blue: 0.1686),
            dark: Color(.sRGB, red: 1, green: 0.4784, blue: 0.4784),
            increasedContrastLight: Color(.sRGB, red: 0.549, green: 0.1216, blue: 0.1216),
            increasedContrastDark: Color(.sRGB, red: 1, green: 0.5765, blue: 0.5765)
        )
        static let function = Color(
            light: Color(.sRGB, red: 0.2, green: 0.3608, blue: 0.6196),
            dark: Color(.sRGB, red: 0.4706, green: 0.702, blue: 0.9882),
            increasedContrastLight: Color(.sRGB, red: 0.1608, green: 0.2902, blue: 0.502),
            increasedContrastDark: Color(.sRGB, red: 0.498, green: 0.7176, blue: 0.9882)
        )
        static let inserted = Color(
            light: Color(.sRGB, red: 0.1216, green: 0.4784, blue: 0.2275),
            dark: Color(.sRGB, red: 0.4353, green: 0.8392, blue: 0.549),
            increasedContrastLight: Color(.sRGB, red: 0.0824, green: 0.3333, blue: 0.1569)
        )
        static let keyword = Color(
            light: Color(.sRGB, red: 0.6118, green: 0.1412, blue: 0.5804),
            dark: Color(.sRGB, red: 0.9882, green: 0.4706, blue: 0.749),
            increasedContrastLight: Color(.sRGB, red: 0.4941, green: 0.1137, blue: 0.4706),
            increasedContrastDark: Color(.sRGB, red: 0.9922, green: 0.5686, blue: 0.7961)
        )
        static let meta = Color(
            light: Color(.sRGB, red: 0.4706, green: 0.2863, blue: 0.1647),
            dark: Color(.sRGB, red: 0.9922, green: 0.6353, blue: 0.3529),
            increasedContrastLight: Color(.sRGB, red: 0.4157, green: 0.2549, blue: 0.1451)
        )
        static let number = Color(
            light: Color(.sRGB, red: 0.1098, green: 0, blue: 0.8118),
            dark: Color(.sRGB, red: 0.8196, green: 0.749, blue: 0.4784)
        )
        static let plain = Color(
            light: Color(.sRGB, red: 0.0588, green: 0.0588, blue: 0.0588),
            dark: Color(.sRGB, red: 0.9608, green: 0.9608, blue: 0.9608)
        )
        static let string = Color(
            light: Color(.sRGB, red: 0.7608, green: 0.2392, blue: 0.1608),
            dark: Color(.sRGB, red: 0.9882, green: 0.6196, blue: 0.4706),
            increasedContrastLight: Color(.sRGB, red: 0.5294, green: 0.1647, blue: 0.1098)
        )
        static let type = Color(
            light: Color(.sRGB, red: 0.1098, green: 0.4196, blue: 0.5294),
            dark: Color(.sRGB, red: 0.4196, green: 0.8392, blue: 0.8902),
            increasedContrastLight: Color(.sRGB, red: 0.0824, green: 0.3098, blue: 0.3922)
        )
    }
}
