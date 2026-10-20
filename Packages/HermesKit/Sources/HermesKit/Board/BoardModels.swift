import Foundation

// The Board: a project's kanban of cards that Hermes and its Bots work through on their own
// (the gateway's kanban plugin, `plugins/kanban/dashboard/plugin_api.py`, REST + WebSocket under
// `/api/plugins/kanban/`). The gateway calls a card a "task" (`t_<hex>`); that word stops here,
// because Tasks in the app are scheduled jobs. Shapes mirror the desktop app's
// `apps/desktop/src/plugins/kanban/types.ts`. Card titles, bodies and comments are the person's
// words: never log them.

/// A column of the board's workflow (`GET /workflow`).
public struct BoardColumn: Identifiable, Hashable, Sendable {
    /// The gateway's status key (`triage`, `todo`, `ready`, …).
    public var key: String
    /// The gateway's label ("Todo"); the app shows `title`.
    public var label: String
    /// Cards can be dropped here by hand. Running, scheduled and review can't: a worker, a wake
    /// time or a reviewer puts cards there.
    public var isDropTarget: Bool

    public var id: String { key }

    public init(key: String, label: String, isDropTarget: Bool = true) {
        self.key = key
        self.label = label
        self.isDropTarget = isDropTarget
    }

    /// The column's name in the app ("To Do"); a column the app doesn't know keeps the gateway's.
    public var title: String {
        switch key {
        case "triage": String(localized: "Triage")
        case "todo": String(localized: "To Do")
        case "scheduled": String(localized: "Scheduled")
        case "ready": String(localized: "Ready")
        case "running": String(localized: "Running")
        case "blocked": String(localized: "Blocked")
        case "review": String(localized: "Review")
        case "done": String(localized: "Done")
        case BoardWorkflow.archived: String(localized: "Archived")
        default: label.isEmpty ? key.capitalized : label
        }
    }
}

/// The columns, in order, and which hand moves the gateway allows (`GET /workflow`). Every
/// column list and Move menu comes from here, never from a list in the app.
public struct BoardWorkflow: Hashable, Sendable {
    /// Not a column: archived cards are hidden from the board (and restorable).
    public static let archived = "archived"

    public var columns: [BoardColumn]
    /// From status → the statuses a person may move a card to.
    public var manual: [String: Set<String>]

    public init(columns: [BoardColumn], manual: [String: Set<String>]) {
        self.columns = columns
        self.manual = manual
    }

    public init(json: JSONValue) {
        var columns: [BoardColumn] = []
        if case .array(let rows)? = json["columns"] {
            for row in rows {
                guard let key = row["key"]?.stringValue, !key.isEmpty else { continue }
                columns.append(BoardColumn(key: key, label: row["label"]?.stringValue ?? key, isDropTarget: row["drag_target"]?.boolValue ?? true))
            }
        }
        var manual: [String: Set<String>] = [:]
        if case .object(let table)? = json["manual"] {
            for (source, targets) in table {
                if case .array(let keys) = targets { manual[source] = Set(keys.compactMap(\.stringValue)) }
            }
        }
        self.init(columns: columns, manual: manual)
    }

    public func column(_ key: String) -> BoardColumn? {
        columns.first { $0.key == key }
    }

    /// Where a person can move a card from `status` (the Move menu and drops): the allowed
    /// moves that are drop targets, Ready first, then in column order.
    public func moves(from status: String) -> [BoardColumn] {
        guard let allowed = manual[status] else { return [] }
        let targets = columns.filter { $0.key != status && $0.isDropTarget && allowed.contains($0.key) }
        return targets.filter { $0.key == "ready" } + targets.filter { $0.key != "ready" }
    }

    public func allows(from status: String, to target: String) -> Bool {
        moves(from: status).contains { $0.key == target }
    }

    /// The next allowed column to the right (`forward`) or left of `status` (⌘→ / ⌘← on the Mac).
    public func nextMove(from status: String, forward: Bool) -> BoardColumn? {
        guard let index = columns.firstIndex(where: { $0.key == status }) else { return nil }
        let allowed = Set(moves(from: status).map(\.key))
        let candidates = forward ? Array(columns[(index + 1)...]) : Array(columns[..<index].reversed())
        return candidates.first { allowed.contains($0.key) }
    }

