import ImageIO
import SwiftUI

/// How a Bot looks: Hermes Desktop's avatar model (`ui_meta['hermes-bots']`
/// shape + colour + image), drawn natively so a Bot looks the same everywhere.
struct BotAppearance: Hashable, Sendable {
    enum Shape: String, CaseIterable, Sendable {
        case circle, squircle, pill, triangle, hexagon, cloud, drop

        var label: String {
            switch self {
            case .circle: String(localized: "Circle")
            case .squircle: String(localized: "Rounded square")
            case .pill: String(localized: "Pill")
            case .triangle: String(localized: "Triangle")
            case .hexagon: String(localized: "Hexagon")
            case .cloud: String(localized: "Cloud")
            case .drop: String(localized: "Drop")
            }
        }
    }

    var shape: Shape
    var color: Color
    var isDark: Bool
    /// `data:` or `http(s):` image that replaces the drawn face.
    var imageURL: String?
    /// Staggers blinks so a roster of faces doesn't blink in unison.
    var blinkOffset: Double

    /// Desktop's rules (`botAppearance`): a stored pick wins; otherwise shape and hue
    /// come from the profile name. The primary profile wears a fixed violet squircle.
    init(profile: String, shape storedShape: String? = nil, color storedColor: String? = nil, image: String? = nil, customized: Bool = false) {
        let name = profile.trimmingCharacters(in: .whitespaces)
        let hash = Self.stringHash(name)
        imageURL = (image?.isEmpty ?? true) ? nil : image
        blinkOffset = Double(hash % 97) / 97 * Self.blinkPeriod
        if name.lowercased() == "default" && !customized {
            shape = .squircle
            (color, isDark) = Self.parseColor("#8b5cf6") ?? (.purple, false)
            return
        }
        shape = storedShape.flatMap { Shape(rawValue: $0) } ?? Shape.allCases[Int(hash % UInt32(Shape.allCases.count))]
        if let parsed = storedColor.flatMap(Self.parseColor) {
            (color, isDark) = parsed
        } else {
            let hue = Double(hash % 360) / 360
            (color, isDark) = (Color(hue: hue, saturation: 0.68, lightness: 0.58), false)
        }
    }

    static let blinkPeriod: TimeInterval = 4.2
    static let blinkLength: TimeInterval = 0.14

    /// Java-style `hash * 31 + code unit`, wrapping at 32 bits — Desktop's `hashString`.
    static func stringHash(_ text: String) -> UInt32 {
        text.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
    }

    /// Accepts `#rrggbb` and `hsl(h s% l%)`, the two forms Desktop stores.
    static func parseColor(_ text: String) -> (Color, Bool)? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) {
            let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
            let dark = 0.2126 * r + 0.7152 * g + 0.0722 * b < 110
            return (Color(red: r / 255, green: g / 255, blue: b / 255), dark)
        }
        if value.hasPrefix("hsl(") {
            let numbers = value.dropFirst(4).split(whereSeparator: { " ,%)".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 3 else { return nil }
            return (Color(hue: numbers[0] / 360, saturation: numbers[1] / 100, lightness: numbers[2] / 100), numbers[2] < 35)
        }
        return nil
    }
}

extension Color {
    /// HSL, as CSS writes it.
    init(hue: Double, saturation: Double, lightness: Double) {
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        self.init(hue: hue, saturation: hsbSaturation, brightness: brightness)
    }
}

/// What a Bot's face is doing.
enum BotMood: Equatable {
    case idle
    /// Eyes on the composer while the person types.
    case listening
    /// Eyes up and three pulsing dots while a turn runs.
    case thinking
    /// A happy squint: a reply landed, or it was poked.
    case happy
}

/// A Bot's face: a coloured body with depth (a soft top light, a bottom shade and a gloss
/// spot), two eyes that blink, glance and squint, and three dots that pulse while it works.
/// The native twin of Hermes Desktop's `BotFace`, drawn to the Elyx spec (docs/bot-faces.md).
struct BotFace: View {
    let appearance: BotAppearance
    var size: CGFloat = 36
    var mood: BotMood = .idle
    /// An approval or question waits on the person: a short wiggle every few seconds.
    var needsYou = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var openness: CGFloat = 1
    @State private var pointer: CGPoint = .zero
    @State private var bounces = 0
    @State private var wiggles = 0

