import Foundation

/// The chat list's last lines (`docs/inbox.md` §2), each with the chat activity it was read at.
///
/// Reads come back in any order: a chat's newest rows asked for before a reply landed can arrive
/// after the open chat showed that reply. So a line read at an earlier activity never replaces one
/// read at a later activity, and a chat whose activity moved past its line is read again. Kept on
/// the device (`LastLinesCache`), so a launch shows each row's last message before the gateway
/// answers.
public struct LastLineBook: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var line: LastLine
        /// The chat's activity the line was read at: its newest message then, or when the open
        /// chat showed it.
        public var asOf: Date
    }

    /// How far a chat's activity may run ahead of its line before it's read again: the gateway
    /// stamps a row a moment after the app shows it.
    static let slack: TimeInterval = 1
    /// The lines kept: every row a list shows, with room to spare.
    static let capacity = 400

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public subscript(key: String) -> LastLine? {
        entries[key]?.line
    }

    /// Takes `line` unless the one there was read at a later activity. Returns whether the row's
    /// line changed.
    @discardableResult
    public mutating func note(_ key: String, _ line: LastLine?, asOf: Date) -> Bool {
        guard let line else { return false }
        if let kept = entries[key], kept.asOf > asOf { return false }
        let changed = entries[key]?.line != line
        entries[key] = Entry(line: line, asOf: asOf)
        if entries.count > Self.capacity { trim() }
        return changed
    }

    /// The chat moved on since its line was read (or it has none): read it again.
    public func isStale(_ key: String, activity: Date?) -> Bool {
        guard let entry = entries[key] else { return true }
        guard let activity else { return false }
        return activity.timeIntervalSince(entry.asOf) > Self.slack
    }

    /// Lines kept on the device, under the ones read since (a newer read wins).
    public mutating func merge(_ other: LastLineBook) {
        for (key, entry) in other.entries {
            if let kept = entries[key], kept.asOf >= entry.asOf { continue }
            entries[key] = entry
        }
        if entries.count > Self.capacity { trim() }
    }

    private mutating func trim() {
        let kept = entries.sorted { $0.value.asOf > $1.value.asOf }.prefix(Self.capacity)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
