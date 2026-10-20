import Foundation

/// Muted chats and Bots on this device (`docs/inbox.md` §1 Muting). The gateway has no such
/// setting. A muted chat keeps its count (grey), stays out of the badges and is delivered quietly.
public struct MuteList: Codable, Hashable, Sendable {
    /// For how long (Mute ▸).
    public enum Duration: String, CaseIterable, Sendable {
        case hour, eightHours, week, untilTurnedOff

        public func end(from now: Date) -> Date {
            switch self {
            case .hour: now.addingTimeInterval(3600)
            case .eightHours: now.addingTimeInterval(8 * 3600)
            case .week: now.addingTimeInterval(7 * 86_400)
            case .untilTurnedOff: .distantFuture
            }
        }
    }

    /// Chat key (a session's stable id, `bot:<name>`, `group:<id>`) → when the mute ends.
    public private(set) var ends: [String: Date]

    public init(ends: [String: Date] = [:]) {
        self.ends = ends
    }

    public func isMuted(_ key: String, now: Date = .now) -> Bool {
        guard let end = ends[key] else { return false }
        return end > now
    }

    /// When the mute ends; nil when it isn't muted. `.distantFuture`: until turned off.
    public func end(of key: String, now: Date = .now) -> Date? {
        isMuted(key, now: now) ? ends[key] : nil
    }

    public mutating func mute(_ key: String, for duration: Duration, now: Date = .now) {
        ends[key] = duration.end(from: now)
    }

    public mutating func unmute(_ key: String) {
        ends[key] = nil
    }

    /// Drops mutes that ended. Returns whether any did.
    @discardableResult
    public mutating func prune(now: Date = .now) -> Bool {
        let before = ends.count
        ends = ends.filter { $0.value > now }
        return ends.count != before
    }

    /// The next time a mute ends, to redraw then.
    public func nextEnd(after now: Date = .now) -> Date? {
        ends.values.filter { $0 > now && $0 != .distantFuture }.min()
    }
}