    init(appearance: BotAppearance, size: CGFloat = 36, isWorking: Bool = false, mood: BotMood? = nil, needsYou: Bool = false) {
        self.appearance = appearance
        self.size = size
        self.mood = mood ?? (isWorking ? .thinking : .idle)
        self.needsYou = needsYou
    }

    /// Tiles, headers and the hello screen move; small list faces stay still apart from the blink.
    private var isLarge: Bool { size >= 40 }
    /// Only the hello screen's face breathes: a never-ending animation on every tile kept the
    /// main thread redrawing a screen of faces, shadows and the text around them all day.
    private var breathes: Bool { size >= 72 }
    private var moves: Bool { !reduceMotion && !motionPaused }
    private var increasedContrast: Bool { contrast == .increased }

    private var gaze: CGPoint {
        guard !reduceMotion else { return .zero }
        return switch mood {
        case .idle: pointer
        case .happy: .zero
        case .listening: CGPoint(x: 0.6, y: 1.3)
        case .thinking: CGPoint(x: -0.3, y: -1.4)
        }
    }

    var body: some View {
        face
            .modifier(Breathing(active: breathes && moves && mood == .idle))
            .rotationEffect(.degrees(mood == .listening && moves ? 2 : 0), anchor: .bottom)
            .keyframeAnimator(initialValue: Squash(), trigger: bounces) { content, value in
                content.scaleEffect(x: value.x, y: value.y, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    SpringKeyframe(0.94, duration: 0.12)
                    SpringKeyframe(1.08, duration: 0.15)
                    SpringKeyframe(1, duration: 0.18)
                }
                KeyframeTrack(\.x) {
                    SpringKeyframe(1.05, duration: 0.12)
                    SpringKeyframe(0.95, duration: 0.15)
                    SpringKeyframe(1, duration: 0.18)
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(4, duration: 0.08)
                    CubicKeyframe(-4, duration: 0.12)
                    CubicKeyframe(3, duration: 0.1)
                    CubicKeyframe(0, duration: 0.1)
                }
            }
            .onChange(of: mood) { _, new in
                if new == .happy, moves, size >= 24 { bounces += 1 }
            }
            .task(id: needsYou && moves && size >= 24) {
                guard needsYou, moves, size >= 24 else { return }
                while !Task.isCancelled {
                    wiggles += 1
                    try? await Task.sleep(for: .seconds(6))
                }
            }
            #if os(macOS) || os(iOS)
            .onContinuousHover { phase in
                guard isLarge, moves else { return }
                switch phase {
                case .active(let location):
                    let dx = (location.x / size - 0.5) * 2.4
                    let dy = (location.y / size - 0.5) * 2.4
                    pointer = CGPoint(x: max(-1.2, min(1.2, dx)), y: max(-1.2, min(1.2, dy)))
                case .ended:
                    pointer = .zero
                }
            }
            #endif
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: pointer)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let image = appearance.imageURL {
            imageFace(image)
        } else {
            FaceCanvas(
                appearance: appearance,
                gazeX: gaze.x,
                gazeY: gaze.y,
                openness: openness,
                smile: mood == .happy ? 1 : 0,
                detail: FaceDetail(size: size, isDark: colorScheme == .dark, increasedContrast: increasedContrast)
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: mood)
            .overlay(alignment: .bottom) {
                if mood == .thinking {
                    ThinkingDots(animated: moves)
                        .frame(width: size, height: size * 8 / 40)
                        .transition(.opacity)
                }
            }
            .frame(width: size, height: size * 44 / 40)
            .shadow(color: liftColor, radius: liftRadius, y: liftRadius / 2)
            .task(id: moves) { await blink() }
        }
    }

    /// A hue-tinted lift that follows the shape (photo faces get a neutral one), skipped on
    /// small faces and with Increase Contrast.
    private var liftColor: Color {
        guard size >= 24, !increasedContrast else { return .clear }
        if appearance.imageURL != nil { return .black.opacity(0.25) }
        return appearance.color.opacity(colorScheme == .dark ? 0.45 : 0.35)
    }

    private var liftRadius: CGFloat { size >= 24 && !increasedContrast ? size * 0.12 : 0 }

    /// Blinks every few seconds, staggered per Bot. A sleeping task rather than a
    /// timeline, so an idle face costs nothing between blinks.
    private func blink() async {
        openness = 1
        // Tiny faces (mention chips) don't blink; a 0.14 s blink isn't visible at that size.
        guard moves, size >= 24 else { return }
        let period = BotAppearance.blinkPeriod
        let phase = (Date.now.timeIntervalSinceReferenceDate - appearance.blinkOffset).truncatingRemainder(dividingBy: period)
        try? await Task.sleep(for: .seconds(period - phase))
        while !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.06)) { openness = 0 }
            try? await Task.sleep(for: .seconds(BotAppearance.blinkLength))
            withAnimation(.easeOut(duration: 0.09)) { openness = 1 }
            try? await Task.sleep(for: .seconds(period - BotAppearance.blinkLength))
        }
    }

    @ViewBuilder
    private func imageFace(_ source: String) -> some View {
        Group {
            if source.hasPrefix("data:") || source.hasPrefix("face://"), let image = FaceImageCache.image(for: source) {
                Image(platformImage: image).resizable().scaledToFill()
            } else if let url = URL(string: source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    appearance.color.opacity(0.4)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .shadow(color: liftColor, radius: liftRadius, y: liftRadius / 2)
        // Same footprint as a drawn face (40 × 44), so rows and cards line up.
        .frame(width: size, height: size * 44 / 40, alignment: .top)
        .scaleEffect(mood == .happy && moves ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: mood)
    }
}

private struct Squash {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

/// A slow 1.00 → 1.02 breath while a large face is idle.
private struct Breathing: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { content, inhale in
                content.scaleEffect(inhale ? 1.02 : 1, anchor: .bottom)
            } animation: { _ in
                .easeInOut(duration: 2)
            }
        } else {
            content
        }
    }
}

