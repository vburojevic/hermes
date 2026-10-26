import Foundation

/// Everything that can go wrong talking to a gateway, phrased for people.
public enum HermesError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    case unauthorized
    case notFound(message: String?)
    case rateLimited
    case gatewayRestarting
    case requestTooLarge
    case server(status: Int, code: String?, message: String?)
    case unreachable(host: String, reason: Reason)
    case invalidResponse(String)
    case unsupportedServer

    public enum Reason: Sendable, Equatable {
        case cannotConnect, timedOut, offline, connectionLost, insecure, tls, other(String)
        /// A setting on this device is in the way, not the network or the gateway.
        case mobileDataOff, wifiOff, localNetworkDenied
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key is saved for this gateway on this device."
        case .unauthorized:
            "Hermes rejected the API key. Check API_SERVER_KEY in the gateway's .env file."
        case .notFound(let message):
            message ?? "Hermes doesn't recognise this request."
        case .rateLimited:
            "Hermes is busy with other runs. Try again in a moment."
        case .gatewayRestarting:
            "Hermes is restarting. Try again in a moment."
        case .requestTooLarge:
            "That message is too large for Hermes (10 MB limit). Try fewer or smaller images."
        case .server(_, let code, let message):
            // The API server's store refusals carry their bare reason as the message.
            code.flatMap { message == $0 ? Self.storeRefusals[$0] : nil } ?? message ?? "Hermes ran into a problem."
        case .unreachable(let host, let reason):
            switch reason {
            case .offline: "You're offline."
            case .timedOut: "\(host) took too long to respond."
            case .connectionLost: "The connection to \(host) was lost."
            case .insecure: "This connection must use HTTPS."
            case .tls: "A secure connection to \(host) couldn't be established. Check its TLS certificate."
            case .cannotConnect, .other: "Can't reach Hermes at \(host)."
            case .mobileDataOff: "Mobile Data is off for Hermes."
            case .wifiOff: "Wi-Fi is off for Hermes."
            case .localNetworkDenied: "Hermes isn't allowed on your local network."
            }
        case .invalidResponse(let detail):
            "Hermes sent a response this app doesn't understand (\(detail))."
        case .unsupportedServer:
            "This Hermes gateway is too old for the app. Run `hermes update`, then restart the gateway."
        }
    }

    /// Hermes refused a message, in its words (`SendRefusal.line`).
    public static func refused(_ line: String) -> HermesError {
        .server(status: 409, code: "refused", message: line)
    }

    /// Hermes refused the request for a reason of its own (a 409 or 429 from the API server, a
    /// store refusal, a 4090 the app can't wait out) rather than failing: the chat shows it in
    /// Hermes's words, never as a red error.
    public var isRefusal: Bool {
        guard case .server(let status, let code, _) = self else { return false }
        return status == 409 || status == 429 || code.map { Self.storeRefusals[$0] != nil } ?? false
    }

    /// Whether sending it again right away can help: not for a chat Hermes no longer has, or one
    /// only the gateway's own connection can take (`refusedBanner` then has no Try Again).
    public var refusalOffersRetry: Bool {
        guard case .server(_, let code, _) = self else { return false }
        return code != "not_found" && code != "permission_denied"
    }

    /// The API server's refusals that come with only their reason (hermes-agent
    /// `gateway/platforms/api_server_authority_runs.py`), in words.
    static let storeRefusals: [String: String] = [
        "permission_denied": "This chat belongs to the gateway's own chats, so it can't take a message over the API server. Send it again when the connection to the gateway is back.",
        "queue_full": "Hermes already has as many messages waiting in this chat as it takes. Send it again when some have run.",
        "admission_conflict": "Hermes is settling another message in this chat. Send it again in a moment.",
        "not_found": "Hermes doesn't have this chat any more.",
    ]

    public var recoverySuggestion: String? {
        switch self {
        case .unreachable(let host, .cannotConnect), .unreachable(let host, .timedOut), .unreachable(let host, .other):
            Self.isTailnet(host)
                ? "This is a Tailscale address: turn on Tailscale on this device, and check that the computer running Hermes is awake."
                : "Make sure `hermes gateway` is running with API_SERVER_ENABLED=true, and that API_SERVER_HOST allows connections from this device."
        case .unreachable(_, .mobileDataOff):
            "Turn on Mobile Data for Hermes in Settings, or join Wi-Fi."
        case .unreachable(_, .wifiOff):
            "Allow Wi-Fi for Hermes in Settings, or use Mobile Data."
        case .unreachable(let host, .localNetworkDenied):
            "\(host) is on your local network. Turn on Local Network for Hermes in Settings → Privacy & Security → Local Network."
        case .unauthorized:
            "Profile URLs (/p/<name>) need that profile's own key."
        case .missingAPIKey:
            "Add the key in Settings → Hermes Gateways."
        default:
            nil
        }
    }

    /// An address on a local network (private IPv4 ranges, link-local, `.local` names), which
    /// needs local network access (TN3179). Tailnet addresses aren't: they go over the VPN.
    public static func isLocalNetwork(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".local") || host.hasPrefix("fe80:") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 != nil }), let first = octets[0], let second = octets[1] else { return false }
        switch first {
        case 10: return true
        case 172: return (16...31).contains(second)
        case 192: return second == 168
        case 169: return second == 254
        default: return false
        }
    }

    /// A Tailscale MagicDNS name or tailnet address (100.64.0.0/10), reachable only while
    /// Tailscale is on.
    public static func isTailnet(_ host: String) -> Bool {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard octets.count == 4, let first = octets[0], let second = octets[1], octets.allSatisfy({ $0 != nil }) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    /// Whether retrying the same request later could succeed.
    /// The gateway didn't answer in time (as opposed to being unreachable or refusing).
    public var isTimeout: Bool {
        if case .unreachable(_, .timedOut) = self { true } else { false }
    }

    public var isTransient: Bool {
        switch self {
        case .rateLimited, .gatewayRestarting, .unreachable: true
        case .server(let status, _, _): status >= 500
        default: false
        }
    }

    public static func from(urlError: URLError, host: String) -> HermesError {
        let reason: Reason = switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut: .timedOut
        case .networkConnectionLost: .connectionLost
        case .appTransportSecurityRequiresSecureConnection: .insecure
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            .tls
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse: .cannotConnect
        default: .other(urlError.localizedDescription)
        }
        return .unreachable(host: host, reason: reason)
    }

    /// Maps an HTTP error response, decoding whichever error envelope the route used.
    static func from(status: Int, body: Data, contentType: String?) -> HermesError {
        var code: String?
        var message: String?
        if contentType?.contains("json") == true || body.first == UInt8(ascii: "{"),
           let envelope = JSONValue.parse(body) {
            if let text = envelope["error"]?.stringValue {
                message = text
            } else if let error = envelope["error"] {
                message = error["message"]?.stringValue
                code = error["code"]?.stringValue
            }
        } else if let text = String(data: body.prefix(300), encoding: .utf8), !text.isEmpty {
            message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch (status, code) {
        case (401, _), (403, _): return .unauthorized
        case (413, _), (_, "body_too_large"): return .requestTooLarge
        case (429, _): return .rateLimited
        case (503, "gateway_draining"): return .gatewayRestarting
        case (404, _):
            if message == "404: Not Found" { return .unsupportedServer }
            return .notFound(message: message)
        default:
            return .server(status: status, code: code, message: message)
        }
    }
}
