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

    // MARK: Head turn

    /// Hermes's `projectFacePoint`: roll rotates the point about (20, 20); turn and tilt squash it.
    public static func project(_ point: CGPoint, turn: Double, tilt: Double, roll: Double) -> CGPoint {
        let dx = point.x - 20, dy = point.y - 20
        let r = roll * .pi / 180
        let xr = dx * cos(r) - dy * sin(r)
        let yr = dx * sin(r) + dy * cos(r)
        let sx = 0.74 + 0.26 * abs(cos(turn * .pi / 180))
        let sy = 0.8 + 0.2 * abs(cos(tilt * .pi / 180))
        return CGPoint(x: 20 + xr * sx, y: 20 + yr * sy)
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
