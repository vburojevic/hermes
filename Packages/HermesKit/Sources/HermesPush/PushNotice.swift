import Foundation

/// What a gateway sent, once the extension or the app has opened its envelope
/// (`Tools/hermes-app-push/notices.py`). Every field is optional on the wire; unknown kinds
/// still show their title and body.
public struct PushNotice: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case approval, question, password, reply, task, message, background, test, withdraw
        /// Chats changed while the app was away: a background push that has the app read them.
        case sync
        /// Chats read on another device: a background push that clears their notifications
        /// (`docs/notifications.md` §2 Reading).
        case read
        case taskFailed = "task_failed"
        /// Board cards (`docs/board.md` §5): a card needs you, is ready for review, stopped, is done.
        case cardNeedsYou = "card_needs_you"
        case cardReview = "card_review"
        case cardStopped = "card_stopped"
        case cardDone = "card_done"
        /// Hermes tidied its skills and changed something (`docs/learned.md`): opens Tidying.
        case tidied
        /// A widget request in a reply (`docs/widgets.md` §12): opens the chat, answered on its card.
        case widget
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// Hermes is paused until someone answers.
        public var needsYou: Bool { self == .approval || self == .question || self == .password }

        /// A board card's news.
        public var isCard: Bool { self == .cardNeedsYou || self == .cardReview || self == .cardStopped || self == .cardDone }
    }

    public struct Gateway: Codable, Sendable, Hashable {
        /// The relay's installation id: stable per Hermes home.
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// How the app answers in the background.
    public struct Answer: Codable, Sendable, Hashable {
        /// `socket`: `approval.respond` / `request.answer` on the backend socket.
        /// `run`: `POST /v1/runs/{run_id}/approval` on the API server.
        public var via: String
        public var sessionID: String?
        public var runID: String?

        enum CodingKeys: String, CodingKey {
            case via
            case sessionID = "session_id"
            case runID = "run_id"
        }

        public init(via: String, sessionID: String? = nil, runID: String? = nil) {
            self.via = via
            self.sessionID = sessionID
            self.runID = runID
        }
    }

    public struct Question: Codable, Sendable, Hashable {
        public var question: String
        public var choices: [String]
        public var multiSelect: Bool

        enum CodingKeys: String, CodingKey {
            case question, choices
            case multiSelect = "multi_select"
        }

        public init(question: String, choices: [String] = [], multiSelect: Bool = false) {
            self.question = question
            self.choices = choices
            self.multiSelect = multiSelect
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
            choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
            multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        }
    }

    public var kind: Kind
    public var id: String
    public var title: String
    public var body: String
    public var subtitle: String
    /// The Lock Screen text when details are hidden: the kind and the gateway.
    public var hidden: String
    /// `threadIdentifier`: the chat, room or task.
    public var thread: String
    /// `summaryArgument`: the chat title.
    public var summary: String
    public var sessionID: String?
    public var requestID: String?
    public var expiresAt: Date?
    public var category: String?
    public var gateway: Gateway?
    /// Open "needs you" requests on that gateway when this was sent (the badge).
    public var open: Int?
    /// Requests answered recently: their notices can go.
    public var resolved: [String]
    public var sentAt: Date?

    // Approvals
    public var command: String?
    public var detail: String?
    public var choices: [String]
    public var smartDenied: Bool
    /// Where Hermes asked from: `vault-payment` for a card fill (`docs/web.md` §4).
    public var surface: String?
    public var answer: Answer?

    // Questions
    public var questions: [Question]

    // Replies, tasks, Bot messages
    public var turnID: String?
    public var seconds: Double?
    public var jobID: String?
    public var failed: Bool
    public var roomID: String?
    public var memberID: String?
    public var bot: String?
    /// The Bot's profile, for a Bot Chat: its session lives there.
    public var profile: String?
    public var mention: Bool

    // Board cards
    /// The card (`t_<hex>`), its board and the project the app keeps that board for.
    public var cardID: String?
    public var board: String?
    public var projectID: String?
    public var cardTitle: String?
    /// The profile working on it.
    public var assignee: String?

    // Widget requests
    /// `approval`, `choice` or `form`: only an approval is time sensitive.
    public var widgetType: String?

    // Withdrawals
    public var ids: [String]

    // Chats to read now (`sync`), or read elsewhere (`read`): stored session ids.
    public var sessions: [String]
    /// Group chats read elsewhere (`read`).
    public var rooms: [String]
    /// Chats read lately on any device, with when: their notifications can go (every notice).
    public var read: ReadMarks?

    enum CodingKeys: String, CodingKey {
        case kind, id, title, body, subtitle, hidden, thread, summary, category, gateway, open, resolved
        case sessionID = "session_id"
        case requestID = "request_id"
        case expiresAt = "expires_at"
        case sentAt = "sent_at"
        case command
        case detail = "description"
        case choices
        case smartDenied = "smart_denied"
        case surface
        case answer, questions
        case turnID = "turn_id"
        case seconds
        case jobID = "job_id"
        case failed
        case roomID = "room_id"
        case memberID = "member_id"
        case bot, profile, mention, ids, sessions, rooms, read
        case cardID = "card_id"
        case board
        case projectID = "project_id"
        case cardTitle = "card_title"
        case assignee
        case widgetType = "widget_type"
    }

    public init(
        kind: Kind, id: String, title: String = "", body: String = "", subtitle: String = "", hidden: String = "",
        thread: String = "", summary: String = "", sessionID: String? = nil, requestID: String? = nil,
        expiresAt: Date? = nil, gateway: Gateway? = nil, open: Int? = nil, resolved: [String] = [],
        command: String? = nil, detail: String? = nil, choices: [String] = [], answer: Answer? = nil,
        questions: [Question] = [], bot: String? = nil, memberID: String? = nil, roomID: String? = nil,
        failed: Bool = false, mention: Bool = false, ids: [String] = [], sessions: [String] = [],
        rooms: [String] = [], read: ReadMarks? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.hidden = hidden
        self.thread = thread
        self.summary = summary
        self.sessionID = sessionID
        self.requestID = requestID
        self.expiresAt = expiresAt
        self.gateway = gateway
        self.open = open
        self.resolved = resolved
        self.command = command
        self.detail = detail
        self.choices = choices
        self.smartDenied = false
        self.answer = answer
        self.questions = questions
        self.failed = failed
        self.mention = mention
        self.bot = bot
        self.memberID = memberID
        self.roomID = roomID
        self.ids = ids
        self.sessions = sessions
        self.rooms = rooms
        self.read = read
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        func date(_ key: CodingKeys) throws -> Date? {
            try c.decodeIfPresent(Double.self, forKey: key).map { Date(timeIntervalSince1970: $0) }
        }
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        id = try text(.id)
        title = try text(.title)
        body = try text(.body)
        subtitle = try text(.subtitle)
        hidden = try text(.hidden)
        thread = try text(.thread)
        summary = try text(.summary)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        expiresAt = try date(.expiresAt)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        gateway = try c.decodeIfPresent(Gateway.self, forKey: .gateway)
        open = try c.decodeIfPresent(Int.self, forKey: .open)
        resolved = try c.decodeIfPresent([String].self, forKey: .resolved) ?? []
        sentAt = try date(.sentAt)
        command = VisibleText.of(try c.decodeIfPresent(String.self, forKey: .command))
        detail = VisibleText.of(try c.decodeIfPresent(String.self, forKey: .detail))
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        smartDenied = try c.decodeIfPresent(Bool.self, forKey: .smartDenied) ?? false
        surface = try? c.decodeIfPresent(String.self, forKey: .surface)
        answer = try c.decodeIfPresent(Answer.self, forKey: .answer)
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        jobID = try c.decodeIfPresent(String.self, forKey: .jobID)
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID)
        memberID = try c.decodeIfPresent(String.self, forKey: .memberID)
        bot = try c.decodeIfPresent(String.self, forKey: .bot)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        mention = try c.decodeIfPresent(Bool.self, forKey: .mention) ?? false
        ids = try c.decodeIfPresent([String].self, forKey: .ids) ?? []
        sessions = try c.decodeIfPresent([String].self, forKey: .sessions) ?? []
        rooms = try c.decodeIfPresent([String].self, forKey: .rooms) ?? []
        // An entry this build can't read costs only that cleanup, never the notice.
        read = try? c.decodeIfPresent(ReadMarks.self, forKey: .read)
        cardID = try c.decodeIfPresent(String.self, forKey: .cardID)
        board = try c.decodeIfPresent(String.self, forKey: .board)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID).flatMap { $0.isEmpty ? nil : $0 }
        cardTitle = try c.decodeIfPresent(String.self, forKey: .cardTitle)
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee).flatMap { $0.isEmpty ? nil : $0 }
        widgetType = try c.decodeIfPresent(String.self, forKey: .widgetType)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind == .unknown ? "unknown" : kind.rawValue, forKey: .kind)
        try c.encode(id, forKey: .id)
        for (key, value) in [(CodingKeys.title, title), (.body, body), (.subtitle, subtitle), (.hidden, hidden), (.thread, thread), (.summary, summary)]
        where !value.isEmpty {
            try c.encode(value, forKey: key)
        }
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(requestID, forKey: .requestID)
        try c.encodeIfPresent(expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(gateway, forKey: .gateway)
        try c.encodeIfPresent(open, forKey: .open)
        if !resolved.isEmpty { try c.encode(resolved, forKey: .resolved) }
        try c.encodeIfPresent(sentAt?.timeIntervalSince1970, forKey: .sentAt)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(detail, forKey: .detail)
        if !choices.isEmpty { try c.encode(choices, forKey: .choices) }
        if smartDenied { try c.encode(true, forKey: .smartDenied) }
        try c.encodeIfPresent(surface, forKey: .surface)
        try c.encodeIfPresent(answer, forKey: .answer)
        if !questions.isEmpty { try c.encode(questions, forKey: .questions) }
        try c.encodeIfPresent(turnID, forKey: .turnID)
        try c.encodeIfPresent(seconds, forKey: .seconds)
        try c.encodeIfPresent(jobID, forKey: .jobID)
        if failed { try c.encode(true, forKey: .failed) }
        try c.encodeIfPresent(roomID, forKey: .roomID)
        try c.encodeIfPresent(memberID, forKey: .memberID)
        try c.encodeIfPresent(bot, forKey: .bot)
        try c.encodeIfPresent(profile, forKey: .profile)
        if mention { try c.encode(true, forKey: .mention) }
        if !ids.isEmpty { try c.encode(ids, forKey: .ids) }
        if !sessions.isEmpty { try c.encode(sessions, forKey: .sessions) }
        if !rooms.isEmpty { try c.encode(rooms, forKey: .rooms) }
        try c.encodeIfPresent(read, forKey: .read)
        try c.encodeIfPresent(cardID, forKey: .cardID)
        try c.encodeIfPresent(board, forKey: .board)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(cardTitle, forKey: .cardTitle)
        try c.encodeIfPresent(assignee, forKey: .assignee)
        try c.encodeIfPresent(widgetType, forKey: .widgetType)
    }

    /// The chat this notice is about (opening it, grouping, the foreground rule). A card's
    /// notice is about a board, not a chat.
    public var chatID: String? {
        if kind.isCard { return nil }
        if let sessionID, !sessionID.isEmpty { return sessionID }
        return thread.isEmpty ? nil : thread
    }

    /// Says which Bot a notice is from, with what the app shared (`PushShared.botChats`, `botNames`):
    /// Hermes tags a Bot Chat's notice with the Bot's profile, but not the primary Bot's (the
    /// gateway's own profile), whose chat is found by its session id. Without this its notices read
    /// "Bot Chat" and opened the chat as an ordinary one.
    public mutating func nameBot(chats: [String: String], names: [String: String]) {
        if profile == nil, roomID == nil, let chat = chatID, let owner = chats[chat] {
            profile = owner
        }
        if bot == nil, let profile {
            bot = names[profile]
        }
    }

    /// The keys a mute may be under (`docs/inbox.md` §1 Muting): the chat, its Bot, its room.
    public var muteKeys: [String] {
        var keys: [String] = []
        if let id = sessionID ?? chatID { keys.append(id) }
        if let profile { keys.append("bot:\(profile)") }
        if let roomID { keys.append("group:\(roomID)") }
        return keys
    }

    /// Delivered quietly when its chat is muted: everything but what pauses Hermes (approvals,
    /// questions, keys) and a mention of the person in a group chat.
    public var quietWhenMuted: Bool {
        !kind.needsYou && !mention && !kind.isCard
    }

    /// Past its deadline: answering would only fail.
    public func isExpired(now: Date = .now) -> Bool {
        expiresAt.map { $0 < now } ?? false
    }

    /// Choices shown as notification actions: only a single, single-select question's.
    public var actionChoices: [String] {
        guard kind == .question else { return [] }
        if !choices.isEmpty { return Array(choices.prefix(3)) }
        guard questions.count == 1, let first = questions.first, !first.multiSelect else { return [] }
        return Array(first.choices.prefix(3))
    }
}

