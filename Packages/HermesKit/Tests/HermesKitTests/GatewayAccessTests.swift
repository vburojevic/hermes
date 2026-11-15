import Foundation
import Testing
@testable import HermesKit

/// An access gateway in front of Hermes (`docs/connecting-and-voice.md` §11): its refusals are told
/// apart from Hermes's own, every kind of request carries the service token to the gateway's origin
/// and nowhere else, and the token's secret lives in the Keychain.
@Suite("Gateway access")
struct GatewayAccessTests {
    static let access = GatewayAccess(method: .serviceToken, clientID: "client.access")
    static let token = GatewayAccessRegistry.Credentials.serviceToken(access, secret: "secret-0123")!

    static func response(_ status: Int, type: String? = nil, location: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let type { headers["Content-Type"] = type }
        if let location { headers["Location"] = location }
        return HTTPURLResponse(
            url: URL(string: "https://hermes.example.com/v1/models")!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: Telling refusals apart

    @Test(arguments: [301, 302, 303, 307, 308])
    func aRedirectToSignInIsTheAccessGateways(status: Int) {
        let redirect = Self.response(status, type: "text/html", location: "https://team.example.com/cdn-cgi/access/login")
        #expect(AccessRefusal.classify(redirect, body: Data(), sent: .nothing) == .signInNeeded)
        #expect(AccessRefusal.classify(redirect, body: Data(), sent: .serviceToken) == .tokenRejected)
    }

    @Test(arguments: [401, 403])
    func anHTMLPageIsTheAccessGatewaysAndJSONIsHermess(status: Int) {
        let page = Data("<html><title>Forbidden | Access</title></html>".utf8)
        #expect(AccessRefusal.classify(Self.response(status, type: "text/html; charset=utf-8"), body: page, sent: .nothing) == .signInNeeded)
        #expect(AccessRefusal.classify(Self.response(status, type: "text/html"), body: page, sent: .serviceToken) == .tokenRejected)
        #expect(AccessRefusal.classify(Self.response(status, type: "text/plain"), body: Data("Forbidden".utf8), sent: .nothing) == .signInNeeded)

        // Hermes's own refusals are JSON, and its bare 403 for a browser origin is empty.
        let hermes = Data(#"{"error":{"message":"Invalid API key","code":"invalid_api_key"}}"#.utf8)
        #expect(AccessRefusal.classify(Self.response(status, type: "application/json"), body: hermes, sent: .serviceToken) == nil)
        #expect(AccessRefusal.classify(Self.response(status), body: Data(), sent: .nothing) == nil)
    }

    @Test func otherAnswersAreNotRefusals() {
        let page = Data("<html>Oops</html>".utf8)
        #expect(AccessRefusal.classify(Self.response(304), body: Data(), sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(500, type: "text/html"), body: page, sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(404, type: "text/html"), body: page, sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(200, type: "text/html"), body: page, sent: .nothing) == nil)
    }

    /// A socket's upgrade answer has no body to read: only an HTML page counts, since Hermes's
    /// own bare 403 for a browser origin it doesn't allow is `text/plain`.
    @Test func aSocketsRefusalIsReadFromItsContentType() {
        #expect(AccessRefusal.classify(Self.response(403, type: "text/html"), body: nil, sent: .nothing) == .signInNeeded)
        #expect(AccessRefusal.classify(Self.response(403, type: "application/json"), body: nil, sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(403, type: "text/plain; charset=utf-8"), body: nil, sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(403, type: "text/plain"), body: Data(), sent: .nothing) == nil)
        #expect(AccessRefusal.classify(Self.response(403), body: nil, sent: .nothing) == nil)
    }

    @Test func certificateFailuresAreTheProxysAndOtherTLSFailuresAreNot() {
        let registry = GatewayAccessRegistry()
        #expect(AccessRefusal.classify(URLError(.clientCertificateRequired), registry: registry) == .certificateNeeded)
        #expect(AccessRefusal.classify(URLError(.clientCertificateRejected), registry: registry) == .certificateRejected)
        #expect(AccessRefusal.classify(URLError(.serverCertificateUntrusted), registry: registry) == nil)
        #expect(AccessRefusal.classify(URLError(.timedOut), registry: registry) == nil)
        // A lost connection or a failed handshake with no challenge before it is just that.
        #expect(AccessRefusal.classify(URLError(.networkConnectionLost), registry: registry) == nil)
        #expect(AccessRefusal.classify(URLError(.secureConnectionFailed), registry: registry) == nil)
        #expect(HermesError.from(urlError: URLError(.clientCertificateRequired), host: "h.example.com")
            == .accessRefused(host: "h.example.com", .certificateNeeded))
        #expect(HermesError.from(urlError: URLError(.serverCertificateUntrusted), host: "h.example.com")
            == .unreachable(host: "h.example.com", reason: .tls))
    }

    @Test func anErrorResponseReadsAsTheRefusalBeforeHermessKeyCheck() {
        let url = URL(string: "https://refusing-\(UUID().uuidString.lowercased()).example.com/v1/models")!
        let page = Self.response(401, type: "text/html")
        #expect(HermesError.from(page, body: Data("<html>Sign in</html>".utf8), url: url)
            == .accessRefused(host: url.host()!, .signInNeeded))
        let json = Self.response(401, type: "application/json")
        let error = HermesError.from(json, body: Data(#"{"error":{"message":"Invalid API key"}}"#.utf8), url: url)
        #expect(error.accessRefusal == nil)
    }

    // MARK: Where the token goes

    @Test func theTokenGoesOnlyToTheGatewaysOrigin() {
        let registry = GatewayAccessRegistry()
        let gateway = UUID()
        registry.set(Self.token, for: gateway, at: [
            URL(string: "https://hermes.example.com/p/work")!, URL(string: "http://mac.example.com:9119")!,
        ])

        for address in [
            "https://hermes.example.com/v1/models", "https://HERMES.example.com:443/p/other/v1/runs",
            "wss://hermes.example.com/v1/browser-control/ws", "http://mac.example.com:9119/api/ws",
            "ws://mac.example.com:9119/api/board/events",
        ] {
            let request = registry.prepared(URLRequest(url: URL(string: address)!))
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client.access", "\(address)")
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret-0123", "\(address)")
        }
        for address in [
            "http://hermes.example.com/v1/models", "https://hermes.example.com:8443/v1/models",
            "https://evil.example.com/v1/models", "https://hermes.example.com.evil.example/v1/models",
            "http://mac.example.com:9120/api/ws", "https://mac.example.com:9119/api/ws", "file:///tmp/x",
        ] {
            let request = registry.prepared(URLRequest(url: URL(string: address)!))
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil, "\(address)")
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil, "\(address)")
        }
    }

