import Foundation

// Hermes using the Preview (`docs/inspector.md` §2): with sessions started as the `desktop`
// platform, Hermes's `desktop_preview` and `drive_preview` tools reach the app as events
// (`preview.open`, `preview.close`) and server requests (`preview.read`, `preview.act`,
// `terminal.read`, `window.read`), answered with `{value: "<json>"}`. A window that isn't
// showing the chat declines with 4404 so the gateway stops waiting at once.

public enum PreviewBridge {
    /// The platform sessions start as, so Hermes gets its preview tools. The gateway takes a
    /// client's `source` as is (`tui_gateway/methods_session.py`).
    public static let sessionSource = "desktop"
    /// "No window is showing this chat" (`server_requests.NOT_SHOWN_CODE`).
    public static let notShownCode = 4404
    public static let requestMethods: Set<String> = ["preview.read", "preview.act", "terminal.read", "window.read"]

    /// The JSON text a bridge request answers with, as the gateway's `ValueResult`.
    public static func answer(_ object: [String: JSONValue]) -> JSONValue {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
        return .object(["value": .string(String(decoding: data, as: UTF8.self))])
    }

    /// What `preview.read` returns: the page's visible text in pages (`start`, `count`).
    public static func readAnswer(kind: String, url: String, title: String, text: String, start: Int?, count: Int?) -> JSONValue {
        let characters = Array(text)
        let total = characters.count
        let from = min(max(start ?? 0, 0), total)
        let length = min(max(count ?? 8000, 1), 20_000)
        let to = min(from + length, total)
        return answer([
            "kind": .string(kind), "url": .string(url), "title": .string(title),
            "text": .string(String(characters[from..<to])),
            "start": .number(Double(from)), "end": .number(Double(to)), "total_chars": .number(Double(total)),
        ])
    }
}

/// One `preview.act` request (`tools/drive_preview_tool.py`).
public struct PreviewAction: Sendable, Hashable {
    public enum Verb: String, Sendable {
        case elements, click, hover, type, scroll, press, strobe, back, forward, reload
    }

    public var verb: Verb
    public var ref: String?
    public var selector: String?
    public var text: String?
    public var key: String?
    public var submit: Bool
    public var full: Bool
    public var to: String?
    public var amount: Int?
    public var max: Int?
    public var allowShortcut: Bool

    public init?(params: JSONValue) {
        guard let raw = params["action"]?.stringValue?.lowercased(), let verb = Verb(rawValue: raw) else { return nil }
        self.verb = verb
        ref = params["ref"]?.stringValue
        selector = params["selector"]?.stringValue
        text = params["text"]?.stringValue
        key = params["key"]?.stringValue
        submit = params["submit"]?.boolValue ?? false
        full = params["full"]?.boolValue ?? false
        to = params["to"]?.stringValue
        // Model-written numbers ("1e300", "nan"): read without a trap and held to what a page can use.
        amount = params["amount"]?.truncatedIntValue.map { Swift.min(Swift.max($0, -10_000_000), 10_000_000) }
        max = params["max"]?.truncatedIntValue.map { Swift.min(Swift.max($0, 1), 500) }
        allowShortcut = params["allow_shortcut"]?.boolValue ?? false
    }

    /// Verbs that change the page (so the person sees the target ringed first).
    public var actsOnElement: Bool { [.click, .hover, .type, .press].contains(verb) }

    /// "click", "type": what the highlight's label says.
    public var label: String { verb.rawValue }

    /// The arguments the in-page engine reads, as JSON.
    public var engineArguments: String {
        var object: [String: JSONValue] = ["kind": .string(verb.rawValue), "submit": .bool(submit), "full": .bool(full),
                                           "allowShortcut": .bool(allowShortcut)]
        if let ref { object["ref"] = .string(ref) }
        if let selector { object["selector"] = .string(selector) }
        if let text { object["text"] = .string(text) }
        if let key { object["key"] = .string(key) }
        if let to { object["to"] = .string(to) }
        if let amount { object["amount"] = .number(Double(amount)) }
        if let max { object["max"] = .number(Double(max)) }
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where a Preview tab points, and how this device reaches it (`docs/inspector.md` §3).
public struct PreviewTarget: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A page on the web.
        case web
        /// A dev server on the gateway machine (`localhost:5173`).
        case localhost(port: Int?)
        /// A file on the gateway (HTML renders; PDFs and images show).
        case gatewayFile(path: String)
    }

    public var kind: Kind
    /// What the person and Hermes call it ("localhost:5173/beta").
    public var displayURL: String
    /// The URL as Hermes gave it.
    public var url: URL?

