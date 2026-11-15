import Foundation

/// Everything that can go wrong talking to a gateway, phrased for people.
public enum HermesError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey
    /// The Keychain can't confirm yet where the key may go (`BotStore.isVerified`), so it isn't read.
    case keychainUnavailable
    case unauthorized
    case notFound(message: String?)
    case rateLimited
    case gatewayRestarting
    case requestTooLarge
    case server(status: Int, code: String?, message: String?)
    case unreachable(host: String, reason: Reason)
    case invalidResponse(String)
    case unsupportedServer
    /// An access gateway or a proxy in front of Hermes stopped the request before Hermes saw it
    /// (`AccessRefusal`, `docs/connecting-and-voice.md` §11.2).
    case accessRefused(host: String, AccessRefusal)

    public enum Reason: Sendable, Equatable {
        case cannotConnect, timedOut, offline, connectionLost, insecure, tls, other(String)
        /// A setting on this device is in the way, not the network or the gateway.
        case mobileDataOff, wifiOff, localNetworkDenied
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key is saved for this gateway on this device."
        case .keychainUnavailable:
            "Hermes can't read this gateway's key from the Keychain right now. Try again in a moment."
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
        case .accessRefused(let host, let refusal):
            switch refusal {
            case .signInNeeded: "An access gateway at \(host) answered, not Hermes."
            case .signInExpired: "Your sign-in to the access gateway at \(host) expired."
            case .tokenRejected: "The access gateway at \(host) refused the service token."
            case .certificateNeeded: "The proxy at \(host) asks for a client certificate."
            case .certificateRejected: "The proxy at \(host) refused the client certificate."
            case .certificateExpired: "The proxy at \(host) refused the client certificate, which has expired."
            }
        }
    }

    /// The access gateway's or proxy's refusal, when that's what this is.
    public var accessRefusal: AccessRefusal? {
        if case .accessRefused(_, let refusal) = self { refusal } else { nil }
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
        case .accessRefused(_, .signInNeeded):
            "Set up a service token for this gateway in Edit Gateway → Access."
        case .accessRefused(_, .signInExpired):
            "Sign in again in Edit Gateway → Access."
        case .accessRefused(_, .tokenRejected):
            "Check the client ID and secret, and that the token is allowed for this gateway and hasn't expired."
        case .accessRefused(_, .certificateNeeded):
            "Import the client certificate in Edit Gateway → Access."
        case .accessRefused(_, .certificateRejected), .accessRefused(_, .certificateExpired):
            "Replace the client certificate in Edit Gateway → Access."
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
        case .rateLimited, .gatewayRestarting, .unreachable, .keychainUnavailable: true
        case .server(let status, _, _): status >= 500
        default: false
        }
    }

    /// Whether a connection kept in the background should keep trying after this. Besides the
    /// transient failures, a proxy's certificate refusal: the app reads it from a TLS failure, and
    /// on TLS 1.3 that can't be told for sure from a connection that dropped just then, so the
    /// certificate state shows while the checks go on (`docs/connecting-and-voice.md` §11.9).
    public var keepsChecking: Bool {
        switch self {
        case .accessRefused(_, .certificateNeeded), .accessRefused(_, .certificateRejected),
             .accessRefused(_, .certificateExpired):
            true
        default:
            isTransient
        }
    }

    /// An access gateway answered and turned the app away for a sign-in or a token: no retry gets
    /// through until the person signs in or fixes Access, so reconnect loops stop and wait for
    /// that (`docs/connecting-and-voice.md` §11.10).
    public var waitsForAccess: Bool {
        accessRefusal != nil && !keepsChecking
    }

    /// `afterAnswer` says the request already had its answer when it failed (a stream that
    /// dropped): its handshake went through, so the failure is never a proxy's refusal, however
    /// recently that origin asked for a certificate.
    public static func from(urlError: URLError, host: String, afterAnswer: Bool = false) -> HermesError {
        if !afterAnswer, let refusal = AccessRefusal.classify(urlError) { return .accessRefused(host: host, refusal) }
        let reason: Reason = switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut: .timedOut
        case .networkConnectionLost: .connectionLost
        case .appTransportSecurityRequiresSecureConnection: .insecure
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            .tls
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse: .cannotConnect
        default: .other(urlError.localizedDescription)
        }
        return .unreachable(host: host, reason: reason)
    }

    /// Maps an HTTP error response to a request to `url`: an access gateway's refusal first
    /// (`AccessRefusal.classify`), so its sign-in page is never read as Hermes's own 401, then
    /// Hermes's answer (`from(status:body:contentType:)`).
    static func from(_ response: HTTPURLResponse, body: Data, url: URL?) -> HermesError {
        if let refusal = AccessRefusal.classify(response, body: body, to: url) {
            return .accessRefused(host: url?.host() ?? response.url?.host() ?? "", refusal)
        }
        return from(status: response.statusCode, body: body, contentType: response.value(forHTTPHeaderField: "Content-Type"))
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
