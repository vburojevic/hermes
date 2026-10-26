import HermesKit
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Decorative loops played by Core Animation, as `FaceLayers` plays faces: the app hands the render
// server a layer and its animation once, and does nothing per frame. A SwiftUI `repeatForever`
// animation is the app's own work every frame it runs (interpolating and committing the window),
// and every place that says what a Bot is doing shimmers (`docs/chat.md` §4a). `DecorativeLoop`
// still decides when one exists at all (seen, in front, no Reduce Motion or Low Power Mode);
// taking the view away ends its animation.

/// How often the render server draws a loop: slow pulses and sweeps look the same at 30 frames a
/// second as at 120.
private let loopFrameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

/// The base of the loops' platform views: no hit testing, y down on the Mac as on iOS, and the
/// layers rebuilt when the size, scale or colours change.
class LoopLayerView: FacePlatformView {
    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var rootLayer: CALayer {
        #if os(macOS)
        layer!
        #else
        layer
        #endif
    }

    var displayScale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        #else
        window?.screen.scale ?? traitCollection.displayScale
        #endif
    }

    /// Lays the layers out for `bounds` and starts their animation; called again when either changes.
    func refresh() {}

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        refresh()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refresh()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refresh()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }
    #endif

    /// An animation that loops from `now`, at the loops' frame rate.
    func looping(_ animation: CAAnimation, duration: Double, autoreverses: Bool = false, delay: Double = 0) -> CAAnimation {
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = rootLayer.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.preferredFrameRateRange = loopFrameRate
        return animation
    }
}

// MARK: - Halo

/// A dot's halo (`PulseHalo`): a circle the dot's size that grows to `scale` and fades, every
/// `period` seconds.
struct HaloLayer {
    let color: Color
    let scale: CGFloat
    let period: Double
}

#if os(macOS)
extension HaloLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> HaloLayerView { HaloLayerView() }
    func updateNSView(_ view: HaloLayerView, context: Context) {
        view.show(color: color.resolve(in: context.environment).cgColor, scale: scale, period: period)
    }
}
#else
extension HaloLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> HaloLayerView { HaloLayerView() }
    func updateUIView(_ view: HaloLayerView, context: Context) {
        view.show(color: color.resolve(in: context.environment).cgColor, scale: scale, period: period)
    }
}
#endif

final class HaloLayerView: LoopLayerView {
    private struct Shown: Equatable {
        var color: CGColor?
        var scale: CGFloat
        var period: Double
        var size: CGSize
        var displayScale: CGFloat
    }

    private let circle = CAShapeLayer()
    private var wanted = Shown(color: nil, scale: 1, period: 1, size: .zero, displayScale: 2)
    private var shown: Shown?

    override init() {
        super.init()
        rootLayer.addSublayer(circle)
    }

    func show(color: CGColor, scale: CGFloat, period: Double) {
        wanted.color = color
        wanted.scale = scale
        wanted.period = period
        refresh()
    }

    override func refresh() {
        var next = wanted
        next.size = bounds.size
        next.displayScale = displayScale
        guard next != shown, next.size.width > 0 else { return }
        shown = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.frame = CGRect(origin: .zero, size: next.size)
        circle.path = CGPath(ellipseIn: CGRect(origin: .zero, size: next.size), transform: nil)
        circle.fillColor = next.color
        circle.contentsScale = next.displayScale
        circle.removeAllAnimations()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = next.scale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        grow.duration = next.period
        fade.duration = next.period
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        circle.add(looping(pulse, duration: next.period), forKey: "pulse")
        CATransaction.commit()
    }
}

// MARK: - Shimmer

/// The band that passes over a `ShimmerText` (`Chips.shimmerText`, `docs/chat.md` §4a), shaped
/// and paced by `ShimmerBand`: `color` at its middle, easing out to nothing at its edges, from
/// wholly before the words to wholly past them at a steady pace, then a rest, once every
/// `ShimmerBand.period` seconds. The text masks it.
struct ShimmerLayer {
    let color: Color
}

#if os(macOS)
extension ShimmerLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerLayerView { ShimmerLayerView() }
    func updateNSView(_ view: ShimmerLayerView, context: Context) {
        view.show(color: color.resolve(in: context.environment).cgColor)
    }
}
#else
extension ShimmerLayer: UIViewRepresentable {
    func makeUIView(context: Context) -> ShimmerLayerView { ShimmerLayerView() }
    func updateUIView(_ view: ShimmerLayerView, context: Context) {
        view.show(color: color.resolve(in: context.environment).cgColor)
    }
}
#endif

final class ShimmerLayerView: LoopLayerView {
    private struct Shown: Equatable {
        var color: CGColor?
        var size: CGSize
    }

    private let sweep = CAGradientLayer()
    private var wanted = Shown(color: nil, size: .zero)
    private var shown: Shown?

    override init() {
        super.init()
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        rootLayer.addSublayer(sweep)
    }

    func show(color: CGColor) {
        wanted.color = color
        refresh()
    }

    override func refresh() {
        var next = wanted
        next.size = bounds.size
        guard next != shown, next.size.width > 0, let color = next.color else { return }
        shown = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = next.size.width
        let band = ShimmerBand.width(over: width)
        let travel = ShimmerBand.travel(over: width)
        // Each stop is the band colour, fainter: fading towards clear black would grey its edges.
        sweep.colors = ShimmerBand.stops.map { color.copy(alpha: color.alpha * $0.strength) ?? color }
        sweep.locations = ShimmerBand.stops.map { NSNumber(value: $0.location) }
        sweep.frame = CGRect(x: travel.from - band / 2, y: 0, width: band, height: next.size.height)
        sweep.removeAllAnimations()
        // A steady pass, then a rest past the words. Eased, it dwelt on the first and last words.
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = [travel.from, travel.to, travel.to]
        move.keyTimes = [0, NSNumber(value: ShimmerBand.pass / ShimmerBand.period), 1]
        move.calculationMode = .linear
        // On one clock for every shimmer: new words ("Thinking… · 12s" each second) carry on
        // the sweep where it was rather than starting it again, and rows sweep together.
        let phase = CACurrentMediaTime().truncatingRemainder(dividingBy: ShimmerBand.period)
        sweep.add(looping(move, duration: ShimmerBand.period, delay: -phase), forKey: "sweep")
        CATransaction.commit()
    }
}
