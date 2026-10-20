import Foundation

// What Hermes Learned (`docs/learned.md`): the skills Hermes wrote or was taught and the
// memories it keeps, from `GET /api/learning/graph` (`agent/learning_graph.py`). Each Bot
// (profile) learns on its own. Only skills with a learning signal appear: made by Hermes,
// taught with /learn, or used; bundled and external skills never do.

/// One node of the learning graph: a skill or a remembered thing.
public struct LearningNode: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        case skill, memory
    }

    public enum State: String, Sendable, Hashable {
        case active, stale, archived
    }

    /// The skill's name, or `memory:<source>:<index>:<fingerprint>`.
    public var id: String
    public var kind: Kind
    /// The skill's name, or a memory's first line.
    public var label: String
    /// A skill's latest activity (use, view, patch), else when it was written; a memory's file
    /// time. The gateway keeps no separate creation time in the graph.
    public var date: Date?
    /// A skill's category folder; "memory" for memories.
    public var category: String
    public var useCount: Int
    public var state: State
    /// "agent" (Hermes wrote it), "learn" (taught with /learn), "memory", or nil (only used).
    public var createdBy: String?
    /// Keep As Is: the curator leaves it alone.
    public var pinned: Bool
    /// A memory's store: "profile" (About You) or "memory" (Hermes's Notes).
    public var memorySource: String?
    /// When the skill was written (`/curator usage`), when known.
    public var created: Date?

    /// When it was learned: written, else its date.
    public var learnedAt: Date? { created ?? date }

    public var isSkill: Bool { kind == .skill }

    /// Used often enough to draw in ink on the map.
    public var isWellUsed: Bool { useCount >= 6 }

    public init(id: String, kind: Kind, label: String, date: Date? = nil, category: String, useCount: Int = 0,
                state: State = .active, createdBy: String? = nil, pinned: Bool = false, memorySource: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.date = date
        self.category = category
        self.useCount = useCount
        self.state = state
        self.createdBy = createdBy
        self.pinned = pinned
        self.memorySource = memorySource
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let kind = Kind(rawValue: json["kind"]?.stringValue ?? "") else { return nil }
        self.id = id
        self.kind = kind
        label = json["label"]?.stringValue ?? id
        date = json["timestamp"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        category = json["category"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .memory ? "memory" : "general")
        useCount = max(0, json["useCount"]?.truncatedIntValue ?? 0)
        state = State(rawValue: json["state"]?.stringValue ?? "") ?? .active
        createdBy = json["createdBy"]?.stringValue
        pinned = json["pinned"]?.boolValue ?? false
        memorySource = json["memorySource"]?.stringValue
    }
}

/// A line on the map: two related skills, or a memory and a skill it mentions.
public struct LearningEdge: Hashable, Sendable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// Everything a Bot learned (`GET /api/learning/graph`).
public struct LearningGraph: Sendable, Hashable {
    public var nodes: [LearningNode]
    public var edges: [LearningEdge]
    /// Categories with how many nodes each has, biggest first (memories as "memory").
    public var clusters: [(category: String, count: Int)]

    public static func == (a: LearningGraph, b: LearningGraph) -> Bool {
        a.nodes == b.nodes && a.edges == b.edges && a.clusters.map(\.category) == b.clusters.map(\.category)
            && a.clusters.map(\.count) == b.clusters.map(\.count)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(nodes)
        hasher.combine(edges)
    }

    public init(nodes: [LearningNode] = [], edges: [LearningEdge] = [], clusters: [(category: String, count: Int)] = []) {
        self.nodes = nodes
        self.edges = edges
        self.clusters = clusters
    }

    public init(json: JSONValue) {
        nodes = json["nodes"].items.compactMap(LearningNode.init(json:))
        let ids = Set(nodes.map(\.id))
        edges = json["edges"].items.compactMap { edge in
            guard let a = edge["source"]?.stringValue, let b = edge["target"]?.stringValue, ids.contains(a), ids.contains(b), a != b else { return nil }
            return LearningEdge(source: a, target: b)
        }
        clusters = json["clusters"].items.compactMap { row in
            guard let category = row["category"]?.stringValue else { return nil }
            return (category, row["count"]?.truncatedIntValue ?? 0)
        }
        if clusters.isEmpty {
            clusters = Dictionary(grouping: nodes, by: \.category).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        }
    }

