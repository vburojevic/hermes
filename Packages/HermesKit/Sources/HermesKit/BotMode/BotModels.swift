import Foundation

/// The exact title that makes a session a Bot's canonical, forever "Bot Chat".
public let botChatTitle = "Bot Chat"

/// A session reference inside a `profiles.list` row.
public struct BotSessionRef: Hashable, Sendable {
    /// Durable registry id (the identity).
    public var id: String
    /// Compression-lineage tip: the session to open.
    public var resolvedID: String
    public var title: String?
    public var preview: String?
    public var startedAt: Date?
    public var lastActive: Date?
    public var messageCount: Int?

    public init(id: String, resolvedID: String? = nil, title: String? = nil, preview: String? = nil, startedAt: Date? = nil, lastActive: Date? = nil, messageCount: Int? = nil) {
        self.id = id
        self.resolvedID = resolvedID ?? id
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.lastActive = lastActive
        self.messageCount = messageCount
    }

    init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(
            id: id,
            resolvedID: json["resolved_id"]?.stringValue,
            title: json["title"]?.stringValue,
            preview: json["preview"]?.stringValue,
            startedAt: HermesDate.fromEpoch(json["started_at"]?.doubleValue),
            lastActive: HermesDate.fromEpoch(json["last_active"]?.doubleValue),
            messageCount: json["message_count"]?.doubleValue.map { Int($0) }
        )
    }
}

/// `ui_meta['hermes-bots']` — Bot Mode's per-profile look and organisation.
public struct BotMeta: Hashable, Sendable {
    /// The whole namespace as stored; writes send it back with changes merged in.
    public var raw: [String: JSONValue]

    public init(raw: [String: JSONValue] = [:]) {
        self.raw = raw
    }

    public var title: String? { nonEmpty(raw["title"]?.stringValue) }
    public var description: String? { nonEmpty(raw["description"]?.stringValue) }
    public var shape: String? { nonEmpty(raw["shape"]?.stringValue) }
    public var color: String? { nonEmpty(raw["color"]?.stringValue) }
    public var isCustom: Bool { raw["custom"]?.boolValue ?? false }
    public var isHidden: Bool { raw["hidden"]?.boolValue ?? false }
    public var isPinned: Bool { raw["pinned"]?.boolValue ?? false }
    public var imageKind: String? { raw["imageKind"]?.stringValue }
    /// Creation time (milliseconds in the store).
    public var created: Date? { raw["created"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) } }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// One Bot: a Hermes profile as `profiles.list` reports it.
public struct BotProfile: Identifiable, Hashable, Sendable {
    public var name: String
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    /// Role text (`profile.yaml` description; Desktop writes "<title> — <role>").
    public var profileDescription: String
    public var displayName: String
    public var previousNames: [String]
    public var lastSession: BotSessionRef?
    public var workerSession: BotSessionRef?
    /// The Bot Chat, when one exists.
    public var canonicalSession: BotSessionRef?
    public var meta: BotMeta
    public var metaRevision: Int?
    public var hasAvatar: Bool

    /// Derived once per roster read; rows read these on every redraw.
    public private(set) var title = ""
    public private(set) var handle = ""
    public private(set) var mentionTag = ""
    public private(set) var role: String?
    public private(set) var preview: String?

    public var id: String { name }

    public init(json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        isDefault = json["is_default"]?.boolValue ?? (name == "default")
        model = json["model"]?.stringValue
        provider = json["provider"]?.stringValue
        profileDescription = json["description"]?.stringValue ?? ""
        displayName = json["display_name"]?.stringValue ?? ""
        if case .array(let names)? = json["previous_names"] {
            previousNames = names.compactMap(\.stringValue)
        } else {
            previousNames = []
        }
        lastSession = BotSessionRef(json: json["last_session"])
        workerSession = BotSessionRef(json: json["worker_session"])
        canonicalSession = BotSessionRef(json: json["canonical_session"])
        if case .object(let namespace)? = json["ui_meta"]?["hermes-bots"] {
            meta = BotMeta(raw: namespace.filter { $0.key != "chat" }) // `chat` is a dead legacy pointer
        } else {
            meta = BotMeta()
        }
        metaRevision = json["ui_meta_revisions"]?["hermes-bots"]?.doubleValue.map { Int($0) }
        hasAvatar = json["has_avatar"]?.boolValue ?? false
        title = computedTitle
        handle = isDefault || name == "default" ? "hermes" : name
        mentionTag = computedMentionTag
        role = computedRole
        preview = computedPreview
    }

