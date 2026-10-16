import CoreGraphics
import Foundation

/// The face's outline in Hermes's 40 × 40 face box (`docs/bot-faces.md` §1), sampled from the same
/// formulas as Hermes Bot Mode (`sampleFaceRing`), so a Bot keeps its face across both apps.
public enum FaceGeometry {
    /// Hermes's sample count. Larger faces use more so the facets don't show.
    public static let hermesSteps = 52

    /// Points around the body, clockwise from the top.
    public static func ring(_ shape: FaceShape, steps: Int = hermesSteps) -> [CGPoint] {
        switch shape {
        case .drop: return dropRing(steps)
        case .cloud: return cloudRing(steps)
        default: break
        }
        return (0..<steps).map { i in
            let a = Double(i) / Double(steps) * .pi * 2 - .pi / 2
            let r = radius(shape, at: a)
            return CGPoint(x: 20 + r * cos(a), y: 20 + r * sin(a))
        }
    }

    /// r(a) for the formula shapes; angle `a` runs from −π/2 around (20, 20).
    public static func radius(_ shape: FaceShape, at a: Double) -> Double {
        let c = cos(a), s = sin(a)
        switch shape {
        case .squircle:
            let d = pow(pow(abs(c), 5) + pow(abs(s), 5), 1 / 5.0)
            return 16.2 / (d == 0 ? 1 : d)
        case .pill:
            let d = pow(pow(abs(c), 8) + pow(abs(s / 0.72), 8), 1 / 8.0)
            return 16 / (d == 0 ? 1 : d)
        case .triangle:
            let u = (a + .pi / 2 + .pi * 2).truncatingRemainder(dividingBy: .pi * 2)
            let sector = (u / (.pi * 2 / 3)).truncatingRemainder(dividingBy: 1)
            return 13.5 / max(0.42, cos((sector - 0.5) * 1.9))
        case .hexagon:
            let segment = Double.pi / 3
            // `Math.round` rounds halves up.
            return 16.2 * cos(segment / 2) / cos(a - segment * (a / segment + 0.5).rounded(.down))
        case .circle, .cloud, .drop:
            return 16.2
        }
    }

    // MARK: Drop: the cubic down the left, a half ellipse along the bottom, the cubic back up

