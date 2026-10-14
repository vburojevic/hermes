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
        case .server(_, _, let message):
            message ?? "Hermes ran into a problem."
        case .unreachable(let host, let reason):
            switch reason {
            case .offline: "You're offline."
            case .timedOut: "\(host) took too long to respond."
            case .connectionLost: "The connection to \(host) was lost."
            case .insecure: "This connection must use HTTPS."
            case .tls: "A secure connection to \(host) couldn't be established. Check its TLS certificate."
            case .cannotConnect, .other: "Can't reach Hermes at \(host)."
            }
        case .invalidResponse(let detail):
            "Hermes sent a response this app doesn't understand (\(detail))."
        case .unsupportedServer:
            "This Hermes gateway is too old for the app. Run `hermes update`, then restart the gateway."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreachable(let host, .cannotConnect), .unreachable(let host, .timedOut), .unreachable(let host, .other):
            Self.isTailnet(host)
                ? "This is a Tailscale address: turn on Tailscale on this device, and check that the computer running Hermes is awake."
                : "Make sure `hermes gateway` is running with API_SERVER_ENABLED=true, and that API_SERVER_HOST allows connections from this device."
        case .unauthorized:
            "Profile URLs (/p/<name>) need that profile's own key."
        case .missingAPIKey:
            "Add the key in Settings → Hermes Gateways."
        default:
            nil
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
           let envelope = try? JSONDecoder().decode(JSONValue.self, from: body) {
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
