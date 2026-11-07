import Foundation
import Markdown

/// A render-ready, value-typed Markdown tree.
///
/// Built with swift-markdown (cmark-gfm), then flattened into plain enums so
/// SwiftUI can diff it cheaply while a reply is still streaming in.
public struct MarkdownDocument: Hashable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public init(parsing source: String) {
        let document = Document(parsing: Self.boundedNesting(source))
        self.blocks = Array(document.children).compactMap(MarkdownBlock.init(markup:))
    }

    /// Deepest block-quote nesting and longest run of emphasis or link marks kept as Markdown.
    static let maxQuoteDepth = 32
    static let maxMarkRun = 128

    /// The source with nesting no reply needs taken out, outside code fences: quote markers past
    /// `maxQuoteDepth` dropped, emphasis and bracket marks past `maxMarkRun` in a row escaped.
    /// Parsing and converting recurse once per level, so thousands of `>` or `*_` from an
    /// injected reply would otherwise run out of stack and stop the app (security scan F31).
    static func boundedNesting(_ source: String) -> String {
        guard source.utf8.count > maxQuoteDepth else { return source }
        var lines: [Substring] = []
        var changed = false
        var fence: Character?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(3).allSatisfy({ $0 == marker }), trimmed.count >= 3 {
                fence = fence == nil ? marker : (fence == marker ? nil : fence)
                lines.append(line)
                continue
            }
            guard fence == nil else {
                lines.append(line)
                continue
            }
            var bounded = line
            let prefix = line.prefix { $0 == ">" || $0 == " " || $0 == "\t" }
            if prefix.count(where: { $0 == ">" }) > maxQuoteDepth {
                var markers = ""
                var depth = 0
                for character in prefix {
                    if character == ">" { depth += 1 }
                    if character != ">" || depth <= maxQuoteDepth { markers.append(character) }
                }
                bounded = Substring(markers) + line[prefix.endIndex...]
                changed = true
            }
            if let escaped = escapingLongMarkRuns(bounded) {
                bounded = escaped
                changed = true
            }
            lines.append(bounded)
        }
        return changed ? lines.joined(separator: "\n") : source
    }

    private static func escapingLongMarkRuns(_ line: Substring) -> Substring? {
        guard line.count > maxMarkRun else { return nil }
        var result = ""
        var run = 0
        var changed = false
        for character in line {
            if "*_~[".contains(character) {
                run += 1
                if run > maxMarkRun {
                    result.append("\\")
                    changed = true
                }
            } else {
                run = 0
            }
            result.append(character)
        }
        return changed ? Substring(result) : nil
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// Where text still arriving can be cut so that its two halves parse to the same blocks as
    /// the whole: after a blank line outside a code fence, before a paragraph that can't belong
    /// to what came before (a list item, a quote, a table row, an indented line or HTML could).
    /// The latest such place; `nil` when there is none.
    public static func streamingCut(in text: String) -> String.Index? {
        var stream = Stream()
        _ = stream.blocks(for: text, parsingTail: false)
        guard stream.cut > 0 else { return nil }
        return text.utf8.index(text.utf8.startIndex, offsetBy: stream.cut)
    }

    fileprivate static func startsFreshBlock(_ first: Character) -> Bool {
        first.isLetter || "#`\"“‘(".contains(first)
    }

    /// A reply still arriving, parsed as it grows. While it streams only what follows its last
    /// safe cut (`streamingCut`) changes, so what precedes it is parsed once and kept, and the
    /// search for the next cut picks up where the last one stopped: each redraw costs about
    /// the paragraph still arriving, not the whole reply. The blocks are the same as a parse of
    /// the whole text.
    public struct Stream: Sendable {
        /// The text last read. Everything this stream knows is about its first `scanned` bytes.
        private var text = ""
        /// The blocks of `text`'s first `cut` bytes, which end at a safe cut.
        private var head: [MarkdownBlock] = []
        fileprivate private(set) var cut = 0
        /// The end of the character after the cut, which decided that the cut is safe: a text that
        /// has another character there (a list item where a paragraph began) can't keep the cut.
        private var decided = 0
        /// Where the search for blank lines resumes.
        private var scanned = 0
        /// The ``` marks found (without overlaps) before `fenceSearch`, where that search resumes.
        private var fences = 0
        private var fenceSearch = 0
        /// Whether a "~~~" came before `scanned`: no cut after it is safe.
        private var sawTilde = false

        public init() {}

        /// Whether `text` keeps the part of the last text this stream has already parsed.
        public func continues(_ text: String) -> Bool {
            Self.sharePrefix(text, self.text, bytes: decided)
        }

        /// How much of the text this stream has parsed for good, in UTF-8 bytes.
        public var parsedLength: Int { cut }

        /// The blocks of `text`. A text that doesn't keep the part already parsed starts over.
        public mutating func blocks(for text: String) -> [MarkdownBlock] {
            blocks(for: text, parsingTail: true)
        }

        fileprivate mutating func blocks(for text: String, parsingTail: Bool) -> [MarkdownBlock] {
            var text = text
            text.makeContiguousUTF8()
            if !Self.sharePrefix(text, self.text, bytes: decided) {
                self = Stream()
            } else if !Self.sharePrefix(text, self.text, bytes: scanned) {
                // The end changed (a marker held back): the search starts again at the cut,
                // where every fence is closed.
                scanned = cut
                fenceSearch = cut
                fences = 0
                sawTilde = false
            }
            self.text = text
            let next = text.utf8.withContiguousStorageIfAvailable { advance(over: $0) } ?? nil
            if let next, next.cut > cut {
                head += MarkdownDocument(parsing: Self.slice(text, cut, next.cut)).blocks
                cut = next.cut
                decided = next.decided
            }
            guard parsingTail else { return head }
            let tail = Self.slice(text, cut, text.utf8.count)
            return tail.isEmpty ? head : head + MarkdownDocument(parsing: tail).blocks
        }

        /// Looks for blank lines past `scanned` and answers the latest safe cut among them, with the
        /// end of the character that made it safe.
        private mutating func advance(over bytes: UnsafeBufferPointer<UInt8>) -> (cut: Int, decided: Int)? {
            let newline = UInt8(ascii: "\n")
            var latest: (cut: Int, decided: Int)?
            var index = scanned
            while !sawTilde, index + 1 < bytes.count {
                guard bytes[index] == newline, bytes[index + 1] == newline else {
                    index += 1
                    continue
                }
                var start = index + 2
                while start < bytes.count, bytes[start] == newline { start += 1 }
                // Not decided until the line after the gap has begun.
                guard start < bytes.count else { break }
                countMarks(in: bytes, upTo: index)
                if !sawTilde, fences % 2 == 0, let first = Self.character(in: bytes, at: start),
                   MarkdownDocument.startsFreshBlock(first) {
                    latest = (start, start + first.utf8.count)
                }
                index = start
            }
            scanned = min(index, bytes.count)
            return latest
        }

        /// Counts ``` (greedily, as `countBytes` does) and looks for "~~~" in what precedes `end`.
        private mutating func countMarks(in bytes: UnsafeBufferPointer<UInt8>, upTo end: Int) {
            guard let base = bytes.baseAddress, fenceSearch < end else { return }
            let tick = Array("```".utf8)
            let tilde = Array("~~~".utf8)
            if memmem(base + fenceSearch, end - fenceSearch, tilde, 3) != nil { sawTilde = true }
            var start = fenceSearch
            while start + 3 <= end, let hit = memmem(base + start, end - start, tick, 3) {
                fences += 1
                start = UnsafeRawPointer(base).distance(to: hit) + 3
            }
            // A mark can't straddle `end`, which is a newline: the search resumes there.
            fenceSearch = max(start, end)
        }

        private static func character(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Character? {
            let end = min(bytes.count, offset + 16)
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[offset..<end]), as: UTF8.self).first
        }

        private static func slice(_ text: String, _ from: Int, _ to: Int) -> String {
            text.utf8Slice(from, to)
        }

        private static func sharePrefix(_ a: String, _ b: String, bytes count: Int) -> Bool {
            a.sharesPrefix(with: b, bytes: count)
        }
    }
}

