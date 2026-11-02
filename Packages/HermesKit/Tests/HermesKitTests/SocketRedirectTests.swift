import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import HermesKit

/// The Board's live events and the Bot Screen's socket carry a token or a ticket in their URL, so
/// their upgrade must never follow a redirect to another server (`docs/architecture.md`). These
/// run real sockets against two loopback servers: the first answers the upgrade with a redirect.
@Suite("Socket redirects", .timeLimit(.minutes(1)))
struct SocketRedirectTests {
    enum Elsewhere: CaseIterable, Sendable {
        /// Another server: the same address, another port.
        case otherPort
        /// The same listener under another host name (localhost instead of 127.0.0.1). A followed
        /// redirect reaches it again, which the first server's request count catches.
        case otherHostName
    }

    // MARK: Board

    @Test(arguments: [302, 307], Elsewhere.allCases)
    func boardEventsNeverFollowARedirectToAnotherServer(status: Int, elsewhere: Elsewhere) async throws {
        let (first, other) = try await Self.redirectingServers(status: status, elsewhere: elsewhere)
        defer { first.stop(); other.stop() }

        let client = BackendClient(baseURL: first.baseURL, credential: .sessionToken("board-token"))
        let batches = try await Self.openBoard(client)
        await #expect(throws: (any Error).self) {
            for try await _ in batches {}
        }
        try await Self.expectNothingFollowed(first: first, other: other)
    }

    @Test func boardEventsFollowARedirectOnTheSameServer() async throws {
        let server = try await LoopbackServer.start { line, port in
            line.contains("/moved") ? .webSocket(.text(#"{"events":[],"cursor":7}"#))
                : .redirect(307, "ws://127.0.0.1:\(port)/moved")
        }
        defer { server.stop() }

        let client = BackendClient(baseURL: server.baseURL, credential: .sessionToken("board-token"))
        var cursor: Int?
        for try await batch in try await Self.openBoard(client) {
            cursor = batch.cursor
            break
        }
        #expect(cursor == 7)
        #expect(server.requests.count == 2)
    }

    // MARK: Bot Screen

    @Test(arguments: [302, 307], Elsewhere.allCases)
    func displaySocketNeverFollowsARedirectToAnotherServer(status: Int, elsewhere: Elsewhere) async throws {
        let (first, other) = try await Self.redirectingServers(status: status, elsewhere: elsewhere)
        defer { first.stop(); other.stop() }

        let client = BackendClient(baseURL: first.baseURL, credential: .sessionToken("screen-token"))
        let socket = try await Self.openDisplay(client)
        socket.resume()
        await #expect(throws: (any Error).self) {
            _ = try await socket.receive()
        }
        socket.cancel(with: .goingAway, reason: nil)
        try await Self.expectNothingFollowed(first: first, other: other)
    }

    @Test func displaySocketFollowsARedirectOnTheSameServer() async throws {
        let server = try await LoopbackServer.start { line, port in
            line.contains("/moved") ? .webSocket(.binary(Data([1, 2, 3])))
                : .redirect(302, "ws://127.0.0.1:\(port)/moved")
        }
        defer { server.stop() }

        let client = BackendClient(baseURL: server.baseURL, credential: .sessionToken("screen-token"))
        let socket = try await Self.openDisplay(client)
        socket.resume()
        let message = try await socket.receive()
        socket.cancel(with: .goingAway, reason: nil)
        guard case .data(let data) = message else {
            Issue.record("Expected the server's frame, got \(message)")
            return
        }
        #expect(data == Data([1, 2, 3]))
        #expect(server.requests.count == 2)
    }

    // MARK: Helpers

    /// What the app calls to open each socket.
    private static func openBoard(_ client: BackendClient) async throws -> AsyncThrowingStream<BoardEventBatch, any Error> {
        try await client.boardEvents("default", since: 0)
    }

    private static func openDisplay(_ client: BackendClient) async throws -> URLSessionWebSocketTask {
        await client.displaySocket(ticket: "display-ticket")
    }

    /// The first server redirects every upgrade elsewhere; the other one records whatever reaches it.
    private static func redirectingServers(status: Int, elsewhere: Elsewhere) async throws -> (first: LoopbackServer, other: LoopbackServer) {
        let other = try await LoopbackServer.start { _, _ in .close }
        let first = try await LoopbackServer.start { [otherPort = other.port] _, port in
            switch elsewhere {
            case .otherPort: .redirect(status, "ws://127.0.0.1:\(otherPort)/elsewhere")
            case .otherHostName: .redirect(status, "ws://localhost:\(port)/elsewhere")
            }
        }
        return (first, other)
    }

    private static func expectNothingFollowed(first: LoopbackServer, other: LoopbackServer) async throws {
        // A followed redirect connects before the socket fails; give a late one time to land.
        try await Task.sleep(for: .milliseconds(300))
        #expect(other.requests.isEmpty, "The other server was asked: \(other.requests)")
        #expect(first.requests.count == 1, "The first server was asked: \(first.requests)")
    }
}

/// A tiny HTTP server on 127.0.0.1 that answers each request head with a redirect, a WebSocket
/// upgrade and one frame, or a closed connection, and records each request line.
final class LoopbackServer: @unchecked Sendable {
    enum Frame: Sendable {
        case text(String)
        case binary(Data)
    }

    enum Answer: Sendable {
        case redirect(Int, String)
        case webSocket(Frame)
        case close
    }

    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [String] { recorded.withLock { $0 } }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let answer: @Sendable (String, UInt16) -> Answer
    private let recorded = Mutex<[String]>([])
    private let connections = Mutex<[NWConnection]>([])

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue, answer: @escaping @Sendable (String, UInt16) -> Answer) {
        self.listener = listener
        self.port = port
        self.queue = queue
        self.answer = answer
    }

    static func start(answer: @escaping @Sendable (_ requestLine: String, _ ownPort: UInt16) -> Answer) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LoopbackServer")
        let pending = Mutex<[NWConnection]>([])
        let server = Mutex<LoopbackServer?>(nil)
        listener.newConnectionHandler = { connection in
            if let server = server.withLock({ $0 }) {
                server.accept(connection)
            } else {
                pending.withLock { $0.append(connection) }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let result, !resumed.withLock({ was in defer { was = true }; return was }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        let started = LoopbackServer(listener: listener, port: port, queue: queue, answer: answer)
        server.withLock { $0 = started }
        for connection in pending.withLock({ $0 }) { started.accept(connection) }
        return started
    }

    func stop() {
        listener.cancel()
        for connection in connections.withLock({ $0 }) { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                readHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        recorded.withLock { $0.append(requestLine) }
        switch answer(requestLine, port) {
        case .redirect(let status, let location):
            let response = "HTTP/1.1 \(status) Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        case .webSocket(let frame):
            let key = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-key:") }
                .map { $0.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var response = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
            response.append(Self.encode(frame))
            connection.send(content: response, completion: .contentProcessed { _ in })
        case .close:
            connection.cancel()
        }
    }

    /// One unmasked server frame (RFC 6455 §5.2), short enough for a 7- or 16-bit length.
    private static func encode(_ frame: Frame) -> Data {
        let (opcode, payload): (UInt8, Data) = switch frame {
        case .text(let text): (0x1, Data(text.utf8))
        case .binary(let data): (0x2, data)
        }
        var data = Data([0x80 | opcode])
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else {
            data.append(126)
            data.append(UInt8(payload.count >> 8))
            data.append(UInt8(payload.count & 0xFF))
        }
        data.append(payload)
        return data
    }
}