/// Keys the Notification Service Extension writes into `userInfo` after opening a notice, so the
/// app and the content extension can act without decrypting again.
public enum PushUserInfo {
    public static let envelope = "hermes"
    public static let notice = "hermes.notice"
    public static let gateway = "hermes.gateway"
    public static let request = "hermes.request"
    public static let chat = "hermes.chat"
    public static let kind = "hermes.kind"
    /// A local (Mac) notification's gateway, as the app's own id.
    public static let localGateway = "hermes.localGateway"

    /// The decoded notice the extension stored, if any.
    public static func notice(in userInfo: [AnyHashable: Any]) -> PushNotice? {
        guard let data = (userInfo[notice] as? String).map({ Data($0.utf8) }) else { return nil }
        return try? JSONDecoder().decode(PushNotice.self, from: data)
    }

    /// The values to merge into `userInfo` for a notice.
    public static func values(for notice: PushNotice) -> [String: Any] {
        var values: [String: Any] = [kind: notice.kind.rawValue]
        if let data = try? JSONEncoder().encode(notice), let text = String(data: data, encoding: .utf8) {
            values[Self.notice] = text
        }
        if let id = notice.gateway?.id { values[gateway] = id }
        if let id = notice.requestID { values[request] = id }
        if let id = notice.chatID { values[chat] = id }
        return values
    }
}
