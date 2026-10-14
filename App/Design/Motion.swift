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

extension EnvironmentValues {
    /// True while the window isn't in front or Low Power Mode is on. Decorative loops (blinks,
    /// shimmer, auras, pulsing dots) hold still; Reduce Motion stops them altogether.
    @Entry var pausesDecorativeMotion = false
}
