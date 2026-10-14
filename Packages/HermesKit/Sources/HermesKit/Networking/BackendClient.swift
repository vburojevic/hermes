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
    public func transcript(storedSessionID: String, profile: String?) async throws -> SessionTranscript {
        var query = [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "include_compacted", value: "true"),
        ]
        if let profile { query.append(URLQueryItem(name: "profile", value: profile)) }
        let (data, _) = try await send(path: "api/sessions/\(Self.escape(storedSessionID))/messages", query: query)
        let envelope = try JSONDecoder().decode(BackendMessagesEnvelope.self, from: data)
        return SessionTranscript(sessionID: envelope.sessionID ?? storedSessionID, messages: envelope.messages)
    }

    // MARK: - Routines

    /// Runs a routine now (REST only; there is no RPC for it).
    public func triggerRoutine(id: String, profile: String) async throws {
        _ = try await send(
            path: "api/cron/jobs/\(Self.escape(id))/trigger", method: "POST",
            query: [URLQueryItem(name: "profile", value: profile)], body: .object([:])
        )
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
