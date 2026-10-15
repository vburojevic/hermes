import Foundation
import os

/// Connection events (the gateway and Bot Mode) in the system log, so a drop can be traced
/// afterwards:
/// `log show --last 2h --predicate 'subsystem == "co.caffeinatedcode.hermes" && category == "connection"'`
nonisolated enum ConnectionLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes", category: "connection")
}
