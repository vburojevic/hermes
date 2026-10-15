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
    /// Hermes "work": glances at the work, dots wave a little faster.
    case working
    /// ^ ^ for a moment: a reply landed, or it was tapped.
    case happy
    /// Offline or reclaimed: eyes closed, half strength, still.
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

/// One frame of a face: Hermes's `FacePose`.
public struct FacePose: Sendable, Equatable {
    /// Degrees. turn and tilt squash the outline; tilt also rotates the face.
    public var turn: Double
    public var tilt: Double
    public var roll: Double
    /// Eye offset in face units (±3.6 at most in Hermes's moods; ±3.2 when looking at something).
    public var gazeX: Double
    public var gazeY: Double
    public var blink: Bool
    /// The three dots' opacities.
    public var dots: (Double, Double, Double)

    public init(turn: Double = 0, tilt: Double = 0, roll: Double = 0, gazeX: Double = 0, gazeY: Double = 0, blink: Bool = false, dots: (Double, Double, Double) = (0, 0, 0)) {
        self.turn = turn
        self.tilt = tilt
        self.roll = roll
        self.gazeX = gazeX
        self.gazeY = gazeY
        self.blink = blink
        self.dots = dots
    }

    public static let rest = FacePose()

    public static func == (a: FacePose, b: FacePose) -> Bool {
        a.turn == b.turn && a.tilt == b.tilt && a.roll == b.roll && a.gazeX == b.gazeX && a.gazeY == b.gazeY
            && a.blink == b.blink && a.dots == b.dots
    }

    /// Hermes's `facePose` (t in seconds on the shared clock), plus the app's moods.
    public static func of(_ mood: FaceMood, at t: Double) -> FacePose {
        switch mood {
        case .thinking:
            return FacePose(
                turn: -18 + sin(t * 0.55) * 14,
                tilt: sin(t * 0.48) * 12 + sin(t * 1.35) * 3,
                roll: sin(t * 0.95) * 10,
                gazeX: sin(t * 0.7) * 3.6,
                gazeY: -2.2 + sin(t * 0.4) * 2.2,
                blink: t.truncatingRemainder(dividingBy: 1.45) > 1.26,
                dots: wave(t, frequency: 2.4)
            )
        case .working:
            return FacePose(
                turn: -11 + sin(t * 0.48) * 8,
                tilt: sin(t * 0.42) * 8 + sin(t * 1.1) * 1.6,
                roll: sin(t * 0.75) * 4.2,
                gazeX: sin(t * 0.55) * 3.6,
                gazeY: -1.6 + sin(t * 0.38) * 2,
                blink: t.truncatingRemainder(dividingBy: 1.45) > 1.26,
                dots: wave(t, frequency: 2.6)
            )
        case .sleeping:
            return .rest
        case .idle, .listening, .happy:
            var pose = FacePose(
                turn: sin(t * 0.5) * 1.5,
                tilt: sin(t * 0.27),
                roll: sin(t * 0.85) * 1.2,
                blink: t.truncatingRemainder(dividingBy: 3.2) > 3.02
            )
            if mood == .listening {
                pose.gazeX = 1.4
                pose.gazeY = 1.0
            }
            if mood == .happy { pose.blink = false }
            return pose
        }
    }

    /// 0.2 + 0.8·max(0, sin(f·t − 0.7k)) for dot k.
    static func wave(_ t: Double, frequency: Double) -> (Double, Double, Double) {
        (0.2 + 0.8 * max(0, sin(t * frequency)),
         0.2 + 0.8 * max(0, sin(t * frequency - 0.7)),
         0.2 + 0.8 * max(0, sin(t * frequency - 1.4)))
    }

    /// Reduce Motion: no sway or gaze; the blink and the dots stay.
    public var stilled: FacePose {
        FacePose(blink: blink, dots: dots)
    }

    /// `self` moved toward `other` by `amount` (blink comes from `other`).
    public func blended(toward other: FacePose, by amount: Double) -> FacePose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        return FacePose(
            turn: mix(turn, other.turn), tilt: mix(tilt, other.tilt), roll: mix(roll, other.roll),
            gazeX: mix(gazeX, other.gazeX), gazeY: mix(gazeY, other.gazeY), blink: other.blink,
            dots: (mix(dots.0, other.dots.0), mix(dots.1, other.dots.1), mix(dots.2, other.dots.2))
        )
    }
}

/// What a face is aiming for: a mood, and maybe something to look at.
public struct FaceTarget: Sendable, Equatable {
    public var mood: FaceMood
    /// A direction to look in (each axis −1…1), or nil for the mood's own gaze.
    public var look: CGVector?

    public init(mood: FaceMood, look: CGVector? = nil) {
        self.mood = mood
        self.look = look
    }

    /// Looking at something moves the eyes up to ±3.2.
    public static let maxGaze = 3.2

    public func pose(at t: Double) -> FacePose {
        var pose = FacePose.of(mood, at: t)
        if let look, mood != .sleeping {
            pose.gazeX = max(-1, min(1, look.dx)) * Self.maxGaze
            pose.gazeY = max(-1, min(1, look.dy)) * Self.maxGaze
        }
        return pose
    }
}

/// Moving from one target to the next: Hermes's `settlePose`, blending from the pose on screen
/// over 0.4 s with ease-out (1 − (1 − p)²).
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
