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
    /// A proxy in front of Hermes asks for a client certificate. Combines with any `method`.
    public var usesClientCertificate: Bool

    /// Cloudflare Access's names for a service token's headers.
    public static let defaultIDHeader = "CF-Access-Client-Id"
    public static let defaultSecretHeader = "CF-Access-Client-Secret"

    public static let none = GatewayAccess(method: .none)

    public init(
        method: Method, clientID: String = "", idHeader: String = defaultIDHeader,
        secretHeader: String = defaultSecretHeader, usesClientCertificate: Bool = false
    ) {
        self.method = method
        self.clientID = clientID
        self.idHeader = idHeader
        self.secretHeader = secretHeader
        self.usesClientCertificate = usesClientCertificate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown method (from a newer build) reads as none rather than losing the gateway.
        method = (try? container.decodeIfPresent(Method.self, forKey: .method)) ?? Method.none
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID) ?? ""
        idHeader = try container.decodeIfPresent(String.self, forKey: .idHeader) ?? Self.defaultIDHeader
        secretHeader = try container.decodeIfPresent(String.self, forKey: .secretHeader) ?? Self.defaultSecretHeader
        usesClientCertificate = try container.decodeIfPresent(Bool.self, forKey: .usesClientCertificate) ?? false
    }

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

        public init(
            method: GatewayAccess.Method, headers: [String: String] = [:], cookies: [String: String] = [:],
            clientCertificate: URLCredential? = nil
        ) {
            self.method = method
            self.headers = headers
            self.cookies = cookies
            self.clientCertificate = clientCertificate
        }

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
    }

    private struct Entry: Sendable {
        var origins: Set<Origin>
        var credentials: Credentials
    }

    private let entries = Mutex<[UUID: Entry]>([:])
    /// The header names of settings being tried (`trying`), so a redirect can take them off too.
    /// Names only: the credentials themselves live in the trying task alone.
    private let trialHeaderNames = Mutex<[UUID: Set<String>]>([:])

    /// Settings being tried before they are saved, for the task that tries them and its children
    /// alone: the live connection to the same gateway keeps sending the saved ones meanwhile.
    private struct Trial: Sendable {
        var registry: ObjectIdentifier
        var origins: Set<Origin>
        var credentials: Credentials?
    }

    @TaskLocal private static var trial: Trial?

    public init() {}

    /// Runs `body` with `credentials` standing in for whatever is saved at `addresses`: an editor
    /// or pairing checks the settings on screen before they are saved. Nil tries without access.
    /// Only requests `body` makes see them (`docs/connecting-and-voice.md` §11.5): a certificate
    /// being tried isn't offered to a challenge, which arrives outside the task.
    public nonisolated(nonsending) func trying<T>(
        _ credentials: Credentials?, at addresses: [URL], _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        let id = UUID()
        let trial = Trial(
            registry: ObjectIdentifier(self), origins: Set(addresses.compactMap(Origin.init)), credentials: credentials
        )
        trialHeaderNames.withLock { $0[id] = Set(credentials?.headers.keys.map { $0.lowercased() } ?? []) }
        defer { _ = trialHeaderNames.withLock { $0.removeValue(forKey: id) } }
        return try await Self.$trial.withValue(trial, operation: body)
    }

    /// What a gateway's requests carry from now on, for its gateway and backend addresses alone.
    /// Nil or empty credentials forget it.
    public func set(_ credentials: Credentials?, for gateway: UUID, at addresses: [URL]) {
        let origins = Set(addresses.compactMap(Origin.init))
        entries.withLock { entries in
            guard let credentials, !origins.isEmpty,
                  !credentials.headers.isEmpty || !credentials.cookies.isEmpty || credentials.clientCertificate != nil
            else {
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

    /// Adds `url`'s access headers and cookies to a request about to go there.
    public func prepare(_ request: inout URLRequest) {
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
        let tried = trialHeaderNames.withLock { $0.values.flatMap { $0 } }
        let usual = [GatewayAccess.defaultIDHeader, GatewayAccess.defaultSecretHeader]
        return Set((saved + usual).map { $0.lowercased() } + tried)
    }

    /// Whether a request carries any access header, whoever added it.
    public func carriesAccess(_ request: URLRequest) -> Bool {
        let names = accessHeaderNames
        return (request.allHTTPHeaderFields ?? [:]).keys.contains { names.contains($0.lowercased()) }
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

    /// The certificate to answer a proxy's client-certificate challenge from `host` and `port`.
    func clientCertificate(host: String, port: Int, isSecure: Bool) -> URLCredential? {
        var components = URLComponents()
        components.scheme = isSecure ? "https" : "http"
        components.host = host
        components.port = port
        guard let url = components.url else { return nil }
        return credentials(for: url)?.clientCertificate
    }
}

/// Who stopped a request before Hermes saw it (`docs/connecting-and-voice.md` §11.2). Told apart
/// from Hermes's own refusals, which are JSON, so a sign-in page is never read as a wrong key.
public enum AccessRefusal: Sendable, Equatable {
    /// An access gateway wants a sign-in, or a token, and got neither.
    case signInNeeded
    /// The access gateway refused the service token the app sent.
    case tokenRejected
    /// A proxy asked for a client certificate and the app had none to give.
    case certificateNeeded
    /// A proxy refused the client certificate.
    case certificateRejected

    /// An answer that came from an access gateway rather than Hermes, or nil: a redirect to
    /// another server (`SameOriginRedirects` doesn't follow it, so it comes back as the answer),
    /// or a 401 or 403 with a body that isn't JSON (an HTML sign-in or error page). Hermes's own
    /// refusals are JSON, apart from the API server's bare, empty 403 for a browser origin it
    /// doesn't allow, so an empty body stays Hermes's. `body` is nil when it can't be read (a
    /// socket's upgrade); then only an HTML page counts, since that bare 403 is `text/plain`.
    /// `sentToken` says whether the request carried a service token, which decides between asking
    /// for one and saying the one sent was refused.
    public static func classify(_ response: HTTPURLResponse, body: Data?, sentToken: Bool) -> AccessRefusal? {
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
        return sentToken ? .tokenRejected : .signInNeeded
    }

    /// `classify` for a request made through `GatewayAccessRegistry`.
    public static func classify(
        _ response: HTTPURLResponse, body: Data?, to url: URL?, registry: GatewayAccessRegistry = .shared
    ) -> AccessRefusal? {
        let sent = url.flatMap { registry.credentials(for: $0) }.map { !$0.headers.isEmpty } ?? false
        return classify(response, body: body, sentToken: sent)
    }

    /// Why a socket's upgrade failed, when an access gateway or a proxy refused it: the answer to
    /// the upgrade (its body never reaches the app), or the TLS failure.
    public static func refused(_ task: URLSessionTask, error: any Error) -> HermesError? {
        let host = task.originalRequest?.url?.host() ?? ""
        if let urlError = error as? URLError, let refusal = classify(urlError) {
            return .accessRefused(host: host, refusal)
        }
        // The upgrade's own headers say whether a token went: the delegate runs outside any
        // task that was trying settings, so the registry can't be asked.
        let sent = (task.currentRequest ?? task.originalRequest).map(GatewayAccessRegistry.shared.carriesAccess) ?? false
        guard let response = task.response as? HTTPURLResponse,
              let refusal = classify(response, body: nil, sentToken: sent)
        else { return nil }
        return .accessRefused(host: host, refusal)
    }

    /// The TLS failures that mean a proxy wanted a client certificate.
    public static func classify(_ error: URLError) -> AccessRefusal? {
        switch error.code {
        case .clientCertificateRequired: .certificateNeeded
        case .clientCertificateRejected: .certificateRejected
        default: nil
        }
    }
}

extension AccessRefusal {
    /// The status card's title (`docs/connecting-and-voice.md` §11.2).
    public var title: String {
        switch self {
        case .signInNeeded: String(localized: "An access gateway answered, not Hermes")
        case .tokenRejected: String(localized: "The access gateway refused the service token")
        case .certificateNeeded: String(localized: "The proxy asks for a certificate")
        case .certificateRejected: String(localized: "The proxy refused this certificate")
        }
    }

    /// What to do about it.
    public var detail: String {
        switch self {
        case .signInNeeded:
            String(localized: "An access gateway stands in front of Hermes and turns the app away. Set up a service token for it.")
        case .tokenRejected:
            String(localized: "Check the client ID and secret, and that the token is allowed for this gateway and hasn't expired.")
        case .certificateNeeded, .certificateRejected:
            String(localized: "A proxy in front of Hermes lets in only devices with a client certificate. This version of the app can't send one yet.")
        }
    }

    /// Who said so, so it's never taken for Hermes's own key check.
    public func source(host: String) -> String {
        switch self {
        case .signInNeeded, .tokenRejected: String(localized: "From the access gateway at \(host)")
        case .certificateNeeded, .certificateRejected: String(localized: "From the proxy at \(host)")
        }
    }

    /// The chat banner's title and line (`accessTokenBanner`), for the gateway named `name`.
    public var bannerTitle: String {
        switch self {
        case .signInNeeded: String(localized: "An access gateway turned the app away")
        case .tokenRejected: String(localized: "The access gateway refused the token")
        case .certificateNeeded, .certificateRejected: String(localized: "The proxy turned the app away")
        }
    }

    public func bannerDetail(gateway name: String) -> String {
        switch self {
        case .signInNeeded: String(localized: "Set up a service token for \(name) in Access.")
        case .tokenRejected: String(localized: "Check the service token for \(name) in Access.")
        case .certificateNeeded, .certificateRejected: String(localized: "\(name)'s proxy asks for a client certificate.")
        }
    }

    /// A proxy's certificate check, which this version of the app can't answer.
    public var isCertificate: Bool {
        self == .certificateNeeded || self == .certificateRejected
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
    /// Carried over from the saved settings: the app has no certificate settings yet.
    public var usesClientCertificate: Bool

    public init(_ access: GatewayAccess? = nil, hasSavedSecret: Bool = false) {
        let access = access ?? .none
        method = access.method
        clientID = access.clientID
        secret = ""
        idHeader = access.idHeader
        secretHeader = access.secretHeader
        self.hasSavedSecret = hasSavedSecret && access.method == .serviceToken
        usesClientCertificate = access.usesClientCertificate
    }

    /// What gets saved with the gateway, or nil when nothing stands in front of it.
    public var access: GatewayAccess? {
        let access = GatewayAccess(
            method: method, clientID: method == .serviceToken ? clientID.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            idHeader: idHeader.trimmingCharacters(in: .whitespaces), secretHeader: secretHeader.trimmingCharacters(in: .whitespaces),
            usesClientCertificate: usesClientCertificate
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

    /// What a check of these settings sends, before they are saved (`GatewayAccessRegistry.trying`).
    public func credentials(savedSecret: String?) -> GatewayAccessRegistry.Credentials? {
        guard method == .serviceToken, let access else { return nil }
        return .serviceToken(access, secret: typedSecret ?? savedSecret ?? "")
    }
}
