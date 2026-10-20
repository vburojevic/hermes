import Foundation
import NaturalLanguage

/// What a reply sounds like (`docs/voice.md` §3): the one cleaner every spoken path uses (Listen,
/// Talk, a Bot's voice). It reads the Markdown tree, not the raw text:
/// - prose, headings, lists and quotes are read;
/// - code blocks and tables are described ("I put a table with 4 rows in the chat"), or skipped;
/// - links read their words, never their address, and bare URLs are dropped;
/// - images, HTML and rules are left out.
///
/// Each sentence knows its block and where it sits in that block's text, so the reply can light
/// up the sentence being read.
public struct SpokenScript: Hashable, Sendable {
    public var sentences: [SpokenSentence]

    public init(sentences: [SpokenSentence]) {
        self.sentences = sentences
    }

    /// Everything, as one text.
    public var text: String {
        sentences.map(\.text).joined(separator: " ")
    }
}

public struct SpokenSentence: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case words
        /// A code block, described.
        case code(language: String?)
        /// A table, described.
        case table(rows: Int)
    }

    public var text: String
    public var kind: Kind
    /// The top-level block it comes from (`MarkdownDocument.blocks`).
    public var block: Int
    /// Its place in that block's `MarkdownBlock.readableText`, in `Character`s. Empty for a
    /// description.
    public var range: Range<Int>

    public init(text: String, kind: Kind = .words, block: Int, range: Range<Int>) {
        self.text = text
        self.kind = kind
        self.block = block
        self.range = range
    }
}

/// How code and tables are spoken (Settings → Voice & Audio → Code and tables).
public enum SpokenDetail: String, Sendable, Hashable, CaseIterable {
    case describe, skip
}

/// The sentences that stand for code and tables. The app passes its localised ones.
public struct SpokenDescriptions: Sendable {
    public var code: @Sendable (_ language: String?) -> String
    public var table: @Sendable (_ rows: Int) -> String

    public init(code: @escaping @Sendable (String?) -> String, table: @escaping @Sendable (Int) -> String) {
        self.code = code
        self.table = table
    }

    public static let english = SpokenDescriptions(
        code: { language in
            if let language, !language.isEmpty {
                return "I put the \(SpokenDescriptions.languageName(language)) code in the chat."
            }
            return "I put the code in the chat."
        },
        table: { rows in rows == 1 ? "I put a table with 1 row in the chat." : "I put a table with \(rows) rows in the chat." }
    )

    /// "swift" → "Swift", "sh" → "shell".
    public static func languageName(_ language: String) -> String {
        switch language.lowercased() {
        case "sh", "bash", "zsh", "shell", "console": "shell"
        case "js", "javascript": "JavaScript"
        case "ts", "typescript": "TypeScript"
        case "py", "python": "Python"
        case "swift": "Swift"
        case "json": "JSON"
        case "yaml", "yml": "YAML"
        case "sql": "SQL"
        case "html": "HTML"
        case "css": "CSS"
        case "diff", "patch": "diff"
        default: language
        }
    }
}

extension MarkdownDocument {
    /// The reply as it's read aloud.
    public func spokenScript(detail: SpokenDetail = .describe, descriptions: SpokenDescriptions = .english) -> SpokenScript {
        var sentences: [SpokenSentence] = []
        for (index, block) in blocks.enumerated() {
            sentences += block.spokenSentences(index: index, detail: detail, descriptions: descriptions)
        }
        return SpokenScript(sentences: sentences)
    }

    /// Readable text for speech and previews: formatting dropped, code and tables described.
    public var spokenText: String {
        spokenScript().text
    }
}

extension MarkdownBlock {
    /// The block's words as a reader sees them, which sentence ranges point into.
    public var readableText: String {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            MarkdownInline.spoken(inlines)
        case .blockQuote(let blocks):
            blocks.map(\.readableText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .list(let list):
            list.items.map { item in item.blocks.map(\.readableText).filter { !$0.isEmpty }.joined(separator: " ") }
                .joined(separator: "\n")
        case .codeBlock, .table, .thematicBreak, .html:
            ""
        }
    }

