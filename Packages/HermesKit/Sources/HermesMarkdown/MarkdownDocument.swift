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
        let document = Document(parsing: source)
        self.blocks = Array(document.children).compactMap(MarkdownBlock.init(markup:))
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// Where text still arriving can be cut so that its two halves parse to the same blocks as
    /// the whole: after a blank line outside a code fence, before a paragraph that can't belong
    /// to what came before (a list item, a quote, a table row, an indented line or HTML could).
    /// The latest such place, looking back a little; `nil` when there is none.
    ///
    /// While a reply streams only what follows the cut changes, so what precedes it is parsed once.
    public static func streamingCut(in text: String) -> String.Index? {
        var searchEnd = text.endIndex
        for _ in 0..<24 {
            guard let gap = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<searchEnd) else { return nil }
            var start = gap.upperBound
            while start < text.endIndex, text[start] == "\n" { start = text.index(after: start) }
            if start < text.endIndex, startsFreshBlock(text[start]), fencesClosed(text[..<gap.lowerBound]) {
                return start
            }
            searchEnd = gap.lowerBound
        }
        return nil
    }

    private static func startsFreshBlock(_ first: Character) -> Bool {
        first.isLetter || "#`\"“‘(".contains(first)
    }

    private static func fencesClosed(_ head: Substring) -> Bool {
        head.components(separatedBy: "```").count % 2 == 1 && !head.contains("~~~")
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
    static func convert(_ children: some Sequence<any Markup>) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for child in children {
            guard let inline = MarkdownInline(markup: child) else { continue }
            // Merge adjacent text runs so the renderer builds fewer attributed runs.
            if case .text(let next) = inline, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(inline)
            }
        }
        return result
    }

    init?(markup: any Markup) {
        switch markup {
        case let text as Markdown.Text:
            self = .text(text.string)
        case let emphasis as Emphasis:
            self = .emphasis(Self.convert(emphasis.children))
        case let strong as Strong:
            self = .strong(Self.convert(strong.children))
        case let strike as Strikethrough:
            self = .strikethrough(Self.convert(strike.children))
        case let code as InlineCode:
            self = .code(code.code)
        case let link as Markdown.Link:
            self = .link(destination: link.destination, content: Self.convert(link.children))
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

// MARK: - Plain text

extension MarkdownDocument {
    /// Readable text for speech and previews: formatting dropped, code blocks omitted.
    public var spokenText: String {
        blocks.compactMap(\.spokenText).joined(separator: "\n\n")
    }
}

extension MarkdownBlock {
    var spokenText: String? {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            inlines.map(\.plainText).joined()
        case .codeBlock:
            nil
        case .blockQuote(let blocks):
            blocks.compactMap(\.spokenText).joined(separator: "\n")
        case .list(let list):
            list.items.map { $0.blocks.compactMap(\.spokenText).joined(separator: " ") }.joined(separator: "\n")
        case .table(let table):
            ([table.header] + table.rows).map { row in row.map { $0.map(\.plainText).joined() }.joined(separator: ", ") }
                .joined(separator: "\n")
        case .thematicBreak, .html:
            nil
        }
    }
}
