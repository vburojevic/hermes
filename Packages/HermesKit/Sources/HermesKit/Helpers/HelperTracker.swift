import Foundation

/// A chat's helper teams, built from `subagent.*` events, `subagent.list` snapshots and saved spawn
/// trees. One team per delegation (`delegate_task` call); helpers a helper started join its team
/// under it. Pure state, so the app can coalesce and the tests can drive it.
public struct HelperTracker: Hashable, Sendable {
    public private(set) var teams: [String: HelperTeam] = [:]
    /// Teams in the order they appeared.
    public private(set) var teamOrder: [String] = []
    /// `delegate_task` calls that started but haven't been matched to a team yet, oldest first.
    private var openCalls: [String] = []
    /// Which team each helper is in.
    private var helperTeam: [String: String] = [:]

    public init() {}

    public var orderedTeams: [HelperTeam] { teamOrder.compactMap { teams[$0] } }

    public func team(id: String) -> HelperTeam? { teams[id] }

    public func team(forCall callID: String) -> HelperTeam? {
        teams.values.first { $0.callID == callID }
    }

    public func team(containing helperID: String) -> HelperTeam? {
        helperTeam[helperID].flatMap { teams[$0] }
    }

    public func helper(_ id: String) -> Helper? {
        team(containing: id)?.helpers[id]
    }

    public var hasLiveHelpers: Bool { teams.values.contains(where: \.isLive) }

    // MARK: The parent turn's delegate_task call

    /// A `delegate_task` call started: the next team that appears belongs to it.
    public mutating func delegationStarted(callID: String) {
        guard !openCalls.contains(callID), team(forCall: callID) == nil else { return }
        openCalls.append(callID)
    }

    /// The call returned. In background mode its result names the delegation and its helpers:
    /// `{status: "dispatched", delegation_id, subagent_ids, goals, count, …}`.
    public mutating func delegationReturned(callID: String, result: JSONValue?, sessionID: String?, now: Date = .now) {
        let object = Self.object(result)
        guard let delegationID = object?["delegation_id"]?.stringValue, !delegationID.isEmpty else { return }
        var team = teams[delegationID] ?? HelperTeam(id: delegationID, callID: callID, sessionID: sessionID, startedAt: now)
        team.callID = callID
        if team.sessionID == nil { team.sessionID = sessionID }
        // The call names every helper before all have started (workers can start before it
        // returns): the ones not seen yet are waiting to start.
        if case .array(let goals)? = object?["goals"], case .array(let ids)? = object?["subagent_ids"], goals.count == ids.count {
            for (index, pair) in zip(goals, ids).enumerated() {
                guard let id = pair.1.stringValue, let goal = pair.0.stringValue, team.helpers[id] == nil else { continue }
                team.upsert(Helper(id: id, goal: goal, taskIndex: index, taskCount: goals.count, delegationID: delegationID, status: .queued, startedAt: nil))
                helperTeam[id] = delegationID
            }
        }
        team.finishedAt = team.isFinished ? team.finishedAt : nil
        insert(team)
        teams[delegationID] = team
        openCalls.removeAll { $0 == callID }
    }

