import Foundation

/// `::preview{file="dashboards/q3.html" height="360"}`: a page a reply shows live, on a line of its
/// own (`docs/chat.md` §3c). Mirrors Hermes Desktop's inline preview: the file is read through the
/// gateway once the reply is whole, and `height` is only where it starts, since the page is
/// measured once it draws.
public struct PreviewDirective: Hashable, Sendable {
    /// The file as the reply names it: absolute, `~/…` or relative to the chat's folder.
    public var file: String
    /// The height asked for, already kept to `minHeight...maxHeight`.
    public var height: Int?

    public init(file: String, height: Int? = nil) {
        self.file = file
        self.height = height.map(Self.clamp)
    }

    public static let minHeight = 120
    public static let maxHeight = 1200
    public static let defaultHeight = 280
    /// A page never draws wider than this, as on the desktop.
    public static let maxWidth = 960
    /// Height changes smaller than this are rounding, not the page growing.
    public static let resizeTolerance = 4
    static let maxLength = 2048

    /// The directive on one line, or `nil` when the line is anything else.
    public static func parse(_ line: some StringProtocol) -> PreviewDirective? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.utf8.count <= maxLength, line.hasPrefix("::preview{"), line.hasSuffix("}") else { return nil }
        let body = line.dropFirst("::preview{".count).dropLast()
        guard !body.contains("{"), !body.contains("}"),
              let attributes = WidgetDirective.parseAttributes(body, singleQuotes: true),
              let file = attributes["file"]?.trimmingCharacters(in: .whitespaces), !file.isEmpty,
              !file.contains(where: \.isNewline) else { return nil }
        return PreviewDirective(file: file, height: attributes["height"].flatMap(Self.height))
    }

    /// A whole number of points, as the desktop reads it; anything else asks for no height.
    static func height(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return clamp(value)
    }

    public static func clamp(_ height: Int) -> Int { min(maxHeight, max(minHeight, height)) }

    /// A measured height in the page's band, or `nil` for a report that can't be one.
    public static func measured(_ height: Double) -> Int? {
        guard height.isFinite, height > 0 else { return nil }
        return clamp(Int(height.rounded()))
    }

    /// Only a web page opens live; any other file shows as a file.
    public var isPage: Bool {
        let lower = fileName.lowercased()
        return lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xhtml")
    }

    /// The file's own name, the last part of its path.
    public var fileName: String {
        let trimmed = file.hasSuffix("/") ? String(file.dropLast()) : file
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// The path the gateway reads: an absolute or home path as it is, a relative one joined onto
    /// the chat's folder, as Hermes Desktop resolves it against the chat's folder. Nil for a
    /// relative path with no folder, or one with a `..` step: a page never reads above the folder
    /// it names.
    public func path(in folder: String?) -> String? {
        guard !file.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        if file.hasPrefix("/") || file.hasPrefix("~") { return file }
        guard let folder, !folder.isEmpty else { return nil }
        var relative = Substring(file)
        while relative.hasPrefix("./") { relative = relative.dropFirst(2) }
        guard !relative.isEmpty else { return nil }
        return (folder.hasSuffix("/") ? String(folder.dropLast()) : folder) + "/" + relative
    }

    /// Where the page starts before it is measured.
    public var startHeight: Int { height ?? Self.defaultHeight }

    /// The directive as a line of a reply.
    public var line: String {
        let escaped = file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "::preview{file=\"\(escaped)\"" + (height.map { " height=\"\($0)\"" } ?? "") + "}"
    }
}

/// What a live page asks with `hermes.send("…")` (`docs/chat.md` §3c): a sentence the chat sends
/// as a hidden message of the person's, checked here before anything is sent. The rules and the
/// answers are Hermes Desktop's, so a page made for one works in the other.
public enum PageIntent {
    /// A sentence, not a payload: longer is refused, never cut.
    public static let maxLength = 500
    /// One message a second per page; clicks are human speed.
    public static let throttleMilliseconds = 1000

    public enum Refusal: Hashable, Sendable {
        case invalid
        case tooLong
        case throttled(retryAfterMilliseconds: Int)
        /// The person said no when the page first asked to send.
        case declined
        /// The chat couldn't take it: busy, read-only, or gone.
        case undelivered
    }

