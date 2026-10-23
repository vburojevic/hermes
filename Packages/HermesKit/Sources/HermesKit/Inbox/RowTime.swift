import Foundation

/// The time a row shows and sorts by (`docs/inbox.md` §2): the newest message its last line
/// shows, a person's or a Bot's. Hermes' `last_active` moves for more than messages (each turn's
/// heartbeat, compaction, a Bot's routine run in a session of its own), so it only stands in
/// while the line isn't read yet. Reading, opening or re-attaching a chat moves nothing.
public enum RowTime {
    /// - Parameters:
    ///   - line: the row's last line, with the time of the message it shows.
    ///   - live: a turn is running in the chat: the row may stand at its activity, and settles
    ///     back to its message's time when the reply ends.
    ///   - activity: Hermes' `last_active` for the chat the line is read from.
    ///   - created: when the chat (or the Bot) was made, for a row with no messages.
    public static func of(line: LastLine?, live: Bool = false, activity: Date?, created: Date?) -> Date? {
        of(messageAt: line?.at, live: live, activity: activity, created: created)
    }

    /// The same rule from the newest message's time (a group chat's log).
    public static func of(messageAt: Date?, live: Bool = false, activity: Date?, created: Date?) -> Date? {
        if live, let newest = [messageAt, activity].compactMap(\.self).max() { return newest }
        return messageAt ?? activity ?? created
    }

    /// A list's order: pinned first, then newest first by `time`; rows without one go last, and
    /// ties keep the order they came in.
    public static func ordered<Row>(_ rows: [Row], pinned: (Row) -> Bool, time: (Row) -> Date?) -> [Row] {
        let keys = rows.map { (pinned: pinned($0), time: time($0) ?? .distantPast) }
        return rows.indices.sorted { a, b in
            if keys[a].pinned != keys[b].pinned { return keys[a].pinned }
            return keys[a].time != keys[b].time ? keys[a].time > keys[b].time : a < b
        }.map { rows[$0] }
    }
}
