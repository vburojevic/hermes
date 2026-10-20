import SwiftUI

/// A Bot's ambient glow (the `botAura` Metal shader), drifting slowly in its colour.
struct BotAura: View {
    let color: Color
    var intensity: Double = 0.9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @State private var start = Date.now

    var body: some View {
        let strength = Float(colorScheme == .dark ? intensity : intensity * 0.6)
        // The drift is slow; 20 fps is indistinguishable from 60 and far cheaper.
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion || motionPaused)) { context in
            let time = Float(context.date.timeIntervalSince(start))
            Rectangle()
                .fill(.white)
                .visualEffect { [color] content, proxy in
                    content.colorEffect(ShaderLibrary.botAura(
                        .float2(proxy.size), .float(time), .color(color), .float(strength)
                    ))
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A ripple across the view from where it was touched (the `ripple` Metal shader).
struct RippleEffect<Trigger: Equatable & Sendable>: ViewModifier {
    var origin: CGPoint
    var trigger: Trigger
    var duration: TimeInterval = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let origin = origin
            let duration = duration
            content.keyframeAnimator(initialValue: 0, trigger: trigger) { view, elapsed in
                view.modifier(RippleFrame(origin: origin, elapsed: elapsed, duration: duration))
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(duration, duration: duration)
            }
        }
    }
}

/// One frame of the ripple.
private struct RippleFrame: ViewModifier {
    var origin: CGPoint
    var elapsed: TimeInterval
    var duration: TimeInterval
    var amplitude: Double = 10
    var frequency: Double = 14
    var decay: Double = 7
    var speed: Double = 900

    func body(content: Content) -> some View {
        let shader = ShaderLibrary.ripple(
            .float2(origin), .float(elapsed), .float(amplitude), .float(frequency), .float(decay), .float(speed)
        )
        let offset = CGSize(width: amplitude, height: amplitude)
        let enabled = 0 < elapsed && elapsed < duration
        content.visualEffect { view, _ in
            view.layerEffect(shader, maxSampleOffset: offset, isEnabled: enabled)
        }
    }
}

extension View {
    func ripple<Trigger: Equatable & Sendable>(at origin: CGPoint, trigger: Trigger) -> some View {
        modifier(RippleEffect(origin: origin, trigger: trigger))
    }
}

/// A little burst of sparkles, for moments worth celebrating (a Bot is born).
struct SparkleBurst: View {
    let color: Color
    let trigger: Int
    var count = 12
    var radius: CGFloat = 78

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            ZStack {
                // A nonisolated row builder: a `ViewThatFits` measuring a hidden layout with the
                // burst in it may build these rows on SwiftUI's render thread, where a main-actor
                // closure traps. Each particle's own body still runs on main.
                ForEach(0..<count, id: \.self, content: particle)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private nonisolated func particle(_ index: Int) -> SparkleParticle {
        SparkleParticle(index: index, count: count, color: color, radius: radius, trigger: trigger)
    }
}

nonisolated struct SparkleParticle: View {
    let index: Int
    let count: Int
    let color: Color
    let radius: CGFloat
    let trigger: Int

    var body: some View {
        Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "circle.fill")
            .font(.system(size: index.isMultiple(of: 3) ? 11 : 5, weight: .bold))
            .foregroundStyle(index.isMultiple(of: 2) ? color : .white)
            .keyframeAnimator(initialValue: Particle(), trigger: trigger) { view, particle in
                let angle = Angle.degrees(Double(index) / Double(count) * 360 + Double(index % 3) * 9)
                view
                    .scaleEffect(particle.scale)
                    .offset(
                        x: cos(angle.radians) * radius * particle.distance,
                        y: sin(angle.radians) * radius * particle.distance
                    )
                    .opacity(particle.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.distance) {
                    MoveKeyframe(0.15)
                    SpringKeyframe(1, duration: 0.7, spring: .bouncy)
                }
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0.2)
                    SpringKeyframe(1.2, duration: 0.25)
                    CubicKeyframe(0.4, duration: 0.55)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(1)
                    LinearKeyframe(1, duration: 0.45)
                    CubicKeyframe(0, duration: 0.4)
                }
            }
    }

    struct Particle {
        var distance: CGFloat = 0
        var scale: CGFloat = 0
        var opacity: Double = 0
    }
}

/// Drives `pairingReveal`: a hidden QR code resolving from the centre as `progress` goes 0 → 1.
struct PairingRevealEffect: ViewModifier, Animatable {
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.visualEffect { [progress] view, proxy in
            view.layerEffect(
                ShaderLibrary.pairingReveal(.float2(proxy.size), .float(progress), .float(18)),
                maxSampleOffset: CGSize(width: 18, height: 18),
                isEnabled: progress < 1
            )
        }
    }
}
