import Foundation
import HermesMarkdown

/// Parsed Markdown and tokenized code, kept by their text, so a reply is parsed once: not on every
/// redraw, not again when the chat is opened again, and ahead of time off the main thread
/// (`prewarm`) when a transcript arrives, so opening a chat doesn't parse on the main thread.
nonisolated enum MarkdownCache {
    private final class DocumentBox {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private final class TokensBox {
        let tokens: [CodeHighlighter.Token]
        init(_ tokens: [CodeHighlighter.Token]) { self.tokens = tokens }
    }

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private final class HighlightBox {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }

    // NSCache is thread-safe and gives memory back under pressure.
    nonisolated(unsafe) private static let documents: NSCache<NSString, DocumentBox> = {
        let cache = NSCache<NSString, DocumentBox>()
        cache.countLimit = 400
        return cache
    }()

    nonisolated(unsafe) private static let tokens: NSCache<NSString, TokensBox> = {
        let cache = NSCache<NSString, TokensBox>()
        cache.countLimit = 200
        return cache
    }()

    /// Finished code blocks, highlighted: the attributed text is built once rather than run by
    /// run on every redraw. (Its colours are the theme's, which adapt to light and dark.)
    nonisolated(unsafe) private static let highlighted: NSCache<NSString, HighlightBox> = {
        let cache = NSCache<NSString, HighlightBox>()
        cache.countLimit = 120
        return cache
    }()

    static func highlighted(_ code: String, language: String?, build: ([CodeHighlighter.Token]) -> AttributedString) -> AttributedString {
        let key = "\(language ?? "")\u{0}\(code)" as NSString
        if let hit = highlighted.object(forKey: key) { return hit.text }
        let text = build(tokens(for: code, language: language))
        highlighted.setObject(HighlightBox(text), forKey: key)
        return text
    }

    // MARK: Streaming

    // A reply still arriving changes with every token, but up to its last finished paragraph
    // (and a code block up to its last finished line) it only grows now and then. That part is
    // parsed once and kept here, apart from the finished replies, for the few replies streaming
    // now; only what is still arriving is parsed again.
    nonisolated(unsafe) private static let streamingHeads: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 12
        return cache
    }()

    nonisolated(unsafe) private static let streamingCode: NSCache<NSString, HighlightBox> = {
        let cache = NSCache<NSString, HighlightBox>()
        cache.countLimit = 12
        return cache
    }()

    /// The blocks of a reply still streaming: its finished paragraphs from the cache, the one
    /// still arriving parsed. A whole-text parse when no cut is safe.
    static func streamingBlocks(for text: String) -> [MarkdownBlock] {
        guard let cut = MarkdownDocument.streamingCut(in: text) else { return MarkdownDocument(parsing: text).blocks }
        let head = String(text[..<cut])
        let key = head as NSString
        let headBlocks: [MarkdownBlock]
        if let hit = streamingHeads.object(forKey: key) {
            headBlocks = hit.blocks
        } else {
            headBlocks = MarkdownDocument(parsing: head).blocks
            streamingHeads.setObject(BlocksBox(headBlocks), forKey: key)
        }
        return headBlocks + MarkdownDocument(parsing: String(text[cut...])).blocks
    }

    /// Highlighted code still streaming: its finished lines from the cache, the line arriving
    /// highlighted with `highlight`.
    static func streamingHighlight(_ code: String, language: String?, highlight: (String) -> AttributedString) -> AttributedString {
        guard let cut = code.lastIndex(of: "\n") else { return highlight(code) }
        let head = String(code[...cut])
        let key = "\(language ?? "")\u{0}\(head)" as NSString
        var result: AttributedString
        if let hit = streamingCode.object(forKey: key) {
            result = hit.text
        } else {
            result = highlight(head)
            streamingCode.setObject(HighlightBox(result), forKey: key)
        }
        result.append(highlight(String(code[code.index(after: cut)...])))
        return result
    }

    // MARK: Finished text

    static func document(for text: String) -> MarkdownDocument {
        let key = text as NSString
        if let hit = documents.object(forKey: key) { return hit.document }
        let document = MarkdownDocument(parsing: text)
        documents.setObject(DocumentBox(document), forKey: key)
        return document
    }

    static func tokens(for code: String, language: String?) -> [CodeHighlighter.Token] {
        let key = "\(language ?? "")\u{0}\(code)" as NSString
        if let hit = tokens.object(forKey: key) { return hit.tokens }
        let result = CodeHighlighter.tokenize(code, language: language)
        tokens.setObject(TokensBox(result), forKey: key)
        return result
    }

    /// Parses these texts (and tokenizes their code) off the main thread.
    static func prewarm(_ texts: [String]) async {
        guard !texts.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for text in texts {
                for block in document(for: text).blocks {
                    if case .codeBlock(let language, let code) = block {
                        // The highlighted text itself, not only its tokens: building it run by run
                        // on the main thread cost tens of milliseconds per long block as it drew.
                        _ = highlighted(code, language: language, build: CodeBlockView.attributed)
                    }
                }
            }
        }.value
    }
}
