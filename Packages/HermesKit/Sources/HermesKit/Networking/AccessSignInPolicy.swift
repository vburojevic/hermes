import Foundation

/// Where the access gateway's sign-in page may take the in-app sign-in sheet
/// (`docs/connecting-and-voice.md` §11.10). The page is untrusted content: it loads the gateway's
/// own address and the sign-in addresses the access gateway sends it through (its redirects and
/// forms), and nothing else. A link the person taps to anywhere else opens in the browser, and so
/// does a new window. Kept here, out of the view, so it can be tested.
public struct AccessSignInPolicy: Sendable {
    public enum Navigation: Sendable {
        /// The person tapped a link.
        case link
        /// A form was sent.
        case form
        /// A redirect, the page's own script, a reload or going back.
        case other
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Not here: it opens in the browser through `WebLink`.
        case openOutside(URL)
        case cancel
    }

    public let gateway: URL
    private let gatewayOrigin: GatewayAccessRegistry.Origin?
    /// The addresses the sign-in went through so far, the gateway's first.
    public private(set) var visited: Set<String>

    public init(gateway: URL) {
        self.gateway = gateway
        gatewayOrigin = GatewayAccessRegistry.Origin(gateway)
        visited = gatewayOrigin.map { [Self.key($0)] } ?? []
    }

    /// Where the sheet starts: the gateway's health check, which the access gateway stands in
    /// front of like every other address, and which answers once it lets the app through.
    public var start: URL {
        gateway.appending(path: "health")
    }

    /// What to do with a navigation to `url`. `isNewWindow` is a page asking for another window
    /// (`target="_blank"`, `window.open`), which the sheet never opens.
    public mutating func decide(_ url: URL, navigation: Navigation, isMainFrame: Bool, isNewWindow: Bool = false) -> Decision {
        if url.scheme?.lowercased() == "about" { return isNewWindow ? .cancel : .allow }
        guard let origin = GatewayAccessRegistry.Origin(url), WebLink.isWeb(url) else { return .cancel }
        let key = Self.key(origin)
        if isNewWindow { return .openOutside(url) }
        // Plain http only to the gateway itself (the person chose its address) or on a local
        // network; on the internet a sign-in over http could be read and changed in transit.
        guard origin == gatewayOrigin || WebLink.loadsByItself(url) else {
            return navigation == .link ? .openOutside(url) : .cancel
        }
        guard isMainFrame else { return .allow }
        switch navigation {
        case .link:
            return visited.contains(key) ? .allow : .openOutside(url)
        case .form, .other:
            visited.insert(key)
            return .allow
        }
    }

    /// Whether a page the sheet got is the gateway answering past the access gateway: a main
    /// frame from the gateway's own address that isn't a refusal. Its cookies are the session.
    public func isThrough(_ url: URL, status: Int, isMainFrame: Bool) -> Bool {
        isMainFrame && (200..<300).contains(status) && GatewayAccessRegistry.Origin(url) == gatewayOrigin
    }

    /// Whether a client certificate challenge from `host` and `port` is the gateway's own proxy,
    /// the one place its certificate goes.
    public func isGatewayHandshake(host: String, port: Int) -> Bool {
        GatewayAccessRegistry.Origin(host: host, port: port, isSecure: true) == gatewayOrigin
    }

    private static func key(_ origin: GatewayAccessRegistry.Origin) -> String {
        "\(origin.scheme)://\(origin.host):\(origin.port)"
    }
}
