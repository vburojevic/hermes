import Foundation

// The app as Hermes's browser for one chat (`docs/web.md` §6): the browser-control contract from
// Hermes Agent's `gateway/browser_control_broker.py`, `gateway/platforms/api_server.py` (the
// register route and its socket) and `tui_gateway/methods_browser_control.py` (the same over the
// backend socket).

public enum BrowserControl {
    /// The only wire version Hermes accepts (`BROWSER_CONTROL_PROTOCOL_VERSION`).
    public static let protocolVersion = 1
    /// The socket's protocol and the prefix the one-shot ticket rides under: never in the URL.
    public static let socketProtocol = "hermes-browser-control-v1"
    public static let ticketProtocolPrefix = "hermes-browser-control-ticket."
    /// Each command's deadline on the gateway (`DEFAULT_COMMAND_TIMEOUT`).
    public static let commandTimeout: Duration = .seconds(30)
    /// What the app answers within, so a slow page fails here rather than at Hermes's deadline.
    public static let answerWithin: Duration = .seconds(25)

    /// What the app's browser does. Hermes's allowlist minus nothing a person wouldn't want: no
    /// `browser_cdp` / `browser_evaluate` (developer-only) and no artifact transfers.
    public static let capabilities = [
        "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_scroll",
        "browser_press", "browser_back", "browser_screenshot", "browser_tabs", "browser_tab_activate",
    ]

    /// What every command gets while the person has the browser (Take Over): the refusal Hermes's
    /// own browser gives while a person holds its screen (`code: human_has_control`,
    /// `tools/browser_tool_session.py`), so the model waits the same way.
    public static let personHasControl = Self.result([
        "success": .bool(false), "code": .string("human_has_control"),
        "error": .string("The person has taken over this app's browser (they may be signing in). Browser actions and reads are refused until they hand it back. Tell the user what you need in your reply."),
    ])

    /// A command's answer as the JSON text Hermes's browser tools return.
    public static func result(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? String(decoding: encoder.encode(JSONValue.object(fields)), as: UTF8.self)) ?? "{}"
    }
}

/// One command from Hermes (`browser.controller.command`).
public struct BrowserCommand: Sendable, Equatable {
    public let commandID: String
    public let action: String
    public let arguments: JSONValue
    public let toolCallID: String?

    public init(commandID: String, action: String, arguments: JSONValue = .object([:]), toolCallID: String? = nil) {
        self.commandID = commandID
        self.action = action
        self.arguments = arguments
        self.toolCallID = toolCallID
    }

    public init?(params: JSONValue) {
        guard let id = params["command_id"]?.stringValue, !id.isEmpty, let action = params["action"]?.stringValue else { return nil }
        commandID = id
        self.action = action
        arguments = params["arguments"] ?? .object([:])
        toolCallID = params["tool_call_id"]?.stringValue
    }

    public func string(_ key: String) -> String? {
        arguments[key]?.stringValue
    }
}

/// A frame the controller's socket (or the backend socket's `event`) carries to the app.
public enum BrowserControlFrame: Sendable, Equatable {
    case command(BrowserCommand)
    /// `browser.controller.cancel`: stop the command with this id, or the one for this tool call.
    case cancel(commandID: String?, toolCallID: String?)
    case heartbeat(nonce: String)
    case detached
    case other

    /// `{method, params}` on the controller socket.
    public init(json: JSONValue) {
        self.init(method: json["method"]?.stringValue, params: json["params"] ?? .object([:]))
    }

    /// The backend socket's `event` (`type`, `payload`).
    public init(method: String?, params: JSONValue) {
        switch method {
        case "browser.controller.command":
            self = BrowserCommand(params: params).map(BrowserControlFrame.command) ?? .other
        case "browser.controller.cancel":
            self = .cancel(commandID: params["command_id"]?.stringValue, toolCallID: params["tool_call_id"]?.stringValue)
        case "browser.controller.heartbeat":
            self = .heartbeat(nonce: params["nonce"]?.stringValue ?? "")
        case "browser.controller.detach":
            self = .detached
        default:
            self = .other
        }
    }
}