    /// Archived cards can come back to these (`manual["archived"]`).
    public var restoreTargets: [BoardColumn] { moves(from: Self.archived) }
}

/// One card on the board (`GET /board` → `columns[].tasks[]`; the detail's `task`).
public struct BoardCard: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var body: String?
    /// The column it's in (the gateway's `status`).
    public var column: String
    /// The Bot's profile working on it, or reviewing it while in Review; nil = nobody.
    public var assignee: String?
    public var priority: Int
    public var createdAt: Date?
    public var createdBy: String?
    public var startedAt: Date?
    public var completedAt: Date?
    /// The current attempt's start (the run clock); `startedAt` is the first attempt's.
    public var currentRunStartedAt: Date?
    public var lastHeartbeatAt: Date?
    /// The latest handoff summary (200 characters on the board, all of it in the detail).
    public var latestSummary: String?
    public var commentCount: Int
    public var parentCount: Int
    public var childCount: Int
    /// Sub-cards done of total; nil when it has none.
    public var progress: (done: Int, total: Int)?
    public var warningCount: Int
    /// `needs_input`, `capability`, `transient`, `dependency`; kept after an unblock.
    public var blockKind: String?
    public var consecutiveFailures: Int
    public var lastFailureError: String?
    public var branchName: String?
    /// `worktree`, `dir` or `scratch`.
    public var workspaceKind: String?
    public var workspacePath: String?
    /// The chat that created it, if one did.
    public var sessionID: String?
    public var projectID: String?
    public var result: String?
    public var modelOverride: String?

    public init(
        id: String, title: String, body: String? = nil, column: String, assignee: String? = nil, priority: Int = 0,
        createdAt: Date? = nil, createdBy: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil,
        currentRunStartedAt: Date? = nil, lastHeartbeatAt: Date? = nil, latestSummary: String? = nil,
        commentCount: Int = 0, parentCount: Int = 0, childCount: Int = 0, progress: (done: Int, total: Int)? = nil,
        warningCount: Int = 0, blockKind: String? = nil, consecutiveFailures: Int = 0, lastFailureError: String? = nil,
        branchName: String? = nil, workspaceKind: String? = nil, workspacePath: String? = nil, sessionID: String? = nil,
        projectID: String? = nil, result: String? = nil, modelOverride: String? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.column = column
        self.assignee = assignee
        self.priority = priority
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.currentRunStartedAt = currentRunStartedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.latestSummary = latestSummary
        self.commentCount = commentCount
        self.parentCount = parentCount
        self.childCount = childCount
        self.progress = progress
        self.warningCount = warningCount
        self.blockKind = blockKind
        self.consecutiveFailures = consecutiveFailures
        self.lastFailureError = lastFailureError
        self.branchName = branchName
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.sessionID = sessionID
        self.projectID = projectID
        self.result = result
        self.modelOverride = modelOverride
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            guard let value = json[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        func int(_ key: String) -> Int? { json[key]?.truncatedIntValue }
        func date(_ key: String) -> Date? { HermesDate.fromEpoch(json[key]?.doubleValue) }
        var progress: (done: Int, total: Int)?
        if let total = json["progress"]?["total"]?.doubleValue, total > 0 {
            progress = (Int(json["progress"]?["done"]?.doubleValue ?? 0), Int(total))
        }
        self.init(
            id: id,
            title: json["title"]?.stringValue ?? "",
            body: text("body"),
            column: text("status") ?? "todo",
            assignee: text("assignee"),
            priority: int("priority") ?? 0,
            createdAt: date("created_at"),
            createdBy: text("created_by"),
            startedAt: date("started_at"),
            completedAt: date("completed_at"),
            currentRunStartedAt: date("current_run_started_at"),
            lastHeartbeatAt: date("last_heartbeat_at"),
            latestSummary: text("latest_summary"),
            commentCount: int("comment_count") ?? 0,
            parentCount: json["link_counts"]?["parents"]?.truncatedIntValue ?? 0,
            childCount: json["link_counts"]?["children"]?.truncatedIntValue ?? 0,
            progress: progress,
            warningCount: json["warnings"]?["count"]?.truncatedIntValue ?? 0,
            blockKind: text("block_kind"),
            consecutiveFailures: int("consecutive_failures") ?? 0,
            lastFailureError: text("last_failure_error"),
            branchName: text("branch_name"),
            workspaceKind: text("workspace_kind"),
            workspacePath: text("workspace_path"),
            sessionID: text("session_id"),
            projectID: text("project_id"),
            result: text("result"),
            modelOverride: text("model_override")
        )
    }

    public static func == (lhs: BoardCard, rhs: BoardCard) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.body == rhs.body && lhs.column == rhs.column
            && lhs.assignee == rhs.assignee && lhs.priority == rhs.priority && lhs.createdAt == rhs.createdAt
            && lhs.startedAt == rhs.startedAt && lhs.completedAt == rhs.completedAt
            && lhs.currentRunStartedAt == rhs.currentRunStartedAt && lhs.lastHeartbeatAt == rhs.lastHeartbeatAt
            && lhs.latestSummary == rhs.latestSummary && lhs.commentCount == rhs.commentCount
            && lhs.parentCount == rhs.parentCount && lhs.childCount == rhs.childCount
            && lhs.progress?.done == rhs.progress?.done && lhs.progress?.total == rhs.progress?.total
            && lhs.warningCount == rhs.warningCount && lhs.blockKind == rhs.blockKind
            && lhs.consecutiveFailures == rhs.consecutiveFailures && lhs.lastFailureError == rhs.lastFailureError
            && lhs.branchName == rhs.branchName && lhs.workspaceKind == rhs.workspaceKind
            && lhs.workspacePath == rhs.workspacePath && lhs.sessionID == rhs.sessionID && lhs.result == rhs.result
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(column)
        hasher.combine(title)
    }

    /// The short id on the card ("3fa2"): the end of `t_<hex>`.
    public var shortID: String {
        let hex = id.hasPrefix("t_") ? String(id.dropFirst(2)) : id
        return String(hex.suffix(4))
    }

    /// A worker that hasn't been heard from in this long has gone quiet ("No word for 9 min").
    /// Workers touch their heartbeat with every streamed chunk (`_touch_activity`); the
    /// dispatcher only reclaims after an hour, the desktop dims after two minutes.
    public static let staleAfter: TimeInterval = 5 * 60

    /// What the card shows, from the board's facts and, for cards that wait or are in review,
    /// what their detail added (`BoardCardExtras`).
    public func state(now: Date = .now, extras: BoardCardExtras? = nil) -> BoardCardState {
        switch column {
        case "running":
            let heard = lastHeartbeatAt ?? currentRunStartedAt ?? startedAt
            if let heard, now.timeIntervalSince(heard) > Self.staleAfter { return .stale(since: heard) }
            return .running(since: currentRunStartedAt ?? startedAt)
        case "blocked":
            if consecutiveFailures > 0, lastFailureError != nil { return .gaveUp(tries: consecutiveFailures) }
            if blockKind == "transient" { return .blocked }
            return .needsYou
        case "review":
            return .review
        case "done":
            return .done(at: completedAt)
        default:
            if let split = extras?.split { return .parent(done: split.done, total: split.total) }
            if column == "todo", parentCount > 0 {
                let open = extras?.openParents ?? parentCount
                if open > 0 { return .waiting(parents: open) }
            }
            return .idle
        }
    }

    /// A card waiting for a person's answer ("Needs you"). A run that gave up shows on its own
    /// and isn't counted here.
    public var needsPerson: Bool {
        switch state() {
        case .needsYou: true
        default: false
        }
    }
}