    @Test func hermessKeyAndTheSessionCookieStay() {
        let registry = GatewayAccessRegistry()
        var credentials = Self.token
        credentials.cookies = ["CF_Authorization": "signed-in"]
        registry.set(credentials, for: UUID(), at: [URL(string: "https://hermes.example.com")!])

        var request = URLRequest(url: URL(string: "https://hermes.example.com/api/files")!)
        request.setValue("Bearer hermes-key", forHTTPHeaderField: "Authorization")
        request.setValue("hermes_session=abc", forHTTPHeaderField: "Cookie")
        registry.prepare(&request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hermes-key")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "hermes_session=abc; CF_Authorization=signed-in")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client.access")
    }

    @Test func forgettingAGatewayStopsItsToken() {
        let registry = GatewayAccessRegistry()
        let gateway = UUID()
        let url = URL(string: "https://hermes.example.com/v1/models")!
        registry.set(Self.token, for: gateway, at: [url])
        #expect(registry.credentials(for: url) == Self.token)
        registry.forget(gateway)
        #expect(registry.credentials(for: url) == nil)

        registry.set(Self.token, for: gateway, at: [url])
        registry.set(nil, for: gateway, at: [url])
        #expect(registry.credentials(for: url) == nil)
        registry.set(GatewayAccessRegistry.Credentials(method: .serviceToken), for: gateway, at: [url])
        #expect(registry.credentials(for: url) == nil)
    }

