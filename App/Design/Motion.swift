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
