import Foundation

/// A long job the person started on the gateway (`docs/setup.md` §4.2a), as Settings → Setup and
/// the chat card that ran its command show it: the step running now with the lines so far, then
/// how it ended. The same run shows in both places.
public struct GatewayJob: Sendable, Equatable {
    public enum Kind: String, Sendable, Hashable {
        case update, restart
    }

    /// One run of a kind: the chat card that started run 3 keeps showing run 3 after run 4 starts.
    public struct Ref: Sendable, Hashable {
        public var kind: Kind
        public var number: Int

        public init(kind: Kind, number: Int) {
            self.kind = kind
            self.number = number
        }
    }

    public enum Tone: Sendable, Equatable {
        case running, done
        /// It ended, but needs a look or a step from the person.
        case attention
        case failed
    }

    public var kind: Kind
    public var tone: Tone
    /// While it runs, the step running now; then how it ended.
    public var headline: String
    public var detail: String?
    /// What to run on the gateway instead, when Hermes says.
    public var command: String?
    public var log: ActionLog
    public var started: Date
    /// Once it's done: Hermes wrote the gateway's plist again on the way, and macOS runs it at
    /// background priority (`docs/setup.md` §4.17).
    public var priorityReset: PriorityNotice?
    /// Once it's done, on the gateway's own Mac: the app is putting the gateway back at full
    /// priority, as it was before the run, or has.
    public var priorityRestore: PriorityRestore?

    public enum PriorityRestore: Sendable, Equatable {
        case restoring, restored
    }

    public var isRunning: Bool { tone == .running }

    public init(kind: Kind, tone: Tone, headline: String, detail: String? = nil, command: String? = nil,
                log: ActionLog = ActionLog(), started: Date = .now) {
        self.kind = kind
        self.tone = tone
        self.headline = headline
        self.detail = detail
        self.command = command
        self.log = log
        self.started = started
    }

    /// `hermes update`, started with `POST /api/hermes/update`.
    public static func update(_ run: HermesUpdateRun, log: ActionLog, started: Date, gatewayName: String) -> GatewayJob {
        let job = { (tone: Tone, headline: String, detail: String?) in
            GatewayJob(kind: .update, tone: tone, headline: headline, detail: detail, log: log, started: started)
        }
        switch run {
        case .starting:
            return job(.running, String(localized: "Starting the update…"), nil)
        case .running:
            return job(.running, log.currentStep ?? String(localized: "Updating Hermes…"),
                       String(localized: "Hermes restarts when it's done, once running chats and tasks finish."))
        case .finished(.updated(let version)):
            return job(.done, version.map { String(localized: "Updated to \($0)") } ?? String(localized: "Updated"), nil)
        case .finished(.owes(let followups, let userAction)):
            return job(.attention,
                       followups.isEmpty
                           ? String(localized: "Updated, but Hermes needs something from you")
                           : String(localized: "Updated, but Hermes still has steps to finish"),
                       [followups.isEmpty ? nil : followups, userAction].compactMap(\.self).joined(separator: "\n"))
        case .finished(.failed(let code, _)):
            return job(.failed, String(localized: "The update stopped (exit \(code))"),
                       String(localized: "The previous version is still running."))
        case .finished(.unknown), .lostTouch:
            return job(.attention, String(localized: "\(gatewayName) stopped answering while Hermes updated"),
                       String(localized: "Check its version in Settings → Setup in a minute."))
        case .refused(let message, let command):
            var refused = job(.attention, String(localized: "Hermes doesn't update itself here"), message)
            refused.command = command
            return refused
        case .couldNotStart(let message):
            return job(.failed, String(localized: "The update didn't start"), message)
        }
    }

    /// `hermes gateway restart`, started with `POST /api/gateway/restart`.
    public static func restart(_ run: ActionRunState, log: ActionLog, started: Date, gatewayName: String) -> GatewayJob {
        let job = { (tone: Tone, headline: String, detail: String?) in
            GatewayJob(kind: .restart, tone: tone, headline: headline, detail: detail, log: log, started: started)
        }
        switch run {
        case .starting:
            return job(.running, String(localized: "Restarting the gateway…"), nil)
        case .running:
            return job(.running, log.currentStep ?? String(localized: "Restarting the gateway…"),
                       String(localized: "Running chats and tasks finish first."))
        case .succeeded:
            return job(.done, String(localized: "Restarted"), nil)
        case .failed(let code):
            var failed = job(.failed, String(localized: "The restart stopped (exit \(code))"),
                             String(localized: "To see why, run it on \(gatewayName):"))
            failed.command = "hermes gateway restart"
            return failed
        case .lostTouch:
            return job(.attention, String(localized: "\(gatewayName) stopped answering during the restart"),
                       String(localized: "Check Again in Settings → Setup in a minute."))
        case .couldNotStart(let message):
            return job(.failed, String(localized: "The restart didn't start"), message)
        }
    }
}
