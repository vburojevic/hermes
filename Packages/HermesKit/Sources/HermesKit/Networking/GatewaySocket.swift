import Foundation

/// One inbound frame on the `/api/ws` JSON-RPC gateway (`hermes serve`).
public enum GatewayFrame: Sendable, Equatable {
    /// `{"method":"event","params":{"type","session_id","seq","payload"}}`
    case event(GatewayEvent)
    /// A server→client request (approval, clarify, sudo, secret…), answered by id.
    case request(GatewayServerRequest)
    /// A response to one of our requests.
    case response(id: String, result: JSONValue?, error: GatewayRPCError?)

    /// Classifies one text frame. Returns `nil` for anything that isn't a JSON-RPC object.
    public static func parse(_ text: String) -> GatewayFrame? {
        guard let json = JSONValue.parse(text), case .object(let object) = json else { return nil }
        let method = object["method"]?.stringValue
        let id = object["id"].flatMap(Self.idString)
        if method == "event", let params = object["params"] {
            return .event(GatewayEvent(params: params))
        }
        if let method, let id {
            return .request(GatewayServerRequest(id: id, method: method, params: object["params"] ?? .object([:])))
        }
        if let id {
            let error = object["error"].map(GatewayRPCError.init(json:))
            return .response(id: id, result: object["result"], error: error)
        }
        return nil
    }

    static func idString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): String(Int64(number))
        default: nil
        }
    }
}

public struct GatewayEvent: Sendable, Equatable {
    public var type: String
    /// Runtime session id (8 hex). Empty for session-less broadcasts.
    public var sessionID: String
    public var seq: Int?
    public var payload: JSONValue

    public init(type: String, sessionID: String, seq: Int?, payload: JSONValue) {
        self.type = type
        self.sessionID = sessionID
        self.seq = seq
        self.payload = payload
    }

    init(params: JSONValue) {
        type = params["type"]?.stringValue ?? ""
        sessionID = params["session_id"]?.stringValue ?? ""
        seq = params["seq"]?.doubleValue.map { Int($0) }
        payload = params["payload"] ?? .object([:])
    }
}

public struct GatewayServerRequest: Sendable, Equatable {
    public var id: String
    public var method: String
    public var params: JSONValue

    public var sessionID: String { params["session_id"]?.stringValue ?? "" }

    public init(id: String, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct GatewayRPCError: Error, Sendable, Equatable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    init(json: JSONValue) {
        code = json["code"]?.doubleValue.map { Int($0) } ?? -1
        message = json["message"]?.stringValue ?? "Request failed"
        data = json["data"]
    }

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        switch code {
        case 4009: "This Bot is still busy with its last message. Try again when it's done."
        case 4062: "A Bot with that name already exists."
        case 4064: "That bot doesn't exist on this Hermes backend."
        case 4090: "Hermes is running as many sessions as it allows right now."
        case 5035: "Hermes is restarting. Reconnecting…"
        default: message
        }
    }

    /// The runtime session id is stale; re-resume by the stored id.
    public var isSessionNotFound: Bool { code == 4001 }
}