/// What a card's detail adds to the board: how many cards it still waits for, a split card's
/// progress, and a review's checks. Fetched for the few cards that need it.
public struct BoardCardExtras: Hashable, Sendable {
    public var openParents: Int?
    /// Split into cards (`decompose`): the split card waits on every new card, so its progress
    /// is how many of those are done.
    public var split: BoardProgress?
    public var checks: BoardChecks?

    public init(openParents: Int? = nil, split: BoardProgress? = nil, checks: BoardChecks? = nil) {
        self.openParents = openParents
        self.split = split
        self.checks = checks
    }
}

public struct BoardProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// How a card reads on the board (`kanbanCard` variants). Only running (ink), stale (amber),
/// needs-you (orange) and gave-up (red) use colour.
public enum BoardCardState: Hashable, Sendable {
    case idle
    case running(since: Date?)
    case stale(since: Date)
    case needsYou
    /// Blocked by something that may clear on its own (`transient`).
    case blocked
    case waiting(parents: Int)
    case review
    case gaveUp(tries: Int)
    case done(at: Date?)
    case parent(done: Int, total: Int)
}

/// A column with its cards, as `GET /board` sends them (queue order; Done newest first).
public struct BoardLane: Identifiable, Hashable, Sendable {
    public var key: String
    public var cards: [BoardCard]
    public var id: String { key }