    static func dropRing(_ steps: Int) -> [CGPoint] {
        let n = max(8, steps / 3)
        var points: [CGPoint] = []
        for i in 0..<n {
            points.append(cubic(CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), CGPoint(x: 6, y: 20), CGPoint(x: 6, y: 27), Double(i) / Double(n)))
        }
        for i in 0...n {
            let t = Double(i) / Double(n) * .pi
            points.append(CGPoint(x: 20 - 14 * cos(t), y: 27 + 13.5 * sin(t)))
        }
        for i in 1...n {
            points.append(cubic(CGPoint(x: 34, y: 27), CGPoint(x: 34, y: 20), CGPoint(x: 20, y: 3), CGPoint(x: 20, y: 3), Double(i) / Double(n)))
        }
        return points
    }

    static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    // MARK: Cloud: `M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z`

    /// One SVG arc, centre-parameterised.
    public struct Arc: Sendable, Equatable {
        public var center: CGPoint
        public var radius: Double
        public var start: Double
        public var sweep: Double
    }

    /// The cloud's three puffs, as SVG's endpoint arcs resolve them.
    public static let cloudArcs: [Arc] = [
        svgArc(from: CGPoint(x: 11, y: 32), radius: 7.5, sweep: true, to: CGPoint(x: 10, y: 17.1)),
        svgArc(from: CGPoint(x: 10, y: 17.1), radius: 9.5, sweep: true, to: CGPoint(x: 29, y: 12.5)),
        svgArc(from: CGPoint(x: 29, y: 12.5), radius: 7, sweep: true, to: CGPoint(x: 30, y: 32)),
    ]

    /// SVG endpoint-to-centre conversion for a circular arc (large-arc flag 0), as Hermes's `svgArc`.
    static func svgArc(from p1: CGPoint, radius: Double, sweep: Bool, to p2: CGPoint) -> Arc {
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        var r = radius
        let lambda = (dx * dx + dy * dy) / (r * r)
        if lambda > 1 { r *= lambda.squareRoot() }
        let r2 = r * r
        let num = r2 * r2 - r2 * dy * dy - r2 * dx * dx
        let den = r2 * dy * dy + r2 * dx * dx
        var sq = max(0, num / den).squareRoot()
        if !sweep { sq = -sq } // fa (0) == fs flips the root
        let cx = sq * dy + (p1.x + p2.x) / 2
        let cy = sq * -dx + (p1.y + p2.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let n = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / (n == 0 ? 1 : n))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let start = angle(1, 0, (p1.x - cx) / r, (p1.y - cy) / r)
        var delta = angle((p1.x - cx) / r, (p1.y - cy) / r, (p2.x - cx) / r, (p2.y - cy) / r)
        if !sweep && delta > 0 { delta -= .pi * 2 }
        if sweep && delta < 0 { delta += .pi * 2 }
        return Arc(center: CGPoint(x: cx, y: cy), radius: r, start: start, sweep: delta)
    }

    static func cloudRing(_ steps: Int) -> [CGPoint] {
        let lengths = cloudArcs.map { abs($0.sweep) * $0.radius } + [19]
        let total = lengths.reduce(0, +)
        let n = max(64, steps)
        let n1 = max(8, Int((Double(n) * lengths[0] / total).rounded()))
        let n2 = max(10, Int((Double(n) * lengths[1] / total).rounded()))
        let n3 = max(10, Int((Double(n) * lengths[2] / total).rounded()))
        let n4 = max(4, n - n1 - n2 - n3)
        var points: [CGPoint] = []
        for (arc, count) in zip(cloudArcs, [n1, n2, n3]) {
            for i in 0..<count {
                let theta = arc.start + arc.sweep * Double(i) / Double(count)
                points.append(CGPoint(x: arc.center.x + arc.radius * cos(theta), y: arc.center.y + arc.radius * sin(theta)))
            }
        }
        for i in 0..<n4 {
            points.append(CGPoint(x: 30 + (11 - 30) * Double(i) / Double(n4), y: 32))
        }
        return points
    }

    /// The cloud exactly as Hermes paints it (its body isn't sampled or turned).
    public static func cloudPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 11, y: 32))
        for arc in cloudArcs {
            path.addArc(center: arc.center, radius: arc.radius, startAngle: arc.start, endAngle: arc.start + arc.sweep, clockwise: arc.sweep < 0)
        }
        path.closeSubpath()
        return path
    }

    /// `count` points evenly spaced along a closed ring by arc length, starting nearest the top
    /// centre: two shapes resampled this way morph point to point.
    public static func resample(_ ring: [CGPoint], count: Int) -> [CGPoint] {
        guard ring.count > 2, count > 2 else { return ring }
        // One winding for every shape (the drop is sampled the other way round), or a morph
        // collapses through the middle.
        var ring = ring
        let area = zip(ring, ring.dropFirst() + [ring[0]]).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        if area < 0 { ring.reverse() }
        // Start at the point closest to straight up from the centre, so outlines line up.
        let start = ring.indices.min { abs(ring[$0].x - 20) + max(0, ring[$0].y - 20) * 4 < abs(ring[$1].x - 20) + max(0, ring[$1].y - 20) * 4 } ?? 0
        let ordered = Array(ring[start...] + ring[..<start])
        var lengths: [Double] = [0]
        for i in 1...ordered.count {
            let a = ordered[i - 1], b = ordered[i % ordered.count]
            lengths.append(lengths[i - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = lengths.last ?? 1
        var points: [CGPoint] = []
        var segment = 0
        for k in 0..<count {
            let target = total * Double(k) / Double(count)
            while segment < ordered.count - 1, lengths[segment + 1] < target { segment += 1 }
            let a = ordered[segment], b = ordered[(segment + 1) % ordered.count]
            let span = lengths[segment + 1] - lengths[segment]
            let t = span > 0 ? (target - lengths[segment]) / span : 0
            points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return points
    }
}

/// A shape as the app draws it: Hermes's outline, fitted into the face box. Every shape gets about
/// the same weight (a square no longer looms over a hexagon), sits centred with room to move, and
/// never reaches past the box, so none is cut off and none crowds the dots below it.
public struct FaceBody: @unchecked Sendable {
    public let shape: FaceShape
    /// `pointCount` points evenly spaced along the outline, the same way round for every shape and
    /// starting at the top: drawn as is, and morphed point to point.
    public let points: [CGPoint]
    public let path: CGPath
    public let bounds: CGRect
    /// The midpoint between the eyes.
    public let eyes: CGPoint
    /// How far the eyes can look each way and still sit on the body.
    public let gaze: GazeRange

    public struct GazeRange: Sendable, Equatable {
        public var left: Double
        public var right: Double
        public var up: Double
        public var down: Double

        /// `(x, y)` pulled back inside the range.
        public func clamp(x: Double, y: Double) -> (x: Double, y: Double) {
            (max(-left, min(right, x)), max(-up, min(down, y)))
        }
    }

    public static let pointCount = 240
    /// The eyes' half spacing and size (Hermes's 15.4 / 24.6 and rx 2.2).
    public static let eyeSpread = 4.6
    public static let eyeRadius = 2.2
    /// The weight every shape is fitted to (about a 29.5-unit circle), and the most room one may take.
    static let targetArea = 680.0
    static let maxExtent = 33.0

    public static func of(_ shape: FaceShape) -> FaceBody {
        cache[shape] ?? make(shape)
    }

    private static let cache: [FaceShape: FaceBody] = Dictionary(uniqueKeysWithValues: FaceShape.allCases.map { ($0, make($0)) })

    /// The eye line, as a share of the body's height from its top: lower where the top narrows.
    static func eyeLine(_ shape: FaceShape) -> Double {
        switch shape {
        case .triangle: 0.62
        case .drop: 0.6
        case .cloud: 0.6
        case .pill: 0.46
        case .circle, .squircle, .hexagon: 0.44
        }
    }

    static func make(_ shape: FaceShape) -> FaceBody {
        let raw = FaceGeometry.resample(FaceGeometry.ring(shape, steps: 480), count: 480)
        let rawBounds = boundingBox(raw)
        var scale = (targetArea / max(1, area(raw))).squareRoot()
        scale = min(scale, maxExtent / max(rawBounds.width, rawBounds.height))
        let center = CGPoint(x: rawBounds.midX, y: rawBounds.midY)
        let fitted = raw.map { CGPoint(x: 20 + ($0.x - center.x) * scale, y: 20 + ($0.y - center.y) * scale) }
        let points = FaceGeometry.resample(fitted, count: pointCount)
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let bounds = boundingBox(points)
        let eyes = CGPoint(x: 20, y: bounds.minY + bounds.height * eyeLine(shape))
        return FaceBody(shape: shape, points: points, path: path, bounds: bounds, eyes: eyes, gaze: gazeRange(path: path, eyes: eyes))
    }

    /// How far both eyes (with a margin) can move along each axis and stay inside the outline.
    static func gazeRange(path: CGPath, eyes: CGPoint) -> GazeRange {
        func fits(_ dx: Double, _ dy: Double) -> Bool {
            let margin = 1.4
            let reach = eyeRadius + margin
            for side in [-eyeSpread, eyeSpread] {
                let x = eyes.x + side + dx, y = eyes.y + dy
                for (px, py) in [(x - reach, y), (x + reach, y), (x, y - reach - 0.2), (x, y + reach + 0.2),
                                 (x - reach * 0.7, y - reach * 0.7), (x + reach * 0.7, y - reach * 0.7),
                                 (x - reach * 0.7, y + reach * 0.7), (x + reach * 0.7, y + reach * 0.7)] {
                    if !path.contains(CGPoint(x: px, y: py)) { return false }
                }
            }
            return true
        }
        func reach(_ step: (Double) -> (Double, Double)) -> Double {
            var distance = 0.0
            while distance < 3.4 {
                let (dx, dy) = step(distance + 0.1)
                guard fits(dx, dy) else { break }
                distance += 0.1
            }
            return distance
        }
        return GazeRange(
            left: reach { (-$0, 0) }, right: reach { ($0, 0) },
            up: reach { (0, -$0) }, down: reach { (0, $0) }
        )
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func area(_ points: [CGPoint]) -> Double {
        abs(zip(points, points.dropFirst() + [points[0]]).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }) / 2
    }
}
