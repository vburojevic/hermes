import Foundation

/// Which links the app follows. Chat text, tool results and Board checks come from pages,
/// emails and files Hermes read, so a link in them is only followed to the web: never to this
/// app's own scheme (pairing, installs), to files or to other apps.
public enum WebLink {
    /// http or https.
    public static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "https" || scheme == "http") && url.host() != nil
    }

    /// A link in a chat: the web, and mail.
    public static func opensFromChat(_ url: URL) -> Bool {
        isWeb(url) || url.scheme?.lowercased() == "mailto"
    }

    /// On the gateway itself (`gatewayHosts`, `BotConfiguration.hosts`): a reply's picture from
    /// there shows by itself. One from anywhere else, this device's network included, waits for a
    /// tap: fetching it tells that server the chat was read, from where, and whatever its address
    /// carries, and a private address would let a reply send requests into whatever network this
    /// device is on.
    public static func isOnGateway(_ url: URL, gatewayHosts: Set<String>) -> Bool {
        isWeb(url) && (url.host().map { gatewayHosts.contains($0.lowercased()) } ?? false)
    }

    /// Whether a picture may travel this way: https anywhere, plain http only on a local network
    /// (on the internet it can be read and swapped in transit). Where it may come from without a
    /// tap is `isOnGateway`.
    public static func loadsByItself(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": url.host() != nil
        case "http": url.host().map(BotConfiguration.looksLocal) ?? false
        default: false
        }
    }
}

/// A file on the gateway that a reply names: a link to it (`[notes](/Users/me/notes.md)`,
/// `~/notes.md`, `file:///…`), or inline code that is one whole path to a file. It opens in the
/// chat's Inspector, read-only and through the gateway, which refuses `.env` files and credential
/// stores; never through the system or another app (`docs/inspector.md` §2). Only what's found
/// here becomes such a link: a reply that writes the app's own scheme gets nothing.
public enum GatewayFileLink {
    static let scheme = "x-hermes-gateway-file"

    /// A link's destination, when it names a file: an absolute or home path, or a local `file:` URL.
    public static func path(fromLink destination: String) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("file:") {
            guard let url = URL(string: trimmed), (url.host() ?? "").isEmpty || url.host() == "localhost" else { return nil }
            return file(url.path(percentEncoded: false))
        }
        return file(trimmed.removingPercentEncoding ?? trimmed)
    }

    /// Inline code that is a whole path to a file, not a command or a route: it starts at `/` or
    /// `~/`, holds no shell characters, and ends in a file name with an extension. A trailing
    /// line number (`:42`, `:42:7`, `#L42`) is left out.
    public static func path(fromCode code: String) -> String? {
        let text = code.trimmingCharacters(in: .whitespaces)
        // Asked of every inline code span a reply draws: most aren't paths, and are told so
        // before the regular expressions run.
        guard text.hasPrefix("/") || text.hasPrefix("~/") else { return nil }
        guard !text.contains(where: { $0.isNewline || "*?$|;&<>`\"'".contains($0) }) else { return nil }
        let line = /(:\d+(:\d+)?|#L\d+(-L?\d+)?)$/
        return file(text.replacing(line, with: ""))
    }

    /// The link the app gives such a path in a reply's text.
    public static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The path behind a link this app made (`url(for:)`).
    public static func path(from url: URL) -> String? {
        guard url.scheme == scheme, url.host() == "open" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
    }

    /// Absolute or home, and a file with an extension (a folder, `/usr/bin/env` or `/health`
    /// isn't one; nor is a hidden name like `.zshrc`).
    private static func file(_ path: String) -> String? {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), !path.hasPrefix("//") else { return nil }
        guard let name = path.split(separator: "/").last, name.wholeMatch(of: /[^.].*\.[A-Za-z0-9]{1,10}/) != nil else { return nil }
        return path
    }
}

/// Keeps a session's requests on the server they were made to. A redirect to another host or
/// port, or from https down to http, isn't followed, so a key or cookie sent with the request
/// never reaches a third party; the 3xx comes back as the answer instead.
public final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = SameOriginRedirects()

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url else { return nil }
        return Self.allows(from: from, to: to) ? request : nil
    }

    /// Same host; same scheme and port, or http upgraded to https.
    public static func allows(from: URL, to: URL) -> Bool {
        guard let fromHost = from.host()?.lowercased(), fromHost == to.host()?.lowercased() else { return false }
        switch (from.scheme?.lowercased(), to.scheme?.lowercased()) {
        case ("https", "https"), ("http", "http"):
            return port(of: from) == port(of: to)
        case ("http", "https"):
            return true
        default:
            return false
        }
    }

    private static func port(of url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
