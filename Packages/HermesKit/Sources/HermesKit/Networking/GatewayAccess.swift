import Foundation
import Synchronization

/// How the app gets through an access gateway (Cloudflare Access and the like) that stands in front
/// of a Hermes gateway (`docs/connecting-and-voice.md` §11). Set per gateway and saved with it; the
/// service token's secret lives in the Keychain (`BotStore.accessSecret`). Hermes's own key is
/// still sent: this only gets the request past the access gateway.
public struct GatewayAccess: Hashable, Codable, Sendable {
    public enum Method: String, Codable, Sendable, CaseIterable {
        /// Nothing in front of Hermes.
        case none
        /// A client ID and secret sent as headers on every request.
        case serviceToken
        /// The access gateway's own sign-in page, its session kept as cookies.
        case browserSignIn
    }

    public var method: Method
    /// The service token's client ID. Not a secret: it names the token, the secret proves it.
    public var clientID: String
    public var idHeader: String
    public var secretHeader: String
    /// The certificate a proxy in front of Hermes asks for, its identity in the Keychain
    /// (`ClientIdentityStore`). Combines with any `method`.
    public var clientCertificate: ClientCertificate?

    /// Cloudflare Access's names for a service token's headers.
    public static let defaultIDHeader = "CF-Access-Client-Id"
    public static let defaultSecretHeader = "CF-Access-Client-Secret"

    public static let none = GatewayAccess(method: .none)

    public init(
        method: Method, clientID: String = "", idHeader: String = defaultIDHeader,
        secretHeader: String = defaultSecretHeader, clientCertificate: ClientCertificate? = nil
    ) {
        self.method = method
        self.clientID = clientID
        self.idHeader = idHeader
        self.secretHeader = secretHeader
        self.clientCertificate = clientCertificate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown method (from a newer build) reads as none rather than losing the gateway.
        method = (try? container.decodeIfPresent(Method.self, forKey: .method)) ?? Method.none
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        idHeader = try container.decodeIfPresent(String.self, forKey: .idHeader) ?? Self.defaultIDHeader
        secretHeader = try container.decodeIfPresent(String.self, forKey: .secretHeader) ?? Self.defaultSecretHeader
        // A certificate saved by a newer build in a shape this one can't read is dropped, not the gateway.
        clientCertificate = (try? container.decodeIfPresent(ClientCertificate.self, forKey: .clientCertificate)) ?? nil
    }

    /// A proxy in front of Hermes asks for a client certificate.
    public var usesClientCertificate: Bool { clientCertificate != nil }

    /// Whether anything here changes what the app sends.
    public var isEnabled: Bool { method != .none || usesClientCertificate }

    /// What's wrong with a service token before it's saved, in words, or nil when it can be.
    public static func problem(clientID: String, secret: String, idHeader: String, secretHeader: String) -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return String(localized: "Enter the service token's client ID.") }
        if secret.isEmpty { return String(localized: "Enter the service token's secret.") }
        guard isAllowedValue(id), isAllowedValue(secret) else {
            return String(localized: "The client ID and secret can't contain line breaks or control characters.")
        }
        guard isAllowedHeaderName(idHeader), isAllowedHeaderName(secretHeader) else {
            return String(localized: "Header names use letters, digits and dashes, and can't be one the app sends itself.")
        }
        guard idHeader.lowercased() != secretHeader.lowercased() else {
            return String(localized: "The client ID and secret need different header names.")
        }
        return nil
    }

    /// A header name the app may send a token in: an HTTP token, and none of the headers the app
    /// or the system set themselves (Hermes's key, cookies, the host, a socket's handshake).
    public static func isAllowedHeaderName(_ name: String) -> Bool {
        let tchar = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
            .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy(tchar.contains) else { return false }
        let lowered = name.lowercased()
        return !reservedHeaders.contains(lowered) && !lowered.hasPrefix("sec-") && !lowered.hasPrefix("proxy-")
    }

    static let reservedHeaders: Set<String> = [
        "authorization", "cookie", "host", "content-length", "content-type", "accept", "connection",
        "upgrade", "transfer-encoding", "te", "trailer", "keep-alive", "x-hermes-session-token",
        "x-hermes-session-id", "last-event-id", "range", "origin", "referer", "user-agent",
    ]

    private static func isAllowedValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

