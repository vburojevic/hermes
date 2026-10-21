import Foundation

/// Debug timing for opening chats (`-HERMES_LOAD_LOG YES`): prints how long each step took since
/// the chat was asked to load. With `-HERMES_LAUNCH_LOG YES` each line also says when it came
/// after the app started (`LaunchTrace`). Compiled out of Release builds.
enum LoadTrace {
    #if DEBUG
    nonisolated(unsafe) private static var start: [String: Date] = [:]
    private static let enabled = UserDefaults.standard.bool(forKey: "HERMES_LOAD_LOG") || LaunchTrace.enabled
    #endif

    // `@autoclosure`: the steps' text (row counts, matches) costs work, and release builds log nothing.
    static func begin(_ key: String, _ step: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        start[key] = .now
        print("LOADTRACE [\(key)] +0ms\(LaunchTrace.since) \(step())")
        #endif
    }

    static func mark(_ key: String?, _ step: @autoclosure () -> String) {
        #if DEBUG
        guard enabled, let key else { return }
        let ms = start[key].map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? -1
        print("LOADTRACE [\(key)] +\(ms)ms\(LaunchTrace.since) \(step())")
        #endif
    }
}

/// Debug timing for a cold launch (`-HERMES_LAUNCH_LOG YES`, `docs/development.md`): each step
/// once, with its time since the process started, so the time before `main` counts too.
enum LaunchTrace {
    #if DEBUG
    static let enabled = UserDefaults.standard.bool(forKey: "HERMES_LAUNCH_LOG")
    nonisolated(unsafe) private static var seen: Set<String> = []

    /// When the kernel started this process.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return .now }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }()

    /// " L+812ms" for the other traces' lines, or nothing.
    static var since: String {
        enabled ? " L+\(Int(Date.now.timeIntervalSince(processStart) * 1000))ms" : ""
    }
    #endif

    /// A step, the first time it happens (`id` tells apart steps whose words carry counts).
    static func mark(_ step: @autoclosure () -> String, id: String? = nil) {
        #if DEBUG
        guard enabled else { return }
        let words = step()
        guard seen.insert(id ?? words).inserted else { return }
        print("LAUNCHTRACE L+\(Int(Date.now.timeIntervalSince(processStart) * 1000))ms \(words)")
        #endif
    }
}
