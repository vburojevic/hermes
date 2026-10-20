import Foundation
import Testing
@testable import HermesKit

/// Serves canned responses and records requests, keyed by test-unique host.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data
        /// Fail the load with this instead of answering (a dropped connection).
        var error: URLError.Code?
    }

    nonisolated(unsafe) static var routes: [String: @Sendable (URLRequest) -> Response] = [:]
    nonisolated(unsafe) static var recorded: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.routes[request.url?.host() ?? ""]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = handler(request)
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        // Deliver in small chunks to exercise incremental parsing.
        var offset = 0
        while offset < response.body.count {
            let end = min(response.body.count, offset + 37)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func removeRoute(_ host: String) {
        lock.withLock { _ = routes.removeValue(forKey: host) }
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.filter { $0.url?.host() == host }
    }
}

@Suite("Hermes client", .serialized)
struct HermesClientTests {
    private func makeClient(host: String, path: String = "", handler: @escaping @Sendable (URLRequest) -> StubProtocol.Response) -> HermesClient {
        StubProtocol.lock.withLock { StubProtocol.routes[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HermesClient(
            baseURL: URL(string: "http://\(host):8642\(path)")!,
            apiKey: "secret-key-0123456789",
            session: URLSession(configuration: configuration)
        )
    }

    @Test func sendsBearerAndProfilePrefix() async throws {
        let host = "prefix.test"
        let client = makeClient(host: host, path: "/p/research") { _ in
            .init(status: 200, body: Data(#"{"object":"list","data":[],"limit":50,"offset":0,"has_more":false}"#.utf8))
        }
        _ = try await client.sessions()
        let request = try #require(StubProtocol.requests(for: host).last)
        #expect(request.url?.path() == "/p/research/api/sessions")
        #expect(request.url?.query()?.contains("limit=50") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key-0123456789")
    }

    @Test func healthIsUnauthenticated() async throws {
        let host = "health.test"
        let client = makeClient(host: host) { _ in .init(status: 200, body: Data(#"{"status":"ok","platform":"hermes-agent","version":"0.14.2"}"#.utf8)) }
        let health = try await client.health()
        #expect(health.version == "0.14.2")
        #expect(StubProtocol.requests(for: host).last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func pathComponentsAreEscaped() async throws {
        let host = "escape.test"
        let client = makeClient(host: host) { _ in .init(status: 200, body: Data(#"{"object":"hermes.session","session":{"id":"a/b"}}"#.utf8)) }
        _ = try await client.session(id: "a/b")
        let request = try #require(StubProtocol.requests(for: host).last)
        #expect(request.url?.absoluteString.hasSuffix("/api/sessions/a%2Fb") == true)
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Invalid gateway API key (API_SERVER_KEY)","type":"gateway_auth_error","code":"gateway_auth_failed"}}"#, HermesError.unauthorized),
        (429, #"{"error":{"message":"Too many concurrent runs (max 10)","type":"rate_limit_error","param":null,"code":"rate_limit_exceeded"}}"#, .rateLimited),
        (503, #"{"error":{"message":"draining","type":"server_error","param":null,"code":"gateway_draining"}}"#, .gatewayRestarting),
        (404, #"{"error": "Unknown or unconfigured profile"}"#, .notFound(message: "Unknown or unconfigured profile")),
        (409, #"{"error":{"message":"Session has an active turn","type":"invalid_request_error","param":null,"code":"session_active_turn"}}"#, .server(status: 409, code: "session_active_turn", message: "Session has an active turn")),
    ])
    func mapsErrorEnvelopes(status: Int, body: String, expected: HermesError) async {
        let host = "errors\(status).test"
        let client = makeClient(host: host) { _ in .init(status: status, body: Data(body.utf8)) }
        await #expect(throws: expected) {
            _ = try await client.capabilities()
        }
    }

    @Test func plainTextNotFoundMeansOldServer() async {
        let host = "old.test"
        let client = makeClient(host: host) { _ in .init(status: 404, headers: ["Content-Type": "text/plain"], body: Data("404: Not Found".utf8)) }
        await #expect(throws: HermesError.unsupportedServer) {
            _ = try await client.capabilities()
        }
    }

    @Test func startRunBody() async throws {
        let host = "runs.test"
        let client = makeClient(host: host) { _ in .init(status: 202, body: Data(#"{"run_id":"run_abc","status":"started","replayed":false}"#.utf8)) }
        let runID = try await client.startRun(
            sessionID: "s1", input: "hello", model: ModelSelection(provider: "nous", model: "x-ai/grok-4.5"),
            reasoningEffort: .high, idempotencyKey: "key-1"
        )
        #expect(runID == "run_abc")
        let request = try #require(StubProtocol.requests(for: host).last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/v1/runs")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
        let body = try #require(JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self)))
        #expect(body["input"] == .string("hello"))
        #expect(body["session_id"] == .string("s1"))
        #expect(body["model"] == .string("x-ai/grok-4.5"))
        #expect(body["provider"] == .string("nous"))
        #expect(body["model_options"]?["reasoning_effort"] == .string("high"))
    }

    @Test func streamsRunEvents() async throws {
        let host = "events.test"
        let sse = """
        : open

        id: 0
        data: {"event": "message.delta", "delta": "Hi", "seq": 0}

        : keepalive

        id: 1
        data: {"event": "run.completed", "output": "Hi!", "seq": 1}

        : stream closed


        """
        let client = makeClient(host: host) { _ in .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: Data(sse.utf8)) }
        var events: [SequencedTurnEvent] = []
        for try await event in client.runEvents(runID: "run_1", after: 7) {
            events.append(event)
        }
        #expect(events.map(\.event) == [.textDelta("Hi"), .completed(output: "Hi!", usage: nil, runtime: nil)])
        let request = try #require(StubProtocol.requests(for: host).last)
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "7")
        #expect(request.url?.query() == "last_seq=7")
    }

    @Test func streamErrorsBeforeSSEAreThrown() async {
        let host = "streamerr.test"
        let client = makeClient(host: host) { _ in
            .init(status: 404, body: Data(#"{"error":{"message":"Session not found: s9","type":"invalid_request_error","param":null,"code":"session_not_found"}}"#.utf8))
        }
        await #expect(throws: HermesError.notFound(message: "Session not found: s9")) {
            for try await _ in client.streamChat(sessionID: "s9", text: "hi", imageDataURLs: ["data:image/jpeg;base64,AA"], model: nil, reasoningEffort: nil) {}
        }
        let request = StubProtocol.requests(for: host).last
        let body = JSONValue.parse(String(decoding: request?.httpBody ?? Data(), as: UTF8.self))
        #expect(body?["message"] == .array([
            .object(["type": .string("text"), "text": .string("hi")]),
            .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/jpeg;base64,AA")])]),
        ]))
    }

    @Test(arguments: [
        ("mac.tail0c7d3.ts.net", true),
        ("100.110.70.49", true),
        ("100.63.0.1", false),
        ("100.128.0.1", false),
        ("192.168.1.20", false),
        ("hermes.example.com", false),
    ])
    func tailnetHostsSuggestTailscale(host: String, isTailnet: Bool) {
        #expect(HermesError.isTailnet(host) == isTailnet)
        let suggestion = HermesError.unreachable(host: host, reason: .cannotConnect).recoverySuggestion ?? ""
        #expect(suggestion.contains("Tailscale") == isTailnet)
    }

    /// A pooled connection that died while the app was suspended fails the next read once.
    @Test func aReadThatLostItsConnectionGoesAgain() async throws {
        let host = "lost.test"
        let attempts = Attempts()
        let client = makeClient(host: host) { _ in
            attempts.next() == 1
                ? .init(status: 0, body: Data(), error: .networkConnectionLost)
                : .init(status: 200, body: Data(#"{"status":"ok","platform":"hermes-agent","version":"0.14.2"}"#.utf8))
        }
        let health = try await client.health()
        #expect(health.version == "0.14.2")
        #expect(StubProtocol.requests(for: host).count == 2)
    }

    /// A write may have reached the gateway: it's never sent twice.
    @Test func aWriteThatLostItsConnectionIsNotSentAgain() async {
        let host = "lostwrite.test"
        let client = makeClient(host: host) { _ in .init(status: 0, body: Data(), error: .networkConnectionLost) }
        await #expect(throws: HermesError.unreachable(host: host, reason: .connectionLost)) {
            _ = try await client.createSession()
        }
        #expect(StubProtocol.requests(for: host).count == 1)
    }

    @Test(arguments: [
        ("GET", URLError.Code.networkConnectionLost, Duration?.some(.milliseconds(250))),
        ("HEAD", .notConnectedToInternet, .some(.seconds(1))),
        ("GET", .timedOut, nil),
        ("GET", .cannotConnectToHost, nil),
        ("POST", .networkConnectionLost, nil),
        ("PATCH", .notConnectedToInternet, nil),
        ("DELETE", .networkConnectionLost, nil),
    ])
    func onlyReadsGoAgain(method: String, code: URLError.Code, pause: Duration?) {
        var request = URLRequest(url: URL(string: "http://retry.test/api/sessions")!)
        request.httpMethod = method
        #expect(HermesClient.retryPause(after: URLError(code), for: request) == pause)
    }

    @Test(arguments: [
        ("192.168.1.20", true),
        ("10.0.0.5", true),
        ("172.16.4.1", true),
        ("172.31.255.1", true),
        ("172.32.0.1", false),
        ("169.254.10.2", true),
        ("mac-mini.local", true),
        ("[fe80::1]", true),
        ("100.110.70.49", false), // a tailnet address goes over the VPN
        ("mac.tail0c7d3.ts.net", false),
        ("hermes.example.com", false),
        ("8.8.8.8", false),
    ])
    func localNetworkHosts(host: String, isLocal: Bool) {
        #expect(HermesError.isLocalNetwork(host) == isLocal)
    }

    /// A setting in the way says which, and where to change it.
    @Test func settingsInTheWayAreNamed() {
        #expect(HermesError.unreachable(host: "mac", reason: .mobileDataOff).errorDescription == "Mobile Data is off for Hermes.")
        #expect(HermesError.unreachable(host: "mac", reason: .mobileDataOff).recoverySuggestion?.contains("Settings") == true)
        #expect(HermesError.unreachable(host: "192.168.1.20", reason: .localNetworkDenied).recoverySuggestion?.contains("Local Network") == true)
        #expect(HermesError.unreachable(host: "mac", reason: .wifiOff).isTransient)
    }

    @Test func unreachableHost() async {
        let client = makeClient(host: "nowhere.test") { _ in .init(status: 200, body: Data()) }
        StubProtocol.removeRoute("nowhere.test")
        await #expect(throws: HermesError.unreachable(host: "nowhere.test", reason: .cannotConnect)) {
            _ = try await client.capabilities()
        }
    }
}

/// Counts the loads a stub answered.
final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