    /// A web view's own navigation never went through `prepare`, so the preview loads it again with
    /// the headers.
    @Test func aRequestWithoutTheHeadersLacksAccess() {
        let registry = GatewayAccessRegistry()
        registry.set(Self.token, for: UUID(), at: [URL(string: "https://hermes.example.com")!])
        let bare = URLRequest(url: URL(string: "https://hermes.example.com/artifact/index.html")!)
        #expect(registry.lacksAccess(bare))
        #expect(!registry.lacksAccess(registry.prepared(bare)))
        #expect(!registry.lacksAccess(URLRequest(url: URL(string: "https://cdn.example.com/app.js")!)))
    }

    @Test func aRedirectElsewhereLosesTheTokenAndOneHomeKeepsIt() {
        let registry = GatewayAccessRegistry()
        var credentials = Self.token
        credentials.cookies = ["CF_Authorization": "signed-in"]
        registry.set(credentials, for: UUID(), at: [URL(string: "https://hermes.example.com")!])
        let original = registry.prepared(URLRequest(url: URL(string: "https://hermes.example.com/v1/models")!))

        // URLSession copies the original's headers onto the redirect.
        var elsewhere = original
        elsewhere.url = URL(string: "https://team.example.com/cdn-cgi/access/login")
        let away = registry.redirected(elsewhere, from: original)
        #expect(away.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(away.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
        #expect(away.value(forHTTPHeaderField: "Cookie") == nil)

        var home = original
        home.url = URL(string: "https://hermes.example.com/v1/models/")
        let back = registry.redirected(home, from: original)
        #expect(back.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client.access")
        #expect(back.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=signed-in")
    }

    @Test func settingsBeingTriedStandInForTheSavedOnesWhileTheCheckRuns() async {
        let registry = GatewayAccessRegistry()
        let url = URL(string: "https://hermes.example.com/health")!
        registry.set(Self.token, for: UUID(), at: [url])
        let other = GatewayAccessRegistry.Credentials.serviceToken(
            GatewayAccess(method: .serviceToken, clientID: "new.access"), secret: "new-secret"
        )

        let seen = await registry.trying(other, at: [url]) {
            // A check's deadline runs it in a child task: the trial reaches it.
            await withTaskGroup(of: GatewayAccessRegistry.Credentials?.self) { group in
                group.addTask { registry.credentials(for: url) }
                return await group.next() ?? nil
            }
        }
        #expect(seen == other)
        let none = await registry.trying(nil, at: [url]) { registry.credentials(for: url) }
        #expect(none == nil)
        #expect(registry.credentials(for: url) == Self.token)
    }

    /// The live connection to the same gateway keeps its saved token while an editor checks
    /// other settings, and another registry never sees the trial.
    @Test func aTrialReachesOnlyTheCheckThatRunsIt() async {
        let registry = GatewayAccessRegistry()
        let url = URL(string: "https://hermes.example.com/v1/models")!
        registry.set(Self.token, for: UUID(), at: [url])
        let other = GatewayAccessRegistry()
        other.set(Self.token, for: UUID(), at: [url])

        let (live, elsewhere) = await registry.trying(nil, at: [url]) {
            (await Task.detached { registry.credentials(for: url) }.value, other.credentials(for: url))
        }
        #expect(live == Self.token)
        #expect(elsewhere == Self.token)
    }