/// The one place gateway requests get what an access gateway asks for (`docs/connecting-and-voice.md`
/// §11.6). Every transport passes its requests through `prepare`: HermesClient, BackendClient and
/// its sockets, GatewaySocket, the browser bridge, gateway audio, pictures and previews. A request
/// gets a gateway's access headers and cookies only when it goes to exactly that gateway's origin
/// (scheme, host and port), so they never reach another server; `SameOriginRedirects` takes them
/// off a redirect and puts them back only for the same origin.
public final class GatewayAccessRegistry: Sendable {
    public static let shared = GatewayAccessRegistry()

    /// What one gateway's requests carry.
    public struct Credentials: Sendable, Equatable {
        public var method: GatewayAccess.Method
        public var headers: [String: String]
        /// Cookies an access gateway's sign-in gave, by name.
        public var cookies: [String: String]
        /// The certificate a proxy's challenge is answered with.
        public var clientCertificate: URLCredential?
        /// What that certificate is, so a refusal can say it expired.
        public var certificate: ClientCertificate?

        public init(
            method: GatewayAccess.Method, headers: [String: String] = [:], cookies: [String: String] = [:],
            clientCertificate: URLCredential? = nil, certificate: ClientCertificate? = nil
        ) {
            self.method = method
            self.headers = headers
            self.cookies = cookies
            self.clientCertificate = clientCertificate
            self.certificate = certificate
        }

        /// These credentials with `identity` answering a proxy's challenge as well.
        public func presenting(_ identity: ClientIdentity?, as certificate: ClientCertificate?) -> Credentials {
            var credentials = self
            credentials.clientCertificate = identity?.credential
            credentials.certificate = identity == nil ? nil : certificate
            return credentials
        }

        /// Whether a request or a handshake gets anything from these.
        var isEmpty: Bool { headers.isEmpty && cookies.isEmpty && clientCertificate == nil }

        /// A service token's two headers, under the names the access gateway expects. Nil when
        /// they aren't fit to send (`GatewayAccess.problem`): `bots.json` is a plain file, so a
        /// rewritten header name never replaces Hermes's own Authorization or a socket's headers.
        public static func serviceToken(_ access: GatewayAccess, secret: String) -> Credentials? {
            guard GatewayAccess.problem(
                clientID: access.clientID, secret: secret, idHeader: access.idHeader, secretHeader: access.secretHeader
            ) == nil else { return nil }
            return Credentials(method: .serviceToken, headers: [
                access.idHeader: access.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                access.secretHeader: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
    }

    /// Scheme, host and port, with a socket's ws and wss counted as http and https.
    struct Origin: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
            switch url.scheme?.lowercased() {
            case "http", "ws": scheme = "http"
            case "https", "wss": scheme = "https"
            default: return nil
            }
            self.host = host
            port = url.port ?? (scheme == "https" ? 443 : 80)
        }

        /// A TLS challenge's protection space: the host and port the handshake is with.
        init(host: String, port: Int, isSecure: Bool) {
            scheme = isSecure ? "https" : "http"
            self.host = host.lowercased()
            self.port = port > 0 ? port : (isSecure ? 443 : 80)
        }
    }

    private struct Entry: Sendable {
        var origins: Set<Origin>
        var credentials: Credentials
    }

    private let entries = Mutex<[UUID: Entry]>([:])
    /// What the delegate needs of settings being tried (`trying`): their header names, so a
    /// redirect can take them off too, and the certificate, for the challenge of a request the
    /// trying task made. The headers themselves live in the trying task alone.
    private let trials = Mutex<[UUID: TrialRecord]>([:])

    private struct TrialRecord: Sendable {
        var origins: Set<Origin>
        var headerNames: Set<String>
        var cookieNames: Set<String>
        var clientCertificate: URLCredential?
        var certificate: ClientCertificate?
    }

