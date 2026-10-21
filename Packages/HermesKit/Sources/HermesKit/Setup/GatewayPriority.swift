import CryptoKit
import Foundation

/// How the gateway's computer schedules Hermes (`docs/setup.md` §4.17), as the app's push plugin
/// reports it (`/app-push host`) or the Mac app reads it for a gateway on the same Mac.
///
/// On macOS, launchd runs a LaunchAgent with no `ProcessType` as a background job: the system
/// throttles its CPU and I/O, so when the Mac is busy Hermes answers late or not at all while the
/// person's apps carry on. `Interactive` gives a job the limits apps have, none.
public struct GatewayHostReport: Sendable, Equatable {
    public struct Job: Sendable, Equatable, Identifiable {
        public enum Role: String, Sendable {
            case gateway, dashboard
            /// The job the plugin itself runs in, under a label Hermes didn't write.
            case own
        }

        public var label: String
        public var role: Role
        public var plistPath: String
        /// `ProcessType` in the plist: what the next load uses.
        public var processType: String?
        /// What launchd loaded it with (`launchctl print`): `interactive`, `background`, `standard`…
        public var spawnType: String?
        public var pid: Int?
        public var priority: Int?
        public var id: String { label }

        public init(label: String, role: Role, plistPath: String, processType: String? = nil, spawnType: String? = nil,
                    pid: Int? = nil, priority: Int? = nil) {
            self.label = label
            self.role = role
            self.plistPath = plistPath
            self.processType = processType
            self.spawnType = spawnType
            self.pid = pid
            self.priority = priority
        }

        /// Throttled: loaded as anything but interactive, or set up to be from its next start. Hermes
        /// writes the gateway's plist again without ProcessType while it runs (`hermes update`,
        /// `hermes gateway restart`), and launchd keeps running the job as it loaded it until
        /// then, so right after an update the gateway still runs at full priority.
        public var isThrottled: Bool {
            spawnType.map { $0 != "interactive" } == true || processType != "Interactive"
        }

        /// Its plist already says Interactive; only a reload is missing.
        public var needsReload: Bool { isThrottled && processType == "Interactive" }

        /// Running at full priority, but its plist no longer says so: the plist is all that needs
        /// changing, without a restart.
        public var losesPriorityAtNextStart: Bool { spawnType == "interactive" && processType != "Interactive" }

        /// A job the app may change on this Mac: one of Hermes's labels, its plist in the
        /// person's LaunchAgents folder. Whatever the report says, nothing else is touched.
        public func isSafeToChange(agentsFolder: String) -> Bool {
            label.hasPrefix("ai.hermes.") && !label.contains("/")
                && plistPath == agentsFolder + "/" + label + ".plist"
        }
    }

    /// `darwin`, `linux`, `windows`.
    public var os: String
    /// A hash of the machine's hardware id (`hostinfo.machine_id`).
    public var machineID: String?
    public var jobs: [Job]

    public init(os: String, machineID: String? = nil, jobs: [Job] = []) {
        self.os = os
        self.machineID = machineID
        self.jobs = jobs
    }

    public init(json: JSONValue) {
        os = json["os"]?.stringValue ?? ""
        machineID = json["machine_id"]?.stringValue
        jobs = json["jobs"].items.compactMap { row in
            guard let label = row["label"]?.stringValue, let role = row["role"]?.stringValue.flatMap(Job.Role.init(rawValue:)),
                  let plist = row["plist"]?.stringValue else { return nil }
            return Job(label: label, role: role, plistPath: plist, processType: row["process_type"]?.stringValue,
                       spawnType: row["spawn_type"]?.stringValue, pid: row["pid"]?.truncatedIntValue,
                       priority: row["priority"]?.truncatedIntValue)
        }
    }

    public var throttled: [Job] { jobs.filter(\.isThrottled) }

