import Foundation

/// The gateway's helper calls (`tui_gateway/methods_subagents.py`, `methods_session.py`).
///
/// `subagent.*` calls are scoped by the parent's runtime session and the socket that owns it
/// (4001 otherwise); `delegation.*` and `spawn_tree.*` are gateway-wide and ignore the profile, so
/// none of these send one. Unknown parameters are rejected (4000).
public struct HelpersClient: Sendable {
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    // MARK: Helpers of a session

    /// Live helpers of a running session, and its failed background delegations of the last day.
    public func list(sessionID: String) async throws -> JSONValue {
        try await transport("subagent.list", ["session_id": .string(sessionID)])
    }

    /// The last 16 KB of a live helper's transcript.
    public func tail(sessionID: String, helperID: String) async throws -> HelperTail {
        let result = try await transport("subagent.tail", ["session_id": .string(sessionID), "subagent_id": .string(helperID)])
        return HelperTail(
            available: result["available"]?.boolValue ?? false,
            text: result["text"]?.stringValue ?? "",
            truncated: result["truncated"]?.boolValue ?? false
        )
    }

    /// Stops one helper. False when it had already finished (or isn't this client's).
    public func interrupt(sessionID: String, helperID: String) async throws -> Bool {
        let result = try await transport("subagent.interrupt", ["session_id": .string(sessionID), "subagent_id": .string(helperID)])
        return result["found"]?.boolValue ?? false
    }

    /// Sends a helper a note it reads after its current step.
    public func steer(sessionID: String, helperID: String, text: String) async throws -> HelperSteerResult {
        let result = try await transport("subagent.steer", [
            "session_id": .string(sessionID), "subagent_id": .string(helperID), "text": .string(text),
        ])
        return HelperSteerResult(rawValue: result["status"]?.stringValue ?? "") ?? .rejected
    }

    // MARK: Gateway-wide

    public func status() async throws -> DelegationStatus {
        let result = try await transport("delegation.status", [:])
        let active: Int = if case .array(let rows)? = result["active"] { rows.count } else { 0 }
        return DelegationStatus(
            paused: result["paused"]?.boolValue ?? false,
            maxConcurrentChildren: result["max_concurrent_children"]?.truncatedIntValue ?? 10,
            maxSpawnDepth: result["max_spawn_depth"]?.truncatedIntValue ?? 1,
            activeCount: active
        )
    }

    /// Stops (or allows again) new helpers on the whole gateway; running ones finish.
    @discardableResult
    public func setPaused(_ paused: Bool) async throws -> Bool {
        let result = try await transport("delegation.pause", ["paused": .bool(paused)])
        return result["paused"]?.boolValue ?? paused
    }

    // MARK: Spawn trees

    /// Saves a finished team to the gateway's archive. Hermes doesn't save them itself; the TUI saves
    /// its own on `message.complete` in this same shape.
    @discardableResult
    public func save(_ team: HelperTeam, sessionKey: String, label: String) async throws -> String? {
        var params: [String: JSONValue] = [
            "subagents": .array(team.helpers.values.sorted { $0.taskIndex < $1.taskIndex }.map(SpawnTree.row(for:))),
            "session_id": .string(sessionKey),
            "label": .string(label),
        ]
        if let started = team.startedAt ?? team.helpers.values.compactMap(\.startedAt).min() { params["started_at"] = .number(started.timeIntervalSince1970) }
        if let finished = team.finishedAt { params["finished_at"] = .number(finished.timeIntervalSince1970) }
        let result = try await transport("spawn_tree.save", params)
        return result["path"]?.stringValue
    }