    /// Settings being tried before they are saved, for the task that tries them and its children
    /// alone: the live connection to the same gateway keeps sending the saved ones meanwhile.
    private struct Trial: Sendable {
        var id: UUID
        var registry: ObjectIdentifier
        var origins: Set<Origin>
        var credentials: Credentials?
    }

    /// The last client-certificate challenge from each origin: whether a certificate answered it
    /// and which, so a handshake that then fails can be told apart from a lost connection
    /// (`AccessRefusal.classify(_:registry:)`). Cleared once that origin answers.
    private let challenges = Mutex<[Origin: Challenge]>([:])

    struct Challenge: Sendable, Equatable {
        var offered: Bool
        var certificate: ClientCertificate?
        var at: Date
    }

    /// How long after a challenge a failed handshake is still taken as the proxy's answer to it.
    static let challengeWindow: TimeInterval = 30

    /// The request property that ties a request to the settings being tried when it was made.
    static let trialProperty = "co.caffeinatedcode.hermes.access-trial"

    @TaskLocal private static var trial: Trial?

    public init() {}

    /// Runs `body` with `credentials` standing in for whatever is saved at `addresses`: an editor
    /// or pairing checks the settings on screen before they are saved. Nil tries without access.
    /// Only requests `body` makes see them (`docs/connecting-and-voice.md` §11.5). A certificate
    /// being tried answers the challenges of those requests alone: `prepare` marks each one, since
    /// the challenge arrives outside the task.
    public nonisolated(nonsending) func trying<T>(
        _ credentials: Credentials?, at addresses: [URL], _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        let id = UUID()
        let origins = Set(addresses.compactMap(Origin.init))
        let trial = Trial(id: id, registry: ObjectIdentifier(self), origins: origins, credentials: credentials)
        trials.withLock {
            $0[id] = TrialRecord(
                origins: origins, headerNames: Set(credentials?.headers.keys.map { $0.lowercased() } ?? []),
                cookieNames: Set(credentials?.cookies.keys.map(\.self) ?? []),
                clientCertificate: credentials?.clientCertificate, certificate: credentials?.certificate
            )
        }
        defer { _ = trials.withLock { $0.removeValue(forKey: id) } }
        return try await Self.$trial.withValue(trial, operation: body)
    }

    /// What a gateway's requests carry from now on, for its gateway and backend addresses alone.
    /// Nil or empty credentials forget it.
    public func set(_ credentials: Credentials?, for gateway: UUID, at addresses: [URL]) {
        let origins = Set(addresses.compactMap(Origin.init))
        entries.withLock { entries in
            guard let credentials, !origins.isEmpty, !credentials.isEmpty else {
                entries[gateway] = nil
                return
            }
            entries[gateway] = Entry(origins: origins, credentials: credentials)
        }
    }

    public func forget(_ gateway: UUID) {
        _ = entries.withLock { $0.removeValue(forKey: gateway) }
    }

    /// The credentials for a request to `url`: only a gateway registered at exactly its origin.
    public func credentials(for url: URL) -> Credentials? {
        guard let origin = Origin(url) else { return nil }
        if let trial = Self.trial, trial.registry == ObjectIdentifier(self), trial.origins.contains(origin) {
            return trial.credentials
        }
        return entries.withLock { entries in
            // Two gateways at one origin (profiles behind one access gateway) pass the same way;
            // the lowest id keeps the pick stable when they don't.
            entries.filter { $0.value.origins.contains(origin) }.min { $0.key.uuidString < $1.key.uuidString }?.value.credentials
        }
    }

    /// Adds `url`'s access headers and cookies to a request about to go there, and marks a request
    /// made while settings are being tried, so its challenge gets their certificate.
    public func prepare(_ request: inout URLRequest) {
        if let url = request.url, let origin = Origin(url), let trial = Self.trial,
           trial.registry == ObjectIdentifier(self), trial.origins.contains(origin) {
            Self.mark(&request, trial: trial.id)
        }
        guard let url = request.url, let credentials = credentials(for: url) else { return }
        for (name, value) in credentials.headers { request.setValue(value, forHTTPHeaderField: name) }
        guard !credentials.cookies.isEmpty else { return }
        let added = credentials.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let existing = request.value(forHTTPHeaderField: "Cookie").flatMap { $0.isEmpty ? nil : $0 }
        request.setValue(existing.map { "\($0); \(added)" } ?? added, forHTTPHeaderField: "Cookie")
    }

