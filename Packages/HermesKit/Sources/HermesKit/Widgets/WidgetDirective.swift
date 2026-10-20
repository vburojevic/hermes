import Foundation

/// `::widget{id="w_3kq9x2" alt="Apartments in Brooklyn: 3 new"}`: where a widget goes in a reply
/// (`docs/widgets.md` §2).
public struct WidgetDirective: Hashable, Sendable {
    public var id: String
    /// A one-line description, shown while the payload loads and read if it never does.
    public var alt: String?

    public init(id: String, alt: String? = nil) {
        self.id = id
        self.alt = alt
    }

    static let maxLength = 1024
    static let maxAlt = 140
    /// More are the agent's mistake; the rest show as their words.
    public static let maxPerReply = 3

    /// The directive on one line, or `nil` when the line is anything else.
    public static func parse(_ line: some StringProtocol) -> WidgetDirective? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.utf8.count <= maxLength, line.hasPrefix("::widget{"), line.hasSuffix("}") else { return nil }
        let body = line.dropFirst("::widget{".count).dropLast()
        guard let attributes = parseAttributes(body), let id = attributes["id"], isWidgetID(id) else { return nil }
        let alt = attributes["alt"].map { String($0.prefix(maxAlt)) }.flatMap { $0.isEmpty ? nil : $0 }
        return WidgetDirective(id: id, alt: alt)
    }

    /// `w_` and 6–40 letters or digits.
    public static func isWidgetID(_ text: String) -> Bool {
        guard text.hasPrefix("w_") else { return false }
        let rest = text.dropFirst(2)
        return (6...40).contains(rest.count) && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `key="value"` pairs separated by spaces; `\"` escapes a quote. Anything malformed is not a
    /// directive.
    private static func parseAttributes(_ text: Substring) -> [String: String]? {
        var result: [String: String] = [:]
        var index = text.startIndex
        func skipSpaces() { while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) } }
        skipSpaces()
        while index < text.endIndex {
            let keyStart = index
            while index < text.endIndex, text[index].isLetter || text[index] == "_" || text[index] == "-" { index = text.index(after: index) }
            let key = String(text[keyStart..<index])
            guard !key.isEmpty, index < text.endIndex, text[index] == "=" else { return nil }
            index = text.index(after: index)
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            index = text.index(after: index)
            var value = ""
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if character == "\\", text.index(after: index) < text.endIndex {
                    let next = text[text.index(after: index)]
                    value.append(next == "\"" || next == "\\" ? next : character)
                    if next == "\"" || next == "\\" { index = text.index(after: index) }
                } else if character == "\"" {
                    closed = true
                    index = text.index(after: index)
                    break
                } else {
                    value.append(character)
                }
                index = text.index(after: index)
            }
            guard closed else { return nil }
            if result[key] == nil { result[key] = value }
            let before = index
            skipSpaces()
            guard index == text.endIndex || index > before else { return nil }
        }
        return result
    }
}

/// A reply's text split around its widgets, in order.
public enum ReplySegment: Hashable, Sendable {
    case markdown(String)
    case widget(WidgetDirective)
    /// A ` ```widget ` block the plugin wrote into a scheduled delivery (`docs/widgets.md` §2).
    case inline(JSONValue)
}

public enum ReplySplitter {
    /// Splits `text` at directive lines outside code fences.
    /// - Parameters:
    ///   - inlineWidgets: ` ```widget ` blocks draw as widgets (a delivery the plugin processed, or
    ///     the debug setting); otherwise they stay code.
    ///   - streaming: the text is still arriving: a last line that could become a directive is held
    ///     back, so `::widget{…}` never shows raw.
    public static func split(_ text: String, inlineWidgets: Bool = false, streaming: Bool = false) -> [ReplySegment] {
        // Every reply body asks, a streaming one for each word: most have no widget, and are
        // told so by a scan of their bytes before anything is split.
        let lastLine = text.lastIndex(of: "\n").map { text[text.index(after: $0)...] } ?? text[...]
        let holdsLastLine = streaming && !text.hasSuffix("\n") && couldBecomeDirective(lastLine)
        guard holdsLastLine || text.containsBytes("::widget{") || (inlineWidgets && text.containsBytes("widget")) else {
            return [.markdown(text)]
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if holdsLastLine { lines.removeLast() }

        var segments: [ReplySegment] = []
        var prose: [Substring] = []
        var fence: Fence?
        var seen: Set<String> = []

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(.markdown(joined)) }
            prose.removeAll()
        }

