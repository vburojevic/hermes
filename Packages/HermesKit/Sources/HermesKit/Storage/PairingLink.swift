import Foundation

/// A gateway's connection details as a link: what a pairing QR code holds.
///
/// Scanning it on another device connects that device to the same Hermes: the gateway and its
/// API key, plus the Bot Mode backend when there is one. Session cookies never travel; a
/// password-gated backend asks for its password on the new device.
///
/// The link is `https://hermesapp.dev/connect#…`, a universal link only the Hermes app opens (the
/// site's apple-app-site-association names it), with the details in the fragment, which a browser
/// never sends: on a phone without Hermes, Safari opens the site's page and the key goes nowhere.
/// A `hermesapp://connect` link, which codes from older builds hold and which still connects,
/// could be handed to any app that claims the scheme (security scan F10, F17).
public struct PairingLink: Equatable, Sendable {
    /// The scheme older pairing codes and the app's other links use; the App Store app opens it.
    public static let scheme = "hermesapp"
    /// The universal link pairing codes use.
    public static let universalHost = "hermesapp.dev"
    public static let universalPath = "/connect"
    /// Debug builds register their own scheme so they don't take links from the real app.
    public static let acceptedSchemes: Set<String> = [scheme, "hermesapp-dev"]

    public var name: String
    public var gateway: URL
    public var apiKey: String
    public var backend: BackendLink?
    /// The backend's session token, for the `.token` sign-in only.
    public var backendToken: String?

    public init(name: String, gateway: URL, apiKey: String, backend: BackendLink? = nil, backendToken: String? = nil) {
        self.name = name
        self.gateway = gateway
        self.apiKey = apiKey
        self.backend = backend
        self.backendToken = backend?.signIn == .token ? backendToken : nil
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.universalHost
        components.path = Self.universalPath
        var items = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "gateway", value: gateway.absoluteString),
            URLQueryItem(name: "key", value: apiKey),
        ]
        if let backend {
            items.append(URLQueryItem(name: "backend", value: backend.url.absoluteString))
            items.append(URLQueryItem(name: "signin", value: backend.signIn.rawValue))
            if let username = backend.username, !username.isEmpty {
                items.append(URLQueryItem(name: "user", value: username))
            }
            if let backendToken {
                items.append(URLQueryItem(name: "token", value: backendToken))
            }
        }
        // Only unreserved characters stay literal, so `&`, `=` and `+` in a key or name survive any parser.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var details = URLComponents()
        details.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreserved))
        }
        components.percentEncodedFragment = details.percentEncodedQuery
        return components.url!
    }

    /// A pairing link: the universal link with its details in the fragment, or an older code's
    /// `hermesapp://connect?…`.
    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        var details: URLComponents?
        if scheme == "https", url.host()?.lowercased() == Self.universalHost, url.path() == Self.universalPath {
            details = URLComponents()
            details?.percentEncodedQuery = url.fragment(percentEncoded: true)
        } else if let scheme, Self.acceptedSchemes.contains(scheme), url.host()?.lowercased() == "connect" {
            details = URLComponents(url: url, resolvingAgainstBaseURL: false)
        }
        guard let items = details?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard value("v") == "1",
              let gateway = value("gateway").flatMap(BotConfiguration.normalizedURL(from:)),
              let apiKey = value("key")
        else { return nil }
        var backend: BackendLink?
        if let url = value("backend").flatMap(BackendLink.normalizedURL(from:)) {
            let signIn = value("signin").flatMap(BackendLink.SignIn.init(rawValue:)) ?? .password
            backend = BackendLink(url: url, signIn: signIn, username: signIn == .password ? value("user") : nil)
        }
        self.init(name: value("name") ?? "Hermes", gateway: gateway, apiKey: apiKey, backend: backend, backendToken: value("token"))
    }

    /// False when the gateway's address only works on the machine it was set up on
    /// (`127.0.0.1`, `localhost`): another device scanning the code couldn't reach it.
    public var isReachableFromOtherDevices: Bool {
        !Self.isLoopback(gateway)
    }

    /// The link another device can use: a Bot Mode backend on a local-only address is left out
    /// (the gateway still pairs; Bot Mode stays on this machine).
    public var forOtherDevices: PairingLink {
        guard let backend, Self.isLoopback(backend.url) else { return self }
        return PairingLink(name: name, gateway: gateway, apiKey: apiKey)
    }

    public static func isLoopback(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
