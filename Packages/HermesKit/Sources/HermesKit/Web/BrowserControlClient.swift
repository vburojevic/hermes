import Foundation

extension HermesClient {
    /// `POST /v1/browser-control/register` (`gateway/platforms/api_server.py`): a one-shot,
    /// 30-second ticket for the controller socket of one chat. Hermes takes the identity from the
    /// API key, never from the body; `controller_id` and `browser_profile_id` name this app's browser.
    public func registerBrowserController(sessionID: String, controllerID: String, browserProfileID: String) async throws -> BrowserControlTicket {
        var request = makeRequest("POST", ["v1", "browser-control", "register"])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "protocol_version": .number(Double(BrowserControl.protocolVersion)),
            "controller_id": .string(controllerID),
            "browser_profile_id": .string(browserProfileID),
            "session_id": .string(sessionID),
            "capabilities": .array(BrowserControl.capabilities.map(JSONValue.string)),
        ])
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await Self.load(request, in: HermesClient.defaultSession)
        guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse("not HTTP") }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard http.statusCode == 201 || http.statusCode == 200 else {
            // `{"error": {"message", "code"}}` (`_error_response`), or aiohttp's bare 404 on a Hermes
            // without the route.
            let error = json["error"]
            throw BrowserControlRefusal.from(status: http.statusCode, code: error?["code"]?.stringValue,
                                             message: error?["message"]?.stringValue)
        }
        guard let ticket = BrowserControlTicket(json: json) else { throw HermesError.invalidResponse("no browser-control ticket") }
        return ticket
    }

    /// The controller socket for a ticket: `GET <ws_path>` with the ticket as a WebSocket
    /// protocol, never in the URL (it would land in access logs).
    public func browserControlSocket(_ ticket: BrowserControlTicket) -> URLSessionWebSocketTask? {
        guard let url = browserControlSocketURL(path: ticket.socketPath) else { return nil }
        return HermesClient.defaultSession.webSocketTask(with: url, protocols: ticket.protocols)
    }

    /// `ws(s)://<gateway>/<path>`, with nothing in the query.
    func browserControlSocketURL(path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        components.query = nil
        return components.url
    }
}
