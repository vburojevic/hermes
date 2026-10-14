import CoreGraphics

/// Geometry of the Hermes mark: a single swept wing.
///
/// Kept CoreGraphics-only so the app icon generator in `Tools/IconGen` can
/// compile this exact file and draw the same mark the UI shows.
nonisolated enum HermesMarkPath {
    /// The mark in a 100 × 100 design grid, fitted to `rect` (aspect preserved, centred).
    static func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let scale = side / 100
        var transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return unitPath.copy(using: &transform) ?? unitPath
    }

    /// An immutable `CGPath` is safe to share across threads; CoreGraphics just doesn't say so.
    nonisolated(unsafe) private static let unitPath: CGPath = {
        let path = CGMutablePath()
        // Leading edge: from the shoulder, up and out to the primary feather's tip.
        path.move(to: CGPoint(x: 12, y: 66))
        path.addCurve(to: CGPoint(x: 90, y: 12), control1: CGPoint(x: 24, y: 34), control2: CGPoint(x: 58, y: 14))
        // Trailing edge: four feathers stepping back toward the shoulder.
        let feathers: [(notch: CGPoint, notchControl: CGPoint, tip: CGPoint)] = [
            (CGPoint(x: 66, y: 40), CGPoint(x: 84, y: 28), CGPoint(x: 86, y: 36)),
            (CGPoint(x: 58, y: 56), CGPoint(x: 78, y: 48), CGPoint(x: 77, y: 55)),
            (CGPoint(x: 48, y: 68), CGPoint(x: 68, y: 64), CGPoint(x: 64, y: 71)),
        ]
        for feather in feathers {
            path.addQuadCurve(to: feather.notch, control: feather.notchControl)
            path.addQuadCurve(to: feather.tip, control: CGPoint(x: (feather.notch.x + feather.tip.x) / 2 + 2, y: feather.notch.y - 1))
        }
        path.addQuadCurve(to: CGPoint(x: 22, y: 82), control: CGPoint(x: 50, y: 84))
        path.addQuadCurve(to: CGPoint(x: 12, y: 66), control: CGPoint(x: 8, y: 80))
        path.closeSubpath()
        return path
    }()

    /// The convex hull of two circles: a capsule that narrows from `start` to `end`.
    private static func taperedCapsule(from start: CGPoint, radius r1: CGFloat, to end: CGPoint, radius r2: CGFloat) -> CGPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let axis = atan2(dy, dx)
        // Angle between the axis and the radius that touches the outer tangent lines.
        let spread = acos(max(-1, min(1, (r1 - r2) / distance)))

        let path = CGMutablePath()
        path.addArc(center: start, radius: r1, startAngle: axis + spread, endAngle: axis - spread + 2 * .pi, clockwise: false)
        path.addArc(center: end, radius: r2, startAngle: axis - spread, endAngle: axis + spread, clockwise: false)
        path.closeSubpath()
        return path
    }
}