    /// A redirect within the gateway's origin keeps the headers the request went out with, so
    /// settings being tried survive it: URLSession asks its delegate outside the trying task.
    @Test func aRedirectHomeKeepsTheTokenBeingTried() async {
        let registry = GatewayAccessRegistry()
        let url = URL(string: "https://hermes.example.com/v1/models")!
        let tried = GatewayAccessRegistry.Credentials.serviceToken(
            GatewayAccess(method: .serviceToken, clientID: "new.access"), secret: "new-secret"
        )
        let original = await registry.trying(tried, at: [url]) { registry.prepared(URLRequest(url: url)) }
        var home = original
        home.url = URL(string: "https://hermes.example.com/v1/models/")
        let back = await Task.detached { registry.redirected(home, from: original) }.value
        #expect(back.value(forHTTPHeaderField: "CF-Access-Client-Id") == "new.access")
        #expect(back.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "new-secret")

        var away = original
        away.url = URL(string: "https://team.example.com/cdn-cgi/access/login")
        let gone = await registry.trying(tried, at: [url]) { registry.redirected(away, from: original) }
        #expect(gone.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(gone.value(forHTTPHeaderField: "CF-Access-Client-Secret") == nil)
    }

    /// A preview page that redirects or links off the gateway would take the token along in a web
    /// view, which `SameOriginRedirects` doesn't cover: the preview loads it again without.
    @Test func aWebNavigationOffTheGatewayLeaksAccessUntilItIsTakenOff() {
        let registry = GatewayAccessRegistry()
        registry.set(Self.token, for: UUID(), at: [URL(string: "https://hermes.example.com")!])
        let page = registry.prepared(URLRequest(url: URL(string: "https://hermes.example.com/artifact/index.html")!))
        #expect(!registry.leaksAccess(page))

        var away = page
        away.url = URL(string: "https://team.example.com/cdn-cgi/access/login")
        away.setValue("Bearer hermes-key", forHTTPHeaderField: "Authorization")
        #expect(registry.leaksAccess(away))
        let stripped = registry.withoutAccess(away)
        #expect(!registry.leaksAccess(stripped))
        #expect(!registry.carriesAccess(stripped))
        #expect(stripped.value(forHTTPHeaderField: "Authorization") == "Bearer hermes-key")
        #expect(!registry.leaksAccess(URLRequest(url: URL(string: "https://cdn.example.com/app.js")!)))
    }

    // MARK: Settings

    @Test func aTokenThatCouldReplaceTheAppsOwnHeadersIsRefused() {
        #expect(GatewayAccess.problem(clientID: "a", secret: "b", idHeader: "CF-Access-Client-Id", secretHeader: "CF-Access-Client-Secret") == nil)
        #expect(GatewayAccess.problem(clientID: " ", secret: "b", idHeader: "X-Id", secretHeader: "X-Secret") != nil)
        #expect(GatewayAccess.problem(clientID: "a", secret: "", idHeader: "X-Id", secretHeader: "X-Secret") != nil)
        #expect(GatewayAccess.problem(clientID: "a", secret: "b\r\nX-Evil: 1", idHeader: "X-Id", secretHeader: "X-Secret") != nil)
        #expect(GatewayAccess.problem(clientID: "a", secret: "b", idHeader: "X-Same", secretHeader: "x-same") != nil)
        for name in ["Authorization", "cookie", "Host", "Sec-WebSocket-Protocol", "Proxy-Authorization", "X Id", "", "X-Id:"] {
            #expect(!GatewayAccess.isAllowedHeaderName(name), "\(name)")
        }
        let rewritten = GatewayAccess(method: .serviceToken, clientID: "a", idHeader: "Authorization")
        #expect(GatewayAccessRegistry.Credentials.serviceToken(rewritten, secret: "b") == nil)
    }