        for line in lines {
            if let open = fence {
                if closesFence(line, marker: open.marker, length: open.length) {
                    if open.isWidget {
                        if let json = JSONValue.parse(open.lines.joined(separator: "\n")), case .object = json {
                            flushProse()
                            segments.append(.inline(json))
                        } else {
                            // Not a payload: the block stays code.
                            prose.append(open.opening)
                            prose.append(contentsOf: open.lines)
                            prose.append(line)
                        }
                    } else {
                        prose.append(line)
                    }
                    fence = nil
                } else if open.isWidget {
                    fence?.lines.append(line)
                } else {
                    prose.append(line)
                }
                continue
            }
            if let opening = opensFence(line) {
                let isWidget = inlineWidgets && opening.info.unicodeScalars.elementsEqual("widget".unicodeScalars)
                fence = Fence(marker: opening.marker, length: opening.length, isWidget: isWidget, opening: line)
                if !isWidget { prose.append(line) }
                continue
            }
            if let directive = WidgetDirective.parse(line) {
                guard seen.insert(directive.id).inserted else { continue } // the same widget twice draws once
                if seen.count > WidgetDirective.maxPerReply {
                    if let alt = directive.alt { prose.append(Substring(alt)) }
                    continue
                }
                flushProse()
                segments.append(.widget(directive))
                continue
            }
            prose.append(line)
        }
        // An unclosed widget block is code once the reply is whole; while it streams, it waits.
        if let open = fence, open.isWidget, !streaming {
            prose.append(open.opening)
            prose.append(contentsOf: open.lines)
        }
        flushProse()
        return segments.isEmpty ? [.markdown("")] : segments
    }

    private struct Fence {
        var marker: Unicode.Scalar
        var length: Int
        var isWidget: Bool
        var opening: Substring
        var lines: [Substring] = []
    }

    /// A last line still arriving that may turn out to be a directive.
    private static func couldBecomeDirective(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == ":" else { return false }
        return trimmed.hasPrefix("::widget{") || "::widget{".hasPrefix(trimmed)
    }

    /// The text with each widget as words: a directive as its `alt`, an inline block as its
    /// `fallback_text`. What Copy, Share and Read Aloud take.
    public static func readableText(_ text: String) -> String {
        guard text.containsBytes("::widget{") || text.containsBytes("```widget") else { return text }
        return split(text, inlineWidgets: true).compactMap { segment -> String? in
            switch segment {
            case .markdown(let markdown): markdown
            case .widget(let directive): directive.alt
            case .inline(let json): json["fallback_text"]?.stringValue
            }
        }.joined(separator: "\n\n")
    }

    /// The widget a fenced JSON block is a copy of: a payload's id and revision, when the whole
    /// block is one (a Bot repeating a routine's brief, whose widget fence the plugin turned into
    /// json). The app draws the widget it already holds for that id instead of the raw JSON; the
    /// block's own JSON is never read into the store.
    public static func echoedWidget(language: String?, code: String) -> (id: String, rev: Int)? {
        guard let language = language?.lowercased(), language == "json" || language == "widget",
              code.first(where: { !$0.isWhitespace }) == "{",
              let json = JSONValue.parse(Data(code.utf8)), json["type"]?.stringValue != nil,
              let id = json["id"]?.stringValue, WidgetDirective.isWidgetID(id) else { return nil }
        return (id, json["rev"]?.intValue ?? 1)
    }

    /// The widget ids a reply's text points at, in order.
    public static func directiveIDs(in text: String) -> [String] {
        split(text).compactMap { segment in
            if case .widget(let directive) = segment { directive.id } else { nil }
        }
    }

    /// A line opening a fenced code block: up to three spaces, then three or more backticks or
    /// tildes, then the info string. Read scalar by scalar, as the plugin's fence check reads it:
    /// Swift's `Character` equality is canonical, so a look-alike such as U+1FEF GREEK VARIA
    /// (which decomposes to a backtick) would open a block here that the plugin never saw as one,
    /// letting a Bot's text plant a widget (security scan F8, F11).
    private static func opensFence(_ line: Substring) -> (marker: Unicode.Scalar, length: Int, info: String)? {
        let scalars = line.unicodeScalars
        let indent = scalars.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = scalars.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let after = rest.dropFirst(length)
        if marker == "`", after.contains("`") { return nil }
        let info = String(String.UnicodeScalarView(after)).trimmingCharacters(in: .whitespaces)
        let word = info.unicodeScalars.prefix { $0 != " " }
        return (marker, length, String(String.UnicodeScalarView(word)))
    }

    private static func closesFence(_ line: Substring, marker: Unicode.Scalar, length: Int) -> Bool {
        let scalars = line.unicodeScalars
        let indent = scalars.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = scalars.dropFirst(indent)
        let run = rest.prefix { $0 == marker }.count
        return run >= length && rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
