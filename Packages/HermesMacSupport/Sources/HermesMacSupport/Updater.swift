#if canImport(Sparkle)
import Foundation
import Observation
import Sparkle

/// Sparkle for the Developer ID Mac app: background checks that notify (never a silent
/// install) and a "Check for Updates…" command.
///
/// Starts only in Release builds that carry a feed and public key, so "Hermes Dev" never
/// checks the real appcast or offers to replace itself with the released app.
@MainActor
@Observable
public final class Updater {
    public private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    public init() {
        // Debug builds ("Hermes Dev") carry an empty feed and key, so they never update themselves.
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        guard enabled else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // SPUUpdater is main-thread affined and posts KVO there.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    /// Whether this build updates itself at all.
    public var isAvailable: Bool { controller != nil }

    public func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    /// "Check for updates automatically" (Settings → General).
    public var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }
}
#endif