    public func prepared(_ request: URLRequest) -> URLRequest {
        var request = request
        prepare(&request)
        return request
    }

    /// Whether a request to a gateway's origin is missing its access headers: a page's own
    /// navigation in a web view, which `prepare` never saw (`PreviewController`).
    public func lacksAccess(_ request: URLRequest) -> Bool {
        guard let url = request.url, let credentials = credentials(for: url) else { return false }
        return credentials.headers.contains { request.value(forHTTPHeaderField: $0.key) != $0.value }
    }

    /// Every name an access header goes by: saved, being tried, and the usual pair.
    private var accessHeaderNames: Set<String> {
        let saved = entries.withLock { entries in entries.values.flatMap { $0.credentials.headers.keys } }
        let tried = trials.withLock { $0.values.flatMap(\.headerNames) }
        let usual = [GatewayAccess.defaultIDHeader, GatewayAccess.defaultSecretHeader]
        return Set((saved + usual).map { $0.lowercased() } + tried)
    }

    /// Whether a request carries any access header, whoever added it.
    public func carriesAccess(_ request: URLRequest) -> Bool {
        let names = accessHeaderNames
        return (request.allHTTPHeaderFields ?? [:]).keys.contains { names.contains($0.lowercased()) }
    }

    /// Whether a request carries a sign-in's cookie, saved or being tried, whoever added it: a
    /// socket's upgrade, which the delegate sees outside any trying task.
    public func carriesSession(_ request: URLRequest) -> Bool {
        guard let cookie = request.value(forHTTPHeaderField: "Cookie"), !cookie.isEmpty else { return false }
        let saved = entries.withLock { entries in entries.values.flatMap { $0.credentials.cookies.keys } }
        let names = Set(saved + trials.withLock { $0.values.flatMap(\.cookieNames) })
        return cookie.split(separator: ";").contains { part in
            let name = part.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return names.contains(name)
        }
    }

    /// The request with every access header taken off.
    public func withoutAccess(_ request: URLRequest) -> URLRequest {
        var request = request
        let names = accessHeaderNames
        for (name, _) in request.allHTTPHeaderFields ?? [:] where names.contains(name.lowercased()) {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        return request
    }

    /// Whether a web view's navigation would carry a gateway's access headers to another server:
    /// a page on the gateway that redirects or links elsewhere (`PreviewController`).
    public func leaksAccess(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return carriesAccess(request) }
        return credentials(for: url) == nil && carriesAccess(request)
    }

