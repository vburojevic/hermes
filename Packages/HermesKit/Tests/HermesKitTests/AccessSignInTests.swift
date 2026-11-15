import Foundation
import Testing
@testable import HermesKit

/// Browser sign-in to an access gateway (`docs/connecting-and-voice.md` §11.10): the session is the
/// cookies the sign-in page set for the gateway's address and nothing else, it runs out when they
/// or its token do, it goes only to the gateway's origin, a refusal of it asks for a sign-in again,
/// and the sign-in page stays on the gateway and its sign-in addresses.
@Suite("Access sign-in")
struct AccessSignInTests {
    static let gateway = URL(string: "https://hermes.example.com")!
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func cookie(
        _ name: String, _ value: String, domain: String = "hermes.example.com", path: String = "/",
        expires: Date? = nil, secure: Bool = false
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    /// A token shaped like the access gateway's (`header.claims.signature`), unsigned.
    static func token(_ claims: [String: Any]) -> String {
        func part(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = part(Data(#"{"alg":"RS256"}"#.utf8))
        let body = part(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(body).signature"
    }

    // MARK: The session

    @Test func onlyTheGatewaysCookiesAreTheSession() throws {
        let session = try #require(AccessSession.from([
            Self.cookie("CF_Authorization", "signed-in"),
            Self.cookie("shared", "parent", domain: ".example.com"),
            Self.cookie("idp_session", "theirs", domain: "team.example.com"),
            Self.cookie("elsewhere", "theirs", domain: ".example.org"),
            Self.cookie("lookalike", "theirs", domain: "ermes.example.com"),
            Self.cookie("deeper", "theirs", path: "/admin"),
        ], for: Self.gateway, now: Self.now))
        #expect(session.cookies == ["CF_Authorization": "signed-in", "shared": "parent"])
        #expect(session.signedInAt == Self.now)
        #expect(session.credentials == GatewayAccessRegistry.Credentials(method: .browserSignIn, cookies: session.cookies))
    }

    @Test func aGatewayOnAPathTakesCookiesForThatPath() throws {
        let gateway = URL(string: "https://hermes.example.com/hermes")!
        let session = try #require(AccessSession.from([
            Self.cookie("root", "a"),
            Self.cookie("mine", "b", path: "/hermes"),
            Self.cookie("prefix", "c", path: "/herm"),
            Self.cookie("other", "d", path: "/other"),
        ], for: gateway, now: Self.now))
        #expect(session.cookies == ["root": "a", "mine": "b"])
    }

    @Test func anAddressGetsNoParentDomainsCookies() {
        let gateway = URL(string: "https://10.0.0.5:8443")!
        #expect(AccessSession.from([Self.cookie("parent", "a", domain: ".0.0.5")], for: gateway, now: Self.now) == nil)
        #expect(AccessSession.from([Self.cookie("own", "a", domain: "10.0.0.5")], for: gateway, now: Self.now)?.cookies == ["own": "a"])
    }

    @Test func aSecureCookieStaysOffPlainHTTP() {
        let cookies = [Self.cookie("CF_Authorization", "signed-in", domain: "hermes.local", secure: true)]
        #expect(AccessSession.from(cookies, for: URL(string: "http://hermes.local:8642")!, now: Self.now) == nil)
        #expect(AccessSession.from(cookies, for: URL(string: "https://hermes.local")!, now: Self.now) != nil)
    }

    @Test func cookiesThatRanOutOrCantBeSentAreLeft() {
        let cookies = [
            Self.cookie("old", "a", expires: Self.now.addingTimeInterval(-1)),
            Self.cookie("spaced", "a b"),
            Self.cookie("semi", "a;b"),
        ]
        #expect(AccessSession.from(cookies, for: Self.gateway, now: Self.now) == nil)
        #expect(!AccessSession.isSendable(name: "a=b"))
        #expect(!AccessSession.isSendable(name: ""))
        #expect(AccessSession.isSendable(value: ""))
    }

    /// The token's own `exp` counts when it's sooner than the cookie's, and the cookie's when
    /// it is; the email is only shown.
    @Test func itRunsOutWithTheEarliestOfTheCookieAndItsToken() throws {
        let exp = Self.now.addingTimeInterval(15 * 60)
        let value = Self.token(["exp": exp.timeIntervalSince1970, "email": "person@example.com"])
        let tokenFirst = try #require(AccessSession.from(
            [Self.cookie("CF_Authorization", value, expires: Self.now.addingTimeInterval(24 * 3600))], for: Self.gateway, now: Self.now
        ))
        #expect(tokenFirst.expires == exp)
        #expect(tokenFirst.email == "person@example.com")

        let cookieFirst = try #require(AccessSession.from(
            [Self.cookie("CF_Authorization", value, expires: Self.now.addingTimeInterval(60))], for: Self.gateway, now: Self.now
        ))
        #expect(cookieFirst.expires == Self.now.addingTimeInterval(60))

        let plain = try #require(AccessSession.from([Self.cookie("session", "opaque")], for: Self.gateway, now: Self.now))
        #expect(plain.expires == nil)
        #expect(plain.email == nil)
        #expect(!plain.isExpired(at: .distantFuture))

        #expect(!tokenFirst.isExpired(at: exp.addingTimeInterval(-1)))
        #expect(tokenFirst.isExpired(at: exp))
        #expect(AccessSession.tokenClaims("not.a.token") == nil)
    }

    // MARK: On the wire

    static func session(_ value: String = "signed-in") -> AccessSession {
        AccessSession(cookies: ["CF_Authorization": value], expires: nil, email: nil, signedInAt: now)
    }

    @Test func theSessionGoesOnlyToTheGatewaysOrigin() {
        let registry = GatewayAccessRegistry()
        registry.set(Self.session().credentials, for: UUID(), at: [Self.gateway])

        let home = registry.prepared(URLRequest(url: URL(string: "https://hermes.example.com/v1/runs")!))
        #expect(home.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=signed-in")
        for address in ["http://hermes.example.com/v1/runs", "https://hermes.example.com:8443/", "https://team.example.com/", "https://example.com/"] {
            #expect(registry.prepared(URLRequest(url: URL(string: address)!)).value(forHTTPHeaderField: "Cookie") == nil, "\(address)")
        }

        // A redirect to the sign-in page loses the cookie; one back home keeps it.
        var away = home
        away.url = URL(string: "https://team.example.com/cdn-cgi/access/login")
        #expect(registry.redirected(away, from: home).value(forHTTPHeaderField: "Cookie") == nil)
        var back = home
        back.url = URL(string: "https://hermes.example.com/v1/runs/")
        #expect(registry.redirected(back, from: home).value(forHTTPHeaderField: "Cookie") == "CF_Authorization=signed-in")
    }

    @Test func aRequestCarryingTheSessionIsKnownByItsCookie() async {
        let registry = GatewayAccessRegistry()
        registry.set(Self.session().credentials, for: UUID(), at: [Self.gateway])
        func request(_ cookie: String?) -> URLRequest {
            var request = URLRequest(url: Self.gateway)
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            return request
        }
        #expect(registry.carriesSession(request("hermes_session=a; CF_Authorization=b")))
        #expect(!registry.carriesSession(request("hermes_session=a")))
        #expect(!registry.carriesSession(request(nil)))

        let tried = AccessSession(cookies: ["tried": "x"], expires: nil, email: nil, signedInAt: Self.now)
        let seen = await registry.trying(tried.credentials, at: [Self.gateway]) { registry.carriesSession(request("tried=x")) }
        #expect(seen)
    }

    /// The re-sign-in path: a session the access gateway turns away reads as expired, never as a
    /// wrong token or Hermes's key, and a request that carried nothing still asks for a first one.
    @Test func aRefusedSessionAsksForASignInAgain() throws {
        let redirect = HTTPURLResponse(
            url: URL(string: "https://hermes.example.com/v1/runs")!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://team.example.com/cdn-cgi/access/login"]
        )!
        #expect(AccessRefusal.classify(redirect, body: Data(), sent: .session) == .signInExpired)

        let registry = GatewayAccessRegistry()
        #expect(AccessRefusal.classify(redirect, body: Data(), to: redirect.url, registry: registry) == .signInNeeded)
        registry.set(Self.session().credentials, for: UUID(), at: [Self.gateway])
        #expect(AccessRefusal.classify(redirect, body: Data(), to: redirect.url, registry: registry) == .signInExpired)

        let refusal = AccessRefusal.signInExpired
        #expect(refusal.isSignIn && !refusal.isCertificate)
        #expect(refusal.bannerTitle == "Your access sign-in expired")
        #expect(refusal.bannerDetail(gateway: "Home Server") == "The access gateway in front of Home Server wants you to sign in again.")
        #expect(refusal.detail(gateway: "Home Server") == "Sign in again to reach Home Server. Your chats are safe on the gateway.")
        #expect(AccessRefusal.signInNeeded.title(gateway: "Home Server") == "Sign in to reach Home Server")

        let error = HermesError.accessRefused(host: "hermes.example.com", .signInExpired)
        #expect(!error.keepsChecking)
        #expect(RunFollow.waitsForSignIn(after: error))
    }

    /// Reconnect loops (the gateway's and Bot Mode's) stop on an access gateway's sign-in or token
    /// refusal and wait for the person; a certificate refusal or a network failure keeps trying.
    @Test func reconnectingWaitsForASignInButNotForACertificateOrTheNetwork() {
        for refusal in [AccessRefusal.signInNeeded, .signInExpired, .tokenRejected] {
            #expect(HermesError.accessRefused(host: "hermes.example.com", refusal).waitsForAccess)
        }
        for refusal in [AccessRefusal.certificateNeeded, .certificateRejected, .certificateExpired(.now)] {
            #expect(!HermesError.accessRefused(host: "hermes.example.com", refusal).waitsForAccess)
        }
        #expect(!HermesError.unreachable(host: "hermes.example.com", reason: .timedOut).waitsForAccess)
        #expect(!HermesError.gatewayRestarting.waitsForAccess)
    }

    /// Signing in on the editor's sheet is tried on the check only: the live connection keeps
    /// the saved session until the person saves.
    @Test func aSessionBeingTriedNeverReplacesTheSavedOne() async {
        let registry = GatewayAccessRegistry()
        registry.set(Self.session("saved").credentials, for: UUID(), at: [Self.gateway])
        let url = Self.gateway.appending(path: "health")
        let tried = Self.session("new").credentials

        let (inside, live) = await registry.trying(tried, at: [Self.gateway]) {
            (registry.prepared(URLRequest(url: url)), await Task.detached { registry.prepared(URLRequest(url: url)) }.value)
        }
        #expect(inside.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=new")
        #expect(live.value(forHTTPHeaderField: "Cookie") == "CF_Authorization=saved")
        #expect(registry.prepared(URLRequest(url: url)).value(forHTTPHeaderField: "Cookie") == "CF_Authorization=saved")
    }

    // MARK: The editor's draft

    @Test func theDraftKeepsASessionOnlyForBrowserSignIn() {
        let session = Self.session()
        #expect(GatewayAccessDraft(GatewayAccess(method: .serviceToken, clientID: "id"), session: session).session == nil)

        var draft = GatewayAccessDraft(GatewayAccess(method: .browserSignIn), session: session)
        #expect(draft.session == session)
        #expect(draft.savedSession == session)
        #expect(draft.summary == "Browser sign-in")
        #expect(draft.credentials(savedSecret: nil) == session.credentials)

        draft.signOut(at: Self.now)
        #expect(draft.session == nil)
        #expect(draft.signedOutAt == Self.now)
        #expect(draft.credentials(savedSecret: nil) == nil)
        #expect(draft.access == GatewayAccess(method: .browserSignIn))

        var fresh = GatewayAccessDraft()
        fresh.signedOutAt = Self.now
        fresh.signedIn(session)
        #expect(fresh.method == .browserSignIn)
        #expect(fresh.signedOutAt == nil)
        fresh.method = .serviceToken
        #expect(fresh.savedSession == nil)
    }

    // MARK: Setup

    @Test func setupOffersASignInForAnExpiredOrMissingSession() throws {
        var facts = GatewaySetupFacts(gatewayName: "Studio", gatewayOnline: true, botMode: .notLinked)
        facts.access = GatewayAccess(method: .browserSignIn)
        facts.accessRefusal = .signInExpired
        let expired = try #require(GatewaySetup.access(facts))
        #expect(expired.state == .notSetUp)
        #expect(expired.fix?.title == "Sign In…")
        #expect(expired.fix?.action == .editAccess)
        #expect(expired.steps.count == 1)

        facts.accessRefusal = .signInNeeded
        #expect(try #require(GatewaySetup.access(facts)).fix?.title == "Sign In…")

        facts.access = nil
        let unset = try #require(GatewaySetup.access(facts))
        #expect(unset.fix?.title == "Edit Access…")
        #expect(unset.steps.count == 2)
    }

    // MARK: The sign-in page

    @Test func theSignInPageStaysOnTheGatewayAndItsSignInAddresses() {
        var policy = AccessSignInPolicy(gateway: Self.gateway)
        #expect(policy.start == URL(string: "https://hermes.example.com/health"))
        let signIn = URL(string: "https://team.example.com/cdn-cgi/access/login")!
        let help = URL(string: "https://help.example.org/")!

        // A link to the sign-in page before the access gateway sent the page there leaves the app.
        #expect(policy.decide(signIn, navigation: .link, isMainFrame: true) == .openOutside(signIn))
        #expect(policy.decide(signIn, navigation: .other, isMainFrame: true) == .allow)
        #expect(policy.decide(signIn, navigation: .link, isMainFrame: true) == .allow)
        #expect(policy.decide(URL(string: "https://idp.example.net/authorize")!, navigation: .form, isMainFrame: true) == .allow)
        #expect(policy.decide(help, navigation: .link, isMainFrame: true) == .openOutside(help))
        #expect(policy.decide(help, navigation: .other, isMainFrame: false) == .allow)
        #expect(policy.decide(help, navigation: .link, isMainFrame: true, isNewWindow: true) == .openOutside(help))

        for address in ["hermesapp://chat", "file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi"] {
            #expect(policy.decide(URL(string: address)!, navigation: .other, isMainFrame: true) == .cancel, "\(address)")
        }
        #expect(policy.decide(URL(string: "about:blank")!, navigation: .other, isMainFrame: false) == .allow)
        #expect(policy.decide(URL(string: "about:blank")!, navigation: .other, isMainFrame: true, isNewWindow: true) == .cancel)

        // Plain http on the internet never carries a sign-in.
        let plain = URL(string: "http://team.example.com/login")!
        #expect(policy.decide(plain, navigation: .other, isMainFrame: true) == .cancel)
        #expect(policy.decide(plain, navigation: .link, isMainFrame: true) == .openOutside(plain))
    }

    @Test func onlyTheGatewayAnsweringEndsTheSignIn() {
        let policy = AccessSignInPolicy(gateway: Self.gateway)
        let health = URL(string: "https://hermes.example.com/health")!
        #expect(policy.isThrough(health, status: 200, isMainFrame: true))
        #expect(!policy.isThrough(health, status: 302, isMainFrame: true))
        #expect(!policy.isThrough(health, status: 403, isMainFrame: true))
        #expect(!policy.isThrough(health, status: 200, isMainFrame: false))
        #expect(!policy.isThrough(URL(string: "https://team.example.com/")!, status: 200, isMainFrame: true))
        #expect(!policy.isThrough(URL(string: "http://hermes.example.com/health")!, status: 200, isMainFrame: true))

        #expect(policy.isGatewayHandshake(host: "hermes.example.com", port: 443))
        #expect(!policy.isGatewayHandshake(host: "hermes.example.com", port: 8443))
        #expect(!policy.isGatewayHandshake(host: "team.example.com", port: 443))
    }

    // MARK: Keychain

    @Test(.realKeychain) func theSessionRoundTripsInTheKeychainAndLeavesWithTheGateway() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bots-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)")
        let store = BotStore(fileURL: directory.appending(path: "bots.json"), keychain: keychain)
        let bot = BotConfiguration(
            name: "Home", baseURL: Self.gateway, accent: "gold", access: GatewayAccess(method: .browserSignIn)
        )
        defer {
            try? store.removeAPIKey(for: bot.id)
            try? FileManager.default.removeItem(at: directory)
        }
        let session = AccessSession(
            cookies: ["CF_Authorization": "signed-in"], expires: Self.now, email: "person@example.com", signedInAt: Self.now
        )
        try store.save([bot], edited: bot)
        try store.setAPIKey("hermes-key", for: bot.id)
        try store.setAccessSession(session, for: bot.id)

        #expect(try store.accessSession(for: bot) == session)
        // An expired session is still sent: the access gateway's refusal asks for a sign-in again.
        #expect(store.accessCredentials(for: bot) == session.credentials)
        #expect(!(try Data(contentsOf: store.fileURL).contains(Data("signed-in".utf8))))

        var forged = bot
        forged.baseURL = URL(string: "https://attacker.example")!
        #expect(throws: (any Error).self) { try store.accessSession(for: forged) }
        #expect(store.accessCredentials(for: forged) == nil)

        try store.setAccessSession(nil, for: bot.id)
        #expect(try store.accessSession(for: bot) == nil)
        try store.setAccessSession(session, for: bot.id)
        try store.removeAPIKey(for: bot.id)
        try store.save([bot], edited: bot)
        #expect(try store.accessSession(for: bot) == nil)
    }
}