    public enum Decision: Hashable, Sendable {
        case accept(String)
        case reject(Refusal)
    }

    /// Checks what the page sent. `lastAccepted` is when this page's previous message went, in
    /// milliseconds on the same clock as `now`; nil for none.
    public static func evaluate(_ prompt: Any?, now: Double, lastAccepted: Double?) -> Decision {
        let text = (prompt as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return .reject(.invalid) }
        // Counted as JavaScript counts a string's length, as the page measures it.
        guard text.utf16.count <= maxLength else { return .reject(.tooLong) }
        if let lastAccepted {
            let elapsed = now - lastAccepted
            if elapsed < Double(throttleMilliseconds) {
                return .reject(.throttled(retryAfterMilliseconds: max(1, Int((Double(throttleMilliseconds) - elapsed).rounded(.up)))))
            }
        }
        return .accept(text)
    }

    /// What `hermes.send()` resolves to in the page: `{ok: true}`, or why not.
    public static func ack(_ refusal: Refusal?) -> [String: JSONValue] {
        guard let refusal else { return ["ok": .bool(true)] }
        var ack: [String: JSONValue] = ["ok": .bool(false)]
        switch refusal {
        case .invalid:
            ack["error"] = .string("invalid")
        case .tooLong:
            ack["error"] = .string("too_long")
            ack["maxLength"] = .number(Double(maxLength))
        case .throttled(let wait):
            ack["error"] = .string("throttled")
            ack["retryAfterMs"] = .number(Double(wait))
        case .declined:
            ack["error"] = .string("declined")
            ack["reason"] = .string("The person didn't allow this page to send messages.")
        case .undelivered:
            ack["error"] = .string("undelivered")
        }
        return ack
    }
}

/// The page as it is loaded (`docs/chat.md` §3c): the app's look first in its head, so the page's
/// own styles win, and anything else to run before `</body>`, after its markup.
public enum PageFrame {
    public static func assemble(_ html: String, prelude: String, scripts: String = "") -> String {
        var page = html
        if !scripts.isEmpty {
            if let close = page.range(of: "</body", options: [.caseInsensitive, .backwards]) {
                page.insert(contentsOf: scripts, at: close.lowerBound)
            } else {
                page += scripts
            }
        }
        // Inside the head, or after the doctype at least: a style before the doctype would put the
        // page in quirks mode.
        for tag in ["<head(\\s[^>]*)?>", "<html(\\s[^>]*)?>", "<!doctype[^>]*>"] {
            if let open = page.range(of: tag, options: [.regularExpression, .caseInsensitive]) {
                page.insert(contentsOf: prelude, at: open.upperBound)
                return page
            }
        }
        return prelude + page
    }

    /// The look a page inherits: the app's colours as the variables Hermes Desktop names, its
    /// colour scheme, no margin and a clear background, so a small page sits on the chat.
    public static func prelude(dark: Bool, variables: [(String, String)], font: String) -> String {
        let tokens = variables.map { "\($0.0):\($0.1)" }.joined(separator: ";")
        let separator = tokens.isEmpty ? "" : ";"
        return "<style>:root{color-scheme:\(dark ? "dark" : "light")\(separator)\(tokens)}"
            + "html,body{margin:0;padding:0;background:transparent;color:var(--foreground,inherit);font-family:\(font);}</style>"
    }

    /// The page's `<title>`, as a card names it: its words with runs of space made one, a few
    /// common entities read, at most 120 characters; nil when it has none.
    public static func title(of html: String) -> String? {
        // Only the head is looked at: a title is near the top.
        let head = html.prefix(64 * 1024)
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let start = head[open.upperBound...].firstIndex(of: ">"),
              let close = head[start...].range(of: "</title", options: .caseInsensitive) else { return nil }
        var words = String(head[head.index(after: start)..<close.lowerBound])
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            words = words.replacingOccurrences(of: entity, with: character)
        }
        let collapsed = words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 120 ? String(collapsed.prefix(119)) + "…" : collapsed
    }
}