    /// Saved runs of one session, newest first.
    public func savedTrees(sessionKey: String, limit: Int = 50) async throws -> [SpawnTreeEntry] {
        let result = try await transport("spawn_tree.list", ["session_id": .string(sessionKey), "limit": .number(Double(limit))])
        guard case .array(let rows)? = result["entries"] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"]?.stringValue else { return nil }
            return SpawnTreeEntry(
                path: path,
                sessionID: row["session_id"]?.stringValue ?? sessionKey,
                label: row["label"]?.stringValue,
                startedAt: row["started_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
                finishedAt: row["finished_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
                count: row["count"]?.truncatedIntValue ?? 0
            )
        }
    }

    public func loadTree(path: String, teamID: String) async throws -> HelperTeam {
        SpawnTree.team(from: try await transport("spawn_tree.load", ["path": .string(path)]), id: teamID, path: path)
    }
}

/// The saved-tree format: the TUI's `SubagentProgress` rows (camelCase), so trees the app saves read
/// in the TUI's tree viewer and the other way round.
public enum SpawnTree {
    static func row(for helper: Helper) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(helper.id),
            "goal": .string(helper.goal),
            "status": .string(helper.status.rawValue),
            "depth": .number(Double(helper.depth)),
            "parentId": helper.parentID.map(JSONValue.string) ?? .null,
            "index": .number(Double(helper.taskIndex)),
            "taskCount": .number(Double(helper.taskCount)),
            "toolCount": .number(Double(helper.toolCount)),
            "tools": .array(helper.recentTools.map { .string("\($0.tool) \($0.preview)".trimmingCharacters(in: .whitespaces)) }),
            "notes": .array([]),
            "thinking": .array(helper.thinking.map { [.string($0)] } ?? []),
        ]
        func set(_ key: String, _ value: JSONValue?) { if let value { row[key] = value } }
        set("model", helper.model.map(JSONValue.string))
        set("delegationId", helper.delegationID.map(JSONValue.string))
        set("durationSeconds", helper.durationSeconds.map(JSONValue.number))
        set("summary", (helper.summary ?? helper.failureText).map(JSONValue.string))
        set("startedAt", helper.startedAt.map { .number($0.timeIntervalSince1970) })
        set("inputTokens", helper.inputTokens.map { .number(Double($0)) })
        set("outputTokens", helper.outputTokens.map { .number(Double($0)) })
        set("reasoningTokens", helper.reasoningTokens.map { .number(Double($0)) })
        set("apiCalls", helper.apiCalls.map { .number(Double($0)) })
        if !helper.filesRead.isEmpty { row["filesRead"] = .array(helper.filesRead.map(JSONValue.string)) }
        if !helper.filesWritten.isEmpty { row["filesWritten"] = .array(helper.filesWritten.map(JSONValue.string)) }
        if !helper.outputTail.isEmpty {
            row["outputTail"] = .array(helper.outputTail.map { .object(["tool": .string($0.tool), "preview": .string($0.preview), "isError": .bool($0.isError)]) })
        }
        return .object(row)
    }

    /// A team from `spawn_tree.load`'s file (`{session_id, started_at, finished_at, label, subagents}`).
    public static func team(from json: JSONValue, id: String, path: String? = nil) -> HelperTeam {
        var team = HelperTeam(id: id, startedAt: json["started_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)))
        team.finishedAt = json["finished_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        team.savedPath = path
        guard case .array(let rows)? = json["subagents"] else { return team }
        for row in rows {
            guard let helperID = row["id"]?.stringValue else { continue }
            var helper = Helper(
                id: helperID,
                parentID: row["parentId"]?.stringValue,
                depth: row["depth"]?.truncatedIntValue ?? 0,
                goal: row["goal"]?.stringValue ?? "",
                taskIndex: row["index"]?.truncatedIntValue ?? 0,
                taskCount: row["taskCount"]?.truncatedIntValue ?? rows.count,
                model: row["model"]?.stringValue,
                delegationID: row["delegationId"]?.stringValue,
                status: HelperStatus(wire: row["status"]?.stringValue)
            )
            // A saved run is over: anything still marked live was cut off.
            if helper.status.isLive { helper.status = .interrupted }
            helper.toolCount = row["toolCount"]?.truncatedIntValue ?? 0
            helper.durationSeconds = row["durationSeconds"]?.doubleValue
            helper.startedAt = row["startedAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
            if let start = helper.startedAt, let seconds = helper.durationSeconds { helper.finishedAt = start.addingTimeInterval(seconds) }
            let summary = row["summary"]?.stringValue
            if helper.status.isFailure || helper.status == .interrupted { helper.failureText = summary } else { helper.summary = summary }
            helper.inputTokens = row["inputTokens"]?.truncatedIntValue
            helper.outputTokens = row["outputTokens"]?.truncatedIntValue
            helper.reasoningTokens = row["reasoningTokens"]?.truncatedIntValue
            helper.apiCalls = row["apiCalls"]?.truncatedIntValue
            helper.filesRead = HelperTracker.strings(row["filesRead"]) ?? []
            helper.filesWritten = HelperTracker.strings(row["filesWritten"]) ?? []
            if case .array(let tail)? = row["outputTail"] {
                helper.outputTail = tail.compactMap { entry in
                    entry["tool"]?.stringValue.map { HelperOutputLine(tool: $0, preview: HelperTracker.preview(entry["preview"]?.stringValue ?? "", tool: $0), isError: entry["isError"]?.boolValue ?? false) }
                }
            }
            helper.acceptingSteer = false
            team.upsert(helper)
        }
        return team
    }
}
