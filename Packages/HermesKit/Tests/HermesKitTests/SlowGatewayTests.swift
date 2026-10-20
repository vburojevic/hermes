import Foundation
import Testing
@testable import HermesKit

/// Busy is not offline (`GatewayLiveness`): checked against real sockets on this machine, since
/// what decides it is how far the connection got.
@Suite("Gateway liveness")
struct LivenessTests {
    @Test func aTimeoutAfterTheConnectionWasTakenIsBusy() {
        let busy = GatewayLiveness.after(URLError(.timedOut), connection: ConnectionProgress(reachedServer: true), host: "mac")
        #expect(busy == .busy)
        #expect(busy.isThere)
    }

    @Test func aTimeoutBeforeAnyConnectionIsUnreachable() {
        let away = GatewayLiveness.after(URLError(.timedOut), connection: .none, host: "mac")
        #expect(away == .unreachable(.unreachable(host: "mac", reason: .timedOut)))
        #expect(!away.isThere)
    }

    @Test func aRefusalIsUnreachableWhateverTheConnectionDid() {
        let refused = GatewayLiveness.after(URLError(.cannotConnectToHost), connection: ConnectionProgress(reachedServer: true), host: "mac")
        #expect(refused == .unreachable(.unreachable(host: "mac", reason: .cannotConnect)))
    }

    /// A process too starved to accept: the kernel still completes the handshake into its backlog.
    @Test func aListenerThatNeverAnswersIsBusy() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:\(listener.port)")!, apiKey: "")
        let liveness = try await client.liveness(timeout: 1)
        #expect(liveness == .busy)
    }

    @Test func aPortNobodyListensOnIsUnreachable() async throws {
        let port = try SilentListener.freePort()
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "")
        let liveness = try await client.liveness(timeout: 2)
        #expect(liveness == .unreachable(.unreachable(host: "127.0.0.1", reason: .cannotConnect)))
    }

    @Test func aHealthCheckThatAnswersIsAnswering() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        listener.answerOnce(status: "200 OK", body: #"{"status":"ok","platform":"hermes-agent","version":"0.21.6"}"#)
        let client = HermesClient(baseURL: URL(string: "http://127.0.0.1:\(listener.port)")!, apiKey: "")
        #expect(try await client.liveness(timeout: 5) == .answering)
    }
}

