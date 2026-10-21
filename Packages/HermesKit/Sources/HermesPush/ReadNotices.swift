import Foundation

/// Chats read lately and when (the gateway's clock), as the push plugin lists them: in every
/// notice (`read`) and, for a device away from the app, in a `read` push's `sessions` and `rooms`
/// (`docs/notifications.md` §2 Reading). On the wire each is `[[id, unix seconds], …]`.
public struct ReadMarks: Codable, Sendable, Hashable {
    /// By session id: a chat's own id, its lineage root, a Bot Chat's stored id.
    public var chats: [String: Date]
    /// By group room id.
    public var rooms: [String: Date]

    public init(chats: [String: Date] = [:], rooms: [String: Date] = [:]) {
        self.chats = chats
        self.rooms = rooms
    }

    /// A `read` push: each chat with when it was read (`read`); chats it only names (`sessions`,
    /// `rooms`) count as read when it was sent.
    public init(_ notice: PushNotice) {
        let at = notice.sentAt ?? .now
        chats = Dictionary(notice.sessions.map { ($0, at) }) { max($0, $1) }
        rooms = Dictionary(notice.rooms.map { ($0, at) }) { max($0, $1) }
        if let read = notice.read {
            chats.merge(read.chats) { max($0, $1) }
            rooms.merge(read.rooms) { max($0, $1) }
        }
    }

    public var isEmpty: Bool { chats.isEmpty && rooms.isEmpty }

    /// When the chat a notice is about was last read, as far as these marks say.
    public func readAt(_ chat: ReadNotices.Chat) -> Date? {
        let times = chat.ids.compactMap { chats[$0] } + (chat.room.flatMap { rooms[$0] }.map { [$0] } ?? [])
        return times.max()
    }

    private enum CodingKeys: String, CodingKey { case chats, rooms }

    private struct Pair: Codable {
        var id: String
        var at: Date

        init(id: String, at: Date) {
            self.id = id
            self.at = at
        }

        init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            id = try c.decode(String.self)
            at = Date(timeIntervalSince1970: try c.decode(Double.self))
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(id)
            try c.encode(at.timeIntervalSince1970)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func marks(_ key: CodingKeys) throws -> [String: Date] {
            let pairs = try c.decodeIfPresent([Pair].self, forKey: key) ?? []
            return Dictionary(pairs.map { ($0.id, $0.at) }) { max($0, $1) }
        }
        chats = try marks(.chats)
        rooms = try marks(.rooms)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chats.map { Pair(id: $0.key, at: $0.value) }, forKey: .chats)
        try c.encode(rooms.map { Pair(id: $0.key, at: $0.value) }, forKey: .rooms)
    }
}

/// Which delivered notifications a read takes away (`docs/notifications.md` §2 Reading): a chat's
/// news (replies, Bot and group messages) sent before the chat was read. Never a request that
/// still waits for an answer, a task's result or a card: those go when they're settled.
public enum ReadNotices {
    /// The chat a notice is about, every way it can be named.
    public struct Chat: Hashable, Sendable {
        /// Session ids: the notice's session and thread.
        public var ids: Set<String>
        /// The Bot whose own chat it is.
        public var profile: String?
        public var room: String?

        public init(ids: Set<String>, profile: String? = nil, room: String? = nil) {
            self.ids = ids
            self.profile = profile
            self.room = room
        }
    }

    /// The chat whose news this notice is; nil for any other notice.
    public static func chat(of notice: PushNotice) -> Chat? {
        guard notice.kind == .reply || notice.kind == .message else { return nil }
        let ids = Set([notice.sessionID, notice.chatID, notice.thread].compactMap { $0 }.filter { !$0.isEmpty && !$0.hasPrefix("room:") })
        let room = notice.roomID.flatMap { $0.isEmpty ? nil : $0 }
        guard !ids.isEmpty || room != nil else { return nil }
        return Chat(ids: ids, profile: room == nil ? notice.profile : nil, room: room)
    }

    /// Whether a delivered notice can go: its chat was read at or after it was sent. `readAt` says
    /// when a chat was read through, with whatever slack the caller's clock needs.
    public static func isRead(_ notice: PushNotice, deliveredAt: Date, readAt: (Chat) -> Date?) -> Bool {
        guard let chat = chat(of: notice), let read = readAt(chat) else { return false }
        return (notice.sentAt ?? deliveredAt) <= read
    }
}

/// A chat the app icon badge counts (`docs/notifications.md` §2 Badge), as the app or the
/// service extension wrote it into the App Group.
public struct UnreadChat: Codable, Sendable, Hashable {
    /// The app's key (`UnreadStore`): a session's stable key, `bot:<profile>`, `group:<id>`, or
    /// `push:<id>` for one only the extension has seen.
    public var key: String
    /// The session ids it goes by.
    public var ids: [String]
    public var room: String?
    /// The activity that made it unread: a read from before doesn't take it off.
    public var since: Date

    public init(key: String, ids: [String] = [], room: String? = nil, since: Date) {
        self.key = key
        self.ids = ids
        self.room = room
        self.since = since
    }

    /// The extension's entry for a notice's chat.
    public init?(_ notice: PushNotice, at date: Date) {
        guard let chat = ReadNotices.chat(of: notice) else { return nil }
        if let room = chat.room {
            self.init(key: "group:\(room)", room: room, since: date)
        } else if let profile = chat.profile {
            self.init(key: "bot:\(profile)", ids: chat.ids.sorted(), since: date)
        } else {
            self.init(key: "push:\(chat.ids.sorted().first ?? "")", ids: chat.ids.sorted(), since: date)
        }
    }

    public func matches(_ chat: ReadNotices.Chat) -> Bool {
        if let room, room == chat.room { return true }
        if let profile = chat.profile, key == "bot:\(profile)" { return true }
        return !chat.ids.isDisjoint(with: ids)
    }

    /// Read since it became unread, by these marks.
    public func isRead(by marks: ReadMarks) -> Bool {
        let times = ids.compactMap { marks.chats[$0] } + (room.flatMap { marks.rooms[$0] }.map { [$0] } ?? [])
        return times.contains { $0 >= since }
    }
}

extension PushUserInfo {
    /// The notice behind a delivered notification and the app's id for its gateway, believed only
    /// as far as its envelope opens with this device's key; the plain copy counts only in a
    /// notification the app posted itself (the Mac's). Named as the service extension names it.
    public static func opened(_ userInfo: [AnyHashable: Any], isRemote: Bool, shared: PushShared) -> (notice: PushNotice, gateway: UUID)? {
        if let envelope = PushEnvelope(payload: userInfo[Self.envelope]) {
            guard let opened = shared.open(envelope) else { return nil }
            var notice = opened.notice
            notice.nameBot(chats: shared.botChats(gateway: opened.gateway.appID), names: shared.botNames(gateway: opened.gateway.appID))
            return (notice, opened.gateway.appID)
        }
        guard !isRemote, let notice = Self.notice(in: userInfo),
              let gateway = (userInfo[Self.localGateway] as? String).flatMap(UUID.init(uuidString:))
        else { return nil }
        return (notice, gateway)
    }
}
