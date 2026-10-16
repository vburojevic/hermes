import Foundation

// The Board's calls to the gateway's kanban plugin (`docs/board.md` §1). Every call names its
// board (`?board=`): the server's "current" board is whatever someone last switched to on any
// device, so the app never relies on it. Never `kanban.run` (JSON-RPC): that's for the
// gateway's own workers.

extension BackendClient {
    private static func boardQuery(_ board: String, _ more: [URLQueryItem] = []) -> [URLQueryItem] {
        [URLQueryItem(name: "board", value: board)] + more
    }

    private static func cardPath(_ id: String, _ rest: String = "") -> String {
        "tasks/" + escape(id) + rest
    }

    // MARK: Boards

    /// Every board on the gateway (`GET /boards`).
    public func boards() async throws -> [BoardInfo] {
        let json = try await kanban("boards")
        guard case .array(let rows)? = json["boards"] else { return [] }
        return rows.compactMap(BoardInfo.init(json:))
    }

    /// Makes a project's board (`POST /boards`). Idempotent by slug: a slug that's taken answers
    /// with the board already there, which may belong to another project.
    public func createBoard(slug: String, name: String, projectID: String) async throws -> BoardInfo {
        let json = try await kanban("boards", method: "POST", body: .object([
            "slug": .string(slug), "name": .string(name), "project_id": .string(projectID), "switch": .bool(false),
        ]))
        guard let board = json["board"].flatMap(BoardInfo.init(json:)) else { throw Failure.http(200, "The gateway made no board.") }
        return board
    }

    /// Columns and the moves a person may make (`GET /workflow`).
    public func boardWorkflow() async throws -> BoardWorkflow {
        BoardWorkflow(json: try await kanban("workflow"))
    }

    /// Every card by column (`GET /board`).
    public func board(_ board: String) async throws -> BoardSnapshot {
        BoardSnapshot(json: try await kanban("board", query: Self.boardQuery(board)))
    }

    /// Who can work on cards: every profile, and anyone already holding one (`GET /assignees`).
    public func boardAssignees(_ board: String) async throws -> [String] {
        let json = try await kanban("assignees", query: Self.boardQuery(board))
        guard case .array(let rows)? = json["assignees"] else { return [] }
        return rows.compactMap { $0["name"]?.stringValue ?? $0.stringValue }
    }

    /// Who new cards go to unless someone's picked (`GET /orchestration` → `default_assignee`,
    /// resolved to the active profile when unset).
    public func boardDefaultAssignee() async throws -> String? {
        let json = try await kanban("orchestration")
        let explicit = json["default_assignee"]?.stringValue ?? ""
        return explicit.isEmpty ? json["resolved_default_assignee"]?.stringValue : explicit
    }

    // MARK: Cards

    /// A card and everything about it (`GET /tasks/{id}`).
    public func boardCard(_ id: String, board: String) async throws -> BoardCardDetail {
        let json = try await kanban(Self.cardPath(id), query: Self.boardQuery(board))
        guard let detail = BoardCardDetail(json: json) else { throw Failure.http(404, "That card isn't on the board any more.") }
        return detail
    }

    /// The worker's output, its last `tail` bytes (`GET /tasks/{id}/log`).
    public func boardWorkerLog(_ id: String, board: String, tail: Int = 4096) async throws -> BoardWorkerLog {
        let json = try await kanban(Self.cardPath(id, "/log"), query: Self.boardQuery(board, [URLQueryItem(name: "tail", value: String(tail))]))
        return BoardWorkerLog(exists: json["exists"]?.boolValue ?? false, content: json["content"]?.stringValue ?? "", truncated: json["truncated"]?.boolValue ?? false)
    }

    /// Adds a card (`POST /tasks`).
    public func addBoardCard(_ card: NewBoardCard, board: String) async throws -> BoardCreated {
        let json = try await kanban("tasks", method: "POST", query: Self.boardQuery(board), body: card.json)
        return BoardCreated(card: json["task"].flatMap(BoardCard.init(json:)), warning: json["warning"]?.stringValue)
    }

    /// A rough size for a card not yet added (`POST /estimate`).
    public func estimateBoardCard(title: String, body: String) async throws -> BoardEstimate {
        var payload: [String: JSONValue] = ["title": .string(title)]
        if !body.isEmpty { payload["body"] = .string(body) }
        return BoardEstimate(json: try await kanban("estimate", method: "POST", body: .object(payload)))
    }

