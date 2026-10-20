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

        /// Throttled: loaded as anything but interactive, or, when it isn't loaded, set up that way.
        public var isThrottled: Bool {
            if let spawnType { return spawnType != "interactive" }
            return processType != "Interactive"
        }

        /// Its plist already says Interactive; only a reload is missing.
        public var needsReload: Bool { isThrottled && processType == "Interactive" }

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

    /// The Terminal steps that do what Run at Full Priority does, for one job.
    public static func command(for job: Job) -> String {
        let domain = "gui/$(id -u)"
        // The command runs as that user on that Mac, so their home is ~ wherever it is.
        let path = job.plistPath.replacing(/^\/(Users|home)\/[^\/]+\//, with: "~/")
        return "plutil -replace ProcessType -string Interactive \(path) && launchctl bootout \(domain)/\(job.label); launchctl bootstrap \(domain) \(path)"
    }
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
            var steps = throttled.map {
                SetupStep(String(localized: "For \($0.label), in Terminal on \(name):"), command: GatewayHostReport.command(for: $0))
            }
            if throttled.contains(where: { $0.role == .gateway }) {
                steps.append(SetupStep(String(localized: "hermes update and hermes gateway start or restart write the gateway's plist again without it, so check here after updating.")))
            }
            return SetupStatus(
                id: ID.priority, state: .limited, title: title,
                detail: String(localized: "macOS runs Hermes on \(name) as a background job, so when the Mac is busy it answers late or not at all."),
                fallback: throttled.allSatisfy(\.needsReload)
                    ? String(localized: "It's set to run at full priority from its next start.") : nil,
                fix: facts.hostIsThisMac ? SetupFix(title: String(localized: "Run at Full Priority…")) : nil,
                steps: steps
            )
        }
    }
}
