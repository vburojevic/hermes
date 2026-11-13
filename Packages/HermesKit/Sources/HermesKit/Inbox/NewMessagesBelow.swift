import Foundation

/// One row of a chat as the jump pill reads it (`docs/inbox.md` §4 The jump pill).
public struct PillRow: Hashable, Sendable {
    /// The identity the row is drawn under: what the scroll view reports on screen.
    public var key: String
    /// A message for the count (`UnreadCounter.counts`).
    public var counts: Bool
    /// A reply still working: it's news once it ends.
    public var isRunning: Bool

    public init(key: String, counts: Bool, isRunning: Bool = false) {
        self.key = key
        self.counts = counts
        self.isRunning = isRunning
    }

    public init(_ item: TranscriptItem, key: String) {
        self.key = key
        counts = UnreadCounter.counts(item)
        if case .assistant(let turn) = item { isRunning = turn.isWorking } else { isRunning = false }
    }

    /// A group chat's row: its members' messages count (`RoomTranscript.unread`).
    public init(_ item: RoomItem) {
        key = item.id
        if case .member = item { counts = true } else { counts = false }
        isRunning = false
    }
}

/// The new messages below the reader while they read further up, for the jump pill
/// (`docs/inbox.md` §4 The jump pill): every counted message after where they got to, in the
/// chat's order, however many came in one update and in whatever order their replies ended.
///
/// It also keeps the pill's two steps: the first tap goes to the first new message, the next to
/// the end. Messages arriving after the first tap, or scrolling back up past where it went, start
/// over at the first new message.
public struct NewMessagesBelow: Hashable, Sendable {
    /// Where a tap goes.
    public enum Target: Hashable, Sendable {
        case row(String)
        case end
    }

    /// Counting: the reader is up in the chat. Following the end, nothing is below.
    public private(set) var isTracking = false
    /// The new messages below, in the chat's order.
    public private(set) var keys: [String] = []
    /// Goes up each time messages arrive below, and never as they're seen or as rows change
    /// identity: the pill's tick.
    public private(set) var arrivals = 0

    /// The last row the reader got to and up to three before it, newest first, and the row after
    /// it. A row can change identity under the reader (a reply settling into the stored one, a
    /// reload), and one lost id alone then counted nothing again or everything: the place is found
    /// again by the row after it or by one before it.
    private var through: [String] = []
    private var next: String?
    /// Counted rows seen past a reply still running. The place waits in front of the reply, so it
    /// counts when it ends, and these don't count again.
    private var seenPast: Set<String> = []
    /// Replies running while the reader was up in the chat. A reply's stored copy can land above
    /// where the reader got to (it takes its place after the ask, above messages that came in while
    /// it ran), so each one is kept until it ends and counts then, wherever it lands.
    private var running: Set<String> = []
    /// Replies that ended above where the reader got to and haven't been on screen since.
    private var endedAbove: Set<String> = []
    /// Where the first tap went, and whether the reader has been there since.
    private var firstStep: String?
    private var landed = false

    public init() {}

    public var count: Int { keys.count }
    public var first: String? { keys.first }
    /// Nothing new, or the first tap already went to the first of it.
    public var nextTapGoesToEnd: Bool { keys.isEmpty || firstStep != nil }

    /// The reader left the end: everything there is seen, except replies still running.
    public mutating func leave(rows: [PillRow]) {
        guard !isTracking else { return }
        reset()
        isTracking = true
        let lastCounted = rows.lastIndex(where: \.counts) ?? -1
        let wall = rows[(lastCounted + 1)...].firstIndex(where: \.isRunning)
        anchor(at: (wall ?? rows.count) - 1, in: rows)
        running = Set(rows.filter(\.isRunning).map(\.key))
    }

    /// The chat opened at the New Messages line, above the row `lineKey`: it and every message
    /// after it are new.
    public mutating func open(at lineKey: String, rows: [PillRow]) {
        reset()
        guard let line = rows.firstIndex(where: { $0.key == lineKey }) else { return }
        isTracking = true
        anchor(at: line - 1, in: rows)
        running = Set(rows.filter(\.isRunning).map(\.key))
        keys = newKeys(after: line - 1, in: rows)
    }

