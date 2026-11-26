import Foundation
import Testing
@testable import HermesKit

/// Bot Mode's sign-in cookies (`docs/connecting-and-voice.md` §1): the names Hermes gives them,
/// with a prefix by request shape and a gateway Webapp's `_<gateway>` suffix, matched exactly;
/// only the ones the backend reads back are kept; a new sign-in replaces the saved set and a
/// refresh updates it in place.
@Suite("Backend sign-in cookies")
struct BackendSignInCookieTests {
    static let gateway = "0123456789abcdef"

    private func cookies(_ headers: [String], url: String = "http://127.0.0.1:28519/auth/password-login") -> [HTTPCookie] {
        headers.flatMap { HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: URL(string: url)!) }
    }

    @Test(arguments: ["", "__Host-", "__Secure-"])
    func accessCookieIsRecognizedWithEveryPrefix(prefix: String) throws {
        let bare = try #require(BackendSessionCookie(name: prefix + "hermes_session_at"))
        #expect(bare.kind == .access && bare.prefix == prefix && bare.gateway == nil)
        let suffixed = try #require(BackendSessionCookie(name: prefix + "hermes_session_at_" + Self.gateway))
        #expect(suffixed.kind == .access && suffixed.prefix == prefix && suffixed.gateway == Self.gateway)
        #expect(BackendSessionCookie.isAccess(prefix + "hermes_session_at_" + Self.gateway))
    }

    @Test func everyKeptCookieTakesTheSameRules() {
        for kind in BackendSessionCookie.Kind.allCases {
            for prefix in ["", "__Host-", "__Secure-"] {
                #expect(BackendSessionCookie(name: prefix + kind.rawValue)?.kind == kind)
                #expect(BackendSessionCookie(name: "\(prefix)\(kind.rawValue)_\(Self.gateway)")?.kind == kind)
            }
        }
        #expect(!BackendSessionCookie.isAccess("hermes_session_rt_" + Self.gateway))
        #expect(!BackendSessionCookie.isAccess("hermes_webapp_signin_" + Self.gateway))
    }

    @Test(arguments: [
        "xhermes_session_at", "hermes_session_at_", "hermes_session_atx", "hermes_session_at_0123456789abcde",
        "hermes_session_at_0123456789abcdef0", "hermes_session_at_0123456789ABCDEF", "hermes_session_at_0123456789abcdeg",
        "hermes_session_at__0123456789abcdef", "__host-hermes_session_at", "__Host-__Secure-hermes_session_at",
        "_hermes_session_at", "hermes_session_", "hermes_session_pkce", "hermes_session_pkce_0123456789abcdef",
        "hermes_sso_attempt", "hermes_webapp_signin_", "HERMES_SESSION_AT", "hermes_session_at_0123456789abcdef_0123456789abcdef",
    ])
    func lookAlikesAreNotSignInCookies(name: String) {
        #expect(BackendSessionCookie(name: name) == nil)
        #expect(!BackendSessionCookie.isAccess(name))
    }

    @Test func aWebappSignInKeepsItsBindingAndDropsTheBrowserFlowCookies() throws {
        let fresh = cookies([
            "hermes_session_at_\(Self.gateway)=a1; Path=/; HttpOnly; Max-Age=3600",
            "hermes_session_rt_\(Self.gateway)=r1; Path=/; HttpOnly; Max-Age=2592000",
            "hermes_session_provider_\(Self.gateway)=basic; Path=/; Max-Age=2592000",
            "hermes_webapp_signin_\(Self.gateway)=b1; Path=/; HttpOnly; Max-Age=2592000",
            "hermes_session_pkce=p; Path=/; Max-Age=600",
            "other=x; Path=/",
        ])
        #expect(BackendSessionCookie.startsSession(fresh))
        let saved = try #require(BackendSessionCookie.updated([:], with: fresh, signingIn: true))
        #expect(saved == [
            "hermes_session_at_\(Self.gateway)": "a1",
            "hermes_session_rt_\(Self.gateway)": "r1",
            "hermes_session_provider_\(Self.gateway)": "basic",
            "hermes_webapp_signin_\(Self.gateway)": "b1",
        ])
    }

    @Test func aNewSignInReplacesTheSavedCookies() throws {
        let earlier = [
            "hermes_session_at": "old-a", "hermes_session_rt": "old-r", "__Host-hermes_session_at": "older-a",
            "hermes_session_at_\(Self.gateway)": "old-webapp-a",
        ]
        let fresh = cookies([
            "hermes_session_at_\(Self.gateway)=a2; Path=/; HttpOnly; Max-Age=3600",
            "hermes_webapp_signin_\(Self.gateway)=b2; Path=/; HttpOnly; Max-Age=2592000",
        ])
        let saved = try #require(BackendSessionCookie.updated(earlier, with: fresh, signingIn: true))
        #expect(saved == ["hermes_session_at_\(Self.gateway)": "a2", "hermes_webapp_signin_\(Self.gateway)": "b2"])
    }

    @Test func aRefreshUpdatesTheSavedCookiesInPlace() throws {
        let earlier = [
            "__Host-hermes_session_at": "a1", "__Host-hermes_session_rt": "r1", "hermes_session_pkce": "left-over",
        ]
        let fresh = cookies(["__Host-hermes_session_at=a2; Path=/; Secure; HttpOnly; Max-Age=3600"], url: "https://hermes.example.com/api/sessions")
        let saved = try #require(BackendSessionCookie.updated(earlier, with: fresh, signingIn: false))
        #expect(saved == ["__Host-hermes_session_at": "a2", "__Host-hermes_session_rt": "r1"])
    }

    @Test func aClearedOrExpiredCookieIsRemoved() throws {
        let earlier = ["hermes_session_at": "a1", "hermes_session_rt": "r1"]
        let fresh = cookies([
            "hermes_session_at=; Path=/; Max-Age=0",
            "hermes_session_rt=r1; Path=/; Expires=Wed, 01 Jan 2020 00:00:00 GMT",
        ])
        #expect(!BackendSessionCookie.startsSession(fresh))
        #expect(try #require(BackendSessionCookie.updated(earlier, with: fresh, signingIn: false)).isEmpty)
    }

    @Test func aSignInThatStartedNoSessionLeavesTheSavedCookiesAlone() {
        let earlier = ["hermes_session_at": "a1"]
        #expect(BackendSessionCookie.updated(earlier, with: cookies(["other=x; Path=/"]), signingIn: true) == nil)
        #expect(!BackendSessionCookie.startsSession(cookies(["hermes_session_pkce=p; Path=/"])))
        // Only a provider hint, no access cookie: nothing replaced, the hint updated in place.
        let hint = cookies(["hermes_session_provider=basic; Path=/"])
        #expect(BackendSessionCookie.updated(earlier, with: hint, signingIn: true)
            == ["hermes_session_at": "a1", "hermes_session_provider": "basic"])
    }
}