public indirect enum MarkdownBlock: Hashable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
    case html(String)
}

public struct MarkdownList: Hashable, Sendable {
    public var isOrdered: Bool
    public var startIndex: Int
    public var items: [MarkdownListItem]

    public init(isOrdered: Bool, startIndex: Int, items: [MarkdownListItem]) {
        self.isOrdered = isOrdered
        self.startIndex = startIndex
        self.items = items
    }
}

public struct MarkdownListItem: Hashable, Sendable {
    /// `nil` for a plain item, `true`/`false` for a GFM task item.
    public var isChecked: Bool?
    public var blocks: [MarkdownBlock]

    public init(isChecked: Bool?, blocks: [MarkdownBlock]) {
        self.isChecked = isChecked
        self.blocks = blocks
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }

    public var alignments: [Alignment]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]]

    public init(alignments: [Alignment], header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }
}

public indirect enum MarkdownInline: Hashable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String?, content: [MarkdownInline])
    case image(source: String?, alt: String)
    case softBreak
    case lineBreak

    /// The text a reader would copy, without any formatting.
    public var plainText: String {
        switch self {
        case .text(let text), .code(let text): text
        case .emphasis(let content), .strong(let content), .strikethrough(let content), .link(_, let content):
            content.map(\.plainText).joined()
        case .image(_, let alt): alt
        case .softBreak: " "
        case .lineBreak: "\n"
        }
    }
}

