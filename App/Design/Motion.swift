import Foundation
import Observation
import SwiftUI

/// Low Power Mode, observed, so decorative motion can rest while it's on.
@MainActor
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PowerState.shared.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

/// The drawer is sliding. A change that would redraw a lot at once (a fetched transcript
/// landing) waits for it to settle: SwiftUI animates on the main thread, so it would stutter the
/// slide. A wait is never longer than the slide.
@MainActor
enum Settling {
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static var isSliding = false {
        didSet {
            guard !isSliding else { return }
            let resumed = waiters
            waiters = []
            for waiter in resumed { waiter.resume() }
        }
    }

    static func untilSettled() async {
        guard isSliding else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

extension EnvironmentValues {
    /// True while the window isn't in front or Low Power Mode is on. Decorative loops (blinks,
    /// shimmer, auras, pulsing dots) hold still; Reduce Motion stops them altogether.
    @Entry var pausesDecorativeMotion = false
    /// The drawer is sliding. SwiftUI runs that animation on the main thread, so a chat being
    /// opened holds back work it can put off (the rest of its first page) until the slide has
    /// settled, rather than doing it mid-animation and stuttering it.
    @Entry var isSliding = false
}

/// Sets `pausesDecorativeMotion` for a window: the app in the background, Low Power Mode, and on
/// the Mac a window that isn't the key window (visible behind other apps, it kept animating all
/// day). Every window's root has it; the Settings and Inspector windows had none and never paused.
struct PausesMotionWhenAway: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.environment(\.pausesDecorativeMotion, pauses)
    }

    private var pauses: Bool {
        #if os(macOS)
        if !appearsActive { return true }
        #endif
        return scenePhase != .active || PowerState.shared.isLowPower
    }
}

extension View {
    func pausesMotionWhenAway() -> some View {
        modifier(PausesMotionWhenAway())
    }
}

/// A decorative loop (a pulsing halo, waving dots, a shimmer) that runs only while it can be seen:
/// shown, on screen, the window in front, no Reduce Motion. `content` gets `true` then, and its
/// moving part must exist only while it does: SwiftUI doesn't end a `repeatForever` animation
/// when its value is set back without one. A live dot in a row the sidebar's list had hidden for
/// reuse pulsed at the display's frame rate until the app quit, window in front or not (a Mac
/// core at 100% for 20 minutes). Taking the view away is what ends its animation. A hidden row
/// gets no `onDisappear`, so the sidebar also starts a new list when it swaps its rows.
struct DecorativeLoop<Content: View>: View {
    @ViewBuilder let content: (_ runs: Bool) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @State private var isShown = false
    @State private var isOnScreen = true

    var body: some View {
        content(isShown && isOnScreen && !reduceMotion && !motionPaused)
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    }
}

#if DEBUG
/// How many shimmers sweep right now, for the UI tests' "one moving thing per place" checks
/// (`docs/chat.md` §4a). `-HERMES_MOTION_PROBE YES` shows it as a near-invisible element,
/// `motionProbe`, whose value is the count.
@MainActor
@Observable
final class MotionProbe {
    static let shared = MotionProbe()

    var sweeps = 0

    private init() {}

    static let isOn = UserDefaults.standard.bool(forKey: "HERMES_MOTION_PROBE")
}

private struct MotionProbeOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            if MotionProbe.isOn {
                Text(verbatim: "\(MotionProbe.shared.sweeps)")
                    .font(.system(size: 2))
                    .opacity(0.05)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("motionProbe")
                    .accessibilityLabel(Text(verbatim: "Motion probe"))
                    .accessibilityValue(Text(verbatim: "\(MotionProbe.shared.sweeps)"))
            }
        }
    }
}

extension View {
    /// `-HERMES_MOTION_PROBE YES`: the shimmer count on screen, for UI tests.
    func motionProbe() -> some View {
        modifier(MotionProbeOverlay())
    }
}
#endif