    public init(key: String, cards: [BoardCard]) {
        self.key = key
        self.cards = cards
    }
}

/// `GET /board`.
public struct BoardSnapshot: Hashable, Sendable {
    public var lanes: [BoardLane]
    public var assignees: [String]
    /// Where the event socket resumes (`?since=`).
    public var latestEventID: Int
    /// The gateway's clock, for the run clocks.
    public var now: Date?

    public init(lanes: [BoardLane], assignees: [String] = [], latestEventID: Int = 0, now: Date? = nil) {
        self.lanes = lanes
        self.assignees = assignees
        self.latestEventID = latestEventID
        self.now = now
    }

    public init(json: JSONValue) {
        var lanes: [BoardLane] = []
        if case .array(let columns)? = json["columns"] {
            for column in columns {
                guard let key = column["name"]?.stringValue else { continue }
                let cards: [BoardCard] = if case .array(let rows)? = column["tasks"] { rows.compactMap(BoardCard.init(json:)) } else { [] }
                lanes.append(BoardLane(key: key, cards: cards))
            }
        }
        let assignees: [String] = if case .array(let names)? = json["assignees"] { names.compactMap(\.stringValue) } else { [] }
        self.init(
            lanes: lanes,
            assignees: assignees,
            latestEventID: json["latest_event_id"]?.truncatedIntValue ?? 0,
            now: HermesDate.fromEpoch(json["now"]?.doubleValue)
        )
    }

    public var cards: [BoardCard] { lanes.flatMap(\.cards) }

    public func cards(in column: String) -> [BoardCard] {
        lanes.first { $0.key == column }?.cards ?? []
    }

    public func card(_ id: String) -> BoardCard? {
        for lane in lanes {
            if let card = lane.cards.first(where: { $0.id == id }) { return card }
        }
        return nil
    }

    /// Puts a card where its column says, replacing the old copy (an event, a move, an edit).
    /// A card moved into a column joins its end, except Done, which is newest first.
    public mutating func upsert(_ card: BoardCard) {
        var position: (lane: Int, index: Int)?
        for (laneIndex, lane) in lanes.enumerated() {
            if let index = lane.cards.firstIndex(where: { $0.id == card.id }) { position = (laneIndex, index) }
        }
        if let position, lanes[position.lane].key == card.column {
            lanes[position.lane].cards[position.index] = card
            return
        }
        if let position { lanes[position.lane].cards.remove(at: position.index) }
        guard let target = lanes.firstIndex(where: { $0.key == card.column }) else { return }
        if card.column == "done" {
            lanes[target].cards.insert(card, at: 0)
        } else {
            lanes[target].cards.append(card)
        }
    }

    public mutating func remove(_ id: String) {
        for index in lanes.indices {
            lanes[index].cards.removeAll { $0.id == id }
        }
    }
}

/// A file a worker reported changing (`metadata.changed_files`: paths, or objects with a path
/// and line counts; the field is free-form).
public struct BoardChangedFile: Hashable, Sendable, Identifiable {
    public var path: String
    public var added: Int?
    public var removed: Int?
    public var id: String { path }

    public init(path: String, added: Int? = nil, removed: Int? = nil) {
        self.path = path
        self.added = added
        self.removed = removed
    }

    init?(json: JSONValue) {
        if let path = json.stringValue, !path.isEmpty {
            self.init(path: path)
            return
        }
        guard let path = (json["path"] ?? json["file"] ?? json["filename"])?.stringValue, !path.isEmpty else { return nil }
        func count(_ keys: String...) -> Int? {
            keys.lazy.compactMap { json[$0]?.truncatedIntValue }.first
        }
        self.init(path: path, added: count("additions", "added", "insertions"), removed: count("deletions", "removed"))
    }
}

/// One attempt at a card (`runs[]`).
public struct BoardRun: Identifiable, Hashable, Sendable {
    public var id: Int
    public var profile: String?
    /// `running`, `done`, `blocked`, `crashed`, `timed_out`, `reclaimed`, `gave_up`, …
    public var status: String
    public var outcome: String?
    public var summary: String?
    public var error: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var lastHeartbeatAt: Date?
    /// Files the worker reported changing (`metadata.changed_files`).
    public var changedFiles: [BoardChangedFile]
    public var metadata: JSONValue?

