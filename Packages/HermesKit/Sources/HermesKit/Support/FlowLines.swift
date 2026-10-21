import Foundation

/// Where the chips of a wrapping row go (the app's `FlowLayout`): left to right, onto a new line
/// when the next doesn't fit. A chip wider than the whole width gets that width and shortens its
/// own text. Laid out at its own width, one long chip (a clarify answer in "Question 2 of 2")
/// made the row, and the bottom bar's card with it, wider than the screen: clipped on both sides.
public struct FlowLines: Equatable, Sendable {
    /// Each chip's place and size, in order, from the row's top leading corner.
    public let frames: [CGRect]
    /// The whole row: never wider than the width it was given.
    public let size: CGSize

    /// - Parameters:
    ///   - width: the width offered, or nil for as wide as the chips want.
    ///   - spacing: between chips, and between lines.
    ///   - sizes: each chip's own size.
    ///   - fitted: a chip's size when it may be only so wide (its text truncated).
    public init(width: CGFloat?, spacing: CGFloat, sizes: [CGSize], fitted: (Int, CGFloat) -> CGSize) {
        let width = width ?? .infinity
        var frames: [CGRect] = []
        frames.reserveCapacity(sizes.count)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for (index, own) in sizes.enumerated() {
            var size = own
            if size.width > width {
                // Asked again at the full width; a chip that won't shrink still only counts as wide
                // as the row, so it can't widen what holds it.
                let shorter = fitted(index, width)
                size = CGSize(width: min(shorter.width, width), height: shorter.height)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        self.frames = frames
        // Whole points: a fractional height carried into a List row left the cells a pixel apart,
        // the page showing through as a line between them (the Plugins hub's wrapped tags).
        size = CGSize(width: maxX, height: (y + rowHeight).rounded(.up))
    }
}