/// The chat list kept on the device (`SessionsCache`) reads back as the gateway sent it.
@Suite("Chat list kept on the device")
struct SessionRowCacheTests {
    @Test func aRowReadsBackTheSame() throws {
        let row = #"""
        {"data": [
          {"id": "s2", "source": "telegram", "model": "m", "title": "Homelab", "started_at": 1760000000.5,
           "last_active": 1760000100, "preview": "hi", "message_count": 12, "_lineage_root_id": "s1",
           "pinned": true, "archived": false, "is_internal_child": false, "last_read_at": 1760000050},
          {"id": "s3", "last_read_at": null},
          {"id": "s4", "last_read_at": 0},
          {"id": "s5"}
        ], "has_more": false}
        """#
        let page = try JSONDecoder().decode(SessionPage.self, from: Data(row.utf8))
        let again = try JSONDecoder().decode([HermesSession].self, from: JSONEncoder().encode(page.sessions))
        #expect(again == page.sessions)
        #expect(again.map(\.readMark) == [.readUntil(Date(timeIntervalSince1970: 1760000050)), .untracked, .markedUnread, nil])
        #expect(again[0].stableID == "s1")
    }
}

/// Answers kept by the request's id until Hermes has them (`AnswerLedger`).
@Suite("Answers while the gateway is away")
struct AnswerLedgerTests {
    private let allow: JSONValue = .object(["choice": .string("once"), "all": .bool(false)])

    private func unsent(_ id: String, _ summary: String = "ls") -> AnswerLedger {
        var ledger = AnswerLedger()
        ledger.record(id: id, result: allow, summary: summary)
        ledger.finishSending(id, sent: false)
        return ledger
    }

    @Test func anAnswerThatNeverWentOutGoesAgainToItsOwnRequest() {
        var ledger = unsent("srq-a", "rm -rf build")
        #expect(ledger.holds("srq-a"))
        let settled = ledger.settle(openIDs: ["srq-b", "srq-a"])
        #expect(settled.resend.map(\.id) == ["srq-a"])
        #expect(settled.resend.first?.result == allow)
        #expect(settled.expired.isEmpty)
        // Still kept while it goes again; an attach meanwhile doesn't send it a third time.
        #expect(ledger.holds("srq-a"))
        #expect(ledger.settle(openIDs: ["srq-a"]).resend.isEmpty)
        ledger.finishSending("srq-a", sent: true)
        // Gone from the open requests once it went out: Hermes has it.
        #expect(ledger.settle(openIDs: ["srq-b"]) == AnswerLedger.Settlement())
        #expect(!ledger.holds("srq-a"))
    }

    @Test func anAnswerThatWentOutAndIsNoLongerOpenArrived() {
        var ledger = AnswerLedger()
        ledger.record(id: "srq-a", result: allow, summary: "ls")
        ledger.finishSending("srq-a", sent: true)
        #expect(ledger.settle(openIDs: []) == AnswerLedger.Settlement())
        #expect(ledger.entries.isEmpty)
    }

    /// Written to a socket that died before Hermes read it: the request is still open.
    @Test func anAnswerLostWithItsSocketGoesAgain() {
        var ledger = AnswerLedger()
        ledger.record(id: "srq-a", result: allow, summary: "ls")
        ledger.finishSending("srq-a", sent: true)
        #expect(ledger.settle(openIDs: ["srq-a"]).resend.map(\.id) == ["srq-a"])
    }

    @Test func anAnswerHermesStoppedWaitingForIsSaidToHaveExpired() {
        var ledger = unsent("srq-a", "deploy")
        let settled = ledger.settle(openIDs: ["srq-c"])
        #expect(settled.expired.map(\.summary) == ["deploy"])
        #expect(settled.resend.isEmpty)
        #expect(ledger.entries.isEmpty)
    }

    /// An attach while the answer is still being written: it may be what settled the request.
    @Test func anAnswerOnItsWayIsNeverSaidToHaveExpired() {
        var ledger = AnswerLedger()
        ledger.record(id: "srq-a", result: allow, summary: "deploy")
        #expect(ledger.settle(openIDs: []) == AnswerLedger.Settlement())
    }

    @Test func aWithdrawnRequestIsForgotten() {
        var ledger = unsent("srq-a")
        ledger.forget("srq-a")
        #expect(ledger.settle(openIDs: ["srq-a"]) == AnswerLedger.Settlement())
    }

    @Test func answeringAgainReplacesTheFirstAnswer() {
        var ledger = AnswerLedger()
        ledger.record(id: "srq-a", result: allow, summary: "ls")
        let deny: JSONValue = .object(["choice": .string("deny"), "all": .bool(false)])
        ledger.record(id: "srq-a", result: deny, summary: "ls")
        #expect(ledger.entries.map(\.result) == [deny])
    }
}

/// What a failed send means for the message (`SendFailure`).
@Suite("Sends while the gateway is slow or away")
struct SendFailureTests {
    @Test func withNoSocketTheMessageWaitsAndGoesAgain() {
        #expect(SendFailure.overSocket(GatewaySocket.Failure.notConnected) == .notSent)
        #expect(SendFailure.overSocket(GatewayRPCError(code: 5035, message: "backend is retiring; reconnect to continue")) == .notSent)
    }

    @Test func aLostAnswerIsLookedForBeforeAnythingGoesAgain() {
        #expect(SendFailure.overSocket(GatewaySocket.Failure.timedOut(method: "prompt.submit")) == .mayHaveArrived)
        #expect(SendFailure.overSocket(GatewaySocket.Failure.closed("Lost the connection to the Hermes backend.")) == .mayHaveArrived)
        #expect(SendFailure.overSocket(URLError(.networkConnectionLost)) == .mayHaveArrived)
    }

    @Test func aRefusalGoesBackToThePerson() {
        #expect(SendFailure.overSocket(GatewayRPCError(code: 4000, message: "invalid params for prompt.submit")) == .refused)
        #expect(SendFailure.overSocket(CancellationError()) == .refused)
        #expect(SendFailure.overHTTP(HermesError.server(status: 400, code: "invalid_request_error", message: "Missing 'input' field")) == .refused)
        #expect(SendFailure.overHTTP(HermesError.unauthorized) == .refused)
    }

    /// `POST /v1/runs` dedupes on its `Idempotency-Key`, so the same request goes again.
    @Test func anHTTPSendWithItsKeyGoesAgainOnABusyOrAwayGateway() {
        #expect(SendFailure.overHTTP(HermesError.unreachable(host: "mac", reason: .timedOut)) == .sendAgain)
        #expect(SendFailure.overHTTP(HermesError.unreachable(host: "mac", reason: .cannotConnect)) == .sendAgain)
        #expect(SendFailure.overHTTP(HermesError.server(status: 503, code: "gateway_draining", message: nil)) == .sendAgain)
        #expect(SendFailure.overHTTP(HermesError.server(status: 429, code: "rate_limit_exceeded", message: nil)) == .sendAgain)
        #expect(SendFailure.overHTTP(HermesError.rateLimited) == .sendAgain)
    }

    @Test func aSettingOnTheDeviceIsThePersonsToFixNotAWait() {
        #expect(SendFailure.overHTTP(HermesError.unreachable(host: "mac", reason: .localNetworkDenied)) == .refused)
        #expect(SendFailure.overHTTP(HermesError.unreachable(host: "mac", reason: .tls)) == .refused)
    }

    /// The key went with another body: Hermes had the first send, so it's never given back.
    @Test func anIdempotencyConflictMeansHermesHadIt() {
        let conflict = HermesError.server(status: 409, code: "idempotency_key_conflict", message: nil)
        #expect(SendFailure.overHTTP(conflict) == .mayHaveArrived)
    }

    /// `POST /api/sessions` isn't deduped: only a request that never left goes again.
    @Test func onlyARequestThatNeverLeftIsSafeToRepeatUnkeyed() {
        #expect(SendFailure.neverLeft(HermesError.unreachable(host: "mac", reason: .cannotConnect)))
        #expect(SendFailure.neverLeft(HermesError.unreachable(host: "mac", reason: .offline)))
        #expect(!SendFailure.neverLeft(HermesError.unreachable(host: "mac", reason: .timedOut)))
        #expect(!SendFailure.neverLeft(HermesError.server(status: 503, code: nil, message: nil)))
    }

    @Test func pausesGrowToFifteenSeconds() {
        #expect((1...7).map(SendFailure.pause(before:)) == [1, 2, 4, 8, 15, 15, 15].map { Duration.seconds($0) })
    }
}

/// A TCP listener on 127.0.0.1 that accepts nothing unless asked to (`answerOnce`).
private final class SilentListener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        fd = socketFD
        port = UInt16(bigEndian: address.sin_port)
    }

    /// A port that was free a moment ago, with nothing listening on it now.
    static func freePort() throws -> UInt16 {
        let listener = try SilentListener()
        listener.close()
        return listener.port
    }

    /// Accepts one connection on another thread, reads the request and answers it.
    func answerOnce(status: String, body: String) {
        let fd = fd
        Thread.detachNewThread {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(connection, &buffer, buffer.count)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { write(connection, $0, strlen($0)) }
            Darwin.close(connection)
        }
    }

    func close() {
        Darwin.close(fd)
    }
}
