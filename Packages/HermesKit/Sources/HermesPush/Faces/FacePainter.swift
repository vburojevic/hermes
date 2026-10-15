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

    /// The eyes a mood shows with this pose: happy and sleeping draw their strokes; a blink
    /// closes the others; busy and listening eyes are 2.6 tall.
    public static func eyes(for mood: FaceMood, pose: FacePose) -> FaceEyes {
        switch mood {
        case .happy: return .happy
        case .sleeping: return .sleeping
        default: break
        }
        if pose.blink { return .closed }
        return .open(height: mood.isBusy || mood == .listening ? 2.6 : 2.3)
    }

    public init(mood: FaceMood, pose: FacePose) {
        self.init(pose: pose, eyes: Self.eyes(for: mood, pose: pose))
        if mood == .sleeping { bodyOpacity = 0.45 }
    }
}

/// Draws a Bot's face in Hermes's 40 × 44 box (`docs/bot-faces.md` §1): a flat body, two eyes with
/// a catchlight, and three dots in the body colour. No gradient, gloss, glow or shadow.
public enum FacePainter {
    /// Eye centres in the face box.
    public static let eyeX: [Double] = [15.4, 24.6]
    public static func eyeY(_ shape: FaceShape) -> Double { shape == .cloud ? 22 : 17.2 }

    /// The height a face of `width` points takes (the dots sit under the body).
    public static func height(forWidth width: CGFloat) -> CGFloat { width * 1.1 }

    /// The body outline for `shape` at this pose, in face units.
    public static func body(_ shape: FaceShape, pose: FacePose, pointSize: CGFloat, morph: (from: FaceShape, progress: Double)? = nil) -> Path {
        if let morph, morph.progress < 1, morph.from != shape {
            let count = 120
            let a = FaceGeometry.resample(FaceGeometry.ring(morph.from, steps: 160), count: count)
            let b = FaceGeometry.resample(FaceGeometry.ring(shape, steps: 160), count: count)
            let p = max(0, min(1, morph.progress))
            let points = zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * p, y: $0.y + ($1.y - $0.y) * p) }
            return polygon(points.map { FaceGeometry.project($0, turn: pose.turn, tilt: pose.tilt, roll: pose.roll) })
        }
        // Hermes paints the cloud as its fixed path; it isn't sampled or turned.
        if shape == .cloud { return Path(FaceGeometry.cloudPath()) }
        let steps = pointSize >= 60 ? 120 : FaceGeometry.hermesSteps
        return polygon(FaceGeometry.ring(shape, steps: steps).map {
            FaceGeometry.project($0, turn: pose.turn, tilt: pose.tilt, roll: pose.roll)
        })
    }

    static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// Draws `look` filling `size` (width = the face's point size, height = width × 1.1).
    public static func draw(_ look: FaceLook, frame: FaceFrame, in context: inout GraphicsContext, size: CGSize) {
        let pointSize = size.width
        let scale = pointSize / 40
        context.scaleBy(x: scale, y: scale)
        // Hop up, squash about the bottom of the body, and tilt about (50%, 70%) like Hermes.
        if frame.hop != 0 { context.translateBy(x: 0, y: -frame.hop) }
        if frame.squash != CGSize(width: 1, height: 1) {
            context.translateBy(x: 20, y: 37)
            context.scaleBy(x: frame.squash.width, y: frame.squash.height)
            context.translateBy(x: -20, y: -37)
        }
        if frame.pose.tilt != 0 {
            context.translateBy(x: 20, y: 30.8)
            context.rotate(by: .degrees(frame.pose.tilt))
            context.translateBy(x: -20, y: -30.8)
        }

        let bodyColor = Color(look.color)
        let body = Self.body(look.shape, pose: frame.pose, pointSize: pointSize, morph: frame.morph)
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
        let y = eyeY(look.shape) + frame.pose.gazeY
        let xs = eyeX.map { $0 + frame.pose.gazeX }
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round)
        switch frame.eyes {
        case .open(let height):
            let sparkle = Color(look.color.catchlight)
            for x in xs {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.2, y: y - height, width: 4.4, height: height * 2)), with: .color(eye))
                // Catchlights only where they read.
                if pointSize >= 24 {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.6 - 0.65, y: y - 0.7 - 0.65, width: 1.3, height: 1.3)), with: .color(sparkle))
                }
            }
        case .closed:
            var path = Path()
            for x in xs {
                path.move(to: CGPoint(x: x - 2.6, y: y))
                path.addLine(to: CGPoint(x: x + 2.6, y: y))
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
            var pose = FacePose.of(mood, at: time)
            pose.blink = false
            var frame = FaceFrame(mood: mood, pose: pose)
            frame.outline = outline
            FacePainter.draw(look, frame: frame, in: &context, size: canvasSize)
        }
        .frame(width: size, height: FacePainter.height(forWidth: size))
        .accessibilityHidden(true)
    }
}
