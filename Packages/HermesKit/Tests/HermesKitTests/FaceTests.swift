import CoreGraphics
import Foundation
import Testing
@testable import HermesPush

/// The faces match Hermes Bot Mode (`avatar.tsx`, `profile-color.ts`); the expected numbers were
/// worked out independently from Hermes's formulas.
@Suite("Bot faces")
struct FaceTests {
    private func near(_ a: CGPoint, _ x: Double, _ y: Double, _ tolerance: Double = 0.001) -> Bool {
        abs(a.x - x) < tolerance && abs(a.y - y) < tolerance
    }

    @Test func outlinesFollowHermesFormulas() {
        let expected: [FaceShape: [(Int, Double, Double)]] = [
            .circle: [(0, 20, 3.8), (7, 32.1259, 9.2574), (13, 36.2, 20), (20, 30.7426, 32.1259), (39, 3.8, 20)],
            .squircle: [(0, 20, 3.8), (7, 34.8487, 6.8452), (13, 36.2, 20), (20, 33.1548, 34.8487), (39, 3.8, 20)],
            .pill: [(0, 20, 8.48), (7, 32.7233, 8.7282), (13, 36, 20), (20, 30.1714, 31.4811), (39, 4, 20)],
            .triangle: [(0, 20, -3.2085), (7, 30.2759, 10.8963), (13, 35.1806, 20), (20, 31.3117, 32.7683), (39, 4.8194, 20)],
            .hexagon: [(0, 20, 3.8), (7, 31.0711, 10.1919), (13, 34.0296, 20), (20, 29.4952, 30.7179), (39, 5.9704, 20)],
        ]
        for (shape, points) in expected {
            let ring = FaceGeometry.ring(shape)
            #expect(ring.count == 52)
            for (index, x, y) in points {
                #expect(near(ring[index], x, y), "\(shape) point \(index): \(ring[index])")
            }
        }
        // Drop: 17 + 18 + 17 points, from the tip.
        let drop = FaceGeometry.ring(.drop)
        #expect(drop.count == 52 && near(drop[0], 20, 3))
    }

    @Test func cloudArcsResolveLikeSVG() {
        let arcs = FaceGeometry.cloudArcs
        let expected: [(Double, Double, Double, Double, Double)] = [
            (11.2038, 24.5028, 7.5, 1.598, 2.9532), (19.5, 14.8, 9.7745, 2.9041, 3.1416), (29.5, 22.25, 9.7628, -1.622, 3.1416),
        ]
        for (arc, e) in zip(arcs, expected) {
            #expect(abs(arc.center.x - e.0) < 0.001 && abs(arc.center.y - e.1) < 0.001)
            #expect(abs(arc.radius - e.2) < 0.001 && abs(arc.start - e.3) < 0.001 && abs(arc.sweep - e.4) < 0.001)
        }
    }

    @Test func morphsKeepEveryOutlineTheSameWayRound() {
        // Halfway between any two shapes the outline stays a body: never thinner than either.
        func width(_ points: [CGPoint]) -> Double { (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0) }
        for a in FaceShape.allCases {
            for b in FaceShape.allCases where a != b {
                let ra = FaceGeometry.resample(FaceGeometry.ring(a, steps: 160), count: 120)
                let rb = FaceGeometry.resample(FaceGeometry.ring(b, steps: 160), count: 120)
                let half = zip(ra, rb).map { CGPoint(x: ($0.x + $1.x) / 2, y: ($0.y + $1.y) / 2) }
                #expect(width(half) > min(width(ra), width(rb)) * 0.8, "\(a) → \(b)")
            }
        }
    }

    @Test func headTurnSquashesLikeHermes() {
        #expect(near(FaceGeometry.project(CGPoint(x: 36.2, y: 20), turn: -18, tilt: 12, roll: 10), 35.7509, 22.8008))
    }

