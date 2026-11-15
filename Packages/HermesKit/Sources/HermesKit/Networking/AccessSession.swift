import Foundation

/// What an access gateway's sign-in page gave the app (`docs/connecting-and-voice.md` §11.10): the
/// cookies it set for the gateway's address, when they run out, and who signed in. Saved in the
/// Keychain, device-only (`BotStore.accessSession`), and sent through `GatewayAccessRegistry` like
/// a service token. The app never sees the password; the page took it.
public struct AccessSession: Codable, Sendable, Equatable {
    /// The cookies, by name, that go with every request to the gateway.
    public var cookies: [String: String]
    /// When the access gateway stops taking them: the earliest of the cookies' own expiry and the
    /// token's `exp`. Nil when neither says; the access gateway's refusal says it then.
    public var expires: Date?
    /// The account that signed in, read from the token for the Access screen. Not verified: the
    /// access gateway checks the token, the app only shows the name.
    public var email: String?
    public var signedInAt: Date

    public init(cookies: [String: String], expires: Date?, email: String?, signedInAt: Date) {
        self.cookies = cookies
        self.expires = expires
        self.email = email
        self.signedInAt = signedInAt
    }

    public func isExpired(at now: Date = .now) -> Bool {
        expires.map { $0 <= now } ?? false
    }

    /// What the gateway's requests carry with it.
    public var credentials: GatewayAccessRegistry.Credentials {
        GatewayAccessRegistry.Credentials(method: .browserSignIn, cookies: cookies)
    }

    /// The session in a sign-in page's cookie jar for `gateway`, or nil when the page set none
    /// there. Only cookies the browser would send to the gateway's address count: its host, or a
    /// parent domain the cookie was set for, and never a Secure cookie over plain http. Cookies
    /// for the identity provider's own pages stay behind.
    public static func from(_ cookies: [HTTPCookie], for gateway: URL, now: Date = .now) -> AccessSession? {
        guard let host = gateway.host()?.lowercased(), !host.isEmpty else { return nil }
        let secure = gateway.scheme?.lowercased() == "https"
        let path = gateway.path.isEmpty ? "/" : gateway.path
        var kept: [String: String] = [:]
        var expires: Date?
        for cookie in cookies {
            guard applies(cookie, host: host, path: path, secure: secure),
                  isSendable(name: cookie.name), isSendable(value: cookie.value),
                  cookie.expiresDate.map({ $0 > now }) ?? true
            else { continue }
            kept[cookie.name] = cookie.value
            if let date = cookie.expiresDate { expires = min(expires ?? date, date) }
        }
        guard !kept.isEmpty else { return nil }
        var email: String?
        for name in kept.keys.sorted() {
            guard let claims = tokenClaims(kept[name] ?? "") else { continue }
            if let exp = claims["exp"]?.doubleValue {
                let date = Date(timeIntervalSince1970: exp)
                expires = min(expires ?? date, date)
            }
            email = email ?? claims["email"]?.stringValue
        }
        return AccessSession(cookies: kept, expires: expires, email: email, signedInAt: now)
    }

    /// Whether a browser sends `cookie` to `host` and `path`: RFC 6265 §5.4's domain and path
    /// match, and Secure only over https.
    static func applies(_ cookie: HTTPCookie, host: String, path: String, secure: Bool) -> Bool {
        if cookie.isSecure && !secure { return false }
        var domain = cookie.domain.lowercased()
        let hostOnly = !domain.hasPrefix(".")
        if !hostOnly { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        let domainMatches = host == domain || (!hostOnly && host.hasSuffix("." + domain) && !isAddress(host))
        guard domainMatches else { return false }
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            || cookiePath == "/"
    }

    private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { UInt8($0) != nil }
    }

    /// A cookie name and value fit to go into a Cookie header the app writes itself.
    static func isSendable(name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !"=;,".unicodeScalars.contains($0) }
    }

    static func isSendable(value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && $0 != ";" && $0 != "," }
    }

    /// A JSON Web Token's claims, unverified, or nil when the value isn't one.
    static func tokenClaims(_ value: String) -> JSONValue? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = JSONValue.parse(data), claims["exp"] != nil || claims["email"] != nil
        else { return nil }
        return claims
    }
}