    public init(
        id: Int, profile: String? = nil, status: String, outcome: String? = nil, summary: String? = nil, error: String? = nil,
        startedAt: Date? = nil, endedAt: Date? = nil, lastHeartbeatAt: Date? = nil, changedFiles: [BoardChangedFile] = [], metadata: JSONValue? = nil
    ) {
        self.id = id
        self.profile = profile
        self.status = status
        self.outcome = outcome
        self.summary = summary
        self.error = error
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.changedFiles = changedFiles
        self.metadata = metadata
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.doubleValue else { return nil }
        // Older rows stored the metadata as a JSON string.
        var metadata = json["metadata"]
        if let text = metadata?.stringValue { metadata = JSONValue.parse(text) }
        var files: [BoardChangedFile] = []
        if case .array(let rows)? = metadata?["changed_files"] {
            files = rows.compactMap(BoardChangedFile.init(json:))
        }
        self.init(
            id: Int(id),
            profile: json["profile"]?.stringValue,
            status: json["status"]?.stringValue ?? "",
            outcome: json["outcome"]?.stringValue,
            summary: json["summary"]?.stringValue,
            error: json["error"]?.stringValue,
            startedAt: HermesDate.fromEpoch(json["started_at"]?.doubleValue),
            endedAt: HermesDate.fromEpoch(json["ended_at"]?.doubleValue),
            lastHeartbeatAt: HermesDate.fromEpoch(json["last_heartbeat_at"]?.doubleValue),
            changedFiles: files,
            metadata: metadata
        )
    }

    public var isActive: Bool { endedAt == nil && status == "running" }
}

/// A comment on a card (`comments[]`): the person's or a worker's words.
public struct BoardComment: Identifiable, Hashable, Sendable {
    public var id: Int
    public var author: String
    public var body: String
    public var createdAt: Date?

    public init(id: Int, author: String, body: String, createdAt: Date? = nil) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.doubleValue else { return nil }
        self.init(
            id: Int(id),
            author: json["author"]?.stringValue ?? "",
            body: json["body"]?.stringValue ?? "",
            createdAt: HermesDate.fromEpoch(json["created_at"]?.doubleValue)
        )
    }

    /// Written in this app, the desktop or the dashboard rather than by a Bot.
    public var isFromPerson: Bool {
        ["dashboard", "app", "you", "user", ""].contains(author.lowercased())
    }
}

/// Something that happened to a card (`events[]`, and each frame of the event socket).
public struct BoardEvent: Identifiable, Hashable, Sendable {
    public var id: Int
    /// Present on socket frames; the detail's events are all one card's.
    public var cardID: String?
    public var runID: Int?
    public var kind: String
    public var payload: JSONValue?
    public var createdAt: Date?

    public init(id: Int, cardID: String? = nil, runID: Int? = nil, kind: String, payload: JSONValue? = nil, createdAt: Date? = nil) {
        self.id = id
        self.cardID = cardID
        self.runID = runID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.doubleValue, let kind = json["kind"]?.stringValue else { return nil }
        var payload = json["payload"]
        if let text = payload?.stringValue { payload = JSONValue.parse(text) }
        if payload == .null { payload = nil }
        self.init(
            id: Int(id),
            cardID: json["task_id"]?.stringValue,
            runID: json["run_id"]?.truncatedIntValue,
            kind: kind,
            payload: payload,
            createdAt: HermesDate.fromEpoch(json["created_at"]?.doubleValue)
        )
    }

    /// Heartbeats and claim upkeep: they move no card and say nothing to a person.
    public var isQuiet: Bool {
        ["heartbeat", "claim_extended", "reclaim_deferred", "worker_registered", "respawn_guarded"].contains(kind)
    }
}

/// A linked card (`link_tasks[]`), so parents and sub-cards show titles.
public struct BoardLinkedCard: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var column: String
    public var latestSummary: String?
}

