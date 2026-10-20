import Foundation

/// Debug timing for opening chats (`-HERMES_LOAD_LOG YES`): prints how long each step took since
/// the chat was asked to load. Compiled out of Release builds.
enum LoadTrace {
    #if DEBUG
    nonisolated(unsafe) private static var start: [String: Date] = [:]
    private static let enabled = UserDefaults.standard.bool(forKey: "HERMES_LOAD_LOG")
    #endif

    // `@autoclosure`: the steps' text (row counts, matches) costs work, and release builds log nothing.
    static func begin(_ key: String, _ step: @autoclosure () -> String) {
        #if DEBUG
        guard enabled else { return }
        start[key] = .now
        print("LOADTRACE [\(key)] +0ms \(step())")
        #endif
    }

    static func mark(_ key: String?, _ step: @autoclosure () -> String) {
        #if DEBUG
        guard enabled, let key else { return }
        let ms = start[key].map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? -1
        print("LOADTRACE [\(key)] +\(ms)ms \(step())")
        #endif
    }
}