    /// Reads a tool result that may be JSON text.
    public static func object(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .object?: value
        case .string(let text)?: JSONValue.parse(text).flatMap { if case .object = $0 { $0 } else { nil } }
        default: nil
        }
    }

    // MARK: Events

    /// Applies one `subagent.*` event; false when it changed nothing.
    @discardableResult
    public mutating func apply(type: String, payload: JSONValue, sessionID: String? = nil, now: Date = .now) -> Bool {
        guard type.hasPrefix("subagent."), let id = payload["subagent_id"]?.stringValue, !id.isEmpty else { return false }
        let teamID = teamID(for: id, payload: payload, sessionID: sessionID, now: now)
        guard var team = teams[teamID] else { return false }
        var helper = team.helpers[id] ?? Helper(
            id: id,
            goal: payload["goal"]?.stringValue ?? "",
            taskIndex: Self.int(payload["task_index"]) ?? Self.index(fromID: id) ?? team.helpers.count,
            status: .queued
        )
        fill(&helper, from: payload)

        switch type {
        case "subagent.spawn_requested":
            if helper.status == .queued { helper.status = .queued }
        case "subagent.start":
            helper.status = .running
            if helper.startedAt == nil { helper.startedAt = now }
        case "subagent.thinking":
            if helper.status == .queued { helper.status = .running; helper.startedAt = helper.startedAt ?? now }
            if let text = payload["text"]?.stringValue, !text.isEmpty { helper.thinking = text }
        case "subagent.tool":
            if helper.status == .queued { helper.status = .running; helper.startedAt = helper.startedAt ?? now }
            let name = payload["tool_name"]?.stringValue ?? helper.currentTool ?? "tool"
            let preview = payload["tool_preview"]?.stringValue ?? payload["text"]?.stringValue ?? ""
            helper.currentTool = name
            helper.currentToolPreview = preview
            helper.recentTools.append(HelperOutputLine(tool: name, preview: preview))
            if helper.recentTools.count > 3 { helper.recentTools.removeFirst(helper.recentTools.count - 3) }
            if Helper.writeTools.contains(name) { helper.hasWritten = true }
        case "subagent.progress":
            if helper.status == .queued { helper.status = .running; helper.startedAt = helper.startedAt ?? now }
        case "subagent.complete":
            helper.status = HelperStatus(wire: payload["status"]?.stringValue ?? "completed")
            if helper.status.isLive { helper.status = .completed }
            helper.finishedAt = now
            helper.durationSeconds = payload["duration_seconds"]?.doubleValue ?? helper.durationSeconds
            if helper.startedAt == nil, let seconds = helper.durationSeconds { helper.startedAt = now.addingTimeInterval(-seconds) }
            helper.summary = payload["summary"]?.stringValue ?? helper.summary
            if helper.status.isFailure || helper.status == .interrupted {
                helper.failureText = payload["text"]?.stringValue ?? helper.failureText
            } else if helper.summary == nil {
                helper.summary = payload["text"]?.stringValue
            }
            helper.inputTokens = Self.int(payload["input_tokens"]) ?? helper.inputTokens
            helper.outputTokens = Self.int(payload["output_tokens"]) ?? helper.outputTokens
            helper.reasoningTokens = Self.int(payload["reasoning_tokens"]) ?? helper.reasoningTokens
            helper.apiCalls = Self.int(payload["api_calls"]) ?? helper.apiCalls
            if let read = Self.strings(payload["files_read"]) { helper.filesRead = read }
            if let written = Self.strings(payload["files_written"]) { helper.filesWritten = written }
            if case .array(let tail)? = payload["output_tail"] {
                helper.outputTail = tail.compactMap { row in
                    guard let tool = row["tool"]?.stringValue else { return nil }
                    return HelperOutputLine(tool: tool, preview: row["preview"]?.stringValue ?? "", isError: row["is_error"]?.boolValue ?? false)
                }
            }
            helper.currentTool = nil
            helper.currentToolPreview = nil
            helper.acceptingSteer = false
            helper.endedUnseen = false
        default:
            return false
        }
        team.upsert(helper)
        if team.isFinished, team.finishedAt == nil { team.finishedAt = now }
        if team.isLive { team.finishedAt = nil }
        teams[teamID] = team
        return true
    }

    private mutating func fill(_ helper: inout Helper, from payload: JSONValue) {
        if let goal = payload["goal"]?.stringValue, !goal.isEmpty { helper.goal = goal }
        if let index = Self.int(payload["task_index"]) { helper.taskIndex = index }
        if let count = Self.int(payload["task_count"]) { helper.taskCount = count }
        if let depth = Self.int(payload["depth"]) { helper.depth = depth }
        if let parent = payload["parent_id"]?.stringValue, !parent.isEmpty { helper.parentID = parent }
        if let model = payload["model"]?.stringValue, !model.isEmpty { helper.model = model }
        if let delegation = payload["delegation_id"]?.stringValue, !delegation.isEmpty { helper.delegationID = delegation }
        if let child = payload["child_session_id"]?.stringValue, !child.isEmpty { helper.childSessionID = child }
        if let count = Self.int(payload["tool_count"]) { helper.toolCount = max(helper.toolCount, count) }
    }

    /// The team an event's helper belongs to, creating it on first sight.
    private mutating func teamID(for helperID: String, payload: JSONValue, sessionID: String?, now: Date) -> String {
        if let existing = helperTeam[helperID], teams[existing] != nil { return existing }
        // A helper started by a helper joins its team.
        if let parent = payload["parent_id"]?.stringValue, let parentTeam = helperTeam[parent], teams[parentTeam] != nil {
            helperTeam[helperID] = parentTeam
            return parentTeam
        }
        let delegation = payload["delegation_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let id = delegation ?? openCalls.first.map { "call-\($0)" } ?? "team-\(helperID)"
        if teams[id] == nil {
            // The oldest `delegate_task` call still waiting for its team gets this one.
            let call = openCalls.first
            if call != nil { openCalls.removeFirst() }
            insert(HelperTeam(id: id, callID: call, sessionID: sessionID, startedAt: now))
        }
        helperTeam[helperID] = id
        return id
    }

    private mutating func insert(_ team: HelperTeam) {
        if teams[team.id] == nil { teamOrder.append(team.id) }
        teams[team.id] = team
    }

    // MARK: Snapshots

    /// Reconciles with `subagent.list` (on open and on resume): live helpers it lists are running;
    /// helpers this chat thought live that it doesn't list finished while nobody watched; failed
    /// background delegations it reports are marked failed.
    public mutating func reconcile(list result: JSONValue, sessionID: String?, now: Date = .now) {
        var live: Set<String> = []
        if case .array(let rows)? = result["subagents"] {
            for row in rows {
                guard let id = row["subagent_id"]?.stringValue, !id.isEmpty else { continue }
                live.insert(id)
                let teamID = teamID(for: id, payload: row, sessionID: sessionID, now: now)
                guard var team = teams[teamID] else { continue }
                var helper = team.helpers[id] ?? Helper(id: id, goal: row["goal"]?.stringValue ?? "", taskIndex: Self.index(fromID: id) ?? 0, status: .running)
                fill(&helper, from: row)
                if helper.taskIndex == 0, let index = Self.index(fromID: id) { helper.taskIndex = index }
                helper.status = HelperStatus(wire: row["status"]?.stringValue)
                if let started = row["started_at"]?.doubleValue { helper.startedAt = Date(timeIntervalSince1970: started) }
                if let last = row["last_tool"]?.stringValue, !last.isEmpty { helper.currentTool = last }
                if let accepting = row["accepting_steer"]?.boolValue { helper.acceptingSteer = accepting }
                team.upsert(helper)
                team.finishedAt = nil
                teams[teamID] = team
            }
        }
        for teamID in teamOrder {
            guard var team = teams[teamID], sessionID == nil || team.sessionID == nil || team.sessionID == sessionID else { continue }
            var changed = false
            // Hermes lists a helper once it runs; one waiting for a slot waits on a running
            // sibling, so with none of its team listed it isn't waiting any more either.
            let anyListed = team.helpers.keys.contains(where: live.contains)
            for (id, var helper) in team.helpers where !live.contains(id) && (helper.status == .running || (helper.status == .queued && !anyListed)) {
                helper.status = .completed
                helper.endedUnseen = true
                helper.finishedAt = helper.finishedAt ?? now
                helper.currentTool = nil
                helper.acceptingSteer = false
                team.helpers[id] = helper
                changed = true
            }
            if changed {
                if team.isFinished, team.finishedAt == nil { team.finishedAt = now }
                teams[teamID] = team
            }
        }
        if case .array(let failures)? = result["delegations"] {
            for row in failures {
                guard let delegation = row["delegation_id"]?.stringValue, let index = Self.int(row["task_index"]) else { continue }
                let base = teams.keys.first { delegation == $0 || delegation.hasPrefix($0 + "-") } ?? delegation
                if teams[base] == nil {
                    var partial = HelperTeam(id: base, sessionID: sessionID, startedAt: row["dispatched_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)))
                    partial.isPartial = true
                    insert(partial)
                }
                guard var team = teams[base] else { continue }
                var helper = team.helpers.values.first { $0.parentID == nil && $0.taskIndex == index }
                    ?? Helper(id: "\(base)-\(index)", goal: row["goal"]?.stringValue ?? "", taskIndex: index, delegationID: base, status: .failed)
                guard helper.status.isLive || helper.endedUnseen || team.helpers[helper.id] == nil else { continue }
                helper.status = HelperStatus(wire: row["status"]?.stringValue ?? "failed")
                if helper.status == .completed { helper.status = .failed }
                helper.failureText = row["error"]?.stringValue ?? helper.failureText
                helper.endedUnseen = false
                if let done = row["completed_at"]?.doubleValue { helper.finishedAt = Date(timeIntervalSince1970: done) }
                team.upsert(helper)
                helperTeam[helper.id] = base
                if team.isFinished, team.finishedAt == nil { team.finishedAt = now }
                teams[base] = team
            }
        }
    }

    /// A team from a saved spawn tree (`spawn_tree.load`), for a run that is no longer live.
    /// It replaces a team known only in part (from `subagent.list`'s failures); a live one stays.
    public mutating func load(tree: HelperTeam) {
        if let existing = teams[tree.id] {
            guard existing.isPartial else { return }
            var merged = tree
            merged.callID = existing.callID ?? tree.callID
            merged.sessionID = existing.sessionID ?? tree.sessionID
            for id in existing.helpers.keys where tree.helpers[id] == nil { helperTeam[id] = nil }
            teams[tree.id] = merged
        } else {
            insert(tree)
        }
        for id in tree.helpers.keys { helperTeam[id] = tree.id }
    }

    public mutating func markSaved(teamID: String, path: String) {
        teams[teamID]?.savedPath = path
    }

    /// After `subagent.steer` answered: a rejected helper won't read anything more.
    public mutating func steerRejected(helperID: String) {
        guard let teamID = helperTeam[helperID] else { return }
        teams[teamID]?.helpers[helperID]?.acceptingSteer = false
    }

    // MARK: Helpers

    static func int(_ value: JSONValue?) -> Int? {
        value?.truncatedIntValue
    }

    static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let rows)? = value else { return nil }
        return rows.compactMap(\.stringValue)
    }

    /// `sa-<task_index>-<hex>` → the index (`subagent.list` rows don't carry it).
    static func index(fromID id: String) -> Int? {
        let parts = id.split(separator: "-")
        guard parts.count >= 3, parts[0] == "sa" else { return nil }
        return Int(parts[1])
    }
}