/// The PR and its required checks, from the latest `pr_acceptance` event: what Approve waits on.
public struct BoardChecks: Hashable, Sendable {
    public struct Check: Hashable, Sendable, Identifiable {
        public var name: String
        /// `success`, `failure`, `pending`, `missing`, `stale` or `infra`.
        public var classification: String
        public var url: URL?
        public var id: String { name + (url?.absoluteString ?? "") }

        public var passed: Bool { classification == "success" }
        public var failed: Bool { !passed && classification != "pending" }
    }

    public var ok: Bool
    /// The overall verdict (`success`, `failure`, `missing`, `auth`, `infra`, `stale`, …).
    public var classification: String
    public var prURL: URL?
    public var headSHA: String?
    public var checks: [Check]
    /// Why the gateway couldn't read or accept the checks.
    public var detail: String?
    public var at: Date?

    public init(ok: Bool, classification: String, prURL: URL? = nil, headSHA: String? = nil, checks: [Check] = [], detail: String? = nil, at: Date? = nil) {
        self.ok = ok
        self.classification = classification
        self.prURL = prURL
        self.headSHA = headSHA
        self.checks = checks
        self.detail = detail
        self.at = at
    }

    public init?(event: BoardEvent) {
        guard event.kind == "pr_acceptance", let payload = event.payload else { return nil }
        var checks: [Check] = []
        if case .array(let rows)? = payload["checks"] {
            for row in rows {
                guard let name = row["name"]?.stringValue else { continue }
                checks.append(Check(
                    name: name,
                    classification: row["classification"]?.stringValue ?? "missing",
                    url: row["url"]?.stringValue.flatMap(URL.init(string:))
                ))
            }
        }
        self.init(
            ok: payload["ok"]?.boolValue ?? false,
            classification: payload["classification"]?.stringValue ?? "missing",
            prURL: payload["pr_url"]?.stringValue.flatMap(URL.init(string:)),
            headSHA: payload["head_sha"]?.stringValue,
            checks: checks,
            detail: payload["detail"]?.stringValue,
            at: event.createdAt
        )
    }

    /// The PR's number, from its URL (`…/pull/142`).
    public var prNumber: Int? {
        guard let parts = prURL?.pathComponents, let index = parts.lastIndex(of: "pull"), index + 1 < parts.count else { return nil }
        return Int(parts[index + 1])
    }

    public var failingCount: Int { checks.filter(\.failed).count }
    public var pendingCount: Int { checks.filter { $0.classification == "pending" }.count }
}

/// `GET /tasks/{id}`: the card and everything about it.
public struct BoardCardDetail: Hashable, Sendable {
    public var card: BoardCard
    /// Oldest first.
    public var comments: [BoardComment]
    /// Oldest first.
    public var events: [BoardEvent]
    public var parents: [String]
    public var children: [String]
    public var linkedCards: [BoardLinkedCard]
    /// Oldest first.
    public var runs: [BoardRun]

    public init(card: BoardCard, comments: [BoardComment] = [], events: [BoardEvent] = [], parents: [String] = [], children: [String] = [],
                linkedCards: [BoardLinkedCard] = [], runs: [BoardRun] = []) {
        self.card = card
        self.comments = comments
        self.events = events
        self.parents = parents
        self.children = children
        self.linkedCards = linkedCards
        self.runs = runs
    }

    public init?(json: JSONValue) {
        guard let taskJSON = json["task"], let card = BoardCard(json: taskJSON) else { return nil }
        func rows(_ key: String) -> [JSONValue] {
            if case .array(let rows)? = json[key] { rows } else { [] }
        }
        func ids(_ key: String) -> [String] {
            if case .array(let rows)? = json["links"]?[key] { rows.compactMap(\.stringValue) } else { [] }
        }
        var summaries: [String: String] = [:]
        for row in rows("child_results") {
            if let id = row["id"]?.stringValue, let summary = row["latest_summary"]?.stringValue { summaries[id] = summary }
        }
        self.init(
            card: card,
            comments: rows("comments").compactMap(BoardComment.init(json:)),
            events: rows("events").compactMap(BoardEvent.init(json:)),
            parents: ids("parents"),
            children: ids("children"),
            linkedCards: rows("link_tasks").compactMap { row in
                guard let id = row["id"]?.stringValue else { return nil }
                return BoardLinkedCard(id: id, title: row["title"]?.stringValue ?? id, column: row["status"]?.stringValue ?? "", latestSummary: summaries[id])
            },
            runs: rows("runs").compactMap(BoardRun.init(json:))
        )
    }

