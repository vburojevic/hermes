import Foundation
@testable import HermesKit
import Testing

/// Links from chats, results and checks only go to the web; credentials stay on their server.
@Suite("Link safety")
struct LinkSafetyTests {
    private func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

    @Test func chatLinksOpenOnlyTheWebAndMail() throws {
        #expect(WebLink.opensFromChat(try url("https://example.com/a")))
        #expect(WebLink.opensFromChat(try url("HTTP://example.com")))
        #expect(WebLink.opensFromChat(try url("mailto:someone@example.com")))
        for blocked in [
            "hermesapp://connect?v=1&gateway=http://evil:8642&key=x", "hermesapp://plugin/install?catalog=x",
            "file:///Users/u/x.command", "javascript:alert(1)", "shortcuts://run-shortcut?name=x",
            "tel:123", "data:text/html,hi", "http:///no-host",
        ] {
            #expect(!WebLink.opensFromChat(try url(blocked)), "\(blocked)")
        }
    }

    @Test func picturesFromAnywhereButTheGatewayWaitForATap() throws {
        let gateway = BotConfiguration(
            name: "a", baseURL: try url("http://mac-mini.local:8642"), accent: "gold",
            backend: BackendLink(url: try url("http://Mac-Mini.local:9119"), signIn: .automatic)
        )
        #expect(gateway.hosts == ["mac-mini.local"])
        #expect(WebLink.isOnGateway(try url("http://mac-mini.local:8642/x.png"), gatewayHosts: gateway.hosts))
        #expect(WebLink.isOnGateway(try url("http://MAC-MINI.local/media/x.png"), gatewayHosts: gateway.hosts))
        // Another machine on this network, a look-alike address, a public tailnet name, the internet.
        for other in [
            "http://192.168.1.1/goform/setSysAdm?x=1", "http://localhost:8888/api", "https://10.0.0.1.attacker.example/p.png",
            "https://node.tail0.ts.net/p.png?d=secret", "http://nas/x.png", "https://evil.example/p?d=secret",
        ] {
            #expect(!WebLink.isOnGateway(try url(other), gatewayHosts: gateway.hosts), "\(other)")
        }
        #expect(!WebLink.isOnGateway(try url("http://mac-mini.local:8642/x.png"), gatewayHosts: []))
        #expect(WebLink.loadsByItself(try url("https://cdn.example/avatar.png")))
        #expect(!WebLink.loadsByItself(try url("http://cdn.example/avatar.png")))
        #expect(!WebLink.loadsByItself(try url("http://10.0.0.1.attacker.example/avatar.png")))
    }

    @Test func redirectsStayOnTheSameServer() throws {
        let from = try url("http://mac.local:8642/api/sessions")
        #expect(SameOriginRedirects.allows(from: from, to: try url("http://mac.local:8642/api/sessions/")))
        #expect(SameOriginRedirects.allows(from: from, to: try url("https://mac.local/api/sessions")))
        #expect(!SameOriginRedirects.allows(from: from, to: try url("http://mac.local:9119/api")))
        #expect(!SameOriginRedirects.allows(from: from, to: try url("https://login.example.com/")))
        let secure = try url("https://mac.tail0.ts.net/api")
        #expect(SameOriginRedirects.allows(from: secure, to: try url("https://MAC.tail0.ts.net:443/next")))
        #expect(!SameOriginRedirects.allows(from: secure, to: try url("http://mac.tail0.ts.net/api")))
    }
}

@Suite("Gateway file links")
struct GatewayFileLinkTests {
    /// The path the owner's reply named, as inline code: it opens in the Inspector.
    @Test func aWholePathInCodeIsAFile() {
        let path = "/Users/sam/.hermes/cache/scratch/chat-widgets-design-prompt.md"
        #expect(GatewayFileLink.path(fromCode: path) == path)
        #expect(GatewayFileLink.path(fromCode: "~/notes/plan.txt") == "~/notes/plan.txt")
        #expect(GatewayFileLink.path(fromCode: "/Users/me/Application Support/Hermes/state.json") == "/Users/me/Application Support/Hermes/state.json")
        #expect(GatewayFileLink.path(fromCode: "/repo/App/Model/BotRoster.swift:362") == "/repo/App/Model/BotRoster.swift")
        #expect(GatewayFileLink.path(fromCode: "/repo/README.md#L10-L20") == "/repo/README.md")
    }

    /// Commands, routes, folders, relative and hidden names stay plain code.
    @Test func codeThatIsntAFileStaysCode() {
        for code in ["rm -rf /tmp/build.log", "/usr/bin/env", "/health", "/api/fs/read-text", "~/.zshrc", "~/projects/",
                     "src/app.swift", "/tmp/*.log", "/tmp/a.md; rm x", "//server/share/a.md", "/a.md\n/b.md", ".env", "x.md"] {
            #expect(GatewayFileLink.path(fromCode: code) == nil, "\(code)")
        }
    }

    @Test func linksToFiles() {
        #expect(GatewayFileLink.path(fromLink: "/Users/me/report.md") == "/Users/me/report.md")
        #expect(GatewayFileLink.path(fromLink: "/Users/me/My%20Report.pdf") == "/Users/me/My Report.pdf")
        #expect(GatewayFileLink.path(fromLink: "file:///Users/me/report.md") == "/Users/me/report.md")
        #expect(GatewayFileLink.path(fromLink: "~/notes.md") == "~/notes.md")
        #expect(GatewayFileLink.path(fromLink: "file://evil.example/share/a.md") == nil)
        #expect(GatewayFileLink.path(fromLink: "https://example.com/a.md") == nil)
        #expect(GatewayFileLink.path(fromLink: "hermesapp://pair?x=1") == nil)
    }

    /// The app's own link carries the path there and back; one a reply wrote itself opens nothing.
    @Test func theAppsLinkRoundTrips() throws {
        let path = "/Users/me/a b/notes#1.md"
        let url = try #require(GatewayFileLink.url(for: path))
        #expect(GatewayFileLink.path(from: url) == path)
        #expect(!WebLink.opensFromChat(url))
        #expect(GatewayFileLink.path(fromLink: url.absoluteString) == nil)
    }
}
