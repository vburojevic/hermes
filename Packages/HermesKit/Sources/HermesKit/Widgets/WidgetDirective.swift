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

    /// `key="value"` pairs separated by spaces, or by a comma as models often write them (the
    /// plugin reads both); `\"` escapes a quote. Anything malformed is not a directive.
    /// `singleQuotes`: a value may also be in single quotes, as Hermes Desktop reads `::preview`.
    static func parseAttributes(_ text: Substring, singleQuotes: Bool = false) -> [String: String]? {
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
            guard index < text.endIndex, text[index] == "\"" || (singleQuotes && text[index] == "'") else { return nil }
            let quote = text[index]
            index = text.index(after: index)
            var value = ""
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if character == "\\", text.index(after: index) < text.endIndex {
                    let next = text[text.index(after: index)]
                    value.append(next == quote || next == "\\" ? next : character)
                    if next == quote || next == "\\" { index = text.index(after: index) }
                } else if character == quote {
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
            if index < text.endIndex, text[index] == "," {
                index = text.index(after: index)
                skipSpaces()
                guard index < text.endIndex else { return nil }
                continue
            }
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
    /// A widget's payload a routine typed into its delivery instead of making it with the tool
    /// (`docs/widgets.md` §2): shown as its words, never drawn. Only with `typedAsText`.
    case typed(JSONValue)
    /// A widget's payload that couldn't be read: cut off, not JSON, or without words to show
    /// (`docs/widgets.md` §2). It keeps its place as a plain "couldn't show this card", never code
    /// and never drawn. Only where inline blocks draw or with `typedAsText`.
    case unreadable
    /// Files Hermes sent (`MEDIA:` lines), drawn where their notes are, those on lines next to
    /// each other (blank lines between them aside) together (`docs/chat.md` §3a). Only where the
    /// reply's attachments are given.
    case attachments([ReplyAttachment])
    /// A page the reply shows live, `::preview{file="…"}` on a line of its own (`docs/chat.md` §3c).
    case preview(PreviewDirective)
}

public enum ReplySplitter {
    /// Splits `text` at directive lines outside code fences.
    /// - Parameters:
    ///   - inlineWidgets: ` ```widget ` blocks draw as widgets (a delivery the plugin processed, or
    ///     the debug setting); otherwise they stay code.
    ///   - streaming: the text is still arriving: a last line that could become a directive is held
    ///     back, so `::widget{…}` never shows raw.
    ///   - typedAsText: a routine's delivery: a ` ```json ` (or undrawn ` ```widget `) block that is
    ///     a widget's payload reads as its words (`typedWidget`), never as code.
    ///   - attachments: the files the reply sent (`AssistantTurn.attachments`): a line that is one's
    ///     note, outside a code block, becomes that file. Each is drawn once, in the order its
    ///     notes come; a note with no file left for it stays words.
    public static func split(_ text: String, inlineWidgets: Bool = false, streaming: Bool = false, typedAsText: Bool = false,
                             attachments: [ReplyAttachment] = []) -> [ReplySegment] {
        // Every reply body asks, a streaming one for each word: most have no widget, and are
        // told so by a scan of their bytes before anything is split.
        let lastLine = text.lastIndex(of: "\n").map { text[text.index(after: $0)...] } ?? text[...]
        let holdsLastLine = streaming && !text.hasSuffix("\n") && couldBecomeDirective(lastLine)
        let hasAttachments = !attachments.isEmpty && text.containsBytes("*Attachment on server: ")
        guard holdsLastLine || hasAttachments || text.containsBytes("::widget{") || text.containsBytes("::preview{")
                || ((inlineWidgets || typedAsText) && text.containsBytes("widget"))
                || (typedAsText && text.containsBytes("\"type\"")) else {
            return [.markdown(text)]
        }
        var unused = hasAttachments ? attachments : []
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
                    if open.isTyped {
                        let code = open.lines.joined(separator: "\n")
                        if let json = typedWidget(language: open.info, code: code) {
                            flushProse()
                            segments.append(.typed(json))
                        } else if looksLikeWidget(language: open.info, code: code) {
                            flushProse()
                            segments.append(.unreadable)
                        } else {
                            prose.append(open.opening)
                            prose.append(contentsOf: open.lines)
                            prose.append(line)
                        }
                    } else if open.isWidget {
                        if let json = JSONValue.parse(open.lines.joined(separator: "\n")), case .object = json {
                            flushProse()
                            segments.append(.inline(json))
                        } else {
                            // The plugin wrote this block as a widget, but it isn't one it can be
                            // read as: it keeps its place, never as raw JSON.
                            flushProse()
                            segments.append(.unreadable)
                        }
                    } else {
                        prose.append(line)
                    }
                    fence = nil
                } else if open.isWidget || open.isTyped {
                    fence?.lines.append(line)
                } else {
                    prose.append(line)
                }
                continue
            }
            if let opening = opensFence(line) {
                let isWidget = inlineWidgets && opening.info.unicodeScalars.elementsEqual("widget".unicodeScalars)
                let isTyped = typedAsText && !isWidget && ["json", "widget"].contains(opening.info.lowercased())
                fence = Fence(marker: opening.marker, length: opening.length, isWidget: isWidget, isTyped: isTyped, info: opening.info, opening: line)
                if !isWidget && !isTyped { prose.append(line) }
                continue
            }
            if !unused.isEmpty, let attachment = takeAttachment(for: line, from: &unused) {
                // Files on lines next to each other, with only blank lines between them, go together.
                if case .attachments(let group)? = segments.last, prose.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                    prose.removeAll()
                    segments[segments.count - 1] = .attachments(group + [attachment])
                } else {
                    flushProse()
                    segments.append(.attachments([attachment]))
                }
                continue
            }
            if let preview = PreviewDirective.parse(line) {
                flushProse()
                segments.append(.preview(preview))
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
        // An unclosed widget block was cut off: once the reply is whole it keeps its place as a
        // payload that couldn't be read; while it streams, it waits. Other unclosed json is code.
        if let open = fence, (open.isWidget && !streaming) || open.isTyped {
            if open.isWidget || looksLikeWidget(language: open.info, code: open.lines.joined(separator: "\n")) {
                flushProse()
                segments.append(.unreadable)
            } else {
                prose.append(open.opening)
                prose.append(contentsOf: open.lines)
            }
        }
        flushProse()
        return segments.isEmpty ? [.markdown("")] : segments
    }

    /// The first file still to draw whose note `line` is; it's taken, so it draws once.
    private static func takeAttachment(for line: Substring, from unused: inout [ReplyAttachment]) -> ReplyAttachment? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("*Attachment on server: "),
              let index = unused.firstIndex(where: { $0.note == trimmed }) else { return nil }
        return unused.remove(at: index)
    }

    private struct Fence {
        var marker: Unicode.Scalar
        var length: Int
        var isWidget: Bool
        var isTyped = false
        var info = ""
        var opening: Substring
        var lines: [Substring] = []
    }

    /// A last line still arriving that may turn out to be a directive.
    private static func couldBecomeDirective(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == ":" else { return false }
        return ["::widget{", "::preview{"].contains { trimmed.hasPrefix($0) || $0.hasPrefix(trimmed) }
    }

    /// The text with each widget as words: a directive as its `alt`, an inline block as its
    /// `fallback_text`, a page as its file. What Copy, Share and Read Aloud take.
    public static func readableText(_ text: String, typedAsText: Bool = false) -> String {
        guard text.containsBytes("::widget{") || text.containsBytes("```widget") || text.containsBytes("::preview{") || typedAsText else { return text }
        return split(text, inlineWidgets: true, typedAsText: typedAsText).compactMap { segment -> String? in
            switch segment {
            case .markdown(let markdown): markdown
            case .widget(let directive): directive.alt
            case .inline(let json): json["fallback_text"]?.stringValue
            case .typed(let json): typedWords(json)
            case .unreadable: nil
            case .attachments(let files): files.map(\.note).joined(separator: "\n")
            case .preview(let preview): preview.file
            }
        }.joined(separator: "\n\n")
    }

    /// The payload a fenced block is, when a routine typed a widget instead of making it with the
    /// tool: a JSON object with a `type`, something only a widget carries (`v`, `fallback_text` or
    /// a widget id) and words to show. The plugin from 1.4.0 makes such a block into a card itself;
    /// an older one passes it through as json. It is shown as text and never drawn: the plugin's
    /// checks never saw it.
    public static func typedWidget(language: String?, code: String) -> JSONValue? {
        guard let language = language?.lowercased(), language == "json" || language == "widget",
              code.first(where: { !$0.isWhitespace }) == "{",
              let json = JSONValue.parse(Data(code.utf8)), case .object(let object) = json,
              let type = object["type"]?.stringValue, !type.isEmpty,
              object["v"] != nil || object["fallback_text"] != nil || object["id"]?.stringValue.map(WidgetDirective.isWidgetID) == true,
              typedWords(json) != nil else { return nil }
        return json
    }

    /// A fenced block meant as a widget that `typedWidget` couldn't read: a ` ```widget ` block,
    /// or ` ```json ` that opens an object naming a `type` and a `v` or `fallback_text`, whether
    /// or not it parses (a model can stop halfway or leave the words out). JSON that names neither
    /// is someone's data and stays code.
    static func looksLikeWidget(language: String?, code: String) -> Bool {
        guard let language = language?.lowercased() else { return false }
        if language == "widget" { return true }
        guard language == "json", code.first(where: { !$0.isWhitespace }) == "{" else { return false }
        func names(_ key: String) -> Bool {
            code.range(of: "\"\(key)\"\\s*:", options: .regularExpression) != nil
        }
        return names("type") && (names("v") || names("fallback_text"))
    }

    /// A typed payload's words: its `fallback_text`, else its title.
    public static func typedWords(_ json: JSONValue) -> String? {
        [json["fallback_text"]?.stringValue, json["title"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
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