    public var skills: [LearningNode] { nodes.filter(\.isSkill) }
    public var memories: [LearningNode] { nodes.filter { !$0.isSkill } }

    /// Skills Hermes wrote or was taught (not ones only used).
    public var learnedSkills: [LearningNode] {
        skills.filter { $0.createdBy == "agent" || $0.createdBy == "learn" }
    }

    public func node(_ id: String) -> LearningNode? { nodes.first { $0.id == id } }

    /// The nodes a node is joined to, skills first, most used first.
    public func connections(of id: String) -> [LearningNode] {
        let others = edges.compactMap { edge -> String? in
            if edge.source == id { return edge.target }
            if edge.target == id { return edge.source }
            return nil
        }
        return Array(Set(others)).compactMap(node).sorted {
            if $0.isSkill != $1.isSkill { return $0.isSkill }
            if $0.useCount != $1.useCount { return $0.useCount > $1.useCount }
            return $0.label < $1.label
        }
    }

    /// Skill categories, biggest first (the map's filter chips).
    public var skillCategories: [String] {
        clusters.map(\.category).filter { $0 != "memory" }
    }

    /// Skills by use, most first; never-used ones left out.
    public var mostUsed: [LearningNode] {
        skills.filter { $0.useCount > 0 && $0.state != .archived }.sorted {
            $0.useCount != $1.useCount ? $0.useCount > $1.useCount : $0.label < $1.label
        }
    }

    /// The earliest date anything was learned ("Since August").
    public var since: Date? { nodes.compactMap(\.learnedAt).min() }

    /// The graph with each skill's creation date from `/curator usage`.
    public func applyingCreationDates(_ dates: [String: Date]) -> LearningGraph {
        var copy = self
        for index in copy.nodes.indices where copy.nodes[index].isSkill {
            copy.nodes[index].created = dates[copy.nodes[index].id]
        }
        return copy
    }
}

/// One week of the story's chart.
public struct LearningWeek: Identifiable, Hashable, Sendable {
    /// The week's first day (Monday, in the calendar given).
    public var start: Date
    public var skills: Int
    public var memories: Int

    public var id: Date { start }
    public var total: Int { skills + memories }

    public init(start: Date, skills: Int, memories: Int) {
        self.start = start
        self.skills = skills
        self.memories = memories
    }
}

extension LearningGraph {
    /// Weekly counts of skills and memories by date, oldest first, ending with the week of `now`.
    /// At most `limit` weeks; weeks with nothing in them stay (an empty bar).
    public func weeks(endingAt now: Date = .now, limit: Int = 12, calendar: Calendar = Self.weekCalendar) -> [LearningWeek] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let dated = nodes.compactMap { node in node.learnedAt.map { (node, $0) } }
        guard let first = dated.map(\.1).min(), let firstWeek = calendar.dateInterval(of: .weekOfYear, for: first)?.start else {
            return []
        }
        let span = (calendar.dateComponents([.weekOfYear], from: firstWeek, to: thisWeek).weekOfYear ?? 0) + 1
        let count = min(max(span, 1), limit)
        var weeks: [LearningWeek] = (0..<count).compactMap { index in
            calendar.date(byAdding: .weekOfYear, value: index - (count - 1), to: thisWeek).map { LearningWeek(start: $0, skills: 0, memories: 0) }
        }
        guard let oldest = weeks.first?.start else { return [] }
        for (node, date) in dated where date >= oldest {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
                  let index = weeks.firstIndex(where: { $0.start == start }) else { continue }
            if node.isSkill { weeks[index].skills += 1 } else { weeks[index].memories += 1 }
        }
        return weeks
    }

    /// Skills Hermes wrote or was taught in the last 7 days, newest first.
    public func newThisWeek(now: Date = .now) -> [LearningNode] {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        return learnedSkills.filter { ($0.learnedAt ?? .distantPast) >= cutoff && $0.state != .archived }
            .sorted { ($0.learnedAt ?? .distantPast) > ($1.learnedAt ?? .distantPast) }
    }

    /// Weeks start on Monday, as the design's axis reads.
    public static var weekCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }
}

