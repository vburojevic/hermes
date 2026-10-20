import Foundation

/// How the app authenticates to a `hermes serve` backend.
public enum BackendCredential: Sendable, Equatable, Codable {
    /// Ungated (loopback) backend: the per-start session token.
    case sessionToken(String)
    /// Gated backend: the dashboard login session cookies (`hermes_session_at` / `_rt`,
    /// possibly `__Host-`/`__Secure-` prefixed), refreshed by the server on use.
    case cookies([String: String])
}

/// Public facts a backend reports before sign-in (`GET /api/status`).
public struct BackendStatus: Sendable, Equatable {
    public var version: String?
    public var authRequired: Bool
    public var authProviders: [String]
    public var installID: String?
    public var gatewayRunning: Bool?
    /// Hermes is rebuilding its search index (`fts_rebuild`, present only while it does).
    public var searchIndexRebuilding = false

    public var supportsPassword: Bool { authProviders.contains("basic") }

    init(json: JSONValue) {
        version = json["version"]?.stringValue
        authRequired = json["auth_required"]?.boolValue ?? false
        if case .array(let providers)? = json["auth_providers"] {
            authProviders = providers.compactMap { $0.stringValue ?? $0["name"]?.stringValue }
        } else {
            authProviders = []
        }
        installID = json["install_id"]?.stringValue
        gatewayRunning = json["gateway_running"]?.boolValue
        if case .object? = json["fts_rebuild"] { searchIndexRebuilding = true }
    }
}

