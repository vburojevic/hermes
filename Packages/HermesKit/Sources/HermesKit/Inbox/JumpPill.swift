import Foundation

/// What the pill over the composer says while you read further up (`newMessagesPill`,
/// `docs/inbox.md` §4 The jump pill). Mentions first, then new messages, then the running turn;
/// with nothing below, the round arrow to the latest.
public enum JumpPill: Hashable, Sendable {
    /// "Ada mentioned you": jumps to the mention.
    case mention(name: String, rowID: String)
    /// "2 new messages": jumps to the first new one (the line), then to the bottom.
    case newMessages(count: Int, firstRowID: String)
    /// The turn still running below: the activity line.
    case live
    /// The round arrow (`Transcript.scrollToLatest`).
    case latest

    /// - Parameters:
    ///   - mention: the first mention of you below the view not yet seen (group chats).
    ///   - newCount: messages that arrived below while you were reading up.
    ///   - firstNewRowID: the first of them (or the New Messages line).
    ///   - isLive: a turn is running.
    public static func choose(mention: (name: String, rowID: String)?, newCount: Int, firstNewRowID: String?, isLive: Bool) -> JumpPill {
        if let mention { return .mention(name: mention.name, rowID: mention.rowID) }
        if newCount > 0, let firstNewRowID { return .newMessages(count: newCount, firstRowID: firstNewRowID) }
        if isLive { return .live }
        return .latest
    }

    /// Where a tap goes: a row, or nil for the bottom.
    public var target: String? {
        switch self {
        case .mention(_, let rowID): rowID
        case .newMessages(_, let rowID): rowID
        case .live, .latest: nil
        }
    }
}

/// The time on a row (`docs/inbox.md` §2): "now", "2 min", "14:21", "Yesterday", "Thu", "12 Oct".
/// The app words it; this decides which.
public enum InboxTime: Hashable, Sendable {
    case now
    case minutes(Int)
    case time(Date)
    case yesterday
    case weekday(Date)
    case date(Date)

    public init(_ date: Date, now: Date = .now, calendar: Calendar = .current) {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            self = .now
        } else if interval < 3600 {
            self = .minutes(Int(interval / 60))
        } else if calendar.isDate(date, inSameDayAs: now) {
            self = .time(date)
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            self = .yesterday
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            self = .weekday(date)
        } else {
            self = .date(date)
        }
    }
}
