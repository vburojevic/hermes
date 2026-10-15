import Foundation

// Helpers: Hermes's delegated sub-agents (`delegate_task`), running in parallel and, with
// `delegation.max_spawn_depth` ≥ 2, delegating in turn (`docs/helpers.md`).
//
// Wire facts (tui_gateway, verified against the source):
// - `subagent.*` events arrive on the PARENT's runtime session, with no timestamps; the app stamps
//   arrival. Falsy keys are left out, not sent as null.
// - `task_index` is 0-based; `depth` is 0 for a helper Hermes started itself; `parent_id` names the
//   helper that started this one and is absent at depth 0.
// - Top-level delegations run in the background: helper events go on after the turn's
//   `message.complete`, and the results come back as a new turn.

/// `SubagentStatus` (`contracts/common.py`). `queued` and `running` are live; the rest are final.
public enum HelperStatus: String, Sendable, Hashable, CaseIterable {
    case queued, running, completed, failed, error, timeout, interrupted

    public init(wire: String?) {
        switch wire?.lowercased() {
        case "queued", "pending", "waiting": self = .queued
        case "running", "started", "active", nil, "": self = .running
        case "completed", "complete", "ok", "success", "done": self = .completed
        case "timeout", "timed_out", "stalled": self = .timeout
        case "interrupted", "cancelled", "canceled": self = .interrupted
        case "error": self = .error
        default: self = .failed
        }
    }

    public var isLive: Bool { self == .queued || self == .running }
    public var isFinished: Bool { !isLive }
    /// Failed, errored or timed out (interrupted is its own, quieter outcome).
    public var isFailure: Bool { self == .failed || self == .error || self == .timeout }
}

/// One of the last tool results (`output_tail`).
public struct HelperOutputLine: Hashable, Sendable {
    public var tool: String
    public var preview: String
    public var isError: Bool

    public init(tool: String, preview: String, isError: Bool = false) {
        self.tool = tool
        self.preview = preview
        self.isError = isError
    }
}

/// One helper, as the events, `subagent.list` and saved spawn trees describe it.
public struct Helper: Identifiable, Hashable, Sendable {
    /// `subagent_id` (`sa-<index>-<hex>`).
    public var id: String
    /// The helper that started this one; nil at depth 0.
    public var parentID: String?
    public var depth: Int
    public var goal: String
    /// 0-based, within its delegation.
    public var taskIndex: Int
    public var taskCount: Int
    public var model: String?
    public var delegationID: String?
    /// The helper's own stored session.
    public var childSessionID: String?
    public var status: HelperStatus
    public var startedAt: Date?
    public var finishedAt: Date?
    public var durationSeconds: Double?
    public var toolCount: Int
    /// The tool it's in now, and what that call is about.
    public var currentTool: String?
    public var currentToolPreview: String?
    /// The last few tools it ran, newest last ("read_file  Hermes.xcodeproj/…").
    public var recentTools: [HelperOutputLine]
    public var thinking: String?
    public var summary: String?
    /// Why it failed ("Timed out after 600s"), from `text` on a failed `subagent.complete`.
    public var failureText: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var apiCalls: Int?
    public var filesRead: [String]
    public var filesWritten: [String]
    public var outputTail: [HelperOutputLine]
    /// False once Hermes has drained the last steer (`subagent.list`).
    public var acceptingSteer: Bool
    /// It wrote files while running (a write tool ran), so Stop asks first.
    public var hasWritten: Bool
    /// It finished while the app wasn't watching: no result came in.
    public var endedUnseen: Bool

    public init(
        id: String, parentID: String? = nil, depth: Int = 0, goal: String, taskIndex: Int = 0, taskCount: Int = 1,
        model: String? = nil, delegationID: String? = nil, status: HelperStatus = .running, startedAt: Date? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.depth = depth
        self.goal = goal
        self.taskIndex = taskIndex
        self.taskCount = taskCount
        self.model = model
        self.delegationID = delegationID
        self.status = status
        self.startedAt = startedAt
        toolCount = 0
        recentTools = []
        filesRead = []
        filesWritten = []
        outputTail = []
        acceptingSteer = true
        hasWritten = false
        endedUnseen = false
    }

