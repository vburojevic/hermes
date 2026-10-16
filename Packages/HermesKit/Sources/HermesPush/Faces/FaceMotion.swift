import CoreGraphics
import Foundation

/// What a face is doing (`docs/bot-faces.md` §3). Hermes has idle, think and work; the app adds
/// listening, happy and sleeping.
public enum FaceMood: String, Sendable, Codable, CaseIterable {
    case idle
    /// Eyes wider, on the composer, while the person types or talks.
    case listening
    /// Hermes "think": looks up, sways, dots wave.
    case thinking
    /// Hermes "work": eyes down on the work, reading along, dots wave a little faster.
    case working
    /// ^ ^ for a moment: a reply landed, or it was tapped.
    case happy
    /// Offline or reclaimed: eyes closed, half strength, breathing slowly.
    case sleeping

    /// The working moods' eyes are 2.6 tall instead of 2.3, and their dots wave.
    public var isBusy: Bool { self == .thinking || self == .working }
}

/// How the eyes are drawn this frame.
public enum FaceEyes: Sendable, Equatable {
    /// Open ellipses (rx 2.2 × `height`) with a catchlight.
    case open(height: Double)
    /// A 2-wide stroke across each eye.
    case closed
    /// ^ ^
    case happy
    /// ‿ ‿
    case sleeping
}

/// One frame of a face. The body only ever moves as a whole (it leans, breathes, hops), so its
/// outline keeps its shape; the life is in the eyes.
public struct FacePose: Sendable, Equatable {
    /// Degrees the face leans, rigidly, about the bottom of the body.
    public var lean: Double
    /// The body's height against rest (1): a little taller on the in-breath.
    public var breath: Double
    /// Where the eyes look, in face units from their rest. The painter keeps them on the body.
    public var gazeX: Double
    public var gazeY: Double
    /// How open the eyelids are, 0 (shut) to 1.
    public var lid: Double
    /// The three dots' opacities.
    public var dots: (Double, Double, Double)

    public init(lean: Double = 0, breath: Double = 1, gazeX: Double = 0, gazeY: Double = 0, lid: Double = 1, dots: (Double, Double, Double) = (0, 0, 0)) {
        self.lean = lean
        self.breath = breath
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.lid = lid
        self.dots = dots
    }

    public static let rest = FacePose()

    public static func == (a: FacePose, b: FacePose) -> Bool {
        a.lean == b.lean && a.breath == b.breath && a.gazeX == b.gazeX && a.gazeY == b.gazeY && a.lid == b.lid && a.dots == b.dots
    }

