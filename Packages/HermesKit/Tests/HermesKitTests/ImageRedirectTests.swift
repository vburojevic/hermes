import Foundation
import Testing
@testable import HermesKit

/// A picture the app may load (on the gateway, or after a tap that names its host) stays on that
/// server: a redirect elsewhere would load a third party, or this device's network, with no tap
/// (`docs/architecture.md`, `docs/chat.md` §3). These load real pictures from loopback servers.
@Suite("Picture redirects", .timeLimit(.minutes(1)))
struct ImageRedirectTests {
    typealias Elsewhere = SocketRedirectTests.Elsewhere

    @Test(arguments: [302, 307], Elsewhere.allCases)
    func aPictureNeverFollowsARedirectToAnotherServer(status: Int, elsewhere: Elsewhere) async throws {
        let (first, other) = try await Self.redirectingServers(status: status, elsewhere: elsewhere)
        defer { first.stop(); other.stop() }

        await #expect(throws: RemotePicture.Failure.status(status)) {
            _ = try await RemotePicture.image(at: first.baseURL.appending(path: "picture.png"))
        }
        try await Self.expectNothingFollowed(first: first, other: other)
    }

    /// The servers above do catch a followed redirect: the system's shared session, which the
    /// app's pictures used to load on, reaches the other one.
    @Test func theSharedSessionWouldFollowIt() async throws {
        let (first, other) = try await Self.redirectingServers(status: 302, elsewhere: .otherPort)
        defer { first.stop(); other.stop() }

        _ = try? await RemotePicture.image(at: first.baseURL.appending(path: "picture.png"), in: .shared)
        #expect(other.requests.count == 1)
    }

    @Test(arguments: [302, 307])
    func aPictureFollowsARedirectOnTheSameServer(status: Int) async throws {
        let server = try await LoopbackServer.start { line, port in
            line.contains("/moved") ? .picture(Self.png) : .redirect(status, "http://127.0.0.1:\(port)/moved.png")
        }
        defer { server.stop() }

        let image = try await RemotePicture.image(at: server.baseURL.appending(path: "picture.png"))
        #expect(image.width == 1 && image.height == 1)
        #expect(server.requests.count == 2)
    }

    /// http to https on the same host is an upgrade, so it's followed: the https server is asked.
    /// (It's a loopback server without a certificate, so the handshake ends there.)
    @Test func aPictureFollowsAnUpgradeToHTTPSOnTheSameHost() async throws {
        let secure = try await LoopbackServer.start { _, _ in .close }
        let first = try await LoopbackServer.start { [securePort = secure.port] _, _ in
            .redirect(302, "https://127.0.0.1:\(securePort)/picture.png")
        }
        defer { first.stop(); secure.stop() }

        _ = try? await RemotePicture.image(at: first.baseURL.appending(path: "picture.png"))
        #expect(first.requests.count == 1)
        #expect(secure.requests.first == "TLS", "The https server was asked: \(secure.requests)")
    }

    @Test func aPictureLoadsWhereItIs() async throws {
        let server = try await LoopbackServer.start { _, _ in .picture(Self.png) }
        defer { server.stop() }

        let image = try await RemotePicture.image(at: server.baseURL.appending(path: "here.png"))
        #expect(image.width == 1)
    }

    @Test func onlyWebPicturesLoad() async throws {
        await #expect(throws: RemotePicture.Failure.notWeb) {
            _ = try await RemotePicture.image(at: URL(fileURLWithPath: "/tmp/picture.png"))
        }
        #expect(throws: RemotePicture.Failure.notAPicture) {
            _ = try RemotePicture.decode(Data("<html></html>".utf8))
        }
    }

    // MARK: Health checks

    /// The health check carries no key, but its session holds the rule by itself.
    @Test(arguments: [302, 307])
    func aHealthCheckNeverFollowsARedirectToAnotherServer(status: Int) async throws {
        let (first, other) = try await Self.redirectingServers(status: status, elsewhere: .otherPort)
        defer { first.stop(); other.stop() }

        let session = HermesClient.probeSession()
        defer { session.finishTasksAndInvalidate() }
        #expect(session.delegate is SameOriginRedirects)
        let (_, response) = try await session.data(from: first.baseURL.appending(path: "health"))
        #expect((response as? HTTPURLResponse)?.statusCode == status)
        try await Self.expectNothingFollowed(first: first, other: other)
    }

    /// The real health check hands its task a delegate of its own (`ConnectionWitness`), which
    /// leaves redirects to the session's: the redirect comes back as the answer, and isn't one.
    @Test(arguments: [302, 307])
    func theLivenessCheckNeverFollowsARedirectToAnotherServer(status: Int) async throws {
        let (first, other) = try await Self.redirectingServers(status: status, elsewhere: .otherPort)
        defer { first.stop(); other.stop() }

        let liveness = try await HermesClient(baseURL: first.baseURL, apiKey: "secret-key-0123456789").liveness()
        guard case .unreachable = liveness else { Issue.record("A redirect isn't an answer: \(liveness)"); return }
        try await Self.expectNothingFollowed(first: first, other: other)
    }

    /// And a redirect on the same server is still followed through that delegate.
    @Test func theLivenessCheckFollowsARedirectOnTheSameServer() async throws {
        let server = try await LoopbackServer.start { line, port in
            line.contains("/moved") ? .picture(Self.png) : .redirect(302, "http://127.0.0.1:\(port)/moved")
        }
        defer { server.stop() }

        let liveness = try await HermesClient(baseURL: server.baseURL, apiKey: "secret-key-0123456789").liveness()
        #expect(liveness == .answering)
        #expect(server.requests.count == 2)
    }

    // MARK: Helpers

    /// A 1 × 1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// The first server redirects every request elsewhere; the other one would answer with a picture.
    private static func redirectingServers(status: Int, elsewhere: Elsewhere) async throws -> (first: LoopbackServer, other: LoopbackServer) {
        let other = try await LoopbackServer.start { _, _ in .picture(png) }
        let first = try await LoopbackServer.start { [otherPort = other.port] _, port in
            switch elsewhere {
            case .otherPort: .redirect(status, "http://127.0.0.1:\(otherPort)/elsewhere.png")
            case .otherHostName: .redirect(status, "http://localhost:\(port)/elsewhere.png")
            }
        }
        return (first, other)
    }

    private static func expectNothingFollowed(first: LoopbackServer, other: LoopbackServer) async throws {
        try await Task.sleep(for: .milliseconds(300))
        #expect(other.requests.isEmpty, "The other server was asked: \(other.requests)")
        #expect(first.requests.count == 1, "The first server was asked: \(first.requests)")
    }
}