    public var totalTokens: Int? {
        let parts = [inputTokens, outputTokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// The note Hermes appends to the summary when a steer arrived after the helper's last step:
    /// "[steer did not land — the subagent finished before it could be delivered: <text>]".
    public var missedSteerText: String? {
        guard let summary, let range = summary.range(of: "[steer did not land") else { return nil }
        let tail = summary[range.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return "" }
        var text = tail[tail.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("]") { text.removeLast() }
        return text
    }

    /// The summary without Hermes's missed-steer note.
    public var cleanSummary: String? {
        guard let summary else { return nil }
        if let range = summary.range(of: "[steer did not land") {
            let cleaned = summary[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        return summary
    }

    static let writeTools: Set<String> = ["write_file", "patch", "edit_file", "apply_patch", "str_replace", "create_file", "file_write"]
}

/// A delegation's helpers, with the ones they started under them.
public struct HelperTeam: Identifiable, Hashable, Sendable {
    /// The delegation id of its top-level call, or the first helper's id when Hermes didn't send one.
    public var id: String
    public var helpers: [String: Helper]
    /// Arrival order, for stable ordering of helpers with the same index.
    public var order: [String]
    /// The `delegate_task` call this team came from, when known.
    public var callID: String?
    /// The parent runtime session.
    public var sessionID: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Saved to the gateway's spawn-tree archive (`spawn_tree.save`).
    public var savedPath: String?
    /// Known only from `subagent.list`'s failed delegations: the saved tree has the rest.
    public var isPartial = false

    public init(id: String, callID: String? = nil, sessionID: String? = nil, startedAt: Date? = nil) {
        self.id = id
        helpers = [:]
        order = []
        self.callID = callID
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    // MARK: Shape

    /// Helpers Hermes started itself, in `task_index` order.
    public var topLevel: [Helper] {
        sorted(helpers.values.filter { $0.parentID == nil || helpers[$0.parentID!] == nil })
    }

    /// The helpers this one started, in `task_index` order.
    public func children(of id: String) -> [Helper] {
        sorted(helpers.values.filter { $0.parentID == id })
    }

    private func sorted(_ list: [Helper]) -> [Helper] {
        list.sorted { a, b in
            if a.taskIndex != b.taskIndex { return a.taskIndex < b.taskIndex }
            return (order.firstIndex(of: a.id) ?? 0) < (order.firstIndex(of: b.id) ?? 0)
        }
    }

    /// "1", or "1.2" for the second helper started by helper 1.
    public func number(of helper: Helper) -> String {
        var parts = ["\(helper.taskIndex + 1)"]
        var current = helper
        var guardDepth = 0
        while let parent = current.parentID.flatMap({ helpers[$0] }), guardDepth < 8 {
            parts.insert("\(parent.taskIndex + 1)", at: 0)
            current = parent
            guardDepth += 1
        }
        return parts.joined(separator: ".")
    }

    /// How many helpers the delegation asked for (its `task_count`), at least as many as seen.
    public var total: Int {
        max(topLevel.map(\.taskCount).max() ?? 0, topLevel.count)
    }

    /// Everyone on the team: the delegation's helpers and the ones they started ("Team · 5 helpers").
    public var everyone: Int {
        total + helpers.values.filter { $0.parentID.map { helpers[$0] != nil } ?? false }.count
    }

    public var all: [Helper] { Array(helpers.values) }
    public var runningCount: Int { helpers.values.filter { $0.status == .running }.count }
    public var waitingCount: Int { helpers.values.filter { $0.status == .queued }.count }
    public var doneCount: Int { helpers.values.filter(\.status.isFinished).count }
    public var failedCount: Int { helpers.values.filter(\.status.isFailure).count }
    public var isLive: Bool { helpers.values.contains { $0.status.isLive } }
    /// Every helper has finished (and at least one existed).
    public var isFinished: Bool { !helpers.isEmpty && !isLive }

    /// From the first start to the last finish.
    public var duration: TimeInterval? {
        let starts = helpers.values.compactMap(\.startedAt)
        guard let first = startedAt ?? starts.min() else { return nil }
        let ends = helpers.values.compactMap { helper -> Date? in
            if let finished = helper.finishedAt { return finished }
            if let start = helper.startedAt, let seconds = helper.durationSeconds { return start.addingTimeInterval(seconds) }
            return nil
        }
        guard let last = finishedAt ?? ends.max() else { return nil }
        return max(0, last.timeIntervalSince(first))
    }

    func contains(_ id: String) -> Bool { helpers[id] != nil }

    mutating func upsert(_ helper: Helper) {
        if helpers[helper.id] == nil { order.append(helper.id) }
        helpers[helper.id] = helper
    }
}

/// `delegation.status`: gateway-wide limits and the pause switch.
public struct DelegationStatus: Hashable, Sendable {
    /// New helpers can't start (`delegation.pause`); running ones finish. Process-wide, not saved.
    public var paused: Bool
    public var maxConcurrentChildren: Int
    public var maxSpawnDepth: Int
    /// Every live helper on the gateway, any session.
    public var activeCount: Int

    public init(paused: Bool = false, maxConcurrentChildren: Int = 10, maxSpawnDepth: Int = 1, activeCount: Int = 0) {
        self.paused = paused
        self.maxConcurrentChildren = maxConcurrentChildren
        self.maxSpawnDepth = maxSpawnDepth
        self.activeCount = activeCount
    }
}

/// `subagent.tail`: the end of a helper's live transcript.
public struct HelperTail: Hashable, Sendable {
    /// False once the helper has finished (the gateway only tails live helpers).
    public var available: Bool
    /// At most the last 16 KB; it can start mid-line.
    public var text: String
    public var truncated: Bool
}

/// `subagent.steer`.
public enum HelperSteerResult: String, Sendable {
    /// Accepted; the helper reads it after its current step (or misses it, see `missedSteerText`).
    case queued
    /// Not accepted: it finished, stopped taking notes, or belongs to another client.
    case rejected
}

/// A run saved to the gateway's spawn-tree archive (`spawn_tree.list`).
public struct SpawnTreeEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var sessionID: String
    public var label: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var count: Int

    public var id: String { path }
}
