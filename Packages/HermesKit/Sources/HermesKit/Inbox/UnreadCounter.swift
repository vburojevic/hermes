import Foundation

/// Counts what's new in a chat (`docs/inbox.md` §1 Counting). Hermes has no unread count; the
/// app counts the chat's latest messages after the read mark.
///
/// What counts as a message: each reply that ended a turn (the answer after the steps, however
/// many tool calls it made), each Bot's message in the chat (`message_agent`, a group member) and
/// each routine delivery. Narration, tool steps, reasoning, notices, run events (a background
/// process's heartbeats), a reply that is only a silence marker, compaction summaries, your own
/// messages and your own commands' results don't.
public enum UnreadCounter {
    /// The most a badge says: "99+".
    public static let cap = 99

    public static func label(_ count: Int) -> String {
        count > cap ? "\(cap)+" : "\(count)"
    }

    /// Whether `item` is a message for the count. A compaction summary isn't, whoever it's stored as.
    public static func counts(_ item: TranscriptItem) -> Bool {
        if item.isCompactionSummary { return false }
        return switch item {
        // A reply that says nothing ("[SILENT]", answering a run event) isn't news, shown or not.
        case .assistant(let turn): !turn.isWorking && !turn.answer.isEmpty && !BotMentions.isSilenceMarker(turn.answer)
        case .user(let entry): !entry.isFromPerson
        case .command, .notice: false
        }
    }

    /// When a counted message landed: a reply when it ended.
    static func landedTime(of item: TranscriptItem) -> Date? {
        if case .assistant(let turn) = item { return turn.finishedAt ?? turn.startedAt }
        return startTime(of: item)
    }

    /// When a row started, for walking back to the head of the first new turn.
    static func startTime(of item: TranscriptItem) -> Date? {
        switch item {
        case .user(let entry): entry.timestamp
        case .assistant(let turn): turn.startedAt
        case .command(let command): command.timestamp
        case .notice: nil
        }
    }

    /// Messages that landed after `since`. A message without a time isn't counted: rows from
    /// the gateway always carry one.
    public static func count(_ items: [TranscriptItem], after since: Date) -> Int {
        items.reduce(0) { total, item in
            guard counts(item), let time = landedTime(of: item) else { return total }
            return time.timeIntervalSince(since) > ReadMark.slack ? total + 1 : total
        }
    }
}

/// Where the New Messages line goes in a chat (`docs/inbox.md` §4 Opening a chat), and how many
/// messages are below it.
public struct NewMessagesMarker: Hashable, Sendable {
    /// The row the line sits above: the head of the first new turn.
    public var rowID: String
    /// Counted messages from there on ("2 new messages").
    public var count: Int

    public init(rowID: String, count: Int) {
        self.rowID = rowID
        self.count = count
    }

    /// The line for a chat opened with unread messages.
    /// - Parameters:
    ///   - since: the gateway's read mark (`last_read_at`), when it's a time.
    ///   - seenThrough: the last row this device showed (the device-local "seen up to"). A chat
    ///     left half-way gets its line after the last message seen, even when the gateway's mark
    ///     is older (it only ever means "read until now").
    /// - Returns: nil when nothing counted is new.
    public static func find(in items: [TranscriptItem], since: Date?, seenThrough: String?) -> NewMessagesMarker? {
        guard since != nil || seenThrough != nil else { return nil }
        let seenIndex = seenThrough.flatMap { id in items.lastIndex { $0.id == id } }
        func isNew(_ index: Int, time: Date?) -> Bool {
            if let seenIndex, index <= seenIndex { return false }
            // Read further on another device: only what came after that.
            if let since {
                guard let time else { return false }
                return time.timeIntervalSince(since) > ReadMark.slack
            }
            return seenIndex != nil
        }
        var first: Int?
        var count = 0
        for (index, item) in items.enumerated() {
            guard UnreadCounter.counts(item), isNew(index, time: UnreadCounter.landedTime(of: item)) else { continue }
            if first == nil { first = index }
            count += 1
        }
        guard var start = first else { return nil }
        // Back to the head of that turn: rows before it that are new too (the message that
        // started it from Telegram, a routine's prompt), not your own message read before.
        while start > 0 {
            let previous = items[start - 1]
            guard !UnreadCounter.counts(previous), case .user = previous else { break }
            guard isNew(start - 1, time: UnreadCounter.startTime(of: previous)) else { break }
            start -= 1
        }
        return NewMessagesMarker(rowID: items[start].id, count: count)
    }
}