    /// What the board shows from this detail.
    public var extras: BoardCardExtras {
        let parentsDone = parentCards.filter { $0.column == "done" || $0.column == BoardWorkflow.archived }.count
        let split = events.contains { $0.kind == "decomposed" } && !parents.isEmpty
        return BoardCardExtras(
            openParents: parents.count - parentsDone,
            split: split ? BoardProgress(done: parentsDone, total: parents.count) : nil,
            checks: checks
        )
    }

    /// The checks from the latest `pr_acceptance` event, if the card has a PR.
    public var checks: BoardChecks? {
        events.last { $0.kind == "pr_acceptance" }.flatMap(BoardChecks.init(event:))
    }

    /// What a blocked card asks: the latest block's reason, else the latest summary.
    public var question: String? {
        if let event = events.last(where: { $0.kind == "blocked" || $0.kind == "block_loop_detected" }),
           let reason = event.payload?["reason"]?.stringValue, !reason.isEmpty {
            return reason
        }
        return card.latestSummary
    }

    public var activeRun: BoardRun? { runs.last { $0.isActive } }

    /// Files the latest finished attempt changed.
    public var changedFiles: [BoardChangedFile] {
        runs.last { !$0.changedFiles.isEmpty }?.changedFiles ?? []
    }

    /// Why the gateway refused to finish it (a failed acceptance writes this).
    public var refusal: String? { card.lastFailureError }

    public var parentCards: [BoardLinkedCard] { linkedCards.filter { parents.contains($0.id) } }
    public var childCards: [BoardLinkedCard] { linkedCards.filter { children.contains($0.id) } }

    /// The latest comment from someone reviewing (a Bot's note on Review).
    public var reviewerComment: BoardComment? {
        comments.last { !$0.isFromPerson && $0.author == card.assignee }
    }
}

/// A board on the gateway (`GET /boards`). The app keeps one per project.
public struct BoardInfo: Identifiable, Hashable, Sendable {
    public var slug: String
    public var name: String?
    public var projectID: String?
    public var projectName: String?
    public var total: Int
    public var defaultWorkdir: String?
    /// `worktree` (a git repo), `dir` or `scratch`: what new cards work in by default.
    public var defaultWorkspaceKind: String?
    public var id: String { slug }

    public init(slug: String, name: String? = nil, projectID: String? = nil, projectName: String? = nil, total: Int = 0,
                defaultWorkdir: String? = nil, defaultWorkspaceKind: String? = nil) {
        self.slug = slug
        self.name = name
        self.projectID = projectID
        self.projectName = projectName
        self.total = total
        self.defaultWorkdir = defaultWorkdir
        self.defaultWorkspaceKind = defaultWorkspaceKind
    }

    public init?(json: JSONValue) {
        guard let slug = json["slug"]?.stringValue, !slug.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            guard let value = json[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        self.init(
            slug: slug, name: text("name"), projectID: text("project_id"), projectName: text("project_name"),
            total: json["total"]?.truncatedIntValue ?? 0,
            defaultWorkdir: text("default_workdir"), defaultWorkspaceKind: text("default_workspace_kind")
        )
    }
}

/// What a new card asks for (`POST /tasks`).
public struct NewBoardCard: Hashable, Sendable {
    public enum WorksIn: String, Hashable, Sendable, CaseIterable {
        /// Its own git worktree (`.worktrees/t_<hex>` in the project's repo).
        case worktree
        /// The project folder itself.
        case dir
        /// A throwaway folder.
        case scratch
    }

    public var title: String
    public var body: String
    public var assignee: String?
    public var priority: Int
    public var parents: [String]
    /// Lands in Triage, for Hermes to write up (`specify`).
    public var triage: Bool
    public var worksIn: WorksIn?
    public var workspacePath: String?
    public var projectID: String?
    public var skills: [String]?

    public init(title: String, body: String = "", assignee: String? = nil, priority: Int = 0, parents: [String] = [], triage: Bool = false,
                worksIn: WorksIn? = nil, workspacePath: String? = nil, projectID: String? = nil, skills: [String]? = nil) {
        self.title = title
        self.body = body
        self.assignee = assignee
        self.priority = priority
        self.parents = parents
        self.triage = triage
        self.worksIn = worksIn
        self.workspacePath = workspacePath
        self.projectID = projectID
        self.skills = skills
    }