// MARK: - The curator

/// The curator's settings (`GET /api/curator`).
public struct CuratorStatus: Sendable, Hashable {
    public var enabled: Bool
    public var paused: Bool
    public var intervalHours: Int?
    public var lastRunAt: Date?
    public var minIdleHours: Double?
    public var staleAfterDays: Int?
    public var archiveAfterDays: Int?

    public init(enabled: Bool = true, paused: Bool = false, intervalHours: Int? = nil, lastRunAt: Date? = nil,
                minIdleHours: Double? = nil, staleAfterDays: Int? = nil, archiveAfterDays: Int? = nil) {
        self.enabled = enabled
        self.paused = paused
        self.intervalHours = intervalHours
        self.lastRunAt = lastRunAt
        self.minIdleHours = minIdleHours
        self.staleAfterDays = staleAfterDays
        self.archiveAfterDays = archiveAfterDays
    }

    public init(json: JSONValue) {
        enabled = json["enabled"]?.boolValue ?? true
        paused = json["paused"]?.boolValue ?? false
        intervalHours = json["interval_hours"]?.truncatedIntValue
        lastRunAt = CuratorReport.date(json["last_run_at"])
        minIdleHours = json["min_idle_hours"]?.doubleValue
        staleAfterDays = json["stale_after_days"]?.truncatedIntValue
        archiveAfterDays = json["archive_after_days"]?.truncatedIntValue
    }

    /// Tidying runs on its schedule: on and not paused.
    public var isRunning: Bool { enabled && !paused }
}

/// What one tidy did (`logs/curator/<stamp>/run.json`).
public struct CuratorReport: Sendable, Hashable {
    public struct Merge: Sendable, Hashable, Identifiable {
        public var name: String
        public var into: String
        public var reason: String
        public var id: String { name }
    }

    public struct Removal: Sendable, Hashable, Identifiable {
        public var name: String
        public var reason: String
        public var id: String { name }
    }

    public var startedAt: Date?
    /// Skills folded into another ("umbrella") skill; each original is archived and restorable.
    public var merges: [Merge]
    /// Skills archived as unused (stale long enough).
    public var archived: [Removal]
    /// Skills marked stale this run.
    public var markedStale: [String]
    public var markedStaleCount: Int
    /// Skills archived for being unused before the review began: run.json only counts them.
    public var autoArchivedCount: Int

    public init(startedAt: Date? = nil, merges: [Merge] = [], archived: [Removal] = [], markedStale: [String] = [], markedStaleCount: Int = 0, autoArchivedCount: Int = 0) {
        self.startedAt = startedAt
        self.merges = merges
        self.archived = archived
        self.markedStale = markedStale
        self.markedStaleCount = max(markedStaleCount, markedStale.count)
        self.autoArchivedCount = autoArchivedCount
    }

