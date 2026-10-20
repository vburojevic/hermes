import Foundation

/// Hermes' read mark for a chat, `last_read_at` (`docs/inbox.md` §1). One per chat, shared by
/// every device and Hermes Desktop.
public enum ReadMark: Hashable, Sendable, Codable {
    /// `null`: never tracked, so read.
    case untracked
    /// `0`: marked unread by hand. The row shows a dot, not a count.
    case markedUnread
    /// Read up to then (the gateway's clock).
    case readUntil(Date)

    public init(lastReadAt seconds: Double?) {
        guard let seconds else { self = .untracked; return }
        self = seconds > 0 ? .readUntil(Date(timeIntervalSince1970: seconds)) : .markedUnread
    }

    /// How far the gateway says the chat was read; nil when it isn't tracked or was marked unread.
    public var readUntil: Date? {
        if case .readUntil(let date) = self { return date }
        return nil
    }

    /// Unread = `last_active > last_read_at`. Half a second of slack: Hermes stamps the mark with
    /// its own clock as the last write lands.
    public func isUnread(lastActive: Date?) -> Bool {
        switch self {
        case .untracked: false
        case .markedUnread: true
        case .readUntil(let read): (lastActive?.timeIntervalSince(read) ?? 0) > ReadMark.slack
        }
    }

    static let slack: TimeInterval = 0.5
}

/// What a row says about what's new (`docs/inbox.md` §2): a count, the "marked unread" dot, or
/// nothing.
public enum UnreadBadge: Hashable, Sendable {
    case none
    case dot
    case count(Int)

    public var isUnread: Bool { self != .none }

    /// "3", "99+".
    public var label: String? {
        guard case .count(let count) = self else { return nil }
        return UnreadCounter.label(count)
    }
}
