import Foundation

/// Read marks on their way to the gateway (`docs/inbox.md` §4): a mark that couldn't be sent (the
/// gateway busy or offline) waits here, as a message waits in the send outbox, and goes when it
/// can. Hermes keeps one mark per chat and stamps it "now" when it lands, so a waiting mark only
/// goes while nothing new has come into the chat since it was read (sending it then would mark
/// what wasn't seen); and marks only move forward.
public struct ReadOutbox: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The chat (`UnreadStore` key: a session's stable key, `bot:<profile>`).
        public var key: String
        /// The chat's newest activity when it was read.
        public var through: Date
        public var attempts: Int
        public var nextTry: Date
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// A read to send: replaces a waiting one for the same chat only if it reaches further.
    public mutating func queue(_ key: String, through: Date, now: Date = .now) {
        if let waiting = entries[key], waiting.through >= through { return }
        entries[key] = Entry(key: key, through: through, attempts: 0, nextTry: now)
    }

    /// The marks whose turn it is.
    public func due(now: Date = .now) -> [Entry] {
        entries.values.filter { $0.nextTry <= now }.sorted { $0.key < $1.key }
    }

    /// It landed: done, unless a later read is waiting for the same chat.
    public mutating func sent(_ key: String, through: Date) {
        if let waiting = entries[key], waiting.through <= through { entries[key] = nil }
    }

    /// Didn't land: tried again after 5 s, 15 s, 45 s, then up to every 5 minutes.
    public mutating func failed(_ key: String, now: Date = .now) {
        guard var entry = entries[key] else { return }
        entry.attempts += 1
        entry.nextTry = now.addingTimeInterval(Self.backoff(after: entry.attempts))
        entries[key] = entry
    }

    public mutating func drop(_ key: String) {
        entries[key] = nil
    }

    public static func backoff(after attempts: Int) -> TimeInterval {
        min(300, 5 * pow(3, Double(max(0, attempts - 1))))
    }

    /// Still worth sending: nothing came into the chat after it was read.
    public static func isCurrent(_ entry: Entry, lastActive: Date?) -> Bool {
        guard let lastActive else { return true }
        return lastActive.timeIntervalSince(entry.through) <= 0.5
    }
}

/// One read mark per chat every `interval` while the chat keeps moving (a Bot working on screen):
/// the first goes at once, the next waits out the window and carries everything seen meanwhile.
public struct ReadThrottle: Sendable {
    public let interval: TimeInterval
    private var lastSent: [String: Date] = [:]

    public init(interval: TimeInterval = 10) {
        self.interval = interval
    }

    /// How long a mark for this chat must wait: 0 to send now.
    public func wait(for key: String, now: Date = .now) -> TimeInterval {
        guard let last = lastSent[key] else { return 0 }
        return max(0, interval - now.timeIntervalSince(last))
    }

    public mutating func sent(_ key: String, at date: Date = .now) {
        lastSent[key] = date
    }
}
