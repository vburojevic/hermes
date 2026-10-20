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
            revision: json["revision"]?.truncatedIntValue ?? 0,
            updatedAt: json["updated_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            latestSeq: json["latest_seq"]?.truncatedIntValue,
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
        guard let seq = json["seq"]?.truncatedIntValue, let kind = json["kind"]?.stringValue else { return nil }
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

    /// What's new in a room after `seq` (`docs/inbox.md` §1): its members' messages, and the
    /// first that mentions the person. Hermes keeps no read mark for rooms and the person has no
    /// handle in them, so a mention is `@all`, `@everyone`, `@you` or one of the names they go by
    /// (Settings → Notifications), or a reply quoting what the person wrote.
    public static func unread(_ events: [RoomEvent], after seq: Int, names: [String] = []) -> (count: Int, mention: (memberID: String, seq: Int)?) {
        let sorted = events.sorted { $0.seq < $1.seq }
        var yours: [String] = []
        var count = 0
        var mention: (memberID: String, seq: Int)?
        for event in sorted {
            let text = event.payload["text"]?.stringValue ?? ""
            switch event.kind {
            case "message.user":
                yours.append(text)
            case "message.member" where event.seq > seq:
                count += 1
                if mention == nil, mentionsYou(text, yourMessages: yours, names: names) {
                    mention = (event.payload["member_id"]?.stringValue ?? event.actorID ?? "", event.seq)
                }
            default:
                break
            }
        }
        return (count, mention)
    }

    public static func mentionsYou(_ text: String, yourMessages: [String], names: [String] = []) -> Bool {
        let lower = text.lowercased()
        let handles = names.map { "@" + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }.filter { $0.count > 1 }
        for token in ["@all", "@everyone", "@you"] + handles {
            var rest = lower[...]
            while let range = rest.range(of: token) {
                let after = rest[range.upperBound...].first
                if after.map({ !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) ?? true { return true }
                rest = rest[range.upperBound...]
            }
        }
        // A reply with a quote: `> words you wrote`.
        guard lower.hasPrefix(">") else { return false }
        let quote = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { $0.hasPrefix(">") }
            .map { $0.dropFirst().trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return quote.count >= 3 && yourMessages.contains { $0.contains(quote) }
    }

    public static func build(_ events: [RoomEvent]) -> [RoomItem] {
        var items: [RoomItem] = []
        var round = 0
        var roundsSeen = 1
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let id = "e\(event.seq)"
            let roundIndex = event.payload["round_index"]?.truncatedIntValue
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

    /// The members thinking before their first words in the current discussion, in the order they
    /// started (`Inbox.botThinkingLine`, `docs/inbox.md` §4): a turn started, and neither their
    /// message nor the turn's end has come since.
    public static func thinkingMembers(_ events: [RoomEvent]) -> [String] {
        var thinking: [String] = []
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let member = event.payload["member_id"]?.stringValue ?? (event.actorKind == "member" ? event.actorID : nil)
            switch event.kind {
            case "message.user": thinking = []
            case "turn.started": if let member, !thinking.contains(member) { thinking.append(member) }
            case "message.member", "turn.settled", "turn.failed", "turn.cancelled", "turn.deferred", "turn.reassigned":
                thinking.removeAll { $0 == member }
            case "room.activity":
                if let status = event.payload["status"]?.stringValue, ["settled", "bounded", "stopped"].contains(status) { thinking = [] }
            default: break
            }
        }
        return thinking
    }

    /// The member whose turn is running (`turn.started`, not yet settled, failed or cancelled), in
    /// the current discussion.
    public static func activeMember(_ events: [RoomEvent]) -> String? {
        var active: String?
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            let member = event.payload["member_id"]?.stringValue
            switch event.kind {
            case "message.user": active = nil
            case "turn.started": active = member
            case "turn.settled", "turn.failed", "turn.cancelled", "turn.deferred", "turn.reassigned":
                if member == active { active = nil }
            case "room.activity":
                if let status = event.payload["status"]?.stringValue, ["settled", "bounded", "stopped"].contains(status) { active = nil }
            default: break
            }
        }
        return active
    }

    /// The latest hand-off: a member's message that mentions another member (`@handle`), as
    /// (from, to, seq).
    public static func lastHandOff(_ events: [RoomEvent], handles: [String: String]) -> (from: String, to: String, seq: Int)? {
        for event in events.sorted(by: { $0.seq > $1.seq }) where event.kind == "message.member" {
            let from = event.payload["member_id"]?.stringValue ?? event.actorID ?? ""
            let text = event.payload["text"]?.stringValue ?? ""
            let mentioned = handles.compactMap { member, handle -> (String, String.Index)? in
                guard member != from, let range = text.range(of: "@\(handle)", options: .caseInsensitive) else { return nil }
                return (member, range.lowerBound)
            }.min { $0.1 < $1.1 }
            if let mentioned { return (from, mentioned.0, event.seq) }
            return nil
        }
        return nil
    }

    /// The round the current discussion is in, counting from 1.
    public static func currentRound(_ events: [RoomEvent]) -> Int {
        var round = 0
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if event.kind == "message.user" { round = 0 }
            if let index = event.payload["round_index"]?.truncatedIntValue { round = max(round, index) }
        }
        return round + 1
    }

    /// The discussion ended (settled or at a limit) after the person's last message.
    public static func isSettled(_ events: [RoomEvent]) -> Bool {
        guard let lastUser = events.last(where: { $0.kind == "message.user" })?.seq else { return true }
        return events.contains { $0.seq > lastUser && $0.kind == "room.activity" }
    }
}
