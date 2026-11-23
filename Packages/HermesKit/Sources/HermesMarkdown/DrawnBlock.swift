import Foundation

/// A block of a reply that is drawn as a picture instead of shown as its text: a Mermaid diagram,
/// display math, or an SVG (`docs/chat.md` §3b). The app renders it on the device, offline, and
/// shows its source where it can't.
///
/// Only blocks the writer marked are drawn: a ```` ```mermaid ````, ```` ```math ```` or
/// ```` ```svg ```` fence, a `$$…$$` or `\[…\]` block on lines of its own (`DisplayMath`, which
/// turns them into a math fence before parsing), and an HTML block that is one whole `<svg>`
/// element. Inline `$…$` is never math: "$5 and $10" stays words.
public struct DrawnBlock: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case mermaid
        case math
        case svg
    }

    public var kind: Kind
    /// The diagram's source, the TeX (without its delimiters), or the SVG's markup.
    public var source: String

    public init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
    }

    /// The longest source of each kind that is drawn; a longer one shows as code. Mermaid refuses
    /// past 50,000 characters itself, a formula longer than a few thousand is a document, and an
    /// SVG past half a megabyte is a file to open, not a picture in a reply.
    public static func maxLength(_ kind: Kind) -> Int {
        switch kind {
        case .mermaid: 50_000
        case .math: 8_000
        case .svg: 512_000
        }
    }

    /// The drawn block a reply's block is, or nil when it is shown as written.
    public init?(_ block: MarkdownBlock) {
        switch block {
        case .codeBlock(let language, let code):
            self.init(language: language, code: code)
        case .html(let raw):
            guard Self.isWholeSVG(raw) else { return nil }
            self.init(checked: .svg, source: raw)
        case .paragraph(let inlines):
            // An `<svg>` written on one line is a paragraph of inline HTML, not an HTML block.
            guard let first = inlines.first, case .text(let start) = first, start.hasPrefix("<"),
                  let raw = Self.literal(inlines), Self.isWholeSVG(raw) else { return nil }
            self.init(checked: .svg, source: raw)
        default:
            return nil
        }
    }

    /// A fence by its info string's first word: `mermaid`, `math` and `svg`, in any case.
    public init?(language: String?, code: String) {
        guard let language, let word = language.split(whereSeparator: \.isWhitespace).first else { return nil }
        let kind: Kind
        switch word.lowercased() {
        case "mermaid": kind = .mermaid
        case "math": kind = .math
        case "svg":
            // An SVG fence holds the markup; one that is something else (a path's numbers, a
            // description) is code.
            guard Self.isWholeSVG(code) else { return nil }
            kind = .svg
        default: return nil
        }
        self.init(checked: kind, source: code)
    }

    private init?(checked kind: Kind, source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxLength(kind) else { return nil }
        self.init(kind: kind, source: trimmed)
    }

    /// A paragraph's text as written, when it is nothing but text (inline HTML is kept as text).
    private static func literal(_ inlines: [MarkdownInline]) -> String? {
        var text = ""
        for inline in inlines {
            switch inline {
            case .text(let words): text += words
            case .softBreak, .lineBreak: text += "\n"
            // An address in it (`xmlns="http://…"`) is autolinked: its words are as written.
            case .link(_, let content):
                guard let words = literal(content) else { return nil }
                text += words
            default: return nil
            }
        }
        return text
    }

    /// Markup that is one `<svg …>…</svg>` element, with at most an XML declaration or a comment
    /// before it. Prose around it, or a fragment, isn't drawn.
    public static func isWholeSVG(_ text: String) -> Bool {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.hasPrefix("<?") || rest.hasPrefix("<!--") {
            let close = rest.hasPrefix("<?") ? "?>" : "-->"
            guard let end = rest.range(of: close) else { return false }
            rest = rest[end.upperBound...].drop(while: \.isWhitespace)
        }
        guard rest.count >= 11, rest.prefix(4).lowercased() == "<svg",
              let after = rest.dropFirst(4).first, after.isWhitespace || after == ">" || after == "/" else { return false }
        return rest.suffix(6).lowercased() == "</svg>"
    }

    /// What VoiceOver says the picture is: "Flowchart", "Sequence diagram", "Formula", "Picture".
    /// The source itself is read after it, so the content is never only pixels.
    public var name: String {
        switch kind {
        case .math: return "Formula"
        case .svg: return "Picture"
        case .mermaid: return Self.diagramName(source)
        }
    }

    /// The kind of Mermaid diagram from its first word (after any front matter, comments and
    /// `%%{init}%%` lines): "Flowchart", "Sequence diagram", …; "Diagram" when unknown.
    public static func diagramName(_ source: String) -> String {
        var inFrontMatter = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                inFrontMatter.toggle()
                continue
            }
            guard !inFrontMatter, !trimmed.isEmpty, !trimmed.hasPrefix("%%") else { continue }
            let word = trimmed.prefix { !$0.isWhitespace && $0 != ";" && $0 != "{" }.lowercased()
            return diagramNames[word] ?? "Diagram"
        }
        return "Diagram"
    }

    private static let diagramNames: [String: String] = [
        "graph": "Flowchart", "flowchart": "Flowchart", "flowchart-elk": "Flowchart",
        "sequencediagram": "Sequence diagram", "classdiagram": "Class diagram", "classdiagram-v2": "Class diagram",
        "statediagram": "State diagram", "statediagram-v2": "State diagram", "erdiagram": "Entity relationship diagram",
        "journey": "User journey", "gantt": "Gantt chart", "pie": "Pie chart", "quadrantchart": "Quadrant chart",
        "requirementdiagram": "Requirement diagram", "gitgraph": "Git graph", "mindmap": "Mind map",
        "timeline": "Timeline", "sankey-beta": "Sankey diagram", "sankey": "Sankey diagram", "xychart-beta": "Chart",
        "xychart": "Chart", "block-beta": "Block diagram", "block": "Block diagram", "packet-beta": "Packet diagram",
        "packet": "Packet diagram", "kanban": "Kanban board", "architecture-beta": "Architecture diagram",
        "architecture": "Architecture diagram", "radar-beta": "Radar chart", "treemap-beta": "Treemap",
        "c4context": "C4 diagram", "c4container": "C4 diagram", "c4component": "C4 diagram", "c4dynamic": "C4 diagram",
        "c4deployment": "C4 diagram",
    ]
}

