import HermesPush
import Observation
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
typealias FacePlatformView = NSView
#else
import UIKit
typealias FacePlatformView = UIView
#endif

/// A face doing only its mood's motion (the sway, breath, glances, blinks and dots), played by
/// Core Animation from a `FaceLoop` (`docs/bot-faces.md` §5). The render server runs it: the
/// app hands over the layers and their keyframes once and does nothing per frame, where a drawn
/// face redrew its canvas, and committed the window, on every tick of the face clock. `BotFace`
/// shows it whenever its face has nothing else going on, and draws the one-offs (a blink on cue,
/// a boop, a hop, a new shape or colour, a mood change, a voice) the way it always has.
struct FaceLayers {
    let look: FaceLook
    let loop: FaceLoop
    let size: CGFloat
    /// Increase Contrast's outline, when the body is too close to the background.
    var outline: Color?
    /// How often the render server may draw it: more for a big face in focus, few in Low Power
    /// Mode. Slow sines look the same at 24 frames a second as at 120.
    var frameRate: CAFrameRateRange
    /// The thinking and working dots: only where the face stands alone (`docs/bot-faces.md`).
    var dots = false
}

#if os(macOS)
extension FaceLayers: NSViewRepresentable {
    func makeNSView(context: Context) -> FaceLayerView { FaceLayerView() }
    func updateNSView(_ view: FaceLayerView, context: Context) {
        view.show(self, outline: outline?.resolve(in: context.environment).cgColor)
    }
}
#else
extension FaceLayers: UIViewRepresentable {
    func makeUIView(context: Context) -> FaceLayerView { FaceLayerView() }
    func updateUIView(_ view: FaceLayerView, context: Context) {
        view.show(self, outline: outline?.resolve(in: context.environment).cgColor)
    }
}
#endif

/// The layers of one face, in the painter's face box (40 × 44 units, y down) scaled to points:
/// the body leans and breathes about its bottom, the eyes move together to where they look, and
/// each eye is an ellipse its lids scale, a catchlight, and the stroke a shut eye draws.
final class FaceLayerView: FacePlatformView {
    private struct Shown: Equatable {
        var look: FaceLook
        var loop: FaceLoop
        var size: CGFloat
        var outline: CGColor?
        var frameRate: [Float]
        var scale: CGFloat
        var dots: Bool
    }

    private let breathe = CALayer()
    private let lean = CALayer()
    private let bodyShape = CAShapeLayer()
    private let eyes = CALayer()
    private let eyeLayers = (0..<2).map { _ in (open: CAShapeLayer(), sparkle: CAShapeLayer(), shut: CAShapeLayer()) }
    private let dots = (0..<3).map { _ in CAShapeLayer() }
    private var shown: Shown?
    private var face: FaceLayers?
    private var outline: CGColor?

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
        let root = rootLayer
        root.addSublayer(breathe)
        breathe.addSublayer(lean)
        lean.addSublayer(bodyShape)
        lean.addSublayer(eyes)
        for eye in eyeLayers {
            let group = CALayer()
            group.addSublayer(eye.open)
            group.addSublayer(eye.sparkle)
            group.addSublayer(eye.shut)
            eyes.addSublayer(group)
        }
        dots.forEach(lean.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var rootLayer: CALayer {
        #if os(macOS)
        layer!
        #else
        layer
        #endif
    }

    private var displayScale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        window?.screen.scale ?? traitCollection.displayScale
        #endif
    }

    #if os(macOS)
    // The painter's y runs down; so do the layers' in a flipped view.
    override var isFlipped: Bool { true }
    // Taps go to the SwiftUI face around it (a boop).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }
    #endif

    func show(_ face: FaceLayers, outline: CGColor?) {
        self.face = face
        self.outline = outline
        refresh()
    }

    private func refresh() {
        guard let face else { return }
        let rate = face.frameRate
        let next = Shown(look: face.look, loop: face.loop, size: face.size, outline: outline,
                         frameRate: [rate.minimum, rate.maximum, rate.preferred ?? rate.maximum], scale: displayScale, dots: face.dots)
        guard next != shown else { return }
        shown = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        build(next)
        animate(next)
        CATransaction.commit()
    }