    /// The reader is at the end, following it.
    public mutating func follow() {
        reset()
    }

    /// The rows or what's on screen changed. The rows on screen are seen, and so is everything
    /// above them.
    public mutating func update(rows: [PillRow], visible: [String]) {
        guard isTracking else { return }
        var place = resolve(in: rows)
        let shown = Set(visible)
        let lastShown = rows.lastIndex { shown.contains($0.key) }
        if let lastShown, lastShown > place {
            let wall = rows[(place + 1)...].firstIndex(where: \.isRunning).map { $0 - 1 } ?? rows.count - 1
            let reach = min(lastShown, wall)
            if lastShown > reach {
                for row in rows[(reach + 1)...lastShown] where row.counts { seenPast.insert(row.key) }
            }
            place = reach
        }
        anchor(at: place, in: rows)
        seenPast.formIntersection(rows[(place + 1)...].map(\.key))
        settle(rows: rows, place: place, shown: shown)
        let fresh = newKeys(after: place, in: rows)
        let before = Set(keys)
        if fresh.count > keys.count, fresh.contains(where: { !before.contains($0) }) {
            arrivals += 1
            firstStep = nil
        }
        if let step = firstStep, let target = rows.firstIndex(where: { $0.key == step }) {
            if shown.contains(step) {
                landed = true
            } else if landed, let lastShown, lastShown < target {
                firstStep = nil // scrolled back up past it
            }
        }
        if fresh.isEmpty || firstStep == nil { firstStep = nil; landed = false }
        keys = fresh
    }

    /// The pill was tapped: the first new message, or the end once the first tap went there.
    /// Following the end afterwards (`follow`) clears the count.
    public mutating func tap() -> Target {
        if let first = keys.first, firstStep == nil {
            firstStep = first
            landed = false
            return .row(first)
        }
        firstStep = nil
        landed = false
        return .end
    }

    /// Replies that ended since the last update: one that landed above the place counts, unless
    /// it's on screen now. One below it counts like any other message.
    private mutating func settle(rows: [PillRow], place: Int, shown: Set<String>) {
        var index: [String: Int] = [:]
        for (offset, row) in rows.enumerated() { index[row.key] = offset }
        for key in running {
            guard let at = index[key] else { running.remove(key); continue }
            guard !rows[at].isRunning else { continue }
            running.remove(key)
            if at <= place, rows[at].counts, !shown.contains(key) { endedAbove.insert(key) }
        }
        running.formUnion(rows.filter(\.isRunning).map(\.key))
        endedAbove = endedAbove.filter { index[$0] != nil && !shown.contains($0) }
    }

    private mutating func reset() {
        let ticks = arrivals
        self = NewMessagesBelow()
        arrivals = ticks
    }

    /// The index of the place in `rows`, -1 before the first row.
    private func resolve(in rows: [PillRow]) -> Int {
        if let key = through.first, let index = rows.lastIndex(where: { $0.key == key }) { return index }
        if let next, let index = rows.lastIndex(where: { $0.key == next }) { return index - 1 }
        for (distance, key) in through.enumerated().dropFirst() {
            if let index = rows.lastIndex(where: { $0.key == key }) { return min(index + distance, rows.count - 1) }
        }
        // Lost altogether: nothing below counts, rather than the whole chat.
        return rows.count - 1
    }

    private mutating func anchor(at place: Int, in rows: [PillRow]) {
        through = place < 0 ? [] : rows[max(0, place - 3)...place].reversed().map(\.key)
        next = place + 1 < rows.count ? rows[place + 1].key : nil
    }

    private func newKeys(after place: Int, in rows: [PillRow]) -> [String] {
        rows.indices.filter { at in
            endedAbove.contains(rows[at].key) || (at > place && rows[at].counts && !seenPast.contains(rows[at].key))
        }.map { rows[$0].key }
    }
}
