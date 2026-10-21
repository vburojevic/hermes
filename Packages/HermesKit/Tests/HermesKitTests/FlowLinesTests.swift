import Foundation
import Testing
@testable import HermesKit

@Suite("Wrapping chips onto lines")
struct FlowLinesTests {
    /// A chip whose text truncates: as wide as it's allowed, never narrower than its icon.
    private func truncating(_ sizes: [CGSize]) -> (Int, CGFloat) -> CGSize {
        { index, width in CGSize(width: max(24, min(sizes[index].width, width)), height: sizes[index].height) }
    }

    @Test func chipsThatFitShareALine() {
        let sizes = [CGSize(width: 80, height: 20), CGSize(width: 60, height: 20)]
        let lines = FlowLines(width: 300, spacing: 6, sizes: sizes, fitted: truncating(sizes))
        #expect(lines.frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 86, y: 0)])
        #expect(lines.size == CGSize(width: 146, height: 20))
    }

    @Test func theNextChipWrapsWhenItDoesntFit() {
        let sizes = [CGSize(width: 200, height: 20), CGSize(width: 120, height: 24)]
        let lines = FlowLines(width: 300, spacing: 6, sizes: sizes, fitted: truncating(sizes))
        #expect(lines.frames[1].origin == CGPoint(x: 0, y: 26))
        #expect(lines.size == CGSize(width: 200, height: 50))
    }

    @Test func aChipLongerThanTheLineTakesTheLinesWidth() {
        // "Question 2 of 2": the first answer, as one chip, in a card 408 pt wide (iPhone Pro Max).
        let sizes = [CGSize(width: 640, height: 20)]
        let lines = FlowLines(width: 408, spacing: 6, sizes: sizes, fitted: truncating(sizes))
        #expect(lines.frames == [CGRect(x: 0, y: 0, width: 408, height: 20)])
        #expect(lines.size.width <= 408)
    }

    @Test func nothingIsEverWiderThanTheWidthGiven() {
        let sizes = [CGSize(width: 50, height: 20), CGSize(width: 900, height: 20), CGSize(width: 70, height: 20),
                     CGSize(width: 330, height: 20)]
        for width in [120.0, 280, 343, 408, 700] {
            let lines = FlowLines(width: width, spacing: 6, sizes: sizes, fitted: truncating(sizes))
            #expect(lines.size.width <= width, "\(lines.size.width) at \(width)")
            #expect(lines.frames.allSatisfy { $0.maxX <= width }, "a chip runs past \(width)")
        }
    }

    @Test func aChipThatWontShrinkStillCountsAsTheLinesWidth() {
        // Fixed-size content can't truncate; the row still doesn't widen what holds it.
        let sizes = [CGSize(width: 500, height: 20)]
        let lines = FlowLines(width: 300, spacing: 6, sizes: sizes) { _, _ in CGSize(width: 500, height: 20) }
        #expect(lines.size.width == 300)
    }

    @Test func withoutAWidthEverythingStaysOnOneLineAtItsOwnSize() {
        let sizes = [CGSize(width: 640, height: 20), CGSize(width: 80, height: 20)]
        let lines = FlowLines(width: nil, spacing: 6, sizes: sizes) { _, _ in
            Issue.record("asked to shorten without a width")
            return .zero
        }
        #expect(lines.size == CGSize(width: 726, height: 20))
    }

    @Test func theHeightIsWholePoints() {
        let sizes = [CGSize(width: 40, height: 20.33)]
        #expect(FlowLines(width: 100, spacing: 6, sizes: sizes, fitted: truncating(sizes)).size.height == 21)
    }
}
