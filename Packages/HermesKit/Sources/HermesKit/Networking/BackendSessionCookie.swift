import Foundation

/// A sign-in cookie a gated backend reads back, recognized by its name
/// (`docs/connecting-and-voice.md` §1).
///
/// Hermes names each one from a bare name, a prefix the request's shape calls for (none over
/// HTTP, `__Host-` over HTTPS, `__Secure-` behind a path prefix) and, on a gateway Webapp, a
/// `_<gateway>` suffix: 16 lowercase hex characters (`hermes_cli/dashboard_auth/cookies.py`
/// `_resolved_name` and `gateway_cookie_name`, `hermes_cli/webapp_sign_in.py` `_gateway`).
/// Names are matched exactly against those rules, so a look-alike is never taken for one.
public struct BackendSessionCookie: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The access token the gate checks on every request.
        case access = "hermes_session_at"
        /// The refresh token the gate renews the access token with.
        case refresh = "hermes_session_rt"
        /// Which sign-in provider issued the session.
        case provider = "hermes_session_provider"
        /// A gateway Webapp's sign-in binding: without it the Webapp answers every signed-in
        /// request as signed out.
        case webappSignIn = "hermes_webapp_signin"
    }

    public static let prefixes = ["__Host-", "__Secure-"]
    static let gatewayLength = 16

    public let kind: Kind
    /// `__Host-`, `__Secure-` or empty.
    public let prefix: String
    /// The gateway a Webapp cookie belongs to, nil for a backend's own.
    public let gateway: String?

    /// Nil for any name that isn't one of the cookies the backend reads back.
    public init?(name: String) {
        var rest = Substring(name)
        let prefix = Self.prefixes.first { rest.hasPrefix($0) } ?? ""
        rest = rest.dropFirst(prefix.count)
        for kind in Kind.allCases where rest.hasPrefix(kind.rawValue) {
            let tail = rest.dropFirst(kind.rawValue.count)
            if tail.isEmpty {
                self.init(kind: kind, prefix: prefix, gateway: nil)
                return
            }
            if tail.first == "_", Self.isGateway(tail.dropFirst()) {
                self.init(kind: kind, prefix: prefix, gateway: String(tail.dropFirst()))
                return
            }
        }
        return nil
    }

    private init(kind: Kind, prefix: String, gateway: String?) {
        self.kind = kind
        self.prefix = prefix
        self.gateway = gateway
    }

    private static func isGateway(_ text: Substring) -> Bool {
        text.utf8.count == gatewayLength && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public static func isAccess(_ name: String) -> Bool {
        BackendSessionCookie(name: name)?.kind == .access
    }

    public static func isKept(_ name: String) -> Bool {
        BackendSessionCookie(name: name) != nil
    }

    /// The saved cookies after a response set `fresh`, or nil when it set none of them.
    ///
    /// A sign-in that started a session replaces the saved set, so cookies from an earlier
    /// sign-in (another prefix, names from before a gateway Webapp) never ride along. Any other
    /// response, a refresh or a failed sign-in, updates the saved set in place. A cookie set
    /// empty or already expired is removed.
    static func updated(_ saved: [String: String], with fresh: [HTTPCookie], signingIn: Bool, now: Date = .now) -> [String: String]? {
        let fresh = fresh.filter { isKept($0.name) }
        guard !fresh.isEmpty else { return nil }
        var cookies = signingIn && startsSession(fresh, now: now) ? [:] : saved.filter { isKept($0.key) }
        for cookie in fresh {
            cookies[cookie.name] = isLive(cookie, now: now) ? cookie.value : nil
        }
        return cookies
    }

    /// Whether a response started a session: it set a live access cookie.
    static func startsSession(_ fresh: [HTTPCookie], now: Date = .now) -> Bool {
        fresh.contains { isAccess($0.name) && isLive($0, now: now) }
    }

    private static func isLive(_ cookie: HTTPCookie, now: Date) -> Bool {
        !cookie.value.isEmpty && !(cookie.expiresDate.map { $0 < now } ?? false)
    }
}
