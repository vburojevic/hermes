import SwiftUI

/// Everything about one frame beyond the pose: the eyes, and the app's squash, hop and fades.
public struct FaceFrame: Sendable {
    public var pose: FacePose
    public var eyes: FaceEyes
    /// The whole face scaled about the bottom of the body (boop, voice level).
    public var squash = CGSize(width: 1, height: 1)
    /// Face units up (the happy hop).
    public var hop: Double = 0
    /// Sleeping faces are at 45%.
    public var bodyOpacity: Double = 1
    /// Increase Contrast: a 1 pt outline when the body is too close to the background.
    public var outline: Color?
    /// Morphing from another shape: that shape and how far along (0…1).
    public var morph: (from: FaceShape, progress: Double)?

    public init(pose: FacePose, eyes: FaceEyes) {
        self.pose = pose
        self.eyes = eyes
    }

    /// The eyes a mood shows with this pose: happy and sleeping draw their strokes; the eyelids
    /// close the others smoothly; busy and listening eyes are 2.6 tall.
    public static func eyes(for mood: FaceMood, pose: FacePose) -> FaceEyes {
        switch mood {
        case .happy: return .happy
        case .sleeping: return .sleeping
        default: break
        }
        let height = (mood.isBusy || mood == .listening ? 2.6 : 2.3) * max(0, min(1, pose.lid))
        return height < 0.35 ? .closed : .open(height: height)
    }

    public init(mood: FaceMood, pose: FacePose) {
        self.init(pose: pose, eyes: Self.eyes(for: mood, pose: pose))
        if mood == .sleeping { bodyOpacity = 0.45 }
    }
}

/// Draws a Bot's face in the 40 × 44 face box (`docs/bot-faces.md` §1): a flat body fitted into the
/// box (`FaceBody`), two eyes with a catchlight, and three dots in the body colour. No gradient,
/// gloss, glow or shadow. The body only moves as a whole, so its outline keeps its shape.
public enum FacePainter {
    /// The height a face of `width` points takes (the dots sit under the body).
    public static func height(forWidth width: CGFloat) -> CGFloat { width * 1.1 }