    /// A redirect URLSession is about to follow: every gateway's access headers come off, then go
    /// back on for the new address when it is a gateway's own origin. A redirect within the
    /// original's origin keeps the original's own headers, so settings being tried survive it
    /// (the delegate runs outside the trying task). The cookies the app added come off with them;
    /// a cookie from the original request otherwise stays (`SameOriginRedirects` already keeps
    /// the request on the same host).
    func redirected(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        var request = withoutAccess(request)
        if let originalURL = original?.url, let newURL = request.url, let original,
           Origin(originalURL) != nil, Origin(originalURL) == Origin(newURL) {
            let names = accessHeaderNames
            for (name, value) in original.allHTTPHeaderFields ?? [:] where names.contains(name.lowercased()) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return request
        }
        if let originalURL = original?.url, let added = credentials(for: originalURL), !added.cookies.isEmpty,
           let cookie = request.value(forHTTPHeaderField: "Cookie") {
            let kept = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { part in !added.cookies.keys.contains { part.hasPrefix("\($0)=") } }
            request.setValue(kept.isEmpty ? nil : kept.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        prepare(&request)
        return request
    }

    /// The certificate that answers a proxy's client-certificate challenge for `task` from `host`
    /// and `port`: the one being tried when the task's request was made while trying, otherwise
    /// the one saved for that origin, or nil. Notes the challenge either way.
    func answerChallenge(for task: URLSessionTask?, host: String, port: Int, isSecure: Bool, at now: Date = .now) -> URLCredential? {
        let origin = Origin(host: host, port: port, isSecure: isSecure)
        let request = task?.originalRequest ?? task?.currentRequest
        let tried = request.flatMap(Self.trialID).flatMap { id in
            trials.withLock { $0[id] }.flatMap { $0.origins.contains(origin) ? $0 : nil }
        }
        let answer: (URLCredential?, ClientCertificate?)
        if let tried {
            answer = (tried.clientCertificate, tried.certificate)
        } else {
            let saved = entries.withLock { entries in
                entries.filter { $0.value.origins.contains(origin) }.min { $0.key.uuidString < $1.key.uuidString }?.value.credentials
            }
            answer = (saved?.clientCertificate, saved?.certificate)
        }
        challenges.withLock { $0[origin] = Challenge(offered: answer.0 != nil, certificate: answer.1, at: now) }
        return answer.0
    }

    /// The challenge `url`'s origin sent last, while a failure can still be its answer.
    func recentChallenge(at url: URL, now: Date = .now) -> Challenge? {
        guard let origin = Origin(url) else { return nil }
        return challenges.withLock { $0[origin] }.flatMap { now.timeIntervalSince($0.at) <= Self.challengeWindow ? $0 : nil }
    }

    /// `url`'s origin answered over TLS, so whatever fails there next isn't the handshake.
    func noteAnswered(_ url: URL) {
        guard let origin = Origin(url) else { return }
        _ = challenges.withLock { $0.removeValue(forKey: origin) }
    }

    private static func mark(_ request: inout URLRequest, trial: UUID) {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(trial.uuidString, forKey: trialProperty, in: mutable)
        request = mutable as URLRequest
    }

    static func trialID(_ request: URLRequest) -> UUID? {
        (URLProtocol.property(forKey: trialProperty, in: request) as? String).flatMap(UUID.init(uuidString:))
    }
}

/// Who stopped a request before Hermes saw it (`docs/connecting-and-voice.md` §11.2). Told apart
/// from Hermes's own refusals, which are JSON, so a sign-in page is never read as a wrong key.
public enum AccessRefusal: Sendable, Equatable {
    /// An access gateway wants a sign-in, or a token, and got neither.
    case signInNeeded
    /// The access gateway turned away the session its sign-in page gave: it ran out or was revoked.
    case signInExpired
    /// The access gateway refused the service token the app sent.
    case tokenRejected
    /// A proxy asked for a client certificate and the app had none to give.
    case certificateNeeded
    /// A proxy refused the client certificate.
    case certificateRejected
    /// A proxy refused the client certificate, which ran out on this date.
    case certificateExpired(Date)

    /// An answer that came from an access gateway rather than Hermes, or nil: a redirect to
    /// another server (`SameOriginRedirects` doesn't follow it, so it comes back as the answer),
    /// or a 401 or 403 with a body that isn't JSON (an HTML sign-in or error page). Hermes's own
    /// refusals are JSON, apart from the API server's bare, empty 403 for a browser origin it
    /// doesn't allow, so an empty body stays Hermes's. `body` is nil when it can't be read (a
    /// socket's upgrade); then only an HTML page counts, since that bare 403 is `text/plain`.
    /// `sent` says what the request carried, which decides between asking for a sign-in or a token,
    /// saying the token was refused, and saying the sign-in ran out.
    public static func classify(_ response: HTTPURLResponse, body: Data?, sent: Sent) -> AccessRefusal? {
        let status = response.statusCode
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let refused: Bool
        if (300..<400).contains(status), status != 304 {
            refused = true
        } else if status == 401 || status == 403 {
            refused = type.contains("html") || (!type.contains("json") && (body.map { !$0.isEmpty } ?? false))
        } else {
            refused = false
        }
        guard refused else { return nil }
        return switch sent {
        case .nothing: .signInNeeded
        case .serviceToken: .tokenRejected
        case .session: .signInExpired
        }
    }

    /// What a refused request carried past the access gateway.
    public enum Sent: Sendable {
        case nothing, serviceToken, session
    }

    /// `classify` for a request made through `GatewayAccessRegistry`.
    public static func classify(
        _ response: HTTPURLResponse, body: Data?, to url: URL?, registry: GatewayAccessRegistry = .shared
    ) -> AccessRefusal? {
        let credentials = url.flatMap { registry.credentials(for: $0) }
        let sent: Sent = if !(credentials?.headers.isEmpty ?? true) {
            .serviceToken
        } else if !(credentials?.cookies.isEmpty ?? true) {
            .session
        } else {
            .nothing
        }
        return classify(response, body: body, sent: sent)
    }

    /// Why a socket's upgrade failed, when an access gateway or a proxy refused it: the answer to
    /// the upgrade (its body never reaches the app), or the TLS failure. A socket that got an
    /// answer got through the handshake, so when it drops later that's never a refusal.
    public static func refused(_ task: URLSessionTask, error: any Error) -> HermesError? {
        let host = task.originalRequest?.url?.host() ?? ""
        if task.response == nil, var urlError = error as? URLError {
            // A socket's error may not say where it failed; the challenge is looked up there.
            if urlError.failingURL == nil, let url = task.originalRequest?.url {
                urlError = URLError(urlError.code, userInfo: [NSURLErrorFailingURLErrorKey: url])
            }
            if let refusal = classify(urlError) { return .accessRefused(host: host, refusal) }
        }
        // The upgrade's own headers say whether a token or a session went: the delegate runs
        // outside any task that was trying settings, so the registry can't be asked.
        let request = task.currentRequest ?? task.originalRequest
        let registry = GatewayAccessRegistry.shared
        let sent: Sent = if request.map(registry.carriesAccess) ?? false {
            .serviceToken
        } else if request.map(registry.carriesSession) ?? false {
            .session
        } else {
            .nothing
        }
        guard let response = task.response as? HTTPURLResponse,
              let refusal = classify(response, body: nil, sent: sent)
        else { return nil }
        return .accessRefused(host: host, refusal)
    }

    /// The TLS failures that mean a proxy wanted a client certificate, or nil. The system names
    /// them only now and then: a TLS 1.3 proxy that refuses one ends the connection after the
    /// handshake, which reads as a lost connection (`networkConnectionLost`), and TLS 1.2 gives
    /// a generic handshake failure. So a failure at an origin that sent a client-certificate
    /// challenge moments ago is taken as the answer to it: none given means one is needed, one
    /// given was refused, or expired when it has run out.
    public static func classify(
        _ error: URLError, registry: GatewayAccessRegistry = .shared, now: Date = .now
    ) -> AccessRefusal? {
        let challenge = error.failingURL.flatMap { registry.recentChallenge(at: $0, now: now) }
        switch error.code {
        case .clientCertificateRequired:
            return .certificateNeeded
        case .clientCertificateRejected:
            return challenge.map { refusal(answering: $0, now: now) } ?? .certificateRejected
        case .networkConnectionLost, .secureConnectionFailed:
            return challenge.map { refusal(answering: $0, now: now) }
        default:
            return nil
        }
    }

    private static func refusal(answering challenge: GatewayAccessRegistry.Challenge, now: Date) -> AccessRefusal {
        guard challenge.offered else { return .certificateNeeded }
        if let certificate = challenge.certificate, certificate.isExpired(at: now) {
            return .certificateExpired(certificate.notAfter)
        }
        return .certificateRejected
    }
}

extension AccessRefusal {
    /// The status card's title (`docs/connecting-and-voice.md` §11.2).
    public var title: String {
        switch self {
        case .signInNeeded: String(localized: "An access gateway answered, not Hermes")
        case .signInExpired: String(localized: "Your sign-in to the access gateway expired")
        case .tokenRejected: String(localized: "The access gateway refused the service token")
        case .certificateNeeded: String(localized: "The proxy asks for a certificate")
        case .certificateRejected: String(localized: "The proxy refused this certificate")
        case .certificateExpired: String(localized: "The certificate expired")
        }
    }

    /// The Access status card's title, for the gateway named `name` (`accessStatus`).
    public func title(gateway name: String) -> String {
        self == .signInNeeded ? String(localized: "Sign in to reach \(name)") : title
    }

    /// The Access status card's line, for the gateway named `name` (`accessSignInExpired`).
    public func detail(gateway name: String) -> String {
        self == .signInExpired ? String(localized: "Sign in again to reach \(name). Your chats are safe on the gateway.") : detail
    }

    /// What to do about it.
    public var detail: String {
        switch self {
        case .signInNeeded:
            String(localized: "An access gateway stands in front of Hermes and wants you to sign in before the app gets through.")
        case .signInExpired:
            String(localized: "Sign in again to reach Hermes. Your chats are safe on the gateway.")
        case .tokenRejected:
            String(localized: "Check the client ID and secret, and that the token is allowed for this gateway and hasn't expired.")
        case .certificateNeeded:
            String(localized: "A proxy in front of Hermes lets in only devices with a client certificate. Import the one you were given.")
        case .certificateRejected:
            String(localized: "It may be for another server, or revoked. Import the certificate this proxy expects.")
        case .certificateExpired(let date):
            String(localized: "It ran out on \(date.formatted(date: .abbreviated, time: .omitted)), so the proxy turns the app away. Import a current one.")
        }
    }

    /// Who said so, so it's never taken for Hermes's own key check.
    public func source(host: String) -> String {
        switch self {
        case .signInNeeded, .signInExpired, .tokenRejected: String(localized: "From the access gateway at \(host)")
        case .certificateNeeded, .certificateRejected, .certificateExpired: String(localized: "From the proxy at \(host)")
        }
    }

    /// The chat banner's title and line (`accessTokenBanner`), for the gateway named `name`.
    public var bannerTitle: String {
        switch self {
        case .signInNeeded: String(localized: "An access gateway turned the app away")
        case .signInExpired: String(localized: "Your access sign-in expired")
        case .tokenRejected: String(localized: "The access gateway refused the token")
        case .certificateNeeded: String(localized: "The proxy asks for a certificate")
        case .certificateRejected: String(localized: "The proxy refused this certificate")
        case .certificateExpired: String(localized: "The certificate expired")
        }
    }

    public func bannerDetail(gateway name: String) -> String {
        switch self {
        case .signInNeeded: String(localized: "Sign in for \(name) in Access, or set up a service token.")
        case .signInExpired: String(localized: "The access gateway in front of \(name) wants you to sign in again.")
        case .tokenRejected: String(localized: "Check the service token for \(name) in Access.")
        case .certificateNeeded: String(localized: "\(name)'s proxy asks for a certificate. Import one in Access.")
        case .certificateRejected: String(localized: "\(name)'s proxy turned the app away. Replace the certificate in Access.")
        case .certificateExpired: String(localized: "\(name)'s certificate ran out. Replace it in Access.")
        }
    }

    /// A proxy's certificate check, answered in Access with a certificate.
    public var isCertificate: Bool {
        switch self {
        case .certificateNeeded, .certificateRejected, .certificateExpired: true
        case .signInNeeded, .signInExpired, .tokenRejected: false
        }
    }

    /// An access gateway's sign-in, answered on its own page (`docs/connecting-and-voice.md` §11.10).
    public var isSignIn: Bool {
        switch self {
        case .signInNeeded, .signInExpired: true
        case .tokenRejected, .certificateNeeded, .certificateRejected, .certificateExpired: false
        }
    }
}

/// The Access settings on screen in Edit Gateway, before they are saved
/// (`docs/connecting-and-voice.md` §11.1). The secret field stays empty for a saved token, which
/// it keeps unless something is typed.
public struct GatewayAccessDraft: Equatable, Sendable {
    public var method: GatewayAccess.Method
    public var clientID: String
    /// What was typed; empty keeps the saved secret.
    public var secret: String
    public var idHeader: String
    public var secretHeader: String
    /// A secret is in the Keychain for this gateway already.
    public var hasSavedSecret: Bool
    /// The client certificate the proxy gets (`docs/connecting-and-voice.md` §11.9), or nil.
    public var certificate: ClientCertificate?
    /// Its identity: loaded from the Keychain for a saved certificate, or just imported. Nil
    /// with a certificate when the Keychain no longer has it.
    public var identity: ClientIdentity?
    /// The access gateway's session from its sign-in page (`docs/connecting-and-voice.md` §11.10):
    /// loaded from the Keychain for a saved gateway, or just signed in. Kept even when it expired,
    /// so the Access screen can say who it was.
    public var session: AccessSession?
    /// When the session was last signed out of here, for the Access screen's "Signed out on".
    public var signedOutAt: Date?

    public var usesClientCertificate: Bool { certificate != nil }

    public init(
        _ access: GatewayAccess? = nil, hasSavedSecret: Bool = false, identity: ClientIdentity? = nil,
        session: AccessSession? = nil
    ) {
        let access = access ?? .none
        method = access.method
        clientID = access.clientID
        secret = ""
        idHeader = access.idHeader
        secretHeader = access.secretHeader
        self.hasSavedSecret = hasSavedSecret && access.method == .serviceToken
        certificate = access.clientCertificate
        self.identity = access.clientCertificate == nil ? nil : identity
        self.session = access.method == .browserSignIn ? session : nil
    }

    /// Takes what a sign-in page just gave, in place of any earlier session.
    public mutating func signedIn(_ session: AccessSession) {
        method = .browserSignIn
        self.session = session
        signedOutAt = nil
    }

    public mutating func signOut(at now: Date = .now) {
        session = nil
        signedOutAt = now
    }

    /// The session that gets saved: only with browser sign-in chosen.
    public var savedSession: AccessSession? {
        method == .browserSignIn ? session : nil
    }

    /// Takes a certificate just imported, in place of any other.
    public mutating func useCertificate(_ certificate: ClientCertificate, identity: ClientIdentity) {
        self.certificate = certificate
        self.identity = identity
    }

    public mutating func removeCertificate() {
        certificate = nil
        identity = nil
    }

    /// What gets saved with the gateway, or nil when nothing stands in front of it.
    public var access: GatewayAccess? {
        let access = GatewayAccess(
            method: method, clientID: method == .serviceToken ? clientID.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            idHeader: idHeader.trimmingCharacters(in: .whitespaces), secretHeader: secretHeader.trimmingCharacters(in: .whitespaces),
            clientCertificate: certificate
        )
        return access.isEnabled ? access : nil
    }

    /// The typed secret to save: nil keeps what's saved (or there's nothing to save).
    public var typedSecret: String? {
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return method == .serviceToken && !typed.isEmpty ? typed : nil
    }

    /// Edit Gateway's Access row: "None", "Service token", "Service token, certificate".
    public var summary: String {
        let kind = switch method {
        case .none: usesClientCertificate ? nil : String(localized: "None")
        case .serviceToken: String(localized: "Service token")
        case .browserSignIn: String(localized: "Browser sign-in")
        }
        let certificate = usesClientCertificate ? String(localized: "certificate") : nil
        guard let kind else { return String(localized: "Certificate") }
        return [kind, certificate].compactMap(\.self).joined(separator: ", ")
    }

    /// What's missing before it can be saved, in words, or nil. `savedSecret` is the Keychain's.
    public func problem(savedSecret: String?) -> String? {
        guard method == .serviceToken else { return nil }
        return GatewayAccess.problem(
            clientID: clientID, secret: typedSecret ?? savedSecret ?? "", idHeader: idHeader.trimmingCharacters(in: .whitespaces),
            secretHeader: secretHeader.trimmingCharacters(in: .whitespaces)
        )
    }

    /// What a check of these settings sends, before they are saved (`GatewayAccessRegistry.trying`):
    /// the service token's headers or the sign-in's cookies, and the certificate, or nil when
    /// there's none of them.
    public func credentials(savedSecret: String?) -> GatewayAccessRegistry.Credentials? {
        guard let access else { return nil }
        let token: GatewayAccessRegistry.Credentials? = switch method {
        case .serviceToken: .serviceToken(access, secret: typedSecret ?? savedSecret ?? "")
        case .browserSignIn: session?.credentials
        case .none: nil
        }
        guard let identity, certificate != nil else { return token }
        return (token ?? .init(method: method)).presenting(identity, as: certificate)
    }
}
