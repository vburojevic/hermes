import Foundation

/// Talks to one Hermes Agent API server (`hermes gateway` with `API_SERVER_ENABLED=true`).
public struct HermesClient: Sendable {
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = HermesClient.defaultSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    private var host: String { baseURL.host() ?? baseURL.absoluteString }

    // MARK: - Server

    /// Unauthenticated liveness probe.
    public func health() async throws -> HealthStatus {
        try await get(["health"], authenticated: false)
    }

    public func capabilities() async throws -> ServerCapabilities {
        try await get(["v1", "capabilities"])
    }

    public func modelOptions(refresh: Bool = false) async throws -> ModelOptions {
        var query = [URLQueryItem(name: "include_unconfigured", value: "false")]
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        return try await get(["api", "model", "options"], query: query)
    }

    public func skills() async throws -> [Skill] {
        let envelope: ListEnvelope<Skill> = try await get(["v1", "skills"])
        return envelope.data
    }

    public func toolsets() async throws -> [Toolset] {
        let envelope: ListEnvelope<Toolset> = try await get(["v1", "toolsets"])
        return envelope.data
    }

    // MARK: - Sessions

    public func sessions(limit: Int = 50, offset: Int = 0) async throws -> SessionPage {
        try await get(["api", "sessions"], query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    public func session(id: String) async throws -> HermesSession {
        let envelope: SessionEnvelope = try await get(["api", "sessions", id])
        return envelope.session
    }

    /// Creates an empty server-side session. Leave `title` nil so Hermes auto-titles it.
    public func createSession(model: ModelSelection? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = ["source": .string("api_server")]
        if let model {
            body["model"] = .string(model.model)
            body["provider"] = .string(model.provider)
        }
        let envelope: SessionEnvelope = try await send("POST", ["api", "sessions"], body: body)
        return envelope.session
    }

    public func renameSession(id: String, title: String?) async throws -> HermesSession {
        let body: [String: JSONValue] = ["title": title.map(JSONValue.string) ?? .null]
        let envelope: SessionEnvelope = try await send("PATCH", ["api", "sessions", id], body: body)
        return envelope.session
    }

    public func setSessionFlags(id: String, pinned: Bool? = nil, archived: Bool? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = [:]
        if let pinned { body["pinned"] = .bool(pinned) }
        if let archived { body["archived"] = .bool(archived) }
        let envelope: SessionEnvelope = try await send("PATCH", ["api", "sessions", id], body: body)
        return envelope.session
    }

    public func deleteSession(id: String) async throws {
        let _: JSONValue = try await send("DELETE", ["api", "sessions", id], body: Optional<JSONValue>.none)
    }

    /// Branches a conversation into a new session (the source session is ended).
    public func forkSession(id: String, title: String? = nil) async throws -> HermesSession {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        let envelope: SessionEnvelope = try await send("POST", ["api", "sessions", id, "fork"], body: body)
        return envelope.session
    }

    /// The live transcript (up to the latest 500 messages), resolved to the current compression tip.
    public func transcript(sessionID: String) async throws -> SessionTranscript {
        let envelope: MessagesEnvelope = try await get(["api", "sessions", sessionID, "messages"])
        return SessionTranscript(sessionID: envelope.sessionID ?? sessionID, messages: envelope.data)
    }

    // MARK: - Runs (detached turns)

    /// Starts a turn that keeps running on the server even if this app disconnects.
    ///
    /// - Parameter idempotencyKey: makes retries of the same submission safe.
    public func startRun(
        sessionID: String,
        input: String,
        model: ModelSelection?,
        reasoningEffort: ReasoningEffort?,
        instructions: String? = nil,
        idempotencyKey: String
    ) async throws -> String {
        var body: [String: JSONValue] = [
            "input": .string(input),
            "session_id": .string(sessionID),
        ]
        if let model {
            body["model"] = .string(model.model)
            body["provider"] = .string(model.provider)
        }
        if let reasoningEffort {
            body["model_options"] = .object(["reasoning_effort": .string(reasoningEffort.rawValue)])
        }
        if let instructions, !instructions.isEmpty {
            body["instructions"] = .string(instructions)
        }
        let created: RunCreated = try await send(
            "POST", ["v1", "runs"], body: body, headers: ["Idempotency-Key": idempotencyKey]
        )
        return created.runID
    }

    public func runStatus(runID: String) async throws -> RunStatus {
        try await get(["v1", "runs", runID])
    }

    /// Subscribes to a run's events. Pass the last seen `seq` to resume after a disconnect.
    public func runEvents(runID: String, after lastSeq: Int? = nil) -> AsyncThrowingStream<SequencedTurnEvent, any Error> {
        var query: [URLQueryItem] = []
        if let lastSeq { query.append(URLQueryItem(name: "last_seq", value: String(lastSeq))) }
        var request = makeRequest("GET", ["v1", "runs", runID, "events"], query: query)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastSeq { request.setValue(String(lastSeq), forHTTPHeaderField: "Last-Event-ID") }
        request.timeoutInterval = 120
        return stream(request, decode: RunEventDecoder.decode)
    }

    public func stopRun(runID: String) async throws {
        let _: JSONValue = try await send("POST", ["v1", "runs", runID, "stop"], body: [String: JSONValue]())
    }

    /// Redirects a running turn with more input (`POST /v1/runs/{id}/steer`).
    public func steerRun(runID: String, text: String) async throws {
        let body: [String: JSONValue] = ["input": .string(text)]
        let _: JSONValue = try await send("POST", ["v1", "runs", runID, "steer"], body: body)
    }

    public func respondToApproval(runID: String, requestID: String?, choice: ApprovalChoice) async throws {
        var body: [String: JSONValue] = ["choice": .string(choice.rawValue)]
        if let requestID { body["request_id"] = .string(requestID) }
        let _: JSONValue = try await send("POST", ["v1", "runs", runID, "approval"], body: body)
    }

    // MARK: - Session chat stream (multimodal turns)

    /// Streams one turn with image attachments. Disconnecting interrupts the turn.
    public func streamChat(
        sessionID: String,
        text: String,
        imageDataURLs: [String],
        model: ModelSelection?,
        reasoningEffort: ReasoningEffort?
    ) -> AsyncThrowingStream<SequencedTurnEvent, any Error> {
        var parts: [JSONValue] = []
        if !text.isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for url in imageDataURLs {
            parts.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])]))
        }
        var body: [String: JSONValue] = ["message": .array(parts)]
        if let model {
            body["model"] = .string(model.model)
            body["provider"] = .string(model.provider)
            body["require_model_lock"] = .bool(true)
        }
        if let reasoningEffort {
            body["model_options"] = .object(["reasoning_effort": .string(reasoningEffort.rawValue)])
        }
        var request = makeRequest("POST", ["api", "sessions", sessionID, "chat", "stream"])
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 120
        return stream(request, decode: SessionStreamDecoder.decode)
    }

    // MARK: - Jobs

    public func jobs() async throws -> [CronJob] {
        let envelope: JobsEnvelope = try await get(["api", "jobs"], query: [URLQueryItem(name: "include_disabled", value: "true")])
        return envelope.jobs
    }

    public func createJob(_ job: NewCronJob) async throws -> CronJob {
        let envelope: JobEnvelope = try await send("POST", ["api", "jobs"], body: job)
        return envelope.job
    }

    public func pauseJob(id: String) async throws -> CronJob {
        let envelope: JobEnvelope = try await send("POST", ["api", "jobs", id, "pause"], body: [String: JSONValue]())
        return envelope.job
    }

    public func resumeJob(id: String) async throws -> CronJob {
        let envelope: JobEnvelope = try await send("POST", ["api", "jobs", id, "resume"], body: [String: JSONValue]())
        return envelope.job
    }

    public func runJobNow(id: String) async throws {
        let _: JSONValue = try await send("POST", ["api", "jobs", id, "run"], body: [String: JSONValue]())
    }

    public func deleteJob(id: String) async throws {
        let _: JSONValue = try await send("DELETE", ["api", "jobs", id], body: Optional<JSONValue>.none)
    }

    // MARK: - Plumbing

    func makeRequest(_ method: String, _ path: [String], query: [URLQueryItem] = [], authenticated: Bool = true) -> URLRequest {
        var url = baseURL
        for component in path {
            url.append(component: component)
        }
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<Response: Decodable>(
        _ path: [String], query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> Response {
        try await perform(makeRequest("GET", path, query: query, authenticated: authenticated))
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: [String], body: (some Encodable)?, headers: [String: String] = [:]
    ) async throws -> Response {
        var request = makeRequest(method, path)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, _) = try await data(for: request)
        if data.isEmpty, let empty = JSONValue.null as? Response {
            return empty
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw HermesError.invalidResponse("\(request.url?.path() ?? ""): \(Self.describe(error))")
        }
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw HermesError.from(urlError: error, host: host)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.invalidResponse("not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.from(status: http.statusCode, body: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
        }
        return (data, http)
    }

    private func stream(
        _ request: URLRequest,
        decode: @escaping @Sendable (ServerSentEvent) -> [SequencedTurnEvent]
    ) -> AsyncThrowingStream<SequencedTurnEvent, any Error> {
        let session = session
        let host = host
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw HermesError.invalidResponse("not HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw HermesError.from(status: http.statusCode, body: body, contentType: http.value(forHTTPHeaderField: "Content-Type"))
                    }
                    var parser = ServerSentEventParser()
                    for try await byte in bytes {
                        guard let frame = parser.consume(byte) else { continue }
                        for event in decode(frame) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError {
                    continuation.finish(throwing: HermesError.from(urlError: error, host: host))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context), DecodingError.dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".")
        default: error.localizedDescription
        }
    }
}