    /// The body outline, in face units: the fitted shape, or a blend while it morphs.
    public static func body(_ shape: FaceShape, morph: (from: FaceShape, progress: Double)? = nil) -> Path {
        if let morph, morph.progress < 1, morph.from != shape {
            let a = FaceBody.of(morph.from).points, b = FaceBody.of(shape).points
            let p = max(0, min(1, morph.progress))
            var path = Path()
            path.addLines(zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * p, y: $0.y + ($1.y - $0.y) * p) })
            path.closeSubpath()
            return path
        }
        return Path(FaceBody.of(shape).path)
    }

    /// Where the eyes sit (their midpoint) and how far they may look: blended while morphing.
    static func eyeAnchor(_ shape: FaceShape, morph: (from: FaceShape, progress: Double)?) -> (CGPoint, FaceBody.GazeRange) {
        let body = FaceBody.of(shape)
        guard let morph, morph.progress < 1, morph.from != shape else { return (body.eyes, body.gaze) }
        let from = FaceBody.of(morph.from)
        let p = max(0, min(1, morph.progress))
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        return (
            CGPoint(x: mix(from.eyes.x, body.eyes.x), y: mix(from.eyes.y, body.eyes.y)),
            FaceBody.GazeRange(left: min(from.gaze.left, body.gaze.left), right: min(from.gaze.right, body.gaze.right),
                               up: min(from.gaze.up, body.gaze.up), down: min(from.gaze.down, body.gaze.down))
        )
    }

    /// Draws `look` filling `size` (width = the face's point size, height = width × 1.1).
    public static func draw(_ look: FaceLook, frame: FaceFrame, in context: inout GraphicsContext, size: CGSize) {
        let pointSize = size.width
        let scale = pointSize / 40
        context.scaleBy(x: scale, y: scale)
        let base = FaceBody.of(look.shape).bounds.maxY
        // Hop up; squash and breathe about the bottom of the body; lean about it too.
        if frame.hop != 0 { context.translateBy(x: 0, y: -frame.hop) }
        let breath = frame.pose.breath
        let sx = frame.squash.width * (1 - (breath - 1) * 0.5), sy = frame.squash.height * breath
        if sx != 1 || sy != 1 {
            context.translateBy(x: 20, y: base)
            context.scaleBy(x: sx, y: sy)
            context.translateBy(x: -20, y: -base)
        }
        if frame.pose.lean != 0 {
            context.translateBy(x: 20, y: base)
            context.rotate(by: .degrees(frame.pose.lean))
            context.translateBy(x: -20, y: -base)
        }

        let bodyColor = Color(look.color)
        let body = Self.body(look.shape, morph: frame.morph)
        context.fill(body, with: .color(bodyColor.opacity(frame.bodyOpacity)))
        if let outline = frame.outline {
            context.stroke(body, with: .color(outline), lineWidth: 1 / scale)
        }

        drawEyes(look, frame: frame, in: &context, pointSize: pointSize)

        // Dots: r 1.15 in the body colour; bigger below 24 pt so they still read.
        let (d0, d1, d2) = frame.pose.dots
        let radius = 1.15 * (pointSize < 24 ? 1.4 : 1)
        for (x, opacity) in zip([16.4, 20, 23.6], [d0, d1, d2]) where opacity > 0.001 {
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: 41.2 - radius, width: radius * 2, height: radius * 2)),
                with: .color(bodyColor.opacity(opacity * frame.bodyOpacity))
            )
        }
    }

    static func drawEyes(_ look: FaceLook, frame: FaceFrame, in context: inout GraphicsContext, pointSize: CGFloat) {
        let eye = Color(look.color.eye)
        let (anchor, range) = eyeAnchor(look.shape, morph: frame.morph)
        let gaze = range.clamp(x: frame.pose.gazeX, y: frame.pose.gazeY)
        let y = anchor.y + gaze.y
        let xs = [anchor.x - FaceBody.eyeSpread + gaze.x, anchor.x + FaceBody.eyeSpread + gaze.x]
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round)
        switch frame.eyes {
        case .open(let height):
            let sparkle = Color(look.color.catchlight)
            let rx = FaceBody.eyeRadius
            for x in xs {
                context.fill(Path(ellipseIn: CGRect(x: x - rx, y: y - height, width: rx * 2, height: height * 2)), with: .color(eye))
                // Catchlights only where they read, and only while the eye is open enough to hold one.
                if pointSize >= 24, height > 1.4 {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.6 - 0.65, y: y - 0.7 - 0.65, width: 1.3, height: 1.3)), with: .color(sparkle))
                }
            }
        case .closed:
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x - 2.4, y: y))
                path.addLine(to: CGPoint(x: x + 2.4, y: y))
            }
            context.stroke(path, with: .color(eye), style: stroke)
        case .happy:
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x - 2.6, y: y + 1))
                path.addQuadCurve(to: CGPoint(x: x + 2.6, y: y + 1), control: CGPoint(x: x, y: y - 3.4))
            }
            context.stroke(path, with: .color(eye), style: stroke)
        case .sleeping:
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x - 2.4, y: y + 0.6))
                path.addQuadCurve(to: CGPoint(x: x + 2.4, y: y + 0.6), control: CGPoint(x: x, y: y + 2.6))
            }
            context.stroke(path, with: .color(eye.opacity(frame.bodyOpacity < 1 ? 0.9 : 1)), style: stroke)
        }
    }

    /// Increase Contrast: the outline a body needs on this background (contrast under 3:1).
    public static func contrastOutline(for color: FaceColor, on background: FaceColor, separator: Color) -> Color? {
        color.contrast(with: background) < 3 ? separator : nil
    }

    /// The surface faces mostly sit on: the window in light mode, a raised card in dark mode.
    public static func background(dark: Bool) -> FaceColor {
        dark ? FaceColor(hex: 0x1C1C1E) : .white
    }

    /// The system separator, for the Increase Contrast outline.
    public static var separator: Color {
        #if os(iOS)
        Color(uiColor: .separator)
        #elseif os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color.gray.opacity(0.5)
        #endif
    }
}

extension Color {
    /// A face colour, in sRGB.
    public init(_ face: FaceColor) {
        self.init(.sRGB, red: face.red, green: face.green, blue: face.blue)
    }

    public init(_ ink: FaceInk) {
        self.init(.sRGB, red: ink.red, green: ink.green, blue: ink.blue, opacity: ink.alpha)
    }
}

/// A still face (widgets, the Live Activity, notification avatars): one pose, no clock.
public struct StillFace: View {
    public let look: FaceLook
    public let mood: FaceMood
    public var size: CGFloat
    /// Seconds on the face clock: which moment of the mood's motion to show.
    public var time: Double

    public init(look: FaceLook, mood: FaceMood = .idle, size: CGFloat, time: Double = 0) {
        self.look = look
        self.mood = mood
        self.size = size
        self.time = time
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public var body: some View {
        let outline = contrast == .increased
            ? FacePainter.contrastOutline(for: look.color, on: FacePainter.background(dark: colorScheme == .dark), separator: FacePainter.separator)
            : nil
        Canvas { context, canvasSize in
            // A still frame: eyes open, looking ahead, body at rest.
            var pose = FacePose.of(mood, at: time).stilled
            pose.lid = 1
            var frame = FaceFrame(mood: mood, pose: pose)
            frame.outline = outline
            FacePainter.draw(look, frame: frame, in: &context, size: canvasSize)
        }
        .frame(width: size, height: FacePainter.height(forWidth: size))
        .accessibilityHidden(true)
    }
}
