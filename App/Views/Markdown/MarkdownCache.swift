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
                        _ = tokens(for: code, language: language)
                    }
                }
            }
        }.value
    }
}