    /// Changes a card (`PATCH /tasks/{id}`): `status` moves it (by the workflow's matrix; leaving
    /// Running stops the run; `done` from Review approves it, refused while required checks fail),
    /// and `assignee`, `priority`, `title`, `body` edit it. A refusal throws the gateway's reason.
    @discardableResult
    public func updateBoardCard(
        _ id: String, board: String, column: String? = nil, assignee: String? = nil, priority: Int? = nil,
        title: String? = nil, body: String? = nil
    ) async throws -> BoardCard? {
        var payload: [String: JSONValue] = [:]
        if let column { payload["status"] = .string(column) }
        if let assignee { payload["assignee"] = .string(assignee) }
        if let priority { payload["priority"] = .number(Double(priority)) }
        if let title { payload["title"] = .string(title) }
        if let body { payload["body"] = .string(body) }
        let json = try await kanban(Self.cardPath(id), method: "PATCH", query: Self.boardQuery(board), body: .object(payload))
        return json["task"].flatMap(BoardCard.init(json:))
    }

    /// Adds a comment (`POST /tasks/{id}/comments`). Written as the person (`dashboard`).
    public func commentOnBoardCard(_ id: String, board: String, body: String) async throws {
        _ = try await kanban(Self.cardPath(id, "/comments"), method: "POST", query: Self.boardQuery(board), body: .object([
            "body": .string(body), "author": .string("dashboard"),
        ]))
    }

    /// Stops a run (`POST /tasks/{id}/reclaim`); the card goes back to Ready.
    public func stopBoardCard(_ id: String, board: String, reason: String) async throws {
        _ = try await kanban(Self.cardPath(id, "/reclaim"), method: "POST", query: Self.boardQuery(board), body: .object(["reason": .string(reason)]))
    }

    /// Gives a card to someone else (`POST /tasks/{id}/reassign`); "" = nobody. A running card
    /// is stopped first.
    public func reassignBoardCard(_ id: String, board: String, to profile: String, stopRun: Bool) async throws {
        _ = try await kanban(Self.cardPath(id, "/reassign"), method: "POST", query: Self.boardQuery(board), body: .object([
            "profile": .string(profile), "reclaim_first": .bool(stopRun),
        ]))
    }

    /// Deletes a card for good (`DELETE /tasks/{id}`).
    public func deleteBoardCard(_ id: String, board: String) async throws {
        _ = try await kanban(Self.cardPath(id), method: "DELETE", query: Self.boardQuery(board))
    }

    /// The same change to several cards (`POST /tasks/bulk`): a move, an assignee, or archive.
    /// Each card succeeds or fails on its own.
    public func updateBoardCards(_ ids: [String], board: String, column: String? = nil, assignee: String? = nil, archive: Bool = false) async throws -> [BoardBulkResult] {
        var payload: [String: JSONValue] = ["ids": .array(ids.map(JSONValue.string))]
        if archive { payload["archive"] = .bool(true) }
        if let column { payload["status"] = .string(column) }
        if let assignee {
            payload["assignee"] = .string(assignee)
            payload["reclaim_first"] = .bool(true)
        }
        let json = try await kanban("tasks/bulk", method: "POST", query: Self.boardQuery(board), body: .object(payload))
        guard case .array(let rows)? = json["results"] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            return BoardBulkResult(id: id, ok: row["ok"]?.boolValue ?? false, error: row["error"]?.stringValue)
        }
    }

    /// Split into Cards (`POST /tasks/{id}/decompose`): Hermes fans a triage card out.
    public func splitBoardCard(_ id: String, board: String) async throws -> BoardHelperOutcome {
        BoardHelperOutcome(json: try await kanban(Self.cardPath(id, "/decompose"), method: "POST", query: Self.boardQuery(board), body: .object([:])))
    }

    /// Let Hermes Write It Up (`POST /tasks/{id}/specify`): a triage card's title and body
    /// rewritten, then it moves on to To Do.
    public func writeUpBoardCard(_ id: String, board: String) async throws -> BoardHelperOutcome {
        BoardHelperOutcome(json: try await kanban(Self.cardPath(id, "/specify"), method: "POST", query: Self.boardQuery(board), body: .object([:])))
    }

    /// Start Now (`POST /dispatch?max=1`): a Ready card needn't wait for the next tick (60 s).
    public func dispatchBoard(_ board: String) async throws {
        _ = try await kanban("dispatch", method: "POST", query: Self.boardQuery(board, [URLQueryItem(name: "max", value: "1")]))
    }

    // MARK: Live

    /// The board's event socket (`WS /events?board=&since=`), with this credential attached.
    public func boardEventsURL(_ board: String, since: Int) async throws -> URL {
        try await socketURL(path: "api/plugins/kanban/events", query: Self.boardQuery(board, [URLQueryItem(name: "since", value: String(since))]))
    }
}