/// REST calls to a `hermes serve` backend (the dashboard API Hermes Desktop uses).
public actor BackendClient {
    public enum Failure: Error, LocalizedError, Equatable {
        case notHermes
        case tokenNotFound
        case signInRequired
        case invalidCredentials
        case rateLimited
        case http(Int, String?)

        public var errorDescription: String? {
            switch self {
            case .notHermes: "That address isn't a Hermes backend (`hermes serve`)."
            case .tokenNotFound: "Couldn't read the session token. Is `hermes serve` running on this Mac?"
            case .signInRequired: "Sign in to the Hermes backend again."
            case .invalidCredentials: "The username or password is wrong."
            case .rateLimited: "Too many sign-in attempts. Wait a minute and try again."
            case .http(404, let message?) where HermesVersionGap.isMissingRoute(message):
                HermesVersionGap.message
            case .http(let status, let message):
                if let message { message }
                // A proxy in front of the dashboard (Tailscale's, or a Mac's own) answers these when
                // the dashboard doesn't answer in time: it's busy, not broken.
                else if Self.busyStatuses.contains(status) { "Hermes didn't answer in time: it's busy right now. Try again in a moment." }
                else { "The Hermes backend answered \(status)." }
            }
        }

        static let busyStatuses: Set<Int> = [502, 503, 504]
    }

    /// The backend is there but too slow to answer in time: a proxy's 502, 503 or 504, a request
    /// or socket handshake that timed out. Not a refusal, a wrong address or a network that's gone.
    /// Hermes's dashboard freezes for seconds to minutes on a loaded Mac ("event loop stalled …"),
    /// then carries on: the app waits it out rather than calling the Bots offline.
    public static func isSlowAnswer(_ error: any Error) -> Bool {
        switch error {
        case Failure.http(let status, _):
            return Failure.busyStatuses.contains(status)
        case GatewaySocket.Failure.handshakeTimedOut, GatewaySocket.Failure.timedOut:
            return true
        case let error as HermesError:
            return error.isTimeout || { if case .server(let status, _, _) = error { Failure.busyStatuses.contains(status) } else { false } }()
        case let error as URLError:
            return error.code == .timedOut
        default:
            return false
        }
    }

    public nonisolated let baseURL: URL
    public private(set) var credential: BackendCredential?
    private let session: URLSession
    private let onCredentialChange: (@Sendable (BackendCredential) -> Void)?

    public init(
        baseURL: URL,
        credential: BackendCredential?,
        onCredentialChange: (@Sendable (BackendCredential) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.onCredentialChange = onCredentialChange
        let configuration = URLSessionConfiguration.ephemeral
        // Bot Mode on a busy Mac answers late, not never.
        configuration.timeoutIntervalForRequest = 60
        // Cookies are handled explicitly so they can live in the Keychain.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        // The session token and cookie only ever go to Bot Mode: redirects elsewhere aren't followed.
        session = URLSession(configuration: configuration, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }

    deinit {
        // A session with a delegate lives until it's invalidated: one per notification reply and
        // pairing probe stayed behind, connections and all.
        session.finishTasksAndInvalidate()
    }

    /// Back from the background: new connections for the next requests (`HermesClient.recycleConnections`).
    public func recycleConnections() async {
        await session.flush()
    }

    // MARK: - Discovery

    public func status() async throws -> BackendStatus {
        let (data, _) = try await send(path: "api/status", authenticated: false)
        guard let json = JSONValue.parse(data), json["auth_required"] != nil || json["version"] != nil else {
            throw Failure.notHermes
        }
        return BackendStatus(json: json)
    }

    /// Reads the token an ungated backend injects into its start page — the way Hermes
    /// Desktop attaches to a local `hermes serve`. Only works over loopback.
    public func discoverSessionToken() async throws -> String {
        let (data, _) = try await send(path: "", authenticated: false, accept: "text/html")
        let html = String(decoding: data, as: UTF8.self)
        guard let token = Self.sessionToken(inHTML: html) else { throw Failure.tokenNotFound }
        updateCredential(.sessionToken(token))
        return token
    }

    static func sessionToken(inHTML html: String) -> String? {
        guard let range = html.range(of: #"window\.__HERMES_SESSION_TOKEN__\s*=\s*"((?:\\.|[^"\\])*)""#, options: .regularExpression) else {
            return nil
        }
        let assignment = String(html[range])
        guard let open = assignment.firstIndex(of: "\"") else { return nil }
        let literal = String(assignment[open...])
        return (try? JSONDecoder().decode(String.self, from: Data(literal.utf8))).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Sign-in

    public func useSessionToken(_ token: String) {
        updateCredential(.sessionToken(token))
    }

    /// Username/password sign-in (the `basic` dashboard auth provider).
    public func signIn(username: String, password: String, provider: String = "basic") async throws {
        let body: JSONValue = .object([
            "provider": .string(provider), "username": .string(username), "password": .string(password), "next": .string(""),
        ])
        let (_, response) = try await send(path: "auth/password-login", method: "POST", body: body, authenticated: false, captureCookies: true)
        guard case .cookies(let cookies)? = credential, cookies.keys.contains(where: { $0.hasSuffix("hermes_session_at") }) else {
            throw Failure.http(response.statusCode, "Signed in, but the backend didn't start a session.")
        }
    }

    // MARK: - Gateway socket

    /// The `/api/ws` URL with this credential attached (`?token=` or a one-time `?ticket=`).
    public func gatewaySocketURL() async throws -> URL {
        try await socketURL(path: "api/ws")
    }

    /// A WebSocket URL on this backend with the credential attached: the session token, or a
    /// one-time ticket (30 s, single use) minted with the login cookies.
    func socketURL(path: String, query: [URLQueryItem] = []) async throws -> URL {
        var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        switch credential {
        case .sessionToken(let token):
            components.queryItems = query + [URLQueryItem(name: "token", value: token)]
        case .cookies:
            let (data, _) = try await send(path: "api/auth/ws-ticket", method: "POST", body: .object([:]))
            guard let ticket = (JSONValue.parse(data))?["ticket"]?.stringValue else {
                throw Failure.signInRequired
            }
            components.queryItems = query + [URLQueryItem(name: "ticket", value: ticket)]
        case nil:
            throw Failure.signInRequired
        }
        return components.url!
    }

    /// A WebSocket on this backend (the audio routes, `docs/voice.md` §10), credential attached,
    /// on the backend's own URL session.
    func webSocket(path: String, query: [URLQueryItem] = []) async throws -> URLSessionWebSocketTask {
        var request = URLRequest(url: try await socketURL(path: path, query: query))
        request.timeoutInterval = 15
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        return task
    }

    /// The headers a gateway file needs (`/api/files/stream` takes no token in the URL).
    func authorizationHeaders() -> [String: String] {
        switch credential {
        case .sessionToken(let token): ["X-Hermes-Session-Token": token]
        case .cookies(let cookies): ["Cookie": cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")]
        case nil: [:]
        }
    }

    // MARK: - Sessions

    /// A profile's transcript, the authority Desktop renders from.
    public func transcript(storedSessionID: String, profile: String?, limit: Int = SessionTranscript.firstPage, offset: Int = 0) async throws -> SessionTranscript {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "include_compacted", value: "true"),
        ]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/sessions/\(Self.escape(storedSessionID))/messages", query: query)
        let envelope = try JSONDecoder().decode(BackendMessagesEnvelope.self, from: data)
        return SessionTranscript(sessionID: envelope.sessionID ?? storedSessionID, messages: envelope.messages, hasEarlier: envelope.messages.count >= limit)
    }

    // MARK: - Read state

    /// A stored session's read mark (`last_read_at`, the one Hermes Desktop keeps): the session
    /// detail is the raw row, without the computed `unread`.
    public func readMark(storedSessionID: String, profile: String) async throws -> ReadMark {
        let (data, _) = try await send(path: "api/sessions/\(Self.escape(storedSessionID))",
                                       query: [URLQueryItem(name: "profile", value: profile)])
        return ReadMark(lastReadAt: try JSONValue.decode(data)["last_read_at"]?.doubleValue)
    }

    /// Marks a stored session read for every device, as Hermes Desktop does: the session's
    /// current revision, then an edit fenced on it. A turn landing in between moves the revision;
    /// that conflict is retried once with a fresh one. A Hermes without fenced edits (no
    /// `mutation-snapshot` route, like the one from 2026-10-16) takes the plain edit.
    public func markRead(storedSessionID: String, profile: String?) async throws {
        try await setUnread(false, storedSessionID: storedSessionID, profile: profile)
    }

    /// Marks a stored session unread for every device (`last_read_at` = 0; `docs/inbox.md` §1).
    public func markUnread(storedSessionID: String, profile: String?) async throws {
        try await setUnread(true, storedSessionID: storedSessionID, profile: profile)
    }

    private func setUnread(_ unread: Bool, storedSessionID: String, profile: String?) async throws {
        let id = Self.escape(storedSessionID)
        let profileQuery = Self.profileQuery(profile)
        var plain: [String: JSONValue] = ["unread": .bool(unread)]
        if let profile { plain["profile"] = .string(profile) }
        for attempt in 0..<2 {
            let data: Data
            do {
                (data, _) = try await send(path: "api/sessions/\(id)/mutation-snapshot", query: profileQuery)
            } catch Failure.http(404, let detail?) where Self.isUnroutedPath(detail) {
                _ = try await send(path: "api/sessions/\(id)", method: "PATCH", body: .object(plain))
                return
            }
            let snapshot = try JSONValue.decode(data)
            guard snapshot["exists"]?.boolValue == true, let revision = snapshot["runtime_revision"]?.doubleValue else { return }
            var body = plain
            body["request_id"] = .string(UUID().uuidString)
            body["expected_revision"] = .number(revision)
            if let generation = snapshot["runtime_generation"]?.doubleValue { body["expected_generation"] = .number(generation) }
            do {
                _ = try await send(path: "api/sessions/\(id)", method: "PATCH", body: .object(body))
                return
            } catch Failure.http(409, let detail?) where ["revision_conflict", "stale_generation"].contains(detail) && attempt == 0 {
                continue
            }
        }
    }

    /// The newest chats with Hermes' read marks (`GET /api/sessions?order=recent`, the
    /// dashboard's rows carry `last_read_at`; the API server's don't). At most 100 a page.
    public func recentSessions(limit: Int = 100, profile: String?) async throws -> [HermesSession] {
        let query = [
            URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(min(100, limit))),
        ] + Self.profileQuery(profile)
        let (data, _) = try await send(path: "api/sessions", query: query)
        return try JSONDecoder().decode(DashboardSessionPage.self, from: data).sessions
    }

    /// A 404 that says the route itself is missing (Hermes' catch-all for unmatched `/api/*`, or a
    /// headless `hermes serve`), not that the session or profile is unknown: Desktop's test.
    static func isUnroutedPath(_ detail: String) -> Bool {
        let detail = detail.lowercased()
        return detail.contains("no such api endpoint") || detail.contains("endpoint is likely missing")
            || detail.contains("web ui disabled")
    }

    // MARK: - Routines

    /// Runs a routine now (REST only; there is no RPC for it).
    public func triggerRoutine(id: String, profile: String) async throws {
        _ = try await send(
            path: "api/cron/jobs/\(Self.escape(id))/trigger", method: "POST",
            query: [URLQueryItem(name: "profile", value: profile)], body: .object([:])
        )
    }

    // MARK: - Gateway

    /// Restarts the gateway (`POST /api/gateway/restart`: `hermes gateway restart` in the
    /// background; requests within 10 s join the one already running). Running replies finish
    /// first. REST only; the gateway protocol has no call for it.
    public func restartGateway() async throws {
        _ = try await send(path: "api/gateway/restart", method: "POST", body: .object([:]))
    }

    // MARK: - Git

    /// A repo's checkouts: the main one and its linked worktrees (`GET /api/git/worktrees`, the
    /// REST mirror Hermes Desktop uses for remote gateways; the gateway protocol has no git calls).
    public func gitWorktrees(repo: String) async throws -> [GitWorktree] {
        let (data, _) = try await send(path: "api/git/worktrees", query: [URLQueryItem(name: "path", value: repo)])
        let json = try JSONValue.decode(data)
        guard case .array(let rows)? = json["worktrees"] else { return [] }
        return rows.compactMap(GitWorktree.init(json:))
    }

    /// Adds a worktree on a new branch under `<repo>/.worktrees/` (`POST /api/git/worktree/add`).
    public func addGitWorktree(repo: String, name: String? = nil) async throws -> GitWorktree {
        var body: [String: JSONValue] = ["path": .string(repo)]
        if let name, !name.isEmpty { body["name"] = .string(name) }
        let (data, _) = try await send(path: "api/git/worktree/add", method: "POST", body: .object(body))
        let json = try JSONValue.decode(data)
        guard let path = json["path"]?.stringValue else { throw Failure.http(200, "The gateway didn't say where it made the worktree.") }
        return GitWorktree(path: path, branch: json["branch"]?.stringValue, isMain: false)
    }

    // MARK: - Credentials

    /// Stores a secret in the profile's `.env` (`PUT /api/env`, the dashboard's credential route):
    /// where plugin settings of `type: secret` live. Write-only: nothing reads it back, and the
    /// value is never logged.
    public func setEnv(key: String, value: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["key": .string(key), "value": .string(value)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await send(path: "api/env", method: "PUT", body: .object(body))
    }

    /// The env keys a profile has set (`GET /api/env`): names only. Hermes sends a redacted
    /// preview beside each, which the app never reads.
    public func envKeysSet(profile: String?) async throws -> Set<String> {
        let query = profile.flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "profile", value: $0)] } ?? []
        let (data, _) = try await restData("api/env", query: query)
        guard case .object(let rows) = try JSONValue.decode(data) else { return [] }
        return Set(rows.compactMap { key, row in row["is_set"]?.boolValue == true ? key : nil })
    }

    /// Chats that mention `query` (`GET /api/sessions/search`): one per chat, ID matches first,
    /// then message content (words prefix-matched, quoted phrases exact), then titles. `profile`
    /// searches a Bot's chats; `sources` / `excludeSources` filter by where a chat came from.
    public func searchSessions(
        _ query: String, limit: Int = SessionSearch.defaultLimit, profile: String? = nil,
        sources: [String] = [], excludeSources: [String] = []
    ) async throws -> [SessionSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var items = [URLQueryItem(name: "q", value: trimmed), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let profile, !profile.isEmpty { items.append(URLQueryItem(name: "profile", value: profile)) }
        if !sources.isEmpty { items.append(URLQueryItem(name: "sources", value: sources.joined(separator: ","))) }
        if !excludeSources.isEmpty { items.append(URLQueryItem(name: "exclude_sources", value: excludeSources.joined(separator: ","))) }
        let (data, _) = try await send(path: "api/sessions/search", query: items)
        let json = try JSONValue.decode(data)
        let found = json["results"].items.compactMap(SessionSearchResult.init(json:))
        // A profile asked for by name answers for that profile.
        return profile.map { name in found.map { var result = $0; result.profile = result.profile ?? name; return result } } ?? found
    }

    /// A task's runs, newest first (`GET /api/cron/jobs/{id}/runs`): agent runs are chats, script
    /// runs only have output.
    public func cronRuns(jobID: String, profile: String? = nil, limit: Int = 20) async throws -> [CronRun] {
        var items = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let profile, !profile.isEmpty { items.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/cron/jobs/\(Self.escape(jobID))/runs", query: items)
        let json = try JSONValue.decode(data)
        return json["runs"].items.map(CronRun.init(json:))
    }

    /// Turns checkpoints on or off in the profile's config (`PUT /api/config`, deep-merged).
    /// `config.set` doesn't take this key. A chat's agent reads it when it is built, so open chats
    /// keep the old value until they are reattached.
    public func setCheckpointsEnabled(_ enabled: Bool, profile: String?) async throws {
        var body: [String: JSONValue] = ["config": .object(["checkpoints": .object(["enabled": .bool(enabled)])])]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await send(path: "api/config", method: "PUT", body: .object(body))
    }

    // MARK: Memory (`docs/memory.md` §1)

    private static func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// Every entry of About You and Hermes's Notes, in file order (`GET /api/learning/graph`).
    public func memoryEntries(profile: String?) async throws -> MemoryList {
        let (data, _) = try await send(path: "api/learning/graph", query: Self.profileQuery(profile))
        return MemoryList(graph: try JSONValue.decode(data))
    }

    /// An entry's whole text, for editing (`GET /api/learning/node`). Fails when the entry
    /// changed since it was listed.
    public func memoryEntryText(id: String, profile: String?) async throws -> String {
        let (data, _) = try await send(path: "api/learning/node", query: [URLQueryItem(name: "id", value: id)] + Self.profileQuery(profile))
        return try JSONValue.decode(data)["content"]?.stringValue ?? ""
    }

    /// Rewrites an entry (`PUT /api/learning/node`). The gateway refuses a stale id and an edit
    /// over the store's size cap with a message to show.
    public func editMemoryEntry(id: String, content: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["id": .string(id), "content": .string(content)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await send(path: "api/learning/node", method: "PUT", query: Self.profileQuery(profile), body: .object(body))
    }

    /// Removes an entry (`DELETE /api/learning/node`). The gateway has no undo.
    public func forgetMemoryEntry(id: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["id": .string(id)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await send(path: "api/learning/node", method: "DELETE", query: Self.profileQuery(profile), body: .object(body))
    }

    /// The provider in use, the ones on the gateway, the files' sizes (`GET /api/memory`).
    public func memoryStatus(profile: String?) async throws -> MemoryStatus {
        let (data, _) = try await send(path: "api/memory", query: Self.profileQuery(profile))
        return MemoryStatus(json: try JSONValue.decode(data))
    }

    /// Switches the provider (`PUT /api/memory/provider`); "" is built-in. Only ready providers.
    public func setMemoryProvider(_ provider: String, profile: String?) async throws {
        _ = try await send(path: "api/memory/provider", method: "PUT", query: Self.profileQuery(profile), body: .object(["provider": .string(provider)]))
    }

    /// Deletes the files (`POST /api/memory/reset`): `all`, `memory` or `user`. The backend
    /// refuses an unnamed profile while it serves several, so the default one is named.
    public func resetMemory(target: String, profile: String?) async throws {
        let named = (profile?.isEmpty ?? true) ? "default" : profile
        _ = try await send(path: "api/memory/reset", method: "POST", query: Self.profileQuery(named), body: .object(["target": .string(target)]))
    }

    /// The `memory` section of the profile's config (`GET /api/config`).
    public func memorySettings(profile: String?) async throws -> MemorySettings {
        let (data, _) = try await send(path: "api/config", query: Self.profileQuery(profile))
        return MemorySettings(config: try JSONValue.decode(data))
    }

    /// Sets `memory.<key>` in the profile's config (`PUT /api/config`, deep-merged):
    /// `memory_enabled`, `user_profile_enabled`, `write_approval`. `config.set` has no memory
    /// keys, and `/memory approval` through `command.dispatch` ignores `profile` without a
    /// session, so a Bot's gate would land on the launch profile.
    public func setMemorySetting(_ key: String, to value: Bool, profile: String?) async throws {
        var body: [String: JSONValue] = ["config": .object(["memory": .object([key: .bool(value)])])]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await send(path: "api/config", method: "PUT", query: Self.profileQuery(profile), body: .object(body))
    }

    /// A provider sign-in by device code (`POST /api/providers/oauth/<provider>/start`): Nous for
    /// the Apps tab. The person approves at `url`; `pollProviderSignIn` says when they have.
    public func startProviderSignIn(provider: String, profile: String?) async throws -> (sessionID: String, url: URL, userCode: String, interval: Int) {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/providers/oauth/\(Self.escape(provider))/start", method: "POST", query: query, body: .object([:]))
        let json = try JSONValue.decode(data)
        guard let id = json["session_id"]?.stringValue, let url = json["verification_url"]?.stringValue.flatMap(URL.init(string:)) else {
            throw Failure.http(200, "The gateway started no sign-in.")
        }
        return (id, url, json["user_code"]?.stringValue ?? "", json["poll_interval"]?.truncatedIntValue ?? 3)
    }

    /// `pending`, `approved`, `expired`, `error` or `cancelled`.
    public func pollProviderSignIn(provider: String, sessionID: String, profile: String?) async throws -> String {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/providers/oauth/\(Self.escape(provider))/poll/\(Self.escape(sessionID))", query: query)
        return try JSONValue.decode(data)["status"]?.stringValue ?? "pending"
    }

    /// How many cards the kanban dispatcher runs at once (`kanban.max_in_progress` in the
    /// gateway's config); nil when it's left to the gateway (a memory-derived default).
    public func boardRunLimit() async throws -> Int? {
        let (data, _) = try await send(path: "api/config")
        let kanban = try JSONValue.decode(data)["kanban"]
        return kanban?["max_in_progress"]?.truncatedIntValue
    }

    /// The newest chat a card's worker ran in, for Watch. Workers' chats are tagged `kanban`, run
    /// in the card's folder, and live in the assignee's profile (`GET /api/sessions`); the
    /// project tree leaves them out.
    public func boardWorkerChat(folder: String, profile: String?) async throws -> String? {
        let query = [
            URLQueryItem(name: "source", value: "kanban"), URLQueryItem(name: "cwd_prefix", value: folder),
            URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: "1"),
        ] + Self.profileQuery(profile)
        let (data, _) = try await send(path: "api/sessions", query: query)
        guard case .array(let rows)? = try JSONValue.decode(data)["sessions"] else { return nil }
        return rows.first?["id"]?.stringValue
    }

    // MARK: - Plumbing

    /// A JSON call to the backend (the Inspector's `/api/fs/*`, `/api/git/*`; see
    /// `WorkspaceAPI.swift`).
    /// `timeout` is for the few calls Hermes answers only when it's done (an install).
    func rest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil,
              timeout: TimeInterval? = nil) async throws -> JSONValue {
        let (data, _) = try await send(path: path, method: method, query: query, body: body, timeout: timeout)
        return (JSONValue.parse(data)) ?? .null
    }

    /// Raw bytes from the backend (a gateway file for the Preview, with its content type).
    func restData(_ path: String, query: [URLQueryItem] = []) async throws -> (Data, String?) {
        let (data, response) = try await send(path: path, query: query, accept: "*/*")
        return (data, response.value(forHTTPHeaderField: "Content-Type"))
    }

    /// A call to the kanban plugin (`/api/plugins/kanban/<path>`); the Board's calls are in
    /// `BoardAPI.swift`.
    func kanban(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let (data, _) = try await send(path: "api/plugins/kanban/" + path, method: method, query: query, body: body)
        return (JSONValue.parse(data)) ?? .null
    }

    private func endpoint(_ path: String) -> URL {
        path.isEmpty ? baseURL : baseURL.appending(path: path)
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    /// A read that came back 502, 503 or 504 (the dashboard was too busy to answer its proxy in
    /// time) is asked again after 2 s and then 5 s before it fails.
    private func send(
        path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil,
        authenticated: Bool = true, accept: String = "application/json", captureCookies: Bool = false,
        timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let rereadable = method == "GET" || method == "HEAD"
        for wait in rereadable ? [2.0, 5.0] : [] {
            do {
                return try await sendOnce(path: path, method: method, query: query, body: body, authenticated: authenticated,
                                          accept: accept, captureCookies: captureCookies, timeout: timeout)
            } catch Failure.http(let status, _) where Failure.busyStatuses.contains(status) {
                try await Task.sleep(for: .seconds(wait))
            }
        }
        return try await sendOnce(path: path, method: method, query: query, body: body, authenticated: authenticated,
                                  accept: accept, captureCookies: captureCookies, timeout: timeout)
    }

    private func sendOnce(
        path: String, method: String, query: [URLQueryItem], body: JSONValue?,
        authenticated: Bool, accept: String, captureCookies: Bool, timeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var url = endpoint(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if authenticated {
            switch credential {
            case .sessionToken(let token):
                request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
            case .cookies(let cookies):
                request.setValue(cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; "), forHTTPHeaderField: "Cookie")
            case nil:
                throw Failure.signInRequired
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HermesClient.load(request, in: session)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HermesError.from(urlError: error, host: baseURL.host() ?? baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.notHermes }
        absorbCookies(from: http, force: captureCookies)

        switch http.statusCode {
        case 200..<300:
            return (data, http)
        case 401:
            if path == "auth/password-login" { throw Failure.invalidCredentials }
            throw Failure.signInRequired
        case 429:
            throw Failure.rateLimited
        default:
            let json = JSONValue.parse(data)
            let message = json?["detail"]?.stringValue ?? json?["error"]?.stringValue ?? json?["error"]?["message"]?.stringValue
            throw Failure.http(http.statusCode, message)
        }
    }

    /// Keeps the session cookies current: the gate refreshes the access cookie in place.
    private func absorbCookies(from response: HTTPURLResponse, force: Bool) {
        guard let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
            .filter { $0.name.contains("hermes_session_") }
        guard !fresh.isEmpty else { return }
        var cookies: [String: String] = [:]
        if case .cookies(let existing)? = credential { cookies = existing } else if !force { return }
        for cookie in fresh {
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 < .now } ?? false) {
                cookies[cookie.name] = nil
            } else {
                cookies[cookie.name] = cookie.value
            }
        }
        updateCredential(.cookies(cookies))
    }

    private func updateCredential(_ new: BackendCredential) {
        guard new != credential else { return }
        credential = new
        onCredentialChange?(new)
    }
}

private struct BackendMessagesEnvelope: Decodable {
    var sessionID: String?
    var messages: [SessionMessage]

    enum CodingKeys: String, CodingKey {
        case messages
        case sessionID = "session_id"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        messages = try c.decode([LossyElement<SessionMessage>].self, forKey: .messages).compactMap(\.value)
    }
}