/// A JSON-RPC 2.0 client for the Hermes backend gateway socket (`/api/ws`), the
/// transport Hermes Desktop uses for chat, profiles (Bots) and routines.
///
/// One socket serves every profile: per-request `profile` params pick the Bot.
public actor GatewaySocket {
    public enum Message: Sendable {
        case frame(GatewayFrame)
        case closed((any Error)?)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notConnected
        case handshakeTimedOut
        case closed(String)
        case timedOut(method: String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the Hermes backend."
            case .handshakeTimedOut: "The Hermes backend didn't answer. Check the address and that `hermes serve` is running."
            case .closed(let reason): reason
            case .timedOut(let method): "Hermes didn't answer \(method) in time."
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<Message>.Continuation] = [:]
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var isReady = false
    private var nextID = 0
    private var lastInbound = Date()
    public private(set) var isOpen = false
    /// Identifies the backend process; a change means event watermarks are void.
    public private(set) var replayEpoch: String?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    /// Opens the socket, waits for `gateway.ready`, and opts into server requests
    /// (without `client.capabilities` approvals are never delivered).
    public func connect() async throws {
        guard task == nil else { return }
        var upgrade = URLRequest(url: url)
        upgrade.timeoutInterval = 15
        let task = session.webSocketTask(with: upgrade)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForReady() }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    throw Failure.handshakeTimedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            isOpen = true
            _ = try await request("client.capabilities", ["server_requests": .bool(true)])
        } catch {
            // A socket that never got going must not keep its receive loop or heartbeat.
            shutdown(error: error)
            throw error
        }
    }

    private func waitForReady() async throws {
        // `gateway.ready` may already have arrived before anyone waited for it.
        guard !isReady else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    readyContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelReadyWait() }
        }
    }

    private func cancelReadyWait() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
    }

    /// Every frame and the final close, for as long as the caller iterates.
    public func messages() -> AsyncStream<Message> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .unbounded)
        guard task != nil else {
            // Already closed: say so at once rather than leaving the caller waiting forever.
            continuation.yield(.closed(Failure.closed("Disconnected from the Hermes backend.")))
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Sends a request and waits for its response.
    public func request(_ method: String, _ params: [String: JSONValue] = [:], timeout: Duration = .seconds(120)) async throws -> JSONValue {
        guard let task else { throw Failure.notConnected }
        nextID += 1
        let id = "r\(nextID)"
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": .object(params),
        ])
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(id: id, with: Failure.timedOut(method: method))
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                pending[id] = continuation
                task.send(.string(text)) { error in
                    guard let error else { return }
                    Task { await self.fail(id: id, with: error) }
                }
            }
        } onCancel: {
            Task { await self.fail(id: id, with: CancellationError()) }
        }
    }

    /// Answers a server→client request (approval, clarify, …).
    public func respond(to requestID: String, result: JSONValue) async {
        await sendRaw(.object(["jsonrpc": .string("2.0"), "id": .string(requestID), "result": result]))
    }

    /// Declines a server request we can't handle (desktop-only bridges and the like).
    public func decline(_ requestID: String, code: Int = -32601, message: String = "Not supported by this client") async {
        await sendRaw(.object([
            "jsonrpc": .string("2.0"), "id": .string(requestID),
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    public func close() {
        shutdown(error: nil)
    }

    // MARK: - Internals

    private func sendRaw(_ frame: JSONValue) async {
        guard let task, let data = try? JSONEncoder().encode(frame) else { return }
        try? await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func fail(id: String, with error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop() async {
        while let task = self.task {
            do {
                let message = try await task.receive()
                lastInbound = .now
                let text: String? = switch message {
                case .string(let text): text
                case .data(let data): String(data: data, encoding: .utf8)
                @unknown default: nil
                }
                // A frame may carry several newline-delimited objects.
                for line in (text ?? "").split(whereSeparator: \.isNewline) {
                    if let frame = GatewayFrame.parse(String(line)) {
                        handle(frame)
                    }
                }
            } catch {
                shutdown(error: closeReason(for: error))
                return
            }
        }
    }

    private func closeReason(for error: any Error) -> any Error {
        guard let task else { return error }
        switch task.closeCode.rawValue {
        case 4401: return Failure.closed("The Hermes backend rejected the sign-in. Sign in again in Settings.")
        case 4403: return Failure.closed("The Hermes backend refused this connection (host or origin not allowed).")
        default: return error
        }
    }

    private func handle(_ frame: GatewayFrame) {
        switch frame {
        case .event(let event):
            if event.type == "gateway.ready" {
                replayEpoch = event.payload["replay_epoch"]?.stringValue
                if event.payload["heartbeat"]?.boolValue == true {
                    startHeartbeat()
                }
                isReady = true
                readyContinuation?.resume()
                readyContinuation = nil
                return
            }
        case .response(let id, let result, let error):
            if let continuation = pending.removeValue(forKey: id) {
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result ?? .null)
                }
            }
            return
        case .request:
            break
        }
        for subscriber in subscribers.values {
            subscriber.yield(.frame(frame))
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                beat += 1
                if await self.isStale() {
                    await self.shutdown(error: Failure.closed("Lost the connection to the Hermes backend."))
                    return
                }
                // Recent traffic (a roster poll, a streaming turn) already proves the link.
                guard await self.isQuiet() else { continue }
                await self.sendRaw(.object([
                    "jsonrpc": .string("2.0"), "id": .string("heartbeat-\(beat)"),
                    "method": .string("gateway.ping"), "params": .object([:]),
                ]))
            }
        }
    }

    private func isQuiet() -> Bool {
        Date().timeIntervalSince(lastInbound) >= 14
    }

    private func isStale() -> Bool {
        Date().timeIntervalSince(lastInbound) > 45
    }

    private func shutdown(error: (any Error)?) {
        guard task != nil || readyContinuation != nil else { return }
        isOpen = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        let failure = error ?? Failure.closed("Disconnected from the Hermes backend.")
        readyContinuation?.resume(throwing: failure)
        readyContinuation = nil
        for continuation in pending.values {
            continuation.resume(throwing: failure)
        }
        pending.removeAll()
        for subscriber in subscribers.values {
            subscriber.yield(.closed(error))
            subscriber.finish()
        }
        subscribers.removeAll()
    }
}