    public init(json: JSONValue) {
        startedAt = Self.date(json["started_at"])
        merges = json["consolidated"].items.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return Merge(name: name, into: row["into"]?.stringValue ?? "", reason: row["reason"]?.stringValue ?? row["evidence"]?.stringValue ?? "")
        }
        let merged = Set(merges.map(\.name))
        var removals = json["pruned"].items.compactMap { row -> Removal? in
            if let name = row.stringValue { return Removal(name: name, reason: "") }
            guard let name = row["name"]?.stringValue else { return nil }
            return Removal(name: name, reason: row["reason"]?.stringValue ?? "")
        }
        // Auto-archives (stale long enough) show up only as removed names.
        for name in json["archived"].items.compactMap(\.stringValue) where !merged.contains(name) && !removals.contains(where: { $0.name == name }) {
            removals.append(Removal(name: name, reason: ""))
        }
        archived = removals
        markedStale = json["state_transitions"].items.compactMap { row in
            row["to"]?.stringValue == "stale" ? row["name"]?.stringValue : nil
        }
        markedStaleCount = max(markedStale.count, json["auto_transitions"]?["marked_stale"]?.truncatedIntValue ?? 0)
        autoArchivedCount = json["auto_transitions"]?["archived"]?.truncatedIntValue ?? 0
    }

    /// Everything archived: by name, and the unused ones only counted.
    public var archivedCount: Int { archived.count + autoArchivedCount }

    /// Whether this tidy changed anything.
    public var changedSomething: Bool { !merges.isEmpty || archivedCount > 0 || markedStaleCount > 0 }

    /// The umbrellas merges went into, with the skills each absorbed.
    public var mergeGroups: [(into: String, names: [String], reason: String)] {
        var order: [String] = []
        var groups: [String: [Merge]] = [:]
        for merge in merges {
            if groups[merge.into] == nil { order.append(merge.into) }
            groups[merge.into, default: []].append(merge)
        }
        return order.map { into in (into, groups[into]!.map(\.name), groups[into]!.first(where: { !$0.reason.isEmpty })?.reason ?? "") }
    }

    /// A date from epoch seconds or ISO 8601.
    static func date(_ value: JSONValue?) -> Date? {
        if let seconds = value?.doubleValue { return Date(timeIntervalSince1970: seconds) }
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        // Naive local time (`datetime.now().isoformat()`).
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - `/curator` replies

/// The `/curator` command's text replies (pin, unpin, restore, list-archived), read in one place:
/// the gateway has no structured calls for them yet, so anything unexpected reads as the
/// gateway's own words.
public enum CuratorReply {
    public struct Outcome: Sendable, Hashable {
        public var ok: Bool
        /// The gateway's sentence, without the `curator:` prefix.
        public var message: String
    }

    /// `pinned 'x' (…)`, `unpinned 'x'`, `restored 'x' …`; anything else is a refusal.
    public static func outcome(_ raw: String, verb: String) -> Outcome {
        let text = clean(raw)
        let line = text.split(separator: "\n").map { strip(String($0)) }.first { !$0.isEmpty } ?? ""
        let lowered = line.lowercased()
        let refusals = ["cannot", "could not", "couldn't", "not found", "no such", "is bundled", "is pinned", "error", "failed",
                        "nothing to", "unknown", "usage:", "not archived", "doesn't exist", "does not exist",
                        "no archive", "already exists", "would shadow"]
        if refusals.contains(where: { lowered.contains($0) }) { return Outcome(ok: false, message: line) }
        let ok = lowered.hasPrefix(verb) || lowered.contains(" \(verb) ") || lowered.contains("\(verb) '")
            || (verb == "restore" && lowered.contains("restored"))
        return Outcome(ok: ok, message: line.isEmpty ? text : line)
    }

    /// `usage --json`: each skill's creation date, by name. Anything unreadable is left out.
    public static func creationDates(_ raw: String) -> [String: Date] {
        let text = clean(raw)
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let rows = JSONValue.parse(data) else { return [:] }
        var dates: [String: Date] = [:]
        for row in rows.items {
            guard let name = row["name"]?.stringValue, let date = CuratorReport.date(row["created_at"]) else { continue }
            dates[name] = date
        }
        return dates
    }

    /// `list-archived`: one skill name per line, or "no archived skills".
    public static func archivedNames(_ raw: String) -> [String] {
        let text = clean(raw)
        if text.lowercased().contains("no archived skills") { return [] }
        return text.split(separator: "\n").compactMap { line in
            var name = strip(String(line)).trimmingCharacters(in: CharacterSet(charactersIn: "•-* \t"))
            if let space = name.firstIndex(where: \.isWhitespace) { name = String(name[..<space]) }
            guard !name.isEmpty, !name.hasSuffix(":"), name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil else { return nil }
            return name
        }
    }

    /// Without ANSI colours and carriage returns.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strip(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("curator:") { text = String(text.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        return text
    }
}