    /// Reads what `preview.open` sends: a URL, a bare domain, `localhost:5173`, or a file path.
    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("file://") {
            let path = trimmed.hasPrefix("file://") ? (URL(string: trimmed)?.path ?? trimmed) : trimmed
            kind = .gatewayFile(path: path)
            displayURL = ProjectPath.lastComponent(path)
            url = nil
            return
        }
        var candidate = trimmed
        if !candidate.contains("://") {
            let host = candidate.split(separator: "/").first.map(String.init) ?? candidate
            let isLocal = Self.isLocalHost(host.split(separator: ":").first.map(String.init) ?? host)
            candidate = (isLocal ? "http://" : "https://") + candidate
        }
        let parsed = URL(string: candidate)
        url = parsed
        if let parsed, let host = parsed.host(), Self.isLocalHost(host) {
            kind = .localhost(port: parsed.port)
            var display = "localhost" + (parsed.port.map { ":\($0)" } ?? "")
            let path = parsed.path()
            if !path.isEmpty, path != "/" { display += path }
            displayURL = display
        } else {
            kind = .web
            displayURL = parsed.map { ($0.host() ?? "") + ($0.path() == "/" ? "" : $0.path()) } ?? trimmed
        }
    }

    public static func isLocalHost(_ host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "0.0.0.0" || lowered == "::1" || lowered.hasSuffix(".localhost")
    }

    public var isLocalhost: Bool {
        if case .localhost = kind { true } else { false }
    }

    /// The same page through the gateway machine's host name (its tailnet name), for a device
    /// that isn't that machine. Nil when there's nothing to rewrite.
    public func rewritten(toHost host: String) -> URL? {
        guard isLocalhost, let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = host
        return components.url
    }

    /// Whether two Preview tabs show the same thing (`preview.open` focuses an open tab).
    public func matches(_ other: String) -> Bool {
        let theirs = PreviewTarget(other)
        if case .gatewayFile(let a) = kind, case .gatewayFile(let b) = theirs.kind { return a == b }
        guard let mine = url, let other = theirs.url else { return false }
        return mine.host() == other.host() && mine.port == other.port
            && (mine.path() == other.path() || theirs.displayURL == displayURL || other.path().isEmpty || other.path() == "/")
    }
}

/// Which gateway files a Preview page may read (`hermes-fs://gateway/<path>`): the folders of
/// the files opened in its tab and what's below them, never anything hidden below them, never a
/// path that steps up (`..`). A page's script then can't fetch `~/.ssh` or another project.
///
/// The gateway follows symlinks, so the path's text isn't enough: a link inside the folder
/// (`keys -> ../../.ssh`) would lead anywhere. Each file is checked again where the gateway says
/// it really is (`allows(_:resolvedTo:)`), against where the opened file really is.
public struct PreviewFileAccess: Sendable {
    private struct Root: Sendable {
        /// The name of the file the tab opened in this folder.
        var file: Substring
        /// Where the folder really is, learned when the opened file was first read.
        var resolved: [Substring]?
    }

    private var roots: [[Substring]: Root] = [:]

    public init() {}

    /// The tab opened this file: its folder can be read. A file at the top (`/index.html`)
    /// opens nothing else.
    public mutating func allowFolder(ofFile path: String) {
        guard let parts = Self.components(path), parts.count >= 2, let file = parts.last else { return }
        let root = Array(parts.dropLast())
        if roots[root] == nil { roots[root] = Root(file: file) }
    }

    /// By the path alone: inside an opened folder.
    public func allows(_ path: String) -> Bool {
        guard let parts = Self.components(path) else { return false }
        return roots.keys.contains { Self.isBelow(parts, $0) }
    }

    /// By where the gateway resolved the path to: inside the real place of an opened folder it's
    /// in. The opened file itself, read first, teaches its folder's real place.
    public mutating func allows(_ path: String, resolvedTo resolved: String) -> Bool {
        guard let parts = Self.components(path), let real = Self.components(resolved) else { return false }
        for (root, entry) in roots where Self.isBelow(parts, root) {
            if let base = entry.resolved {
                if Self.isBelow(real, base) { return true }
            } else if parts.count == root.count + 1, parts.last == entry.file, real.count >= 2 {
                roots[root]?.resolved = Array(real.dropLast())
                return true
            }
        }
        return false
    }

    private static func isBelow(_ parts: [Substring], _ root: [Substring]) -> Bool {
        parts.count > root.count && parts.starts(with: root) && !parts.dropFirst(root.count).contains { $0.hasPrefix(".") }
    }

    /// The path's components; nil when it steps up or sideways (`..`, `.`).
    static func components(_ path: String) -> [Substring]? {
        let parts = path.split(separator: "/")
        return parts.contains(where: { $0 == ".." || $0 == "." }) ? nil : parts
    }
}
