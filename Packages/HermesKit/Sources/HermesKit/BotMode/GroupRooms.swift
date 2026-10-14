import Foundation

/// A hosted group chat on the gateway (`groups.*`, protocol 2): two to six Bots who take turns
/// on the person's message, server-side. There are no live room events on the socket; a client
/// reads `groups.log` from its last `seq` and `groups.state` for what's waiting.
public struct GroupRoom: Identifiable, Hashable, Sendable {
    public struct Member: Identifiable, Hashable, Sendable {
        public var memberID: String
        /// The Bot's profile on the gateway.
        public var profile: String
        public var handle: String
        public var displayName: String?

        public var id: String { memberID }

        public init(memberID: String, profile: String, handle: String, displayName: String? = nil) {
            self.memberID = memberID
            self.profile = profile
            self.handle = handle
            self.displayName = displayName
        }

        public var json: JSONValue {
            var object: [String: JSONValue] = [
                "member_id": .string(memberID),
                "profile": .string(profile),
                "handle": .string(handle),
                "target": .object(["kind": .string("local"), "profile": .string(profile)]),
            ]
            if let displayName { object["display_name"] = .string(displayName) }
            return .object(object)
        }
    }

    public var id: String
    public var name: String
    public var members: [Member]
    public var revision: Int
    public var updatedAt: Date?
    public var latestSeq: Int?
    public var disbandedAt: Date?

    public init(id: String, name: String, members: [Member], revision: Int = 0, updatedAt: Date? = nil, latestSeq: Int? = nil, disbandedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.revision = revision
        self.updatedAt = updatedAt
        self.latestSeq = latestSeq
        self.disbandedAt = disbandedAt
    }