    @Test func savedSettingsDecodeWhateverWroteThem() throws {
        let decoder = JSONDecoder()
        let newer = try decoder.decode(GatewayAccess.self, from: Data(#"{"method":"mutualTLS","clientID":"x"}"#.utf8))
        #expect(newer.method == .none)
        let bare = try decoder.decode(GatewayAccess.self, from: Data(#"{"method":"serviceToken","clientID":"x"}"#.utf8))
        #expect(bare == GatewayAccess(method: .serviceToken, clientID: "x"))

        let bot = BotConfiguration(name: "Home", baseURL: URL(string: "https://hermes.example.com")!, accent: "gold", access: Self.access)
        #expect(try decoder.decode(BotConfiguration.self, from: JSONEncoder().encode(bot)).access == Self.access)
        var withoutAccess = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bot)) as! [String: Any]
        withoutAccess["access"] = nil
        let older = try decoder.decode(BotConfiguration.self, from: JSONSerialization.data(withJSONObject: withoutAccess))
        #expect(older.access == nil)
    }

    @Test func theDraftKeepsTheSavedSecretUnlessOneIsTyped() {
        var draft = GatewayAccessDraft(Self.access, hasSavedSecret: true)
        #expect(draft.summary == "Service token")
        #expect(draft.typedSecret == nil)
        #expect(draft.problem(savedSecret: nil) != nil)
        #expect(draft.problem(savedSecret: "saved") == nil)
        #expect(draft.credentials(savedSecret: "saved")?.headers["CF-Access-Client-Secret"] == "saved")

        draft.secret = "  typed  "
        #expect(draft.typedSecret == "typed")
        #expect(draft.credentials(savedSecret: "saved")?.headers["CF-Access-Client-Secret"] == "typed")

        draft.method = .none
        #expect(draft.access == nil)
        #expect(draft.typedSecret == nil)
        #expect(draft.credentials(savedSecret: "saved") == nil)
        #expect(draft.summary == "None")
        #expect(GatewayAccessDraft().summary == "None")
        let certificate = ClientCertificate(fingerprint: "ab", fileName: "a.p12", subject: "s", issuer: "i", notAfter: .distantFuture)
        #expect(GatewayAccessDraft(GatewayAccess(method: .none, clientCertificate: certificate)).summary == "Certificate")
        #expect(GatewayAccessDraft(GatewayAccess(method: .serviceToken, clientCertificate: certificate)).summary == "Service token, certificate")
    }

    @Test func setupShowsAccessOnlyWhereItMatters() throws {
        var facts = GatewaySetupFacts(gatewayName: "Studio", gatewayOnline: true, botMode: .notLinked)
        #expect(GatewaySetup.access(facts) == nil)

        facts.access = Self.access
        let ready = try #require(GatewaySetup.access(facts))
        #expect(ready.state == SetupStatus.State.ready)
        #expect(ready.detail == "Service token")

        facts.accessRefusal = .signInNeeded
        let refused = try #require(GatewaySetup.access(facts))
        #expect(refused.state == .notSetUp)
        #expect(refused.fix?.action == .editAccess)
        #expect(!refused.steps.isEmpty)

        facts.accessRefusal = .certificateNeeded
        let certificate = try #require(GatewaySetup.access(facts))
        #expect(certificate.state == .notSetUp)
        #expect(certificate.fix?.action == .editAccess)
        #expect(!certificate.steps.isEmpty)
    }

    // MARK: Keychain

    @Test(.realKeychain) func theSecretRoundTripsInTheKeychainAndLeavesWithTheGateway() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bots-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)")
        let store = BotStore(fileURL: directory.appending(path: "bots.json"), keychain: keychain)
        let bot = BotConfiguration(
            name: "Home", baseURL: URL(string: "https://hermes.example.com")!, accent: "gold", access: Self.access
        )
        defer {
            try? store.removeAPIKey(for: bot.id)
            try? FileManager.default.removeItem(at: directory)
        }
        try store.save([bot], edited: bot)
        try store.setAPIKey("hermes-key", for: bot.id)
        try store.setAccessSecret("secret-0123", for: bot.id)

        #expect(try store.accessSecret(for: bot) == "secret-0123")
        #expect(store.accessCredentials(for: bot) == Self.token)
        #expect(!(try Data(contentsOf: store.fileURL).contains(Data("secret-0123".utf8))))

        // Moved elsewhere by something other than the app, the gateway gets no secret.
        var forged = bot
        forged.baseURL = URL(string: "https://attacker.example")!
        #expect(throws: (any Error).self) { try store.accessSecret(for: forged) }
        #expect(store.accessCredentials(for: forged) == nil)

        try store.setAccessSecret("", for: bot.id)
        #expect(try store.accessSecret(for: bot) == nil)
        try store.setAccessSecret("secret-0123", for: bot.id)
        try store.removeAPIKey(for: bot.id)
        try store.save([bot], edited: bot)
        #expect(try store.accessSecret(for: bot) == nil)
    }
}

