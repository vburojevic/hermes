import Foundation
import Testing
@testable import HermesKit

@Suite("The composer at each text size")
struct ComposerSizingTests {
    /// The design's handoff, Large to AX5: button, an 18 pt glyph, hit area, corner radius.
    @Test(arguments: [
        (0, 36, 18, 44, 28) as (Int, CGFloat, CGFloat, CGFloat, CGFloat),
        (1, 38, 19, 44, 29),
        (2, 40, 20, 44, 30),
        (3, 42, 21, 44, 31),
        (4, 44, 22, 44, 32),
        (5, 46, 23, 46, 33),
        (6, 48, 24, 48, 34),
        (7, 50, 25, 50, 35),
        (8, 52, 26, 52, 36),
    ])
    func buttonsFollowTheDesign(step: Int, diameter: CGFloat, glyph: CGFloat, hit: CGFloat, radius: CGFloat) {
        let sizing = ComposerSizing(step: step)
        #expect(sizing.buttonDiameter == diameter)
        #expect(sizing.glyph(18) == glyph)
        #expect(sizing.hitTarget == hit)
        #expect(sizing.cornerRadius == radius)
    }

    @Test func largeIsTodaysComposer() {
        let large = ComposerSizing.large
        #expect(large.buttonDiameter == 36)
        #expect(large.glyphScale == 1)
        #expect(large.cornerRadius == 28)
        #expect(large.chipMinHeight == 32)
        #expect(large.chipGlyph(14) == 14)
        #expect(large.projectTileSize == 20)
        #expect(large.chipChevronSize == 9)
        #expect(large.processDotSize == 14)
        #expect(ComposerSizing.controlSpacing == 8)
    }

    @Test func smallerTextKeepsTheLargeSizes() {
        let small = ComposerSizing(step: -3), large = ComposerSizing.large
        #expect(small.buttonDiameter == large.buttonDiameter)
        #expect(small.glyphScale == large.glyphScale)
        #expect(small.hitTarget == large.hitTarget)
        #expect(small.cornerRadius == large.cornerRadius)
        #expect(small.chipMinHeight == large.chipMinHeight)
        #expect(small.chipGlyph(14) == large.chipGlyph(14))
        #expect(small.projectTileSize == large.projectTileSize)
        #expect(small.chipChevronSize == large.chipChevronSize)
        #expect(small.processDotSize == large.processDotSize)
    }

    /// + and Dictate draw a 16 pt symbol at Large, which fills the design's 18 pt frame; it keeps
    /// that size against its circle up to AX5.
    @Test func aGlyphKeepsItsSizeAgainstItsCircle() {
        #expect(ComposerSizing.large.glyph(16) == 16)
        #expect(ComposerSizing(step: 4).glyph(16) == CGFloat(16) * 44 / 36)
        #expect(ComposerSizing(step: 8).glyph(16) == CGFloat(16) * 52 / 36)
        #expect(ComposerSizing(step: 8).glyph(12) == CGFloat(12) * 52 / 36)
    }

    @Test func smallerCirclesReachOutTo44() {
        let large = ComposerSizing.large
        #expect(large.hitMargin(around: large.buttonDiameter) == 4)
        #expect(large.hitMargin(around: 32) == 6)
        #expect(ComposerSizing(step: 8).hitMargin(around: 52) == 0)
        #expect(ComposerSizing(step: 8).hitMargin(around: 48) == 0)
    }

    @Test func theButtonsStopAtAX5() {
        #expect(ComposerSizing(step: 12).buttonDiameter == ComposerSizing.maxDiameter)
    }

    @Test func chipsStopGrowingAtAX1() {
        #expect(ComposerSizing(step: 3).chipMinHeight == 38)
        for step in 4...8 {
            let sizing = ComposerSizing(step: step)
            #expect(sizing.chipMinHeight == 44)
            #expect(sizing.chipGlyph(14) == 20)
            #expect(sizing.projectTileSize == 28)
            #expect(sizing.chipChevronSize == 12)
            #expect(sizing.processDotSize == 21)
        }
        // The chip glyphs reach 20 pt at xxxLarge, a size before the rest.
        #expect(ComposerSizing(step: 3).chipGlyph(14) == 20)
        #expect(ComposerSizing(step: 3).projectTileSize == 26)
    }

    @Test func onlyACompactWidthAtAnAccessibilitySizeGetsTheChipRow() {
        #expect(!ComposerSizing(step: 3).usesChipRow(isCompactWidth: true))
        #expect(ComposerSizing(step: 4).usesChipRow(isCompactWidth: true))
        #expect(ComposerSizing(step: 8).usesChipRow(isCompactWidth: true))
        #expect(!ComposerSizing(step: 8).usesChipRow(isCompactWidth: false))
    }
}