    @Test func coloursComeFromTheNameAndEyesFromLuminance() {
        // Hermes `hashString` and `defaultShapeFor`.
        #expect(FaceColor.nameHash("researcher") % 360 == 312)
        #expect(FaceShape.forName("researcher") == .hexagon && FaceShape.forName("writer") == .drop)
        // hsl(H 68% 58%): cream eyes exactly on red, blue and violet.
        let cream = FaceColor.swatches.enumerated().filter { $0.element.isDark }.map { $0.offset * 30 }
        #expect(cream == [0, 240, 270])
        #expect(!FaceColor.defaultViolet.isDark)
        #expect(FaceColor.swatches[0].eye == .eyeOnDark && FaceColor.swatches[0].catchlight == .sparkleOnDark)
        #expect(FaceColor.swatches[2].eye == .eyeOnLight && FaceColor.swatches[2].catchlight == .sparkleOnLight)
        // Stored forms.
        #expect(FaceColor(css: "hsl(240 68% 58%)") == FaceColor.hue(240))
        #expect(FaceColor(css: "hsl(240, 68%, 58%)") == FaceColor.hue(240))
        #expect(FaceColor(css: "#8b5cf6") == .defaultViolet)
        // The default profile: violet squircle unless customised.
        #expect(FaceLook(profile: "default") == FaceLook(shape: .squircle, color: .defaultViolet))
        #expect(FaceLook(profile: "default", shape: "cloud", customized: true).shape == .cloud)
        #expect(FaceLook(profile: "writer").color == FaceColor.forName("writer"))
    }

    @Test func posesMatchTheTable() {
        let t = 2.0
        let think = FacePose.of(.thinking, at: t)
        #expect(abs(think.turn - (-18 + sin(t * 0.55) * 14)) < 1e-9)
        #expect(abs(think.tilt - (sin(t * 0.48) * 12 + sin(t * 1.35) * 3)) < 1e-9)
        #expect(abs(think.dots.1 - (0.2 + 0.8 * max(0, sin(t * 2.4 - 0.7)))) < 1e-9)
        let work = FacePose.of(.working, at: t)
        #expect(abs(work.gazeY - (-1.6 + sin(t * 0.38) * 2)) < 1e-9)
        #expect(abs(work.dots.0 - (0.2 + 0.8 * max(0, sin(t * 2.6)))) < 1e-9)
        let idle = FacePose.of(.idle, at: 3.1)
        #expect(idle.blink && !FacePose.of(.idle, at: 3.0).blink)
        #expect(idle.dots == (0, 0, 0))
        #expect(FacePose.of(.listening, at: t).gazeX == 1.4)
        #expect(FacePose.of(.sleeping, at: t) == .rest)
    }

    @Test func moodChangesBlendOverFourTenthsWithEaseOut() {
        var transition = FaceTransition(target: FaceTarget(mood: .idle), at: 10)
        transition.change(to: FaceTarget(mood: .thinking), at: 10)
        let start = transition.pose(at: 10), idle = FacePose.of(.idle, at: 10)
        #expect(abs(start.turn - idle.turn) < 1e-9)
        let half = transition.pose(at: 10.2), think = FacePose.of(.thinking, at: 10.2), from = FacePose.of(.idle, at: 10)
        // 1 − (1 − 0.5)² = 0.75 of the way.
        #expect(abs(half.turn - (from.turn + (think.turn - from.turn) * 0.75)) < 1e-9)
        #expect(transition.pose(at: 10.4) == FacePose.of(.thinking, at: 10.4))
        // Looking at something: up to ±3.2.
        #expect(FaceTarget(mood: .idle, look: CGVector(dx: -2, dy: 0.5)).pose(at: 1).gazeX == -3.2)
    }

    @Test func eyesFollowTheMood() {
        #expect(FaceFrame.eyes(for: .working, pose: FacePose()) == .open(height: 2.6))
        #expect(FaceFrame.eyes(for: .idle, pose: FacePose()) == .open(height: 2.3))
        #expect(FaceFrame.eyes(for: .idle, pose: FacePose(blink: true)) == .closed)
        #expect(FaceFrame.eyes(for: .happy, pose: FacePose(blink: true)) == .happy)
        #expect(FaceFrame(mood: .sleeping, pose: .rest).bodyOpacity == 0.45)
        // Increase Contrast outlines: yellow on white, blue on a dark window; not orange on white.
        let darkWindow = FaceColor(hex: 0x1C1C1E)
        #expect(FaceColor.hue(60).contrast(with: .white) < 3 && FaceColor.hue(240).contrast(with: darkWindow) < 3)
        #expect(FacePainter.contrastOutline(for: .hue(30), on: .white, separator: .gray) != nil) // orange is 2.3:1 too
        #expect(FacePainter.contrastOutline(for: .hue(240), on: .white, separator: .gray) == nil)
    }
}