/// What the app answers a command with.
public struct BrowserCommandResult: Sendable, Equatable {
    public let commandID: String
    public let ok: Bool
    /// A string goes to the model as is; Hermes serializes anything else.
    public let value: JSONValue

    public init(commandID: String, ok: Bool, value: JSONValue) {
        self.commandID = commandID
        self.ok = ok
        self.value = value
    }

    public static func success(_ id: String, _ text: String) -> BrowserCommandResult {
        BrowserCommandResult(commandID: id, ok: true, value: .string(text))
    }

    public static func failure(_ id: String, _ message: String) -> BrowserCommandResult {
        BrowserCommandResult(commandID: id, ok: false, value: .string(message))
    }

    /// `browser.controller.result` params (`result` when ok, else `error`).
    public var params: [String: JSONValue] {
        ["command_id": .string(commandID), "ok": .bool(ok), ok ? "result" : "error": value]
    }

    /// The frame on the controller socket.
    public var frame: JSONValue {
        .object(["method": .string("browser.controller.result"), "params": .object(params)])
    }
}

/// `POST /v1/browser-control/register`'s answer: a one-shot ticket for the socket (30 s).
public struct BrowserControlTicket: Sendable, Equatable {
    public let ticket: String
    public let socketPath: String
    public let expiresIn: Double
    public let capabilities: [String]

    public init?(json: JSONValue) {
        guard let ticket = json["ticket"]?.stringValue, !ticket.isEmpty else { return nil }
        self.ticket = ticket
        socketPath = json["ws_path"]?.stringValue ?? "/v1/browser-control/ws"
        expiresIn = json["ticket_expires_in_seconds"]?.doubleValue ?? 30
        if case .array(let names)? = json["scope"]?["capabilities"] {
            capabilities = names.compactMap(\.stringValue)
        } else {
            capabilities = []
        }
    }

    /// The socket's protocols: the public one and the ticket. Never logged.
    public var protocols: [String] { [BrowserControl.socketProtocol, BrowserControl.ticketProtocolPrefix + ticket] }
}

/// Why the app can't be Hermes's browser, from what the gateway answered.
public enum BrowserControlRefusal: Error, Equatable, Sendable {
    /// `browser.extension_control.enabled` is off (404 `browser_control_disabled`, or 4403).
    case turnedOff
    /// A Hermes without the controller (404 with no code, -32601).
    case needsNewerHermes
    /// The API server has no key (403 `browser_control_auth_required`).
    case needsAPIKey
    /// The gateway didn't take this app's key (401).
    case keyRefused
    /// The chat isn't a session the gateway knows yet (403 `browser_control_session_forbidden`).
    case unknownSession
    /// The backend socket has no signed-in identity (Automatic sign-in): Hermes lets only an
    /// authenticated client drive its browser there (4403).
    case needsSignIn
    case other(String)

    /// From the register route's status and JSON error body.
    public static func from(status: Int, code: String?, message: String?) -> BrowserControlRefusal {
        switch (status, code) {
        case (404, "browser_control_disabled"?): .turnedOff
        case (404, _), (400, "browser_control_protocol_unsupported"?): .needsNewerHermes
        case (401, _): .keyRefused
        case (403, "browser_control_auth_required"?): .needsAPIKey
        case (403, "browser_control_session_forbidden"?): .unknownSession
        default: .other(message ?? "HTTP \(status)")
        }
    }

    /// From `browser.controller.register` on the backend socket.
    public static func from(rpc error: GatewayRPCError) -> BrowserControlRefusal {
        if error.code == -32601 { return .needsNewerHermes }
        guard error.code == 4403 else { return .other(error.message) }
        if error.message.contains("extension_control") { return .turnedOff }
        if error.message.contains("identity") { return .needsSignIn }
        if error.message.contains("protocol") { return .needsNewerHermes }
        return .other(error.message)
    }
}