/// Every transport passes its requests through `GatewayAccessRegistry.shared`: the token reaches
/// the gateway on calls, streams, sockets, uploads, downloads and pictures, never another server.
/// These send real requests to loopback servers and read the headers that arrived.
@Suite("Gateway access on the wire", .timeLimit(.minutes(1)))
struct GatewayAccessWireTests {
    /// A server registered as a gateway behind an access gateway, and one that isn't.
    private static func servers(answer: LoopbackServer.Answer = .close) async throws -> (gateway: LoopbackServer, other: LoopbackServer, id: UUID) {
        let gateway = try await LoopbackServer.start { _, _ in answer }
        let other = try await LoopbackServer.start { _, _ in answer }
        let id = UUID()
        GatewayAccessRegistry.shared.set(GatewayAccessTests.token, for: id, at: [gateway.baseURL])
        return (gateway, other, id)
    }

    private static func expectToken(in heads: [String], count: Int, _ comment: Comment? = nil) {
        #expect(heads.count >= count, comment)
        for head in heads {
            let lines = head.lowercased().components(separatedBy: "\r\n")
            #expect(lines.contains("cf-access-client-id: client.access"), "\(head)")
            #expect(lines.contains("cf-access-client-secret: secret-0123"), "\(head)")
        }
    }

    private static func expectNoToken(in heads: [String]) {
        for head in heads {
            #expect(!head.lowercased().contains("cf-access-client"), "\(head)")
        }
    }

    @Test func callsAndStreamsCarryTheToken() async throws {
        let (gateway, other, id) = try await Self.servers()
        defer { gateway.stop(); other.stop(); GatewayAccessRegistry.shared.forget(id) }

        for server in [gateway, other] {
            let client = HermesClient(baseURL: server.baseURL, apiKey: "hermes-key")
            _ = try? await client.health()
            // The server closes without answering, so the stream ends in an error; only the
            // request that reached it matters here.
            do { for try await _ in client.runEvents(runID: "run-1") {} } catch {}
        }
        Self.expectToken(in: gateway.heads, count: 2)
        // The health check is unauthenticated; the run's stream keeps Hermes's key beside the token.
        let stream = try #require(gateway.heads.first { $0.contains("/v1/runs/run-1/events") })
        #expect(stream.contains("Authorization: Bearer hermes-key"))
        Self.expectNoToken(in: other.heads)
    }

    @Test func backendCallsUploadsAndDownloadsCarryTheToken() async throws {
        let (gateway, other, id) = try await Self.servers()
        defer { gateway.stop(); other.stop(); GatewayAccessRegistry.shared.forget(id) }

        for server in [gateway, other] {
            let backend = BackendClient(baseURL: server.baseURL, credential: .sessionToken("session"))
            _ = try? await backend.writeText("notes.md", content: "hello")
            _ = try? await backend.downloadFile("notes.md")
            _ = try? await URLSession.shared.data(for: backend.fileStreamRequest(path: "voice.m4a"))
            _ = try? await RemotePicture.data(at: server.baseURL.appending(path: "picture.png"))
        }
        Self.expectToken(in: gateway.heads, count: 4)
        #expect(gateway.heads.contains { $0.hasPrefix("POST ") })
        Self.expectNoToken(in: other.heads)
    }

