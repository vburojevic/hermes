#if os(macOS)
import Darwin
import Foundation
import HermesKit
import IOKit
import OSLog

/// Hermes's launchd jobs on this Mac (`docs/setup.md` §4.17): whether a gateway runs here, the
/// report the push plugin would give when it's too old to, and Run at Full Priority. The Mac app
/// isn't sandboxed, so it can read and change the person's own LaunchAgents.
enum LocalLaunchJobs {
    private nonisolated static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "launch-jobs")

    /// `-HERMES_LAUNCH_AGENTS_DIR <folder>` (Debug): a stand-in folder for checks, and `launchctl`
    /// only logged, never run.
    private nonisolated static var debugFolder: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_LAUNCH_AGENTS_DIR")
        #else
        nil
        #endif
    }

    nonisolated static var agentsFolder: String { debugFolder ?? NSHomeDirectory() + "/Library/LaunchAgents" }

    /// This Mac's hardware id, hashed the way the push plugin hashes its own.
    nonisolated static let machineID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return uuid.map(GatewayHostReport.machineID(hardwareUUID:))
    }()

    /// Whether `host` is this Mac: a loopback name, or a name that resolves to an address one of
    /// its interfaces has (a Tailscale name resolves to the Mac's tailnet address). It looks the
    /// name up, so call it off the main actor.
    nonisolated static func isThisMac(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return false }
        defer { freeaddrinfo(first) }
        var resolved: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            if let address = numericHost(entry.pointee.ai_addr, length: entry.pointee.ai_addrlen) { resolved.insert(address) }
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let list = interfaces else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: list, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let length = socklen_t(address.pointee.sa_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
            if let local = numericHost(address, length: length), resolved.contains(local) { return true }
        }
        return false
    }

    private nonisolated static func numericHost(_ address: UnsafeMutablePointer<sockaddr>?, length: socklen_t) -> String? {
        guard let address, [sa_family_t(AF_INET), sa_family_t(AF_INET6)].contains(address.pointee.sa_family) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// The report `/app-push host` gives, read on this Mac: Hermes's gateways and the dashboards
    /// (and their proxies) among its `ai.hermes.*` LaunchAgents.
    nonisolated static func report() -> GatewayHostReport {
        let folder = agentsFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var jobs: [GatewayHostReport.Job] = []
        for name in names.sorted() where name.hasPrefix("ai.hermes.") && name.hasSuffix(".plist") {
            let path = folder + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            let arguments = (plist["ProgramArguments"] as? [String] ?? []).joined(separator: " ").lowercased()
            let role: GatewayHostReport.Job.Role
            if label.hasPrefix("ai.hermes.gateway") {
                role = .gateway
            } else if arguments.contains("dashboard") || " \(arguments)".contains(" serve") {
                role = .dashboard
            } else {
                continue
            }
            let printed = run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).output
            let spawn = printed.firstMatch(of: /spawn type = (\w+)/).map { String($0.1) }
            let pid = printed.firstMatch(of: /\n\s*pid = (\d+)/).flatMap { Int($0.1) }
            let priority = pid.flatMap { Int(run("/bin/ps", ["-o", "pri=", "-p", String($0)]).output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            jobs.append(GatewayHostReport.Job(label: label, role: role, plistPath: path, processType: plist["ProcessType"] as? String,
                                              spawnType: spawn, pid: pid, priority: priority))
        }
        return GatewayHostReport(os: "darwin", machineID: machineID, jobs: jobs)
    }

    /// Run at Full Priority: each job's plist gets `ProcessType Interactive`, then launchd reloads
    /// it (`bootout` and `bootstrap`; `kickstart` doesn't read the plist again), unless it still
    /// runs at full priority and only its next start would lose it. Dashboards first, the gateway
    /// last. Only Hermes's own jobs in the LaunchAgents folder are touched. Returns
    /// the labels that didn't come back.
    nonisolated static func runAtFullPriority(_ jobs: [GatewayHostReport.Job]) -> [String] {
        let folder = agentsFolder
        var failed: [String] = []
        for job in jobs.filter({ $0.isSafeToChange(agentsFolder: folder) }).sorted(by: { ($0.role == .gateway ? 1 : 0) < ($1.role == .gateway ? 1 : 0) }) {
            do {
                try setInteractive(at: job.plistPath)
            } catch {
                logger.error("couldn't set \(job.label, privacy: .public) Interactive: \(String(describing: type(of: error)), privacy: .public)")
                failed.append(job.label)
                continue
            }
            // Still running at full priority (Hermes rewrote the plist since it started): the plist
            // is all its next start reads, so nothing restarts.
            if job.losesPriorityAtNextStart { continue }
            if !reload(job) { failed.append(job.label) }
        }
        return failed
    }

    /// Adds `ProcessType Interactive`. As text, so the rest of the file (the comments Hermes
    /// writes in its gateway plist) stays as it is; rewritten as a property list when it already
    /// names another type.
    nonisolated static func setInteractive(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if plist["ProcessType"] as? String == "Interactive" { return }
        if plist["ProcessType"] == nil, format == .xml, var text = String(data: data, encoding: .utf8),
           let end = text.range(of: "</dict>", options: .backwards) {
            let lineStart = text[..<end.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? end.lowerBound
            let indent = text.contains("\n\t<key>") ? "\t" : "    "
            text.insert(contentsOf: "\(indent)<key>ProcessType</key>\n\(indent)<string>Interactive</string>\n", at: lineStart)
            let edited = Data(text.utf8)
            let check = try PropertyListSerialization.propertyList(from: edited, format: nil) as? [String: Any]
            if check?["ProcessType"] as? String == "Interactive", check?.count == plist.count + 1 {
                try edited.write(to: url, options: .atomic)
                return
            }
        }
        plist["ProcessType"] = "Interactive"
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url, options: .atomic)
    }

    /// Unloads the job, waits for its process to go (launchd allows a gateway 60 s to drain), and
    /// loads it again, retrying while launchd still holds the old one.
    private nonisolated static func reload(_ job: GatewayHostReport.Job) -> Bool {
        let domain = "gui/\(getuid())"
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(job.label)"])
        if let pid = job.pid, debugFolder == nil {
            for _ in 0..<35 where kill(pid_t(pid), 0) == 0 { Thread.sleep(forTimeInterval: 2) }
        }
        for attempt in 0..<12 {
            if run("/bin/launchctl", ["bootstrap", domain, job.plistPath]).status == 0 { return true }
            if attempt < 11 { Thread.sleep(forTimeInterval: 5) }
        }
        logger.error("launchd didn't load \(job.label, privacy: .public) again")
        return false
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        #if DEBUG
        if debugFolder != nil, tool == "/bin/launchctl", arguments.first != "print" {
            print("HERMES_LAUNCHCTL", arguments.joined(separator: " "))
            return (0, "")
        }
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
#endif