    /// The machine id as `hostinfo.machine_id` hashes it, from the raw hardware id.
    public static func machineID(hardwareUUID: String) -> String {
        String(SHA256.hash(data: Data(hardwareUUID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The Terminal steps that do what Run at Full Priority does, for one job: the plist, then a
    /// reload, unless the job still runs at full priority and only its next start would lose it.
    public static func command(for job: Job) -> String {
        let domain = "gui/$(id -u)"
        // The command runs as that user on that Mac, so their home is ~ wherever it is.
        let path = job.plistPath.replacing(/^\/(Users|home)\/[^\/]+\//, with: "~/")
        let edit = "plutil -replace ProcessType -string Interactive \(path)"
        if job.losesPriorityAtNextStart { return edit }
        return "\(edit) && launchctl bootout \(domain)/\(job.label); launchctl bootstrap \(domain) \(path)"
    }

    /// The gateway itself, when macOS throttles it or will from its next start.
    public var throttledGateway: Job? { os == "darwin" ? throttled.first { $0.role == .gateway } : nil }
}

extension AppPushClient {
    /// `/app-push host` (plugin 1.3.0 and later). An older plugin refuses it as an unknown command.
    public func host() async throws -> GatewayHostReport {
        GatewayHostReport(json: try await run("host")["host"] ?? .null)
    }
}

extension GatewaySetupFacts {
    /// What `/app-push host` said, or why there's nothing.
    public enum HostPriority: Sendable, Equatable {
        case report(GatewayHostReport)
        /// The plugin is older than `host`.
        case pluginTooOld
        /// No push plugin on the gateway.
        case noPlugin
        /// The gateway didn't answer.
        case failed
    }
}

extension GatewaySetup {
    /// Priority: whether macOS throttles Hermes's services on the gateway's Mac (`docs/setup.md`
    /// §4.17). Ready on other systems and on a Mac that runs them as Interactive.
    public static func priority(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Priority")
        let name = facts.gatewayName
        guard facts.botMode == .online else { return needsBotMode(id: ID.priority, title: title, facts) }
        switch facts.hostPriority {
        case nil:
            return .checking(id: ID.priority, title: title)
        case .noPlugin?:
            return .unknown(id: ID.priority, title: title,
                            reason: String(localized: "Hermes on \(name) can say how its Mac runs it once the Hermes app plugin is installed."))
        case .failed?:
            return .unknown(id: ID.priority, title: title,
                            reason: String(localized: "Hermes on \(name) didn't say how its Mac runs it."))
        case .pluginTooOld?:
            return SetupStatus(
                id: ID.priority, state: .unknown, title: title,
                detail: String(localized: "The Hermes app plugin on \(name) is too old to say how its Mac runs Hermes."),
                steps: [SetupStep(String(localized: "Update it in Settings → Setup → Hermes App Plugins, or on \(name):"), command: "hermes plugins update hermes-app-push")]
            )
        case .report(let report)?:
            guard report.os == "darwin" else {
                return SetupStatus(id: ID.priority, state: .ready, title: title,
                                   detail: String(localized: "Nothing on \(name) slows Hermes down when it's busy."))
            }
            let throttled = report.throttled
            guard !throttled.isEmpty else {
                return SetupStatus(id: ID.priority, state: .ready, title: title,
                                   detail: String(localized: "Hermes runs at full priority on \(name), so it keeps answering when the Mac is busy."))
            }
            var steps = prioritySteps(throttled, on: name)
            if throttled.contains(where: { $0.role == .gateway }) {
                steps.append(SetupStep(String(localized: "hermes update and hermes gateway start or restart write the gateway's plist again without it. When the app's own update or restart does, it says so and offers to put it back.")))
            }
            let later = throttled.allSatisfy(\.losesPriorityAtNextStart)
            let host = hostName(facts)
            return SetupStatus(
                id: ID.priority, state: .limited, title: title,
                detail: later
                    ? String(localized: "From its next start, macOS runs Hermes on \(host) as a background job, so when the Mac is busy it will answer late or not at all.")
                    : String(localized: "macOS runs Hermes on \(host) as a background job, so when the Mac is busy it answers late or not at all."),
                fallback: later ? String(localized: "It runs at full priority until then.")
                    : throttled.allSatisfy(\.needsReload) ? String(localized: "It's set to run at full priority from its next start.") : nil,
                fix: facts.hostIsThisMac ? SetupFix(title: String(localized: "Run at Full Priority…")) : nil,
                steps: steps
            )
        }
    }

    /// One Terminal step per throttled job, on the gateway's Mac.
    static func prioritySteps(_ throttled: [GatewayHostReport.Job], on name: String) -> [SetupStep] {
        throttled.map {
            SetupStep(String(localized: "For \($0.label), in Terminal on \(name):"), command: GatewayHostReport.command(for: $0))
        }
    }

    /// After the app's own update or restart (`docs/setup.md` §4.17): Hermes wrote the gateway's
    /// plist again without ProcessType, so macOS runs it as a background job, now or from its
    /// next start. `wasThrottled` is what the last read before the run said. Nil while it runs at
    /// full priority, and on other systems.
    public static func priorityReset(_ facts: GatewaySetupFacts, after kind: GatewayJob.Kind, wasThrottled: Bool) -> PriorityNotice? {
        guard case .report(let report)? = facts.hostPriority, let gateway = report.throttledGateway else { return nil }
        let name = hostName(facts)
        let headline = if wasThrottled {
            String(localized: "Hermes still runs at background priority")
        } else if kind == .update {
            String(localized: "Updating reset Hermes to background priority")
        } else {
            String(localized: "Restarting reset Hermes to background priority")
        }
        return PriorityNotice(
            headline: headline,
            detail: gateway.losesPriorityAtNextStart
                ? String(localized: "From its next start, macOS runs Hermes on \(name) as a background job, so when the Mac is busy it will answer late or not at all.")
                : String(localized: "macOS runs Hermes on \(name) as a background job, so when the Mac is busy it answers late or not at all."),
            canFixHere: facts.hostIsThisMac,
            steps: facts.hostIsThisMac ? [] : prioritySteps(report.throttled, on: facts.gatewayName)
        )
    }

    /// The gateway's Mac as the words name it: "this Mac" when it's the one the app runs on.
    static func hostName(_ facts: GatewaySetupFacts) -> String {
        facts.hostIsThisMac ? String(localized: "this Mac") : facts.gatewayName
    }

    /// The Mac's notice beside Settings while the gateway runs at background priority, until the
    /// person sets it back or says Not Now. Nil otherwise.
    public static func priorityNotice(_ facts: GatewaySetupFacts) -> PriorityNotice? {
        guard facts.botMode == .online, case .report(let report)? = facts.hostPriority, let gateway = report.throttledGateway else { return nil }
        let name = hostName(facts)
        let later = gateway.losesPriorityAtNextStart
        return PriorityNotice(
            headline: later ? String(localized: "Hermes is set to background priority") : String(localized: "Hermes runs at background priority"),
            detail: later
                ? String(localized: "From its next start, when \(name) is busy, Hermes will answer late or not at all.")
                : String(localized: "When \(name) is busy, Hermes answers late or not at all."),
            canFixHere: facts.hostIsThisMac,
            steps: facts.hostIsThisMac ? [] : prioritySteps(report.throttled, on: facts.gatewayName)
        )
    }

    /// Update Hermes's confirmation: on a Mac, the update also writes the gateway's plist again
    /// without full priority, and the app offers it back afterwards.
    public static func updateConfirmation(_ facts: GatewaySetupFacts) -> String {
        let message = String(localized: "Hermes updates itself, then restarts once running chats and tasks finish. The app reconnects by itself.")
        guard case .report(let report)? = facts.hostPriority, report.os == "darwin",
              report.jobs.contains(where: { $0.role == .gateway }) else { return message }
        return message + "\n\n" + String(localized: "Updating resets Hermes to background priority on \(hostName(facts)). The app offers to restore it when it's done.")
    }
}

/// Hermes on a Mac runs at background priority, said where the person sees it: on the result of an
/// update or restart the app ran, and on the Mac beside Settings (`docs/setup.md` §4.17).
public struct PriorityNotice: Sendable, Equatable {
    public var headline: String
    public var detail: String
    /// Run at Full Priority… does it: the gateway is on this Mac.
    public var canFixHere: Bool
    /// What to run on the gateway's Mac instead.
    public var steps: [SetupStep]

    public init(headline: String, detail: String, canFixHere: Bool, steps: [SetupStep] = []) {
        self.headline = headline
        self.detail = detail
        self.canFixHere = canFixHere
        self.steps = steps
    }
}