/// What the renderer needs to know beyond the face itself.
private struct FaceDetail: Equatable {
    let size: CGFloat
    let isDark: Bool
    let increasedContrast: Bool

    /// Below 24 pt the gloss and rim only muddy the face; the light-to-shade body stays.
    var showsGloss: Bool { size >= 24 && !increasedContrast }
}

/// The drawn face, interpolated frame by frame while its gaze, lids and smile animate.
private struct FaceCanvas: View, Animatable {
    let appearance: BotAppearance
    var gazeX: CGFloat
    var gazeY: CGFloat
    var openness: CGFloat
    var smile: CGFloat
    let detail: FaceDetail

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(gazeX, gazeY), AnimatablePair(openness, smile)) }
        set {
            gazeX = newValue.first.first
            gazeY = newValue.first.second
            openness = newValue.second.first
            smile = newValue.second.second
        }
    }

    var body: some View {
        Canvas { canvas, size in
            draw(in: &canvas, size: size)
        }
    }

    // MARK: Drawing (a 40 × 40 face box, like the Desktop SVG and the Elyx parts)

    private func draw(in canvas: inout GraphicsContext, size: CGSize) {
        let scale = size.width / 40
        canvas.scaleBy(x: scale, y: scale)
        let body = Self.body(appearance.shape)
        drawBody(body, in: canvas, unit: 1 / scale)

        let eyeFill: Color = appearance.isDark ? Palette.Faces.eyeOnDark : Palette.Faces.eyeOnLight
        let sparkle: Color = appearance.isDark ? Palette.Faces.sparkleOnDark : Palette.Faces.sparkleOnLight
        let eyeY: CGFloat = (appearance.shape == .cloud ? 22 : 17.2) + gazeY
        let open = max(0, min(1, openness)) * (1 - smile)

        for baseX in [15.4, 24.6] as [CGFloat] {
            let x = baseX + gazeX
            // Open eyes: tall ovals whose lids close as `open` falls.
            if open > 0.08 {
                let height = 6.6 * open
                canvas.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: eyeY - height / 2, width: 5.2, height: height)), with: .color(eyeFill))
                if open > 0.6 {
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - 0.85 - 1, y: eyeY - 1.45 - 1, width: 2, height: 2)),
                        with: .color(sparkle.opacity(Double((open - 0.6) / 0.4)))
                    )
                }
            } else if smile < 0.5 {
                // Closed lids: a short line.
                var lid = Path()
                lid.move(to: CGPoint(x: x - 2.6, y: eyeY))
                lid.addLine(to: CGPoint(x: x + 2.6, y: eyeY))
                canvas.stroke(lid, with: .color(eyeFill), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            // Happy: upturned arcs, ^ ^.
            if smile > 0.05 {
                var arc = Path()
                arc.move(to: CGPoint(x: x - 2.6, y: eyeY + 1.1))
                arc.addQuadCurve(to: CGPoint(x: x + 2.6, y: eyeY + 1.1), control: CGPoint(x: x, y: eyeY + 1.1 - 5 * smile))
                canvas.stroke(arc, with: .color(eyeFill.opacity(Double(smile))), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
    }

    /// The Bot's hue, a light-to-shade gradient at 160°, a gloss spot, and (on larger faces)
    /// an inner rim: lit along the top, shaded along the bottom.
    private func drawBody(_ body: Path, in canvas: GraphicsContext, unit: CGFloat) {
        canvas.fill(body, with: .color(appearance.color))
        // CSS 160°: from the top-left toward the bottom-right of the 40-unit box.
        canvas.fill(body, with: .linearGradient(
            Gradient(stops: [
                .init(color: Palette.Faces.bodyLight, location: 0),
                .init(color: Palette.Faces.bodyClear, location: 0.45),
                .init(color: Palette.Faces.bodyShade, location: 1),
            ]),
            startPoint: CGPoint(x: 11.2, y: -4.1),
            endPoint: CGPoint(x: 28.8, y: 44.1)
        ))
        guard detail.showsGloss else {
            if detail.increasedContrast {
                let outline = appearance.color.mix(with: detail.isDark ? .white : .black, by: 0.3)
                canvas.stroke(body, with: .color(outline), lineWidth: unit * 2)
            }
            return
        }
        var gloss = canvas
        gloss.clip(to: body)
        gloss.translateBy(x: 12, y: 8.8)
        gloss.scaleBy(x: 1, y: 18 / 22)
        gloss.fill(
            Path(ellipseIn: CGRect(x: -22, y: -22, width: 44, height: 44)),
            with: .radialGradient(
                Gradient(colors: [Palette.Faces.bodyGloss, Palette.Faces.bodyClear]),
                center: .zero, startRadius: 0, endRadius: 22
            )
        )
        // Inner shadows: the shape's inverse casts them, clipped back to the shape.
        var rim = canvas
        rim.clip(to: body)
        rim.addFilter(.shadow(color: .white.opacity(0.45), radius: unit * 0.5, x: 0, y: unit, options: [.invertsAlpha, .shadowOnly]))
        rim.fill(body, with: .color(.black))
        var shade = canvas
        shade.clip(to: body)
        shade.addFilter(.shadow(color: .black.opacity(0.18), radius: unit * 3, x: 0, y: -unit * 2, options: [.invertsAlpha, .shadowOnly]))
        shade.fill(body, with: .color(.black))
    }

    private static func body(_ shape: BotAppearance.Shape) -> Path {
        switch shape {
        case .circle:
            return Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 35, height: 35))
        case .squircle:
            return Path(roundedRect: CGRect(x: 3, y: 3, width: 34, height: 34), cornerRadius: 11, style: .continuous)
        case .pill:
            return Path(roundedRect: CGRect(x: 2, y: 7, width: 36, height: 26), cornerRadius: 13, style: .continuous)
        case .triangle:
            return Path { p in
                p.move(to: CGPoint(x: 20, y: 5.5))
                p.addLine(to: CGPoint(x: 36, y: 33.5))
                p.addLine(to: CGPoint(x: 4, y: 33.5))
                p.closeSubpath()
            }
        case .hexagon:
            return Path { p in
                p.move(to: CGPoint(x: 20, y: 3.5))
                for point in [(34.5, 11.75), (34.5, 28.25), (20, 36.5), (5.5, 28.25), (5.5, 11.75)] {
                    p.addLine(to: CGPoint(x: point.0, y: point.1))
                }
                p.closeSubpath()
            }
        case .cloud:
            // Desktop: M11 32 a7.5 7.5 0 0 1 -1 -14.9 A9.5 9.5 0 0 1 29 12.5 A7 7 0 0 1 30 32 Z
            return Path { p in
                p.move(to: CGPoint(x: 11, y: 32))
                p.addArc(center: CGPoint(x: 10.5, y: 24.55), radius: 7.5, startAngle: .degrees(86), endAngle: .degrees(-94), clockwise: false)
                p.addArc(center: CGPoint(x: 19.5, y: 16.5), radius: 9.5, startAngle: .degrees(196), endAngle: .degrees(-25), clockwise: false)
                p.addArc(center: CGPoint(x: 30, y: 25), radius: 7, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                p.closeSubpath()
            }
        case .drop:
            return Path { p in
                p.move(to: CGPoint(x: 20, y: 3))
                p.addCurve(to: CGPoint(x: 6, y: 27), control1: CGPoint(x: 20, y: 3), control2: CGPoint(x: 6, y: 20))
                p.addArc(center: CGPoint(x: 20, y: 27), radius: 14, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                p.addCurve(to: CGPoint(x: 20, y: 3), control1: CGPoint(x: 34, y: 20), control2: CGPoint(x: 20, y: 3))
                p.closeSubpath()
            }
        }
    }
}

/// Three dots under the face that pulse in turn while the Bot works (steady when
/// Reduce Motion is on): tertiary text, 2.2-unit dots 7 apart, like the design.
private struct ThinkingDots: View {
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let scale = size.width / 40
                canvas.scaleBy(x: scale, y: scale)
                for (index, x) in ([13, 20, 27] as [CGFloat]).enumerated() {
                    let wave = animated ? 0.35 + 0.65 * max(0, sin((time * 4) - Double(index) * 0.9)) : [0.45, 1, 0.7][index]
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - 2.2, y: 4 - 2.2, width: 4.4, height: 4.4)),
                        with: .color(Theme.tertiaryText.opacity(wave))
                    )
                }
            }
        }
    }
}