    func spokenSentences(index: Int, detail: SpokenDetail, descriptions: SpokenDescriptions) -> [SpokenSentence] {
        switch self {
        case .codeBlock(let language, _):
            guard detail == .describe else { return [] }
            return [SpokenSentence(text: descriptions.code(language), kind: .code(language: language), block: index, range: 0..<0)]
        case .table(let table):
            guard detail == .describe else { return [] }
            return [SpokenSentence(text: descriptions.table(table.rows.count), kind: .table(rows: table.rows.count), block: index, range: 0..<0)]
        case .thematicBreak, .html:
            return []
        case .paragraph, .heading, .blockQuote, .list:
            let text = readableText
            return SentenceSplitter.sentences(in: text).map { range in
                SpokenSentence(text: String(text[range.lowerBound..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                               block: index,
                               range: text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound))
            }
            .filter { !$0.text.isEmpty }
        }
    }
}

extension MarkdownInline {
    /// Inline content as it's spoken: link words without their address, no bare URLs, no images.
    static func spoken(_ inlines: [MarkdownInline]) -> String {
        inlines.map(\.spokenText).joined()
    }

    var spokenText: String {
        switch self {
        case .text(let text):
            Self.withoutURLs(text)
        case .code(let code):
            code
        case .emphasis(let content), .strong(let content), .strikethrough(let content):
            Self.spoken(content)
        case .link(let destination, let content):
            // An autolink's words are its address: say nothing rather than spell out a URL.
            Self.spoken(content) == destination ? "" : Self.spoken(content)
        case .image:
            ""
        case .softBreak:
            " "
        case .lineBreak:
            "\n"
        }
    }

    static func withoutURLs(_ text: String) -> String {
        guard text.contains("://") || text.contains("www.") else { return text }
        return text.replacingOccurrences(of: #"https?://\S+|www\.\S+"#, with: "", options: .regularExpression)
    }
}

/// Sentences in a block's text, as ranges.
public enum SentenceSplitter {
    public static func sentences(in text: String) -> [Range<String.Index>] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Lines (list items, a heading's words) are sentences of their own.
            var start = range.lowerBound
            for line in text[range].split(separator: "\n", omittingEmptySubsequences: false) {
                let end = line.endIndex
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { ranges.append(start..<end) }
                start = end < range.upperBound ? text.index(after: end) : end
            }
            return true
        }
        return ranges
    }
}

/// A reply that's still arriving, read as it comes (`docs/voice.md` §4.2): each call takes the
/// whole answer so far and hands back the sentences that are now complete and haven't been
/// handed out. The last sentence of a block still streaming waits (it may not be finished), and
/// a code block or table is described once it's complete.
public struct SpokenStream: Sendable {
    public var detail: SpokenDetail
    public var descriptions: SpokenDescriptions
    /// Sentences handed out so far, per block.
    private var given: [Int: Int] = [:]
    private var lastBlock = 0
    /// The answer at the last update: one that doesn't continue it is a new answer (after a tool
    /// call), read from its start.
    private var previous = ""

    public init(detail: SpokenDetail = .describe, descriptions: SpokenDescriptions = .english) {
        self.detail = detail
        self.descriptions = descriptions
    }

    public mutating func update(_ answer: String, isFinished: Bool) -> [SpokenSentence] {
        if !answer.hasPrefix(previous) {
            given = [:]
            lastBlock = 0
        }
        previous = answer
        let document = MarkdownDocument(parsing: answer)
        guard !document.blocks.isEmpty else { return [] }
        var ready: [SpokenSentence] = []
        let last = document.blocks.count - 1
        // The same answer can parse to fewer blocks as it grows (a "[1]:" paragraph turning into a
        // link definition); a backwards range would stop the app (security scan F23).
        lastBlock = min(lastBlock, last)
        for index in lastBlock...last {
            let block = document.blocks[index]
            var sentences = block.spokenSentences(index: index, detail: detail, descriptions: descriptions)
            if index == last, !isFinished {
                switch block {
                case .codeBlock, .table:
                    // Not closed yet: describe it once it is.
                    sentences = []
                default:
                    sentences = Array(sentences.dropLast())
                }
            }
            let already = given[index] ?? 0
            if sentences.count > already {
                ready += sentences[already...]
                given[index] = sentences.count
            }
        }
        // Blocks before the last are settled; start from the last one next time.
        lastBlock = last
        return ready
    }
}