    /// The pose of `mood` at `t` seconds on the shared clock. `seed` (from the Bot's name) gives
    /// each face its own timing, so a grid of Bots never sways or blinks in step.
    public static func of(_ mood: FaceMood, at t: Double, seed: UInt32 = 0) -> FacePose {
        let rate = 0.9 + 0.2 * FaceNoise.unit(seed, 0, salt: 1)
        let time = t * rate + FaceNoise.unit(seed, 0, salt: 2) * 97
        var pose = FacePose(dots: mood.isBusy ? wave(t, frequency: mood == .working ? 2.6 : 2.2) : (0, 0, 0))
        switch mood {
        case .idle, .happy:
            pose.lean = 1.4 * sin(2 * .pi * time / 6.3) + 0.5 * sin(2 * .pi * time / 2.9)
            pose.breath = 1 + 0.016 * sin(2 * .pi * time / 3.6)
            (pose.gazeX, pose.gazeY) = glance(time, seed: seed, every: 2.6, settle: 0.12) { k in
                // Mostly straight ahead; now and then a look around.
                FaceNoise.unit(seed, k, salt: 3) < 0.4 ? (0, 0)
                    : ((FaceNoise.unit(seed, k, salt: 4) - 0.5) * 4.6, (FaceNoise.unit(seed, k, salt: 5) - 0.5) * 2.4)
            }
            if mood == .happy {
                pose.gazeX *= 0.3
                pose.gazeY = -0.4
            } else {
                pose.lid = blink(time, seed: seed, every: 4.4)
            }
        case .listening:
            // Attentive: leaning in a touch, eyes on the composer, the odd small glance.
            pose.lean = -1.6 + 0.6 * sin(2 * .pi * time / 4.7)
            pose.breath = 1 + 0.012 * sin(2 * .pi * time / 3.2)
            (pose.gazeX, pose.gazeY) = glance(time, seed: seed, every: 1.9, settle: 0.1) { k in
                (0.8 + (FaceNoise.unit(seed, k, salt: 6) - 0.5) * 1.2, 1.4 + (FaceNoise.unit(seed, k, salt: 7) - 0.5) * 0.6)
            }
            pose.lid = blink(time, seed: seed, every: 5.2)
        case .thinking:
            // Eyes up, drifting from one side to the other; a slow sway.
            pose.lean = 3.2 * sin(2 * .pi * time / 4.1)
            pose.breath = 1 + 0.014 * sin(2 * .pi * time / 3.0)
            (pose.gazeX, pose.gazeY) = glance(time, seed: seed, every: 1.7, settle: 0.38) { k in
                let side: Double = FaceNoise.unit(seed, k, salt: 8) < 0.5 ? -1 : 1
                return (side * (1.2 + FaceNoise.unit(seed, k, salt: 9) * 1.4), -1.6 - FaceNoise.unit(seed, k, salt: 10) * 0.8)
            }
            pose.lid = blink(time, seed: seed, every: 3.4)
        case .working:
            // Eyes down on the work, reading along a line and back.
            pose.lean = 1.1 * sin(2 * .pi * time / 1.8)
            pose.breath = 1 + 0.012 * sin(2 * .pi * time / 2.4)
            let line = 1.25
            let along = (time / line).truncatingRemainder(dividingBy: 1)
            let row = Int((time / line).rounded(.down))
            let sweep = along < 0.82 ? along / 0.82 : 1 - FaceNoise.easeOut((along - 0.82) / 0.18)
            pose.gazeX = -1.9 + 3.8 * sweep
            pose.gazeY = 1.1 + (FaceNoise.unit(seed, row, salt: 11) - 0.5) * 0.5
            pose.lid = blink(time, seed: seed, every: 3.1)
        case .sleeping:
            pose.breath = 1 + 0.024 * sin(2 * .pi * time / 4.8)
            pose.gazeY = 0.6
            pose.lid = 0
        }
        return pose
    }

    /// 0.2 + 0.8·max(0, sin(f·t − 0.7k)) for dot k.
    static func wave(_ t: Double, frequency: Double) -> (Double, Double, Double) {
        (0.2 + 0.8 * max(0, sin(t * frequency)),
         0.2 + 0.8 * max(0, sin(t * frequency - 0.7)),
         0.2 + 0.8 * max(0, sin(t * frequency - 1.4)))
    }

    /// Eyes that hop between targets: one target per `every` seconds, switched at an uneven moment
    /// of each stretch (so glances don't keep time), moving there in `settle` seconds.
    static func glance(_ time: Double, seed: UInt32, every: Double, settle: Double, target: (Int) -> (Double, Double)) -> (Double, Double) {
        let index = Int((time / every).rounded(.down))
        let into = time - Double(index) * every
        let at = every * (0.15 + 0.6 * FaceNoise.unit(seed, index, salt: 12))
        let previous = target(index - 1), next = target(index)
        guard into >= at else { return previous }
        let p = FaceNoise.easeOut(min(1, (into - at) / settle))
        return (previous.0 + (next.0 - previous.0) * p, previous.1 + (next.1 - previous.1) * p)
    }

    /// The eyelids, 1 open to 0 shut: about one blink per `every` seconds at an uneven moment, now
    /// and then a double one. Shuts in 70 ms, opens in 120 ms.
    static func blink(_ time: Double, seed: UInt32, every: Double) -> Double {
        let index = Int((time / every).rounded(.down))
        let into = time - Double(index) * every
        let at = every * (0.2 + 0.6 * FaceNoise.unit(seed, index, salt: 13))
        var lid = lidCurve(into - at)
        if FaceNoise.unit(seed, index, salt: 14) < 0.18 { lid = min(lid, lidCurve(into - at - 0.26)) }
        return lid
    }

