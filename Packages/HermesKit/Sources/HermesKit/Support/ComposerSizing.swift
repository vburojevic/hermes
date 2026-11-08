import Foundation

/// How the composer follows the text size (`docs/composer.md` §1, `composerType*` in the design):
/// its round buttons grow 2 pt a size from 36 pt at Large to 52 pt at AX5, their glyphs with them,
/// and from AX1 a compact width moves the chips onto their own row. The chips stop growing at AX1.
/// The Mac keeps the Large sizes.
public struct ComposerSizing: Equatable, Sendable {
    /// Text sizes above the default, Large: 1 for xLarge up to 8 for AX5. Smaller sizes are below 0
    /// and keep the Large sizes.
    public let step: Int

    public init(step: Int) {
        self.step = step
    }

    /// Large, the default, and the Mac at every size.
    public static let large = ComposerSizing(step: 0)

    /// The first accessibility size, AX1: the chips reach their cap and, in a compact width, move
    /// to their own row.
    public static let firstAccessibilityStep = 4
    /// The buttons' diameter at Large.
    public static let baseDiameter: CGFloat = 36
    /// The buttons stop growing here, at AX5.
    public static let maxDiameter: CGFloat = 52
    /// The smallest a button's hit area gets (HIG).
    public static let minimumHitTarget: CGFloat = 44

    /// The step, kept to the sizes the design draws: Large up to AX5.
    private var clamped: CGFloat { CGFloat(min(max(step, 0), 8)) }

    /// The step the chips stop at.
    private var chipStep: CGFloat { min(clamped, CGFloat(Self.firstAccessibilityStep)) }

    public var isAccessibilitySize: Bool { step >= Self.firstAccessibilityStep }

    /// +, Dictate, the trailing button and the dictation row's buttons.
    public var buttonDiameter: CGFloat { min(Self.baseDiameter + 2 * clamped, Self.maxDiameter) }

    /// The glyphs grow with their circle and keep their size against it: a glyph drawn at `size`
    /// at Large is `size × glyphScale`. The design draws each glyph's frame at half its circle;
    /// a symbol drawn at 16 pt fills that 18 pt frame at Large.
    public var glyphScale: CGFloat { buttonDiameter / Self.baseDiameter }

    /// A button's glyph drawn at `size` at Large.
    public func glyph(_ size: CGFloat) -> CGFloat { size * buttonDiameter / Self.baseDiameter }

    /// A chip's glyph drawn at `size` at Large: 2 pt a size on a 14 pt base, stopping at 20 pt
    /// from xxxLarge.
    public func chipGlyph(_ size: CGFloat) -> CGFloat { size * (14 + 2 * min(chipStep, 3)) / 14 }

    /// The circle, or 44 pt around it where the circle is smaller, centered on it.
    public var hitTarget: CGFloat { max(buttonDiameter, Self.minimumHitTarget) }

    /// How far a circle of `diameter` reaches out on each side to give it a 44 pt hit area.
    public func hitMargin(around diameter: CGFloat) -> CGFloat {
        max(Self.minimumHitTarget - diameter, 0) / 2
    }

    /// The panel's corner radius follows its buttons: 28 at Large, 36 at AX5.
    public var cornerRadius: CGFloat { buttonDiameter / 2 + 10 }

    /// A chip's height: 4 pt under the buttons, as at Large, until AX1, where the chips stop growing
    /// at the 44 pt hit target.
    public var chipMinHeight: CGFloat {
        isAccessibilitySize ? Self.minimumHitTarget : buttonDiameter - 4
    }

    /// A chip's chevron: 9 pt at Large, 12 pt from AX1.
    public var chipChevronSize: CGFloat { 9 + 0.75 * chipStep }

    /// The project chip's tile: 20 pt at Large, 28 pt from AX1.
    public var projectTileSize: CGFloat { 20 + 2 * chipStep }

    /// The process chip's running dot: 14 pt at Large, 21 pt from AX1.
    public var processDotSize: CGFloat { 14 + 1.75 * chipStep }

    /// Between the controls row's buttons and chips, at every size.
    public static let controlSpacing: CGFloat = 8

    /// Between the chips on their own row.
    public static let chipRowSpacing: CGFloat = 8

    /// From AX1, a compact width (iPhone, iPad in Slide Over) puts the chips on their own row under
    /// the field, and the controls row keeps +, Dictate and the trailing button. A regular width has
    /// the room for one row at every size.
    public func usesChipRow(isCompactWidth: Bool) -> Bool {
        isCompactWidth && isAccessibilitySize
    }
}
