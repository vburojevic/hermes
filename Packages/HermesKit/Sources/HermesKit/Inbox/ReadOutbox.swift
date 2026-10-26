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

/// Reads made on this device on their way to the push plugin (`read`, `docs/notifications.md` §2
/// Reading), per gateway: the person's other devices drop them from their badges when it hears.
/// Kept until the plugin has them, so a read made while the gateway can't be reached (offline, the
/// plugin not checked yet, a Mac app that never came to the front) still goes, once, when it can.
/// A read whose chat has news since it was read doesn't go: the plugin stamps a read when it hears
/// it, and would count that news as read. Nor does one whose chat this device doesn't know yet (the
/// list not fetched since launch): it waits until the list says whether the chat moved.
public struct PushReadQueue: Codable, Sendable, Equatable {
    /// Chats (session ids) and group chats (room ids), each with how far it was read: its newest
    /// activity then, on the gateway's clock (this device's when it doesn't know).
    public private(set) var chats: [String: Date] = [:]
    public private(set) var rooms: [String: Date] = [:]
    /// When each read whose chat wasn't known was first held back, by id ("room:" for rooms).
    public private(set) var held: [String: Date] = [:]
    public private(set) var attempts = 0
    public private(set) var nextTry = Date.distantPast
    /// A batch is on its way: nothing else goes until it's answered. Not kept: a batch whose answer
    /// a quit lost goes again at the next launch, if its chats are still current.
    public private(set) var isSending = false

    /// What one `read` names: the plugin takes 50 of each.
    public static let batchLimit = 50
    /// How long a read waits for its chat to be known: the plugin remembers reads for six hours.
    public static let holdLimit: TimeInterval = 6 * 3600

    public struct Batch: Sendable, Equatable {
        public var chats: [String: Date]
        public var rooms: [String: Date]

        public var isEmpty: Bool { chats.isEmpty && rooms.isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case chats, rooms, held, attempts, nextTry }

    public init() {}

    public var isEmpty: Bool { chats.isEmpty && rooms.isEmpty }

    /// Read here now: replaces an earlier read of the same chat, and goes at once. `lastActive`
    /// says when a chat, by id, or a room last moved; nil when this device doesn't know.
    public mutating func add(chats: some Sequence<String>, rooms: some Sequence<String>, now: Date = .now,
                             lastActive: (_ id: String, _ isRoom: Bool) -> Date?) {
        for id in chats where !id.isEmpty { self.chats[id] = max(self.chats[id] ?? .distantPast, lastActive(id, false) ?? now) }
        for id in rooms where !id.isEmpty { self.rooms[id] = max(self.rooms[id] ?? .distantPast, lastActive(id, true) ?? now) }
        nextTry = min(nextTry, now)
    }

    public func isDue(now: Date = .now) -> Bool {
        !isEmpty && !isSending && nextTry <= now
    }

    /// The next reads to send, oldest first. One whose chat has news since it was read is dropped
    /// for good; one whose chat this device doesn't know is held back, and dropped once it has waited
    /// `holdLimit`. Nil when nothing is due.
    public mutating func take(now: Date = .now, lastActive: (_ id: String, _ isRoom: Bool) -> Date?) -> Batch? {
        guard isDue(now: now) else { return nil }
        var ready: (chats: [String: Date], rooms: [String: Date]) = ([:], [:])
        var stillHeld: [String: Date] = [:]
        let wasHeld = held
        func sort(_ id: String, _ through: Date, isRoom: Bool) -> Bool {
            let key = isRoom ? "room:\(id)" : id
            guard let active = lastActive(id, isRoom) else {
                let since = wasHeld[key] ?? now
                guard now.timeIntervalSince(since) < Self.holdLimit else { return false }
                stillHeld[key] = since
                return true
            }
            guard active.timeIntervalSince(through) <= 0.5 else { return false }
            if isRoom { ready.rooms[id] = through } else { ready.chats[id] = through }
            return true
        }
        chats = chats.filter { sort($0.key, $0.value, isRoom: false) }
        rooms = rooms.filter { sort($0.key, $0.value, isRoom: true) }
        held = stillHeld
        func oldest(_ reads: [String: Date]) -> [String: Date] {
            Dictionary(uniqueKeysWithValues: reads.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.prefix(Self.batchLimit).map { ($0.key, $0.value) })
        }
        let batch = Batch(chats: oldest(ready.chats), rooms: oldest(ready.rooms))
        guard !batch.isEmpty else { return nil }
        isSending = true
        return batch
    }

    /// The plugin has them: they're done, unless one was read again since it went.
    public mutating func sent(_ batch: Batch) {
        isSending = false
        attempts = 0
        for (id, through) in batch.chats where chats[id].map({ $0 <= through }) ?? false { chats[id] = nil }
        for (id, through) in batch.rooms where rooms[id].map({ $0 <= through }) ?? false { rooms[id] = nil }
        if !isEmpty { nextTry = .distantPast }
    }

    /// Reads held back until their chat is known: they go when the list next comes in.
    public var isHolding: Bool {
        !held.isEmpty
    }

    /// Didn't reach the plugin: tried again after 5 s, 15 s, 45 s, then up to every 5 minutes, and
    /// at once when the gateway comes back (`retryNow`).
    public mutating func failed(now: Date = .now) {
        isSending = false
        attempts += 1
        nextTry = now.addingTimeInterval(ReadOutbox.backoff(after: attempts))
    }

    /// The gateway came back: what waits goes now, not at the end of its backoff.
    public mutating func retryNow() {
        nextTry = .distantPast
    }

    /// Nowhere to send them (the gateway has no push plugin, or an older one without `read`).
    public mutating func clear() {
        self = PushReadQueue()
    }
}