    /// Desktop's label precedence: Bot Mode title → display name → "Hermes" for the
    /// primary profile → the profile name, title-cased.
    private var computedTitle: String {
        if let title = meta.title { return title }
        let display = displayName.trimmingCharacters(in: .whitespaces)
        if !display.isEmpty { return display }
        if isDefault || name == "default" { return "Hermes" }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// What `@`-autocomplete inserts: the friendly-name slug when there is one.
    private var computedMentionTag: String {
        let candidates = [meta.title, nonEmptyDisplayName].compactMap { $0 }.map(BotMentions.slug).filter { !$0.isEmpty }
        if let tag = candidates.first, !BotMentions.reserved.contains(tag) { return tag }
        return handle
    }

    private var nonEmptyDisplayName: String? {
        let value = displayName.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The role line under the name: Bot Mode description, else the profile description
    /// with Desktop's "<title> — " prefix removed.
    private var computedRole: String? {
        if let description = meta.description { return description }
        var text = profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(title) — ", "\(title) - "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text.isEmpty ? nil : text
    }

    /// The fresher of the Bot Chat and the latest other session.
    public var activitySession: BotSessionRef? {
        switch (canonicalSession, lastSession) {
        case (let chat?, let last?):
            (last.lastActive ?? .distantPast) > (chat.lastActive ?? .distantPast) ? last : chat
        case (let chat?, nil): chat
        case (nil, let last?): last
        case (nil, nil): nil
        }
    }

    public var lastActive: Date? { activitySession?.lastActive }

    /// Roster sort key: newest of creation and activity.
    public var recency: Date {
        max(meta.created ?? .distantPast, lastActive ?? .distantPast)
    }

    /// "Active now": wrote in the last 90 s, or a background worker beat in the last 150 s.
    public func isActive(now: Date = .now) -> Bool {
        if let active = lastActive, now.timeIntervalSince(active) < 90 { return true }
        if let worker = workerSession?.lastActive, now.timeIntervalSince(worker) < 150 { return true }
        return false
    }

    /// Latest-message preview with bot-to-bot attribution turned into "Name: text". It describes
    /// what opening the row shows: the Bot Chat when there is one (Desktop, hermes-agent#88200).
    /// A newer routine run or other session moves the row's activity time, not its preview.
    private var computedPreview: String? {
        guard let raw = (canonicalSession ?? lastSession)?.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !BotMentions.isSilenceMarker(raw)
        else { return nil }
        switch Self.controlFrame(raw) {
        case .named(let text)?: return text
        case .hidden?: return nil
        case nil: break
        }
        if let message = BotMentions.parseAgentMessage(raw) {
            return "\(message.senderName): \(message.body)"
        }
        if let routine = BotMentions.parseRoutineDelivery(raw) {
            let quiet = routine.output.isEmpty || BotMentions.isSilenceMarker(routine.output)
            return quiet ? "⏰ \(routine.name)" : "⏰ \(routine.name): \(BotMentions.stripMarkdown(routine.output))"
        }
        return BotMentions.stripMarkdown(raw)
    }
}

extension BotProfile {
    /// One of Hermes' own control frames, which are stored as `user` rows and can be a chat's newest.
    enum ControlFrame: Equatable {
        /// What a person would call it.
        case named(String)
        /// Nothing worth a preview: the row shows its role line instead.
        case hidden
    }

    /// The control frame `text` starts with, if any.
    static func controlFrame(_ text: String) -> ControlFrame? {
        if text.hasPrefix("[OUT-OF-BAND USER MESSAGE") { return .named("Steered the reply") }
        if text.hasPrefix("[IMPORTANT: Background process") { return .named("Background process finished") }
        let skillPrefix = "[IMPORTANT: The user has invoked the \""
        if text.hasPrefix(skillPrefix) {
            let name = text.dropFirst(skillPrefix.count).prefix { $0 != "\"" }
            return name.isEmpty ? .hidden : .named("Used the \(name) skill")
        }
        let machinePrefixes = ["[IMPORTANT:", "[System:", "[SYSTEM", "[System note:", "[Runtime note:"]
        return machinePrefixes.contains(where: text.hasPrefix) ? .hidden : nil
    }
}

/// A Bot's routine: a cron job in its profile, as `cron.manage list` reports it.
public struct BotRoutine: Identifiable, Hashable, Sendable {
    public var id: String
    /// Name without the `[bot:<name>]` tag.
    public var title: String
    public var taggedBot: String?
    public var promptPreview: String
    public var schedule: String
    public var repeatDescription: String?
    public var deliver: String
    public var enabled: Bool
    public var state: String
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastStatus: String?
    public var issue: String?

    public init?(json: JSONValue) {
        guard let id = json["job_id"]?.stringValue ?? json["id"]?.stringValue else { return nil }
        self.id = id
        let name = json["name"]?.stringValue ?? ""
        (taggedBot, title) = Self.parse(name: name)
        promptPreview = json["prompt_preview"]?.stringValue ?? json["prompt"]?.stringValue ?? ""
        schedule = json["schedule"]?.stringValue ?? json["schedule"]?["display"]?.stringValue ?? json["schedule_display"]?.stringValue ?? ""
        repeatDescription = json["repeat"]?.stringValue
        deliver = json["deliver"]?.stringValue ?? "local"
        enabled = json["enabled"]?.boolValue ?? true
        state = json["state"]?.stringValue ?? (enabled ? "scheduled" : "paused")
        nextRunAt = HermesDate.fromISO(json["next_run_at"]?.stringValue)
        lastRunAt = HermesDate.fromISO(json["last_run_at"]?.stringValue)
        lastStatus = json["last_status"]?.stringValue
        issue = [json["last_fire_error"], json["last_delivery_error"], json["last_error"], json["paused_reason"]]
            .compactMap { $0?.stringValue }.first { !$0.isEmpty }
    }

    public var isPaused: Bool { !enabled || state == "paused" }
    public var deliversToBotChat: Bool { deliver.hasPrefix("bot-chat") }
    public var hasFailed: Bool { lastStatus == "error" || lastStatus == "delivery_failed" || state == "error" }

    /// `[bot:researcher] Morning digest` → ("researcher", "Morning digest").
    static func parse(name: String) -> (String?, String) {
        guard let range = name.range(of: #"^\[bot:([a-z0-9][a-z0-9_-]*)\]\s*"#, options: [.regularExpression, .caseInsensitive]) else {
            return (nil, name.isEmpty ? "Untitled routine" : name)
        }
        let tag = name[range]
        let bot = tag.dropFirst(5).prefix { $0 != "]" }.lowercased()
        let title = String(name[range.upperBound...])
        return (bot, title.isEmpty ? "Untitled routine" : title)
    }
}