    public static func parse(_ json: JSONValue) -> GroupRoom? {
        guard let id = json["room_id"]?.stringValue else { return nil }
        var members: [Member] = []
        if case .array(let rows)? = json["members"] {
            members = rows.compactMap { row in
                guard let memberID = row["member_id"]?.stringValue else { return nil }
                let profile = row["profile"]?.stringValue ?? row["target"]?["profile"]?.stringValue ?? memberID
                return Member(memberID: memberID, profile: profile, handle: row["handle"]?.stringValue ?? profile, displayName: row["display_name"]?.stringValue)
            }
        }
        return GroupRoom(
            id: id,
            name: json["name"]?.stringValue ?? id,
            members: members,
            revision: json["revision"]?.doubleValue.map { Int($0) } ?? 0,
            updatedAt: json["updated_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            latestSeq: json["latest_seq"]?.doubleValue.map { Int($0) },
            disbandedAt: json["disbanded_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// A fresh room id: the name as a slug, made unique.
    public static func newID(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let trimmed = String(slug).split(separator: "-").joined(separator: "-").prefix(40)
        return "\(trimmed.isEmpty ? "room" : String(trimmed))-\(UUID().uuidString.prefix(6).lowercased())"
    }
}

/// One entry in a room's log.
public struct RoomEvent: Hashable, Sendable {
    public var seq: Int
    public var kind: String
    public var actorKind: String
    public var actorID: String?
    public var payload: JSONValue
    public var createdAt: Date?

    public init(seq: Int, kind: String, actorKind: String, actorID: String?, payload: JSONValue, createdAt: Date?) {
        self.seq = seq
        self.kind = kind
        self.actorKind = actorKind
        self.actorID = actorID
        self.payload = payload
        self.createdAt = createdAt
    }

    public static func parse(_ json: JSONValue) -> RoomEvent? {
        guard let seq = json["seq"]?.doubleValue.map({ Int($0) }), let kind = json["kind"]?.stringValue else { return nil }
        return RoomEvent(
            seq: seq,
            kind: kind,
            actorKind: json["actor"]?["kind"]?.stringValue ?? "gateway",
            actorID: json["actor"]?["id"]?.stringValue,
            payload: json["payload"] ?? .object([:]),
            createdAt: json["created_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// What a room shows (`screens/*/group-chat.elyx`).
public enum RoomItem: Identifiable, Hashable, Sendable {
    case user(id: String, text: String, date: Date?)
    case member(id: String, memberID: String, text: String, date: Date?)
    case passed(id: String, memberID: String)
    case failed(id: String, memberID: String, error: String)
    /// "Round 2 of 3".
    case round(id: String, index: Int)
    /// "Room settled · 2 rounds", or paused at a limit.
    case settled(id: String, rounds: Int, bounded: Bool)
    case renamed(id: String, name: String)

    public var id: String {
        switch self {
        case .user(let id, _, _), .member(let id, _, _, _), .passed(let id, _), .failed(let id, _, _),
             .round(let id, _), .settled(let id, _, _), .renamed(let id, _): id
        }
    }
}

public enum RoomTranscript {
    /// The rounds a discussion can run (the driver's limit).
    public static let maxRounds = 3

    public static func build(_ events: [RoomEvent]) -> [RoomItem] {
        var items: [RoomItem] = []
        var round = 0
        var roundsSeen = 1
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let id = "e\(event.seq)"
            let roundIndex = event.payload["round_index"]?.doubleValue.map { Int($0) }
            func enterRound() {
                guard let roundIndex, roundIndex > round else { return }
                round = roundIndex
                roundsSeen = max(roundsSeen, roundIndex + 1)
                items.append(.round(id: "\(id)-round", index: roundIndex))
            }
            switch event.kind {
            case "message.user":
                round = 0
                roundsSeen = 1
                items.append(.user(id: id, text: event.payload["text"]?.stringValue ?? "", date: event.createdAt))
            case "message.member":
                enterRound()
                items.append(.member(
                    id: id,
                    memberID: event.payload["member_id"]?.stringValue ?? event.actorID ?? "",
                    text: event.payload["text"]?.stringValue ?? "",
                    date: event.createdAt
                ))
            case "turn.settled" where event.payload["passed"]?.boolValue == true:
                enterRound()
                items.append(.passed(id: id, memberID: event.payload["member_id"]?.stringValue ?? ""))
            case "turn.failed":
                items.append(.failed(id: id, memberID: event.payload["member_id"]?.stringValue ?? "", error: event.payload["error"]?.stringValue ?? "The turn failed."))
            case "room.activity":
                let status = event.payload["status"]?.stringValue
                if status == "settled" || status == "bounded" {
                    items.append(.settled(id: id, rounds: roundsSeen, bounded: status == "bounded"))
                }
            case "room.renamed":
                items.append(.renamed(id: id, name: event.payload["name"]?.stringValue ?? ""))
            default:
                break
            }
        }
        return items
    }

    /// Each member's state in the current discussion, for Activity.
    public enum MemberState: Hashable, Sendable { case waiting, replied, passed, failed }

    public static func memberStates(_ events: [RoomEvent]) -> [String: MemberState] {
        var states: [String: MemberState] = [:]
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let member = event.payload["member_id"]?.stringValue
            switch event.kind {
            case "message.user": states = [:]
            case "turn.settled": if let member { states[member] = event.payload["passed"]?.boolValue == true ? .passed : .replied }
            case "turn.failed": if let member { states[member] = .failed }
            default: break
            }
        }
        return states
    }

    /// The round the current discussion is in, counting from 1.
    public static func currentRound(_ events: [RoomEvent]) -> Int {
        var round = 0
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if event.kind == "message.user" { round = 0 }
            if let index = event.payload["round_index"]?.doubleValue.map({ Int($0) }) { round = max(round, index) }
        }
        return round + 1
    }

    /// The discussion ended (settled or at a limit) after the person's last message.
    public static func isSettled(_ events: [RoomEvent]) -> Bool {
        guard let lastUser = events.last(where: { $0.kind == "message.user" })?.seq else { return true }
        return events.contains { $0.seq > lastUser && $0.kind == "room.activity" }
    }
}