    @Test func socketsCarryTheToken() async throws {
        let (gateway, other, id) = try await Self.servers()
        defer { gateway.stop(); other.stop(); GatewayAccessRegistry.shared.forget(id) }

        for server in [gateway, other] {
            let backend = BackendClient(baseURL: server.baseURL, credential: .sessionToken("session"))
            let board = try await backend.boardEvents("default", since: 0)
            do { for try await _ in board {} } catch {}
            let display = await backend.displaySocket(ticket: "ticket")
            display.resume()
            _ = try? await display.receive()

            var socketURL = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false)!
            socketURL.scheme = "ws"
            socketURL.path = "/api/ws"
            let socket = GatewaySocket(url: socketURL.url!)
            _ = try? await socket.connect()
            await socket.close()

            let ticket = try #require(BrowserControlTicket(json: .object(["ticket": .string("t")])))
            let browser = HermesClient(baseURL: server.baseURL, apiKey: "hermes-key").browserControlSocket(ticket)
            browser?.resume()
            _ = try? await browser?.receive()
        }
        Self.expectToken(in: gateway.heads, count: 4)
        #expect(gateway.heads.allSatisfy { $0.lowercased().contains("upgrade: websocket") })
        Self.expectNoToken(in: other.heads)
    }

    /// A socket's refused upgrade: an HTML page is the access gateway's, named by whether the
    /// upgrade carried a token (one being tried included); a bare `text/plain` 403 stays Hermes's.
    @Test func aSocketsRefusalNamesTheTokenItCarried() async throws {
        let page = Data("<html><title>Forbidden | Access</title></html>".utf8)
        let refusing = try await LoopbackServer.start { _, _ in .page(403, "text/html", page) }
        let plain = try await LoopbackServer.start { _, _ in .page(403, "text/plain; charset=utf-8", Data()) }
        defer { refusing.stop(); plain.stop() }
        func socket(_ server: LoopbackServer) -> GatewaySocket {
            var url = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false)!
            url.scheme = "ws"
            url.path = "/api/ws"
            return GatewaySocket(url: url.url!)
        }

        await #expect(throws: HermesError.accessRefused(host: "127.0.0.1", .signInNeeded)) {
            try await socket(refusing).connect()
        }
        await #expect(throws: HermesError.accessRefused(host: "127.0.0.1", .tokenRejected)) {
            try await GatewayAccessRegistry.shared.trying(GatewayAccessTests.token, at: [refusing.baseURL]) {
                try await socket(refusing).connect()
            }
        }
        do {
            try await socket(plain).connect()
            Issue.record("A refused upgrade connected")
        } catch let HermesError.accessRefused(host, refusal) {
            Issue.record("Hermes's own 403 was read as \(refusal) from \(host)")
        } catch {}
    }

    /// The access gateway's sign-in page comes back as its refusal, never as Hermes's key check.
    @Test func anAccessGatewaysPageIsReadAsItsRefusal() async throws {
        let page = Data("<html><title>Forbidden | Access</title></html>".utf8)
        let server = try await LoopbackServer.start { _, _ in .page(403, "text/html", page) }
        defer { server.stop() }

        let client = HermesClient(baseURL: server.baseURL, apiKey: "hermes-key")
        await #expect(throws: HermesError.accessRefused(host: "127.0.0.1", .signInNeeded)) {
            _ = try await client.healthDetail()
        }
        let id = UUID()
        GatewayAccessRegistry.shared.set(GatewayAccessTests.token, for: id, at: [server.baseURL])
        defer { GatewayAccessRegistry.shared.forget(id) }
        await #expect(throws: HermesError.accessRefused(host: "127.0.0.1", .tokenRejected)) {
            _ = try await client.healthDetail()
        }
    }
}