    var json: JSONValue {
        var body: [String: JSONValue] = ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "priority": .number(Double(priority)), "triage": .bool(triage)]
        let text = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body["body"] = .string(text) }
        if let assignee, !assignee.isEmpty { body["assignee"] = .string(assignee) }
        if !parents.isEmpty { body["parents"] = .array(parents.map(JSONValue.string)) }
        if let worksIn { body["workspace_kind"] = .string(worksIn.rawValue) }
        if let workspacePath, !workspacePath.isEmpty { body["workspace_path"] = .string(workspacePath) }
        if let projectID, !projectID.isEmpty { body["project_id"] = .string(projectID) }
        if let skills { body["skills"] = .array(skills.map(JSONValue.string)) }
        return .object(body)
    }
}

/// `POST /tasks`: the card, and a warning when nothing will pick it up (no dispatcher running).
public struct BoardCreated: Sendable {
    public var card: BoardCard?
    public var warning: String?
}

/// A rough size from the auxiliary model (`POST /estimate`). Never money.
public struct BoardEstimate: Hashable, Sendable {
    public var ok: Bool
    public var reason: String?
    public var tokens: Int
    /// `S`, `M` or `L`.
    public var complexity: String?

    public init(ok: Bool, reason: String? = nil, tokens: Int = 0, complexity: String? = nil) {
        self.ok = ok
        self.reason = reason
        self.tokens = tokens
        self.complexity = complexity
    }

    init(json: JSONValue) {
        self.init(
            ok: json["ok"]?.boolValue ?? false,
            reason: json["reason"]?.stringValue,
            tokens: json["est_tokens"]?.truncatedIntValue ?? 0,
            complexity: json["complexity"]?.stringValue
        )
    }
}

/// The worker's output (`GET /tasks/{id}/log`).
public struct BoardWorkerLog: Hashable, Sendable {
    public var exists: Bool
    public var content: String
    public var truncated: Bool

    /// The last `count` non-empty lines.
    public func lastLines(_ count: Int) -> [String] {
        Array(content.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count))
    }
}

/// Split into Cards (`decompose`) and Let Hermes Write It Up (`specify`). Not OK isn't an
/// error: the reason is shown.
public struct BoardHelperOutcome: Hashable, Sendable {
    public var ok: Bool
    public var reason: String?
    public var newTitle: String?
    public var childIDs: [String]

    init(json: JSONValue) {
        ok = json["ok"]?.boolValue ?? false
        reason = json["reason"]?.stringValue
        newTitle = json["new_title"]?.stringValue
        childIDs = if case .array(let rows)? = json["child_ids"] { rows.compactMap(\.stringValue) } else { [] }
    }
}

/// One card's result in a bulk change (`POST /tasks/bulk`).
public struct BoardBulkResult: Hashable, Sendable {
    public var id: String
    public var ok: Bool
    public var error: String?
}

/// The board's events since a cursor (each frame of `WS /events`, or a catch-up).
public struct BoardEventBatch: Sendable {
    public var events: [BoardEvent]
    public var cursor: Int

    public init(events: [BoardEvent], cursor: Int) {
        self.events = events
        self.cursor = cursor
    }

    public init?(json: JSONValue) {
        guard case .array(let rows)? = json["events"] else { return nil }
        let events = rows.compactMap(BoardEvent.init(json:))
        self.init(events: events, cursor: json["cursor"]?.truncatedIntValue ?? events.last?.id ?? 0)
    }

    /// The cards these events touched (a card shows up once, however many events it had).
    public var touchedCards: [String] {
        var seen = Set<String>()
        return events.compactMap { event in
            guard let id = event.cardID, !event.isQuiet, seen.insert(id).inserted else { return nil }
            return id
        }
    }
}

extension BoardCardDetail {
    /// The card as the board shows it, with the counts the board's payload carries and the
    /// detail's own lists stand in for.
    public var boardCard: BoardCard {
        var card = self.card
        card.commentCount = comments.count
        card.parentCount = parents.count
        card.childCount = children.count
        if children.isEmpty {
            card.progress = nil
        } else {
            card.progress = (childCards.filter { $0.column == "done" }.count, children.count)
        }
        if let summary = card.latestSummary, summary.count > 200 { card.latestSummary = String(summary.prefix(200)) }
        return card
    }
}
