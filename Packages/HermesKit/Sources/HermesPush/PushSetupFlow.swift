import Foundation

/// What the Set Up Push sheet shows (`docs/setup.md` §4.13). It offers the plugin's install only
/// once a check said the plugin is missing: Set Up… on a stopped gateway that has the plugin used to
/// show the install review until its recheck answered.
public struct PushSetupFlow: Sendable, Equatable {
    /// What a check of the gateway said, as far as the sheet cares.
    public enum Check: Sendable, Equatable {
        /// The gateway has no push plugin.
        case missing
        /// No Bot Mode link, so the app can't reach the gateway's commands.
        case needsBotMode
        /// The check ended without push: offline, not registered or failed. The row says why, with
        /// Check Again.
        case ended
        /// Anything else: still checking, stopped or on.
        case other
    }

    public enum Page: Sendable, Equatable {
        /// The title, Close and a spinner (`pushSetupWaiting`).
        case waiting
        /// The plugin's review with its install (`pushSetup`).
        case review
        /// The commands to run on the gateway, without Bot Mode.
        case needsBotMode
        /// The check mark.
        case done
        /// The sheet closes, and the row shows the gateway's state.
        case close
    }

    /// A check said the plugin is missing while the sheet was open. The review then stays, so a
    /// later poll that passes through checking doesn't take it away.
    public private(set) var pluginMissing = false

    /// A check after the one the sheet opened with ended without push. Waiting longer would show
    /// a spinner the gateway never ends.
    public private(set) var checkEnded = false

    private var sawOpening = false

    public init() {}

    /// Each check the sheet sees while it's open, the one it opens with included.
    public mutating func saw(_ check: Check) {
        if check == .missing { pluginMissing = true }
        if check == .ended, sawOpening { checkEnded = true }
        sawOpening = true
    }

    public func page(_ check: Check, hasRoster: Bool, isDone: Bool) -> Page {
        if isDone { return .done }
        if check == .needsBotMode || !hasRoster { return .needsBotMode }
        if pluginMissing || check == .missing { return .review }
        return checkEnded ? .close : .waiting
    }
}