    /// The layers at rest: sizes, paths and colours, in points.
    private func build(_ shown: Shown) {
        let s = shown.size / 40
        let box = CGRect(x: 0, y: 0, width: shown.size, height: FacePainter.height(forWidth: shown.size))
        let body = FaceBody.of(shown.look.shape)
        let pivot = CGPoint(x: 20 * s, y: body.bounds.maxY * s)
        let anchor = CGPoint(x: pivot.x / box.width, y: pivot.y / box.height)
        for layer in [breathe, lean] {
            layer.bounds = box
            layer.anchorPoint = anchor
            layer.position = pivot
        }
        var scaled = CGAffineTransform(scaleX: s, y: s)
        bodyShape.frame = box
        bodyShape.path = body.path.copy(using: &scaled)
        bodyShape.fillColor = Self.cgColor(shown.look.color)
        bodyShape.strokeColor = shown.outline
        bodyShape.lineWidth = shown.outline == nil ? 0 : 1

        // The eyes' midpoint is animated; each eye sits ±spread from it.
        eyes.bounds = .zero
        eyes.position = CGPoint(x: shown.loop.value(of: shown.loop.eyesX, at: 0) * s, y: shown.loop.value(of: shown.loop.eyesY, at: 0) * s)
        let eyeColor = Self.cgColor(shown.look.color.eye)
        let rx = FaceBody.eyeRadius * s, ry = shown.loop.eyeHeight * s
        for (index, eye) in eyeLayers.enumerated() {
            let x = (index == 0 ? -FaceBody.eyeSpread : FaceBody.eyeSpread) * s
            eye.open.superlayer?.frame = CGRect(x: x, y: 0, width: 0, height: 0)
            eye.open.path = CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: nil)
            eye.open.fillColor = eyeColor
            let sparkle = 0.65 * s
            eye.sparkle.path = CGPath(ellipseIn: CGRect(x: -0.6 * s - sparkle, y: -0.7 * s - sparkle, width: sparkle * 2, height: sparkle * 2), transform: nil)
            eye.sparkle.fillColor = Self.cgColor(shown.look.color.catchlight)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: -2.4 * s, y: 0))
            line.addLine(to: CGPoint(x: 2.4 * s, y: 0))
            eye.shut.path = line
            eye.shut.strokeColor = eyeColor
            eye.shut.fillColor = nil
            eye.shut.lineWidth = 2 * s
            eye.shut.lineCap = .round
        }

        // Dots: r 1.15 in the body colour, bigger below 24 pt so they still read.
        let radius = 1.15 * (shown.size < 24 ? 1.4 : 1) * s
        for (dot, x) in zip(dots, [16.4, 20, 23.6]) {
            dot.path = CGPath(ellipseIn: CGRect(x: x * s - radius, y: 41.2 * s - radius, width: radius * 2, height: radius * 2), transform: nil)
            dot.fillColor = Self.cgColor(shown.look.color)
        }
        for shape in [bodyShape] + eyeLayers.flatMap({ [$0.open, $0.sparkle, $0.shut] }) + dots {
            shape.contentsScale = shown.scale
        }
    }

    /// Hands the loop to the render server, `t mod period` seconds in, so it shows what a drawn
    /// face shows at this moment of the face clock.
    private func animate(_ shown: Shown) {
        let loop = shown.loop
        let s = shown.size / 40
        let now = rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        let into = FaceClock.time().truncatingRemainder(dividingBy: loop.duration)
        func play(_ layer: CALayer, _ keyPath: String, _ track: FaceLoop.Track, discrete: Bool = false, map: (Double) -> Double = { $0 }) {
            layer.removeAnimation(forKey: keyPath)
            if let value = track.constant {
                layer.setValue(map(value), forKeyPath: keyPath)
                return
            }
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = track.values.map(map)
            animation.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
            animation.calculationMode = discrete ? .discrete : .linear
            animation.duration = loop.duration
            animation.repeatCount = .infinity
            animation.beginTime = now
            animation.timeOffset = into
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: shown.frameRate[0], maximum: shown.frameRate[1], preferred: shown.frameRate[2])
            layer.add(animation, forKey: keyPath)
        }
        play(lean, "transform.rotation.z", loop.lean) { $0 * .pi / 180 }
        play(breathe, "transform.scale.x", loop.scaleX)
        play(breathe, "transform.scale.y", loop.scaleY)
        play(eyes, "position.x", loop.eyesX) { $0 * s }
        play(eyes, "position.y", loop.eyesY) { $0 * s }
        for eye in eyeLayers {
            play(eye.open, "transform.scale.y", loop.lid) { max($0, 0.001) }
            play(eye.open, "opacity", loop.open, discrete: true)
            play(eye.sparkle, "opacity", loop.catchlight, discrete: true)
            play(eye.shut, "opacity", loop.open, discrete: true) { 1 - $0 }
        }
        for (dot, track) in zip(dots, loop.dots) {
            dot.isHidden = !shown.dots
            if shown.dots { play(dot, "opacity", track) }
        }
    }

    private static func cgColor(_ color: FaceColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func cgColor(_ ink: FaceInk) -> CGColor {
        CGColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
    }
}