    /// The eyelids `since` seconds into a blink: 1, shut in 70 ms, open again by 240 ms.
    public static func lidCurve(_ since: Double) -> Double {
        switch since {
        case ..<0: 1
        case ..<0.07: 1 - FaceNoise.easeIn(since / 0.07)
        case ..<0.12: 0
        case ..<0.24: FaceNoise.easeOut((since - 0.12) / 0.12)
        default: 1
        }
    }

    /// Reduce Motion: no sway, breath or glances; the blink and the dots stay.
    public var stilled: FacePose {
        FacePose(lid: lid, dots: dots)
    }

    /// `self` moved toward `other` by `amount`.
    public func blended(toward other: FacePose, by amount: Double) -> FacePose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return FacePose(
            lean: mix(lean, other.lean), breath: mix(breath, other.breath),
            gazeX: mix(gazeX, other.gazeX), gazeY: mix(gazeY, other.gazeY), lid: mix(lid, other.lid),
            dots: (mix(dots.0, other.dots.0), mix(dots.1, other.dots.1), mix(dots.2, other.dots.2))
        )
    }
}

/// Deterministic noise for faces: the same Bot moves the same way on every device and redraw.
public enum FaceNoise {
    /// 0…1 from a seed, an index and a salt (splitmix64).
    public static func unit(_ seed: UInt32, _ index: Int, salt: UInt64) -> Double {
        var z = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(bitPattern: Int64(index)) &* 0xBF58_476D_1CE4_E5B9 &+ salt &* 0x94D0_49BB_1331_11EB
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    static func easeOut(_ p: Double) -> Double { 1 - pow(1 - max(0, min(1, p)), 3) }
    static func easeIn(_ p: Double) -> Double { pow(max(0, min(1, p)), 2) }
}

/// What a face is aiming for: a mood, maybe something to look at, and its own timing.
public struct FaceTarget: Sendable, Equatable {
    public var mood: FaceMood
    /// A direction to look in (each axis −1…1), or nil for the mood's own gaze.
    public var look: CGVector?
    public var seed: UInt32

    public init(mood: FaceMood, look: CGVector? = nil, seed: UInt32 = 0) {
        self.mood = mood
        self.look = look
        self.seed = seed
    }

    /// Looking at something moves the eyes up to 3.2 units (kept on the body when drawn).
    public static let maxGaze = 3.2

    public func pose(at t: Double) -> FacePose {
        var pose = FacePose.of(mood, at: t, seed: seed)
        if let look, mood != .sleeping {
            pose.gazeX = max(-1, min(1, look.dx)) * Self.maxGaze
            pose.gazeY = max(-1, min(1, look.dy)) * Self.maxGaze
        }
        return pose
    }
}

/// Moving from one target to the next: blending from the pose on screen over 0.4 s with ease-out
/// (1 − (1 − p)²), so a mood change never jumps.
public struct FaceTransition: Sendable, Equatable {
    public private(set) var target: FaceTarget
    public private(set) var from: FacePose
    public private(set) var since: Double

    public static let duration = 0.4

    /// Already settled at `target`.
    public init(target: FaceTarget, at t: Double = -.infinity) {
        self.target = target
        from = target.pose(at: t.isFinite ? t : 0)
        since = t.isFinite ? t - Self.duration : -.infinity
    }

    public func pose(at t: Double) -> FacePose {
        let goal = target.pose(at: t)
        let progress = since.isFinite ? max(0, min(1, (t - since) / Self.duration)) : 1
        guard progress < 1 else { return goal }
        let eased = 1 - (1 - progress) * (1 - progress)
        return from.blended(toward: goal, by: eased)
    }

    /// Starts blending toward `new` from wherever the face is at `t`.
    public mutating func change(to new: FaceTarget, at t: Double) {
        guard new != target else { return }
        from = pose(at: t)
        target = new
        since = t
    }
}
