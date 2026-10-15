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
            case .http(let status, let message): message ?? "The Hermes backend answered \(status)."
            }
        }
    }

    public let baseURL: URL
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
        configuration.timeoutIntervalForRequest = 20
        // Cookies are handled explicitly so they can live in the Keychain.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    // MARK: - Discovery

    public func status() async throws -> BackendStatus {
        let (data, _) = try await send(path: "api/status", authenticated: false)
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), json["auth_required"] != nil || json["version"] != nil else {
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
        var components = URLComponents(url: endpoint("api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        switch credential {
        case .sessionToken(let token):
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        case .cookies:
            let (data, _) = try await send(path: "api/auth/ws-ticket", method: "POST", body: .object([:]))
            guard let ticket = (try? JSONDecoder().decode(JSONValue.self, from: data))?["ticket"]?.stringValue else {
                throw Failure.signInRequired
            }
            components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        case nil:
            throw Failure.signInRequired
        }
        return components.url!
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

    /// When any device last read a stored session: Hermes' sidebar watermark (`last_read_at`,
    /// the one Hermes Desktop keeps). Nil until a client has marked it read.
    public func lastRead(storedSessionID: String, profile: String) async throws -> Date? {
        let (data, _) = try await send(path: "api/sessions/\(Self.escape(storedSessionID))",
                                       query: [URLQueryItem(name: "profile", value: profile)])
        let row = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let seconds = row["last_read_at"]?.doubleValue, seconds > 0 else { return nil } // 0: marked unread
        return Date(timeIntervalSince1970: seconds)
    }

    /// Marks a stored session read for every device, as Hermes Desktop does: the session's
    /// current revision, then an edit fenced on it. A turn landing in between moves the revision;
    /// that conflict is retried once with a fresh one.
    public func markRead(storedSessionID: String, profile: String) async throws {
        let id = Self.escape(storedSessionID)
        let profileItem = URLQueryItem(name: "profile", value: profile)
        for attempt in 0..<2 {
            let (data, _) = try await send(path: "api/sessions/\(id)/mutation-snapshot", query: [profileItem])
            let snapshot = try JSONDecoder().decode(JSONValue.self, from: data)
            guard snapshot["exists"]?.boolValue == true, let revision = snapshot["runtime_revision"]?.doubleValue else { return }
            var body: [String: JSONValue] = [
                "unread": .bool(false), "request_id": .string(UUID().uuidString),
                "expected_revision": .number(revision), "profile": .string(profile),
            ]
            if let generation = snapshot["runtime_generation"]?.doubleValue { body["expected_generation"] = .number(generation) }
            do {
                _ = try await send(path: "api/sessions/\(id)", method: "PATCH", body: .object(body))
                return
            } catch Failure.http(409, let detail?) where detail == "revision_conflict" && attempt == 0 {
                continue
            }
        }
    }

    // MARK: - Routines

    /// Runs a routine now (REST only; there is no RPC for it).
    public func triggerRoutine(id: String, profile: String) async throws {
        _ = try await send(
            path: "api/cron/jobs/\(Self.escape(id))/trigger", method: "POST",
            query: [URLQueryItem(name: "profile", value: profile)], body: .object([:])
        )
    }

    // MARK: - Git

    /// A repo's checkouts: the main one and its linked worktrees (`GET /api/git/worktrees`, the
    /// REST mirror Hermes Desktop uses for remote gateways; the gateway protocol has no git calls).
    public func gitWorktrees(repo: String) async throws -> [GitWorktree] {
        let (data, _) = try await send(path: "api/git/worktrees", query: [URLQueryItem(name: "path", value: repo)])
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let rows)? = json["worktrees"] else { return [] }
        return rows.compactMap(GitWorktree.init(json:))
    }

    /// Adds a worktree on a new branch under `<repo>/.worktrees/` (`POST /api/git/worktree/add`).
    public func addGitWorktree(repo: String, name: String? = nil) async throws -> GitWorktree {
        var body: [String: JSONValue] = ["path": .string(repo)]
        if let name, !name.isEmpty { body["name"] = .string(name) }
        let (data, _) = try await send(path: "api/git/worktree/add", method: "POST", body: .object(body))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
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
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
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
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
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

    /// A provider sign-in by device code (`POST /api/providers/oauth/<provider>/start`): Nous for
    /// the Apps tab. The person approves at `url`; `pollProviderSignIn` says when they have.
    public func startProviderSignIn(provider: String, profile: String?) async throws -> (sessionID: String, url: URL, userCode: String, interval: Int) {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/providers/oauth/\(Self.escape(provider))/start", method: "POST", query: query, body: .object([:]))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let id = json["session_id"]?.stringValue, let url = json["verification_url"]?.stringValue.flatMap(URL.init(string:)) else {
            throw Failure.http(200, "The gateway started no sign-in.")
        }
        return (id, url, json["user_code"]?.stringValue ?? "", json["poll_interval"]?.doubleValue.map { Int($0) } ?? 3)
    }

    /// `pending`, `approved`, `expired`, `error` or `cancelled`.
    public func pollProviderSignIn(provider: String, sessionID: String, profile: String?) async throws -> String {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/providers/oauth/\(Self.escape(provider))/poll/\(Self.escape(sessionID))", query: query)
        return try JSONDecoder().decode(JSONValue.self, from: data)["status"]?.stringValue ?? "pending"
    }

    // MARK: - Plumbing

    private func endpoint(_ path: String) -> URL {
        path.isEmpty ? baseURL : baseURL.appending(path: path)
    }

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    private func send(
        path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil,
        authenticated: Bool = true, accept: String = "application/json", captureCookies: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        var url = endpoint(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
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
            (data, response) = try await session.data(for: request)
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
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
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