/// A photo face's slow breath (1 → 1.02 and back every 4 s, about its bottom edge), played by
/// Core Animation like `FaceLayers`.
struct PhotoFaceLayers {
    let image: PlatformImage
    let size: CGFloat
    var frameRate: CAFrameRateRange
}

#if os(macOS)
extension PhotoFaceLayers: NSViewRepresentable {
    func makeNSView(context: Context) -> PhotoFaceLayerView { PhotoFaceLayerView() }
    func updateNSView(_ view: PhotoFaceLayerView, context: Context) { view.show(self) }
}
#else
extension PhotoFaceLayers: UIViewRepresentable {
    func makeUIView(context: Context) -> PhotoFaceLayerView { PhotoFaceLayerView() }
    func updateUIView(_ view: PhotoFaceLayerView, context: Context) { view.show(self) }
}
#endif

final class PhotoFaceLayerView: FacePlatformView {
    private let photo = CALayer()
    private var shown: (image: PlatformImage, size: CGFloat)?

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        layer!.addSublayer(photo)
        #else
        isUserInteractionEnabled = false
        layer.addSublayer(photo)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    func show(_ face: PhotoFaceLayers) {
        if let shown, shown.image === face.image, shown.size == face.size { return }
        shown = (face.image, face.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A rounded square with a 22% radius, filled by the picture; it breathes about its bottom.
        photo.anchorPoint = CGPoint(x: 0.5, y: 1)
        photo.bounds = CGRect(x: 0, y: 0, width: face.size, height: face.size)
        photo.position = CGPoint(x: face.size / 2, y: face.size)
        photo.cornerRadius = face.size * 0.22
        photo.cornerCurve = .continuous
        photo.masksToBounds = true
        photo.contentsGravity = .resizeAspectFill
        #if os(macOS)
        photo.contents = face.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        photo.contents = face.image.cgImage
        #endif
        let period = 4.0
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        let steps = 40
        animation.values = (0...steps).map { 1 + 0.01 * (1 - cos(Double($0) / Double(steps) * period * .pi / 2)) }
        animation.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.beginTime = photo.convertTime(CACurrentMediaTime(), from: nil)
        animation.timeOffset = FaceClock.time().truncatingRemainder(dividingBy: period)
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = face.frameRate
        photo.add(animation, forKey: "breath")
        CATransaction.commit()
    }
}

/// Each mood's loop, built once per Bot and shared by its faces. A loop takes a few milliseconds
/// to sample, so it's built off the main actor; until it's ready the face is drawn as before.
@MainActor
@Observable
final class FaceLoops {
    static let shared = FaceLoops()

    nonisolated struct Key: Hashable, Sendable {
        let mood: FaceMood
        let seed: UInt32
        let lookX: Double?
        let lookY: Double?
        let shape: FaceShape
        /// Faces under 24 pt draw no catchlight.
        let catchlights: Bool
        let stilled: Bool

        init(target: FaceTarget, shape: FaceShape, size: CGFloat, stilled: Bool) {
            mood = target.mood
            seed = target.seed
            lookX = target.look.map { Double($0.dx) }
            lookY = target.look.map { Double($0.dy) }
            self.shape = shape
            catchlights = size >= 24
            self.stilled = stilled
        }
    }

    private var loops: [Key: FaceLoop] = [:]
    @ObservationIgnored private var building: Set<Key> = []

    private init() {}

    /// The loop, or nil while it's being built (asking starts it).
    func loop(for key: Key, target: FaceTarget) -> FaceLoop? {
        if let loop = loops[key] { return loop }
        guard !building.contains(key) else { return nil }
        building.insert(key)
        Task {
            let loop = await Self.make(target, key: key)
            building.remove(key)
            // A long session meets few moods per Bot; a cap keeps a string of looks from piling up.
            if loops.count > 160 { loops.removeAll() }
            loops[key] = loop
        }
        return nil
    }

    @concurrent
    private nonisolated static func make(_ target: FaceTarget, key: Key) async -> FaceLoop {
        FaceLoop.make(target, shape: key.shape, pointSize: key.catchlights ? 40 : 20, stilled: key.stilled)
    }
}