/// `$$…$$` and `\[…\]` display math, turned into ```` ```math ```` fences before a reply is parsed,
/// so Markdown never reads the TeX's `_` and `*` as emphasis.
///
/// A block opens on a line that starts with `$$` (or `\[`), up to three spaces in, outside a code
/// fence, and closes on the first line that ends with `$$` (`\]`), before any blank line: the
/// TeX is everything between. One line can hold the whole block (`$$ x^2 $$`). A block that
/// never closes stays text, so money ("$$5 and $$10") and a formula still arriving read as written.
public enum DisplayMath {
    /// Lines a block may span; past that it's prose that happens to start with `$$`.
    static let maxLines = 200

    public static func fenced(_ source: String) -> String {
        // Most replies have neither opener: one scan, nothing copied.
        guard source.utf8.contains(UInt8(ascii: "$")) || source.contains("\\[") else { return source }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        out.reserveCapacity(lines.count)
        var changed = false
        var fence: (marker: Character, length: Int)?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let indent = line.prefix { $0 == " " }
            let body = line.dropFirst(indent.count)
            if let open = fence {
                if Self.fenceMark(body).map({ $0.marker == open.marker && $0.length >= open.length }) == true,
                   body.drop(while: { $0 == open.marker }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                out.append(line)
                index += 1
                continue
            }
            if let mark = Self.fenceMark(body), indent.count <= 3 {
                fence = mark
                out.append(line)
                index += 1
                continue
            }
            if indent.count <= 3, let math = Self.block(lines, from: index, indent: indent.count) {
                let pad = String(indent)
                out.append(Substring(pad + "```math"))
                for tex in math.tex { out.append(Substring(pad) + tex) }
                out.append(Substring(pad + "```"))
                index = math.next
                changed = true
                continue
            }
            out.append(line)
            index += 1
        }
        return changed ? out.joined(separator: "\n") : source
    }

    private static let delimiters: [(open: String, close: String)] = [("$$", "$$"), ("\\[", "\\]")]

    /// The math block that opens at `start`: its TeX lines and the line after it.
    private static func block(_ lines: [Substring], from start: Int, indent: Int) -> (tex: [Substring], next: Int)? {
        let first = lines[start].dropFirst(indent).trimmingCharacters(in: .whitespaces)
        guard let delimiter = delimiters.first(where: { first.hasPrefix($0.open) }) else { return nil }
        let opened = Substring(first.dropFirst(delimiter.open.count))
        // `$$$` is not an opener, and a third `$` would leave a stray one in the TeX.
        if delimiter.open == "$$", opened.hasPrefix("$") { return nil }
        // All on one line: `$$ x^2 $$`.
        if opened.count >= delimiter.close.count + 1, opened.hasSuffix(delimiter.close) {
            let tex = opened.dropLast(delimiter.close.count)
            guard !tex.contains(delimiter.open), !tex.allSatisfy(\.isWhitespace) else { return nil }
            return ([Substring(tex.trimmingCharacters(in: .whitespaces))], start + 1)
        }
        guard !opened.contains(delimiter.close) else { return nil }
        var tex: [Substring] = opened.allSatisfy(\.isWhitespace) ? [] : [opened]
        var index = start + 1
        while index < lines.count, index - start <= maxLines {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if trimmed.hasSuffix(delimiter.close) {
                let last = trimmed.dropLast(delimiter.close.count)
                guard !last.contains(delimiter.open) else { return nil }
                if !last.allSatisfy(\.isWhitespace) { tex.append(Substring(last)) }
                guard !tex.isEmpty else { return nil }
                return (tex.map { Substring($0.drop { $0 == " " && indent > 0 }) }, index + 1)
            }
            if trimmed.contains(delimiter.close) || trimmed.contains(delimiter.open) { return nil }
            tex.append(line)
            index += 1
        }
        return nil
    }

    /// A ``` or ~~~ fence opener or closer at the start of the line: its mark and length.
    private static func fenceMark(_ body: Substring) -> (marker: Character, length: Int)? {
        guard let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }
}