// MARK: - Conversion from swift-markdown

extension MarkdownBlock {
    init?(markup: any Markup) {
        switch markup {
        case let paragraph as Paragraph:
            self = .paragraph(MarkdownInline.convert(paragraph.children))
        case let heading as Heading:
            self = .heading(level: heading.level, content: MarkdownInline.convert(heading.children))
        case let code as CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            var source = code.code
            if source.hasSuffix("\n") { source.removeLast() }
            self = .codeBlock(language: (language?.isEmpty ?? true) ? nil : language, code: source)
        case let quote as BlockQuote:
            self = .blockQuote(Array(quote.children).compactMap(MarkdownBlock.init(markup:)))
        case let list as OrderedList:
            self = .list(MarkdownList(
                isOrdered: true,
                startIndex: Int(list.startIndex),
                items: Array(list.listItems).map(MarkdownListItem.init(item:))
            ))
        case let list as UnorderedList:
            self = .list(MarkdownList(
                isOrdered: false,
                startIndex: 1,
                items: Array(list.listItems).map(MarkdownListItem.init(item:))
            ))
        case let table as Markdown.Table:
            self = .table(MarkdownTable(table: table))
        case is ThematicBreak:
            self = .thematicBreak
        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            self = .html(raw)
        default:
            return nil
        }
    }
}

extension MarkdownListItem {
    init(item: ListItem) {
        let checked: Bool? = switch item.checkbox {
        case .checked: true
        case .unchecked: false
        case nil: nil
        }
        self.init(isChecked: checked, blocks: Array(item.children).compactMap(MarkdownBlock.init(markup:)))
    }
}

extension MarkdownTable {
    init(table: Markdown.Table) {
        let alignments: [Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            case .left, nil: .leading
            }
        }
        let header: [[MarkdownInline]] = Array(table.head.cells).map { MarkdownInline.convert($0.children) }
        let rows: [[[MarkdownInline]]] = Array(table.body.rows).map { row in
            Array(row.cells).map { MarkdownInline.convert($0.children) }
        }
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        self.init(
            alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
            header: header,
            rows: rows
        )
    }
}

extension MarkdownInline {
    /// - Parameter linking: web addresses in the plain text become links (`AutoLink`); off for
    ///   a link's own words.
    static func convert(_ children: some Sequence<any Markup>, linking: Bool = true) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for child in children {
            guard let inline = MarkdownInline(markup: child, linking: linking) else { continue }
            // Merge adjacent text runs so the renderer builds fewer attributed runs.
            if case .text(let next) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(inline)
            }
        }
        return linking ? autolinked(result) : result
    }

    init?(markup: any Markup, linking: Bool = true) {
        switch markup {
        case let text as Markdown.Text:
            self = .text(text.string)
        case let emphasis as Emphasis:
            self = .emphasis(Self.convert(emphasis.children, linking: linking))
        case let strong as Strong:
            self = .strong(Self.convert(strong.children, linking: linking))
        case let strike as Strikethrough:
            self = .strikethrough(Self.convert(strike.children, linking: linking))
        case let code as InlineCode:
            self = .code(code.code)
        case let link as Markdown.Link:
            self = .link(destination: link.destination, content: Self.convert(link.children, linking: false))
        case let image as Markdown.Image:
            self = .image(source: image.source, alt: image.plainText)
        case is SoftBreak:
            self = .softBreak
        case is LineBreak:
            self = .lineBreak
        case let html as InlineHTML:
            // Hermes replies are text; show stray tags literally rather than dropping words.
            self = .text(html.rawHTML)
        case let symbol as SymbolLink:
            self = .code(symbol.destination ?? "")
        default:
            let text = markup.format()
            guard !text.isEmpty else { return nil }
            self = .text(text)
        }
    }
}
