import CoreGraphics
import Foundation
import Testing
@testable import HermesPush

/// The faces keep Hermes Bot Mode's shapes and colours (`avatar.tsx`, `profile-color.ts`; the expected
/// numbers were worked out independently from its formulas), fitted and moved the app's own way.
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

    @Test func everyShapeFitsWholeWithRoomToMove() {
        for shape in FaceShape.allCases {
            let body = FaceBody.of(shape)
            // Inside the face box with room for a lean and a breath, and clear of the dots (y 40).
            #expect(body.bounds.minX >= 3 && body.bounds.maxX <= 37, "\(shape) \(body.bounds)")
            #expect(body.bounds.minY >= 3 && body.bounds.maxY <= 37, "\(shape) \(body.bounds)")
            // About the same weight: no shape looms over another.
            let area = FaceBody.area(body.points)
            #expect(area > 520 && area < 700, "\(shape) area \(area)")
            // Leaning 4° and breathing in, still inside the 40 × 44 canvas.
            let base = body.bounds.maxY, angle = 4.0 * .pi / 180
            for point in body.points {
                let dx = point.x - 20, dy = (point.y - base) * 1.03
                let x = 20 + dx * cos(angle) - dy * sin(angle), y = base + dx * sin(angle) + dy * cos(angle)
                #expect(x > 0.5 && x < 39.5 && y > 0.5, "\(shape) leaves the canvas at \(x), \(y)")
            }
        }
    }

    @Test func eyesStayOnTheBodyWhereverTheyLook() {
        for shape in FaceShape.allCases {
            let body = FaceBody.of(shape)
            #expect(body.gaze.left >= 0.8 && body.gaze.right >= 0.8, "\(shape) eyes can hardly move: \(body.gaze)")
            for mood in FaceMood.allCases {
                for step in 0..<400 {
                    let pose = FacePose.of(mood, at: Double(step) * 0.05, seed: 77)
                    let gaze = body.gaze.clamp(x: pose.gazeX, y: pose.gazeY)
                    for side in [-FaceBody.eyeSpread, FaceBody.eyeSpread] {
                        let eye = CGPoint(x: body.eyes.x + side + gaze.x, y: body.eyes.y + gaze.y)
                        for corner in [CGPoint(x: -2.2, y: 0), CGPoint(x: 2.2, y: 0), CGPoint(x: 0, y: -2.6), CGPoint(x: 0, y: 2.6)] {
                            #expect(body.path.contains(CGPoint(x: eye.x + corner.x, y: eye.y + corner.y)), "\(shape) \(mood) eye off the body")
                        }
                    }
                }
            }
        }
    }

    @Test func eachBotKeepsItsOwnTime() {
        // The same Bot moves the same way every time; two Bots don't blink or glance in step.
        let a = (0..<300).map { FacePose.of(.idle, at: Double($0) * 0.05, seed: 1) }
        let again = (0..<300).map { FacePose.of(.idle, at: Double($0) * 0.05, seed: 1) }
        let b = (0..<300).map { FacePose.of(.idle, at: Double($0) * 0.05, seed: 2) }
        #expect(a == again)
        let blinksA = Set(a.indices.filter { a[$0].lid < 0.5 }), blinksB = Set(b.indices.filter { b[$0].lid < 0.5 })
        #expect(!blinksA.isEmpty && !blinksB.isEmpty)
        #expect(blinksA != blinksB)
        #expect(zip(a, b).contains { abs($0.gazeX - $1.gazeX) > 0.5 })
        // Idle eyes look around: not frozen straight ahead.
        #expect(Set(a.map { ($0.gazeX * 10).rounded() }).count > 3)
    }

    @Test func blinksCloseAndOpenSmoothly() {
        #expect(FacePose.lidCurve(-0.1) == 1)
        #expect(FacePose.lidCurve(0.035) > 0 && FacePose.lidCurve(0.035) < 1)
        #expect(FacePose.lidCurve(0.1) == 0)
        #expect(FacePose.lidCurve(0.18) > 0 && FacePose.lidCurve(0.18) < 1)
        #expect(FacePose.lidCurve(0.3) == 1)
        // Half-shut eyes draw as narrower ellipses, then a line.
        #expect(FaceFrame.eyes(for: .idle, pose: FacePose(lid: 1)) == .open(height: 2.3))
        #expect(FaceFrame.eyes(for: .idle, pose: FacePose(lid: 0.5)) == .open(height: 1.15))
        #expect(FaceFrame.eyes(for: .idle, pose: FacePose(lid: 0.05)) == .closed)
        #expect(FaceFrame.eyes(for: .working, pose: FacePose()) == .open(height: 2.6))
        #expect(FaceFrame.eyes(for: .happy, pose: FacePose(lid: 0)) == .happy)
        #expect(FaceFrame(mood: .sleeping, pose: .rest).bodyOpacity == 0.45)
    }

    @Test func busyMoodsWaveTheirDotsAndLookTheirPart() {
        let think = FacePose.of(.thinking, at: 2, seed: 5)
        #expect(think.gazeY < -1) // up
        let work = (0..<100).map { FacePose.of(.working, at: Double($0) * 0.05, seed: 5) }
        #expect(work.allSatisfy { $0.gazeY > 0.5 }) // down, on the work
        #expect(work.contains { $0.gazeX < -1 } && work.contains { $0.gazeX > 1 }) // reading along
        #expect(FacePose.of(.idle, at: 2).dots == (0, 0, 0))
        #expect(think.dots.0 >= 0.2 && think.dots.0 <= 1)
        #expect(FacePose.of(.sleeping, at: 2).lid == 0)
    }

    @Test func moodChangesBlendOverFourTenthsWithEaseOut() {
        var transition = FaceTransition(target: FaceTarget(mood: .idle, seed: 3), at: 10)
        let from = transition.pose(at: 10)
        transition.change(to: FaceTarget(mood: .thinking, seed: 3), at: 10)
        #expect(abs(transition.pose(at: 10).lean - from.lean) < 1e-9)
        let half = transition.pose(at: 10.2), think = FacePose.of(.thinking, at: 10.2, seed: 3)
        // 1 − (1 − 0.5)² = 0.75 of the way.
        #expect(abs(half.lean - (from.lean + (think.lean - from.lean) * 0.75)) < 1e-9)
        #expect(transition.pose(at: 10.4) == FacePose.of(.thinking, at: 10.4, seed: 3))
        // Looking at something: up to ±3.2.
        #expect(FaceTarget(mood: .idle, look: CGVector(dx: -2, dy: 0.5)).pose(at: 1).gazeX == -3.2)
    }

    @Test(arguments: [FaceMood.idle, .listening, .thinking, .working])
    func aLoopFollowsTheMoodAndRepeatsWithoutASeam(mood: FaceMood) {
        let target = FaceTarget(mood: mood, seed: 7)
        let shape = FaceShape.hexagon
        let body = FaceBody.of(shape)
        let loop = FaceLoop.make(target, shape: shape, pointSize: 40)
        // Every channel stays within its tolerance of the pose itself, a period later too.
        // On the loop's own samples (60 a second), where its keys are exact.
        for into in stride(from: 0.0, to: loop.duration, by: 22.0 / 60) {
            let pose = target.pose(at: into + FaceTarget.period * 3)
            let gaze = body.gaze.clamp(x: pose.gazeX, y: pose.gazeY)
            #expect(abs(loop.value(of: loop.lean, at: into) - pose.lean) < 0.031)
            #expect(abs(loop.value(of: loop.scaleY, at: into) - pose.breath) < 0.0005)
            #expect(abs(loop.value(of: loop.eyesX, at: into) - (body.eyes.x + gaze.x)) < 0.021)
            #expect(abs(loop.value(of: loop.eyesY, at: into) - (body.eyes.y + gaze.y)) < 0.021)
            #expect(abs(loop.value(of: loop.lid, at: into) - pose.lid) < 0.011)
            #expect(abs(loop.value(of: loop.dots[1], at: into) - pose.dots.1) < 0.011)
        }
        // The last key is the first: no jump where it repeats.
        for track in [loop.lean, loop.scaleX, loop.scaleY, loop.eyesX, loop.eyesY, loop.lid] + loop.dots {
            #expect(track.keyTimes.first == 0 && track.keyTimes.last == 1)
            #expect(abs(track.values.first! - track.values.last!) < 1e-9)
            #expect(zip(track.keyTimes, track.keyTimes.dropFirst()).allSatisfy { $0 <= $1 })
        }
        // The motion itself wraps: the end of a period runs into the start of the next.
        let end = target.pose(at: FaceTarget.period - 0.001), next = target.pose(at: FaceTarget.period)
        #expect(abs(end.lean - next.lean) < 0.01 && abs(end.gazeX - next.gazeX) < 0.01 && abs(end.lid - next.lid) < 0.05)
        // Thinned: far fewer keys than the 2,400 samples.
        #expect(loop.lean.values.count < 600 && loop.scaleY.values.count < 600)
    }

    @Test func aLoopsEyesShutAndLoseTheirCatchlightAsThePainterDraws() {
        let loop = FaceLoop.make(FaceTarget(mood: .idle, seed: 2), shape: .circle, pointSize: 40)
        // Discrete tracks: one more key time than values, for Core Animation.
        #expect(loop.open.keyTimes.count == loop.open.values.count + 1)
        #expect(loop.catchlight.keyTimes.count == loop.catchlight.values.count + 1)
        // Idle blinks about every 4.4 s, so a 40 s loop shuts its eyes several times.
        #expect(loop.open.values.filter { $0 == 0 }.count >= 5)
        for sample in 0..<2300 {
            // Halfway to the next sample: the step the sample began.
            let lid = FacePose.of(.idle, at: Double(sample) / 60, seed: 2).lid
            let shown = loop.value(of: loop.open, at: (Double(sample) + 0.5) / 60)
            if 2.3 * lid < 0.3 { #expect(shown == 0) }
            if 2.3 * lid > 0.4 { #expect(shown == 1) }
        }
        // Small faces draw no catchlight at all.
        let small = FaceLoop.make(FaceTarget(mood: .idle, seed: 2), shape: .circle, pointSize: 22)
        #expect(small.catchlight.values == [0])
        // Reduce Motion: no sway or glance, the blinks stay.
        let still = FaceLoop.make(FaceTarget(mood: .idle, seed: 2), shape: .circle, pointSize: 40, stilled: true)
        #expect(still.lean.constant == 0 && still.eyesX.constant == FaceBody.of(.circle).eyes.x)
        #expect(still.open.values.contains(0))
    }

    @Test func increaseContrastOutlinesPaleBodies() {
        let darkWindow = FaceColor(hex: 0x1C1C1E)
        #expect(FaceColor.hue(60).contrast(with: .white) < 3 && FaceColor.hue(240).contrast(with: darkWindow) < 3)
        #expect(FacePainter.contrastOutline(for: .hue(30), on: .white, separator: .gray) != nil) // orange is 2.3:1 too
        #expect(FacePainter.contrastOutline(for: .hue(240), on: .white, separator: .gray) == nil)
    }
}