/// Decoded, downsampled photo avatars, keyed by `face://<name>#<revision>`, so faces
/// never decode base64 on the main thread or hash a whole data URL per redraw.
@MainActor
enum FaceImageCache {
    private static var images: [String: PlatformImage] = [:]

    static func image(for key: String) -> PlatformImage? {
        if let cached = images[key] { return cached }
        // A raw data URL (previews, tests): decode once, synchronously.
        guard key.hasPrefix("data:"), let comma = key.firstIndex(of: ","),
              let data = Data(base64Encoded: String(key[key.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let image = PlatformImage(data: data)
        else { return nil }
        images[key] = image
        return image
    }

    /// Decodes and downsamples off the main thread, then caches under `key`.
    static func prepare(dataURL: String, key: String, maxPixelSize: Int = 288) async -> PlatformImage? {
        if let cached = images[key] { return cached }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        #if os(macOS)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        let image = UIImage(cgImage: cgImage)
        #endif
        images[key] = image
        return image
    }
}

#Preview {
    HStack(spacing: 16) {
        ForEach(BotAppearance.Shape.allCases, id: \.self) { shape in
            BotFace(appearance: BotAppearance(profile: "researcher-\(shape.rawValue)", shape: shape.rawValue), size: 44, isWorking: shape == .cloud)
        }
    }
    .padding()
}
