import Foundation
import HermesMarkdown
import os

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

    // A reply still arriving grows with every token and is drawn again each time. Its finished
    // paragraphs are parsed once and kept (`MarkdownDocument.Stream`), and so are the finished
    // lines of a code block, tinted (`CodeHighlighter.Stream`), for the few replies streaming
    // now; each redraw parses and tints only what is new, so the cost stays flat however long the
    // reply grows.
    private struct CodeStream: Sendable {
        var stream: CodeHighlighter.Stream
        /// The tokens handed out for good, tinted.
        var text = AttributedString()
        /// The code last asked for and what it drew, for a block that has finished arriving
        /// but is drawn again while the rest of its reply streams.
        var code = ""
        var drawn = AttributedString()
    }

    private struct Streams: Sendable {
        var replies: [MarkdownDocument.Stream] = []
        var code: [CodeStream] = []
    }

    /// Replies streaming at once (a group chat's Bots), and the code blocks in them. Every code
    /// block of a streaming reply is drawn again on each redraw, in order, and each one drawn goes
    /// to the front: a reply with more blocks than are kept would push out each block just before
    /// it is drawn and tint them all from scratch every time, so a long tutorial's worth are kept.
    private static let repliesKept = 6
    private static let codeKept = 64
    private static let streams = OSAllocatedUnfairLock(initialState: Streams())

    /// The blocks of a reply still streaming, the same as parsing the whole text.
    static func streamingBlocks(for text: String) -> [MarkdownBlock] {
        // The stream is taken out while it parses, so the lock is never held for a parse.
        var stream = streams.withLock { streams in
            let best = streams.replies.indices
                .filter { streams.replies[$0].continues(text) }
                .max { streams.replies[$0].parsedLength < streams.replies[$1].parsedLength }
            return best.map { streams.replies.remove(at: $0) } ?? MarkdownDocument.Stream()
        }
        let blocks = stream.blocks(for: text)
        let parsed = stream
        streams.withLock { streams in
            streams.replies.insert(parsed, at: 0)
            streams.replies = Array(streams.replies.prefix(repliesKept))
        }
        return blocks
    }

    /// Code still streaming, tinted with `build`: the lines tinted before are kept, only the new
    /// ones are tokenized.
    static func streamingHighlight(_ code: String, language: String?, build: ([CodeHighlighter.Token]) -> AttributedString) -> AttributedString {
        // A block already drawn as it is now is answered as it was; otherwise the stream that has
        // the most of it finished goes on from there.
        let found: (kept: CodeStream, same: Bool) = streams.withLock { streams in
            if let same = streams.code.firstIndex(where: { $0.code == code && $0.stream.language == language }) {
                let kept = streams.code.remove(at: same)
                streams.code.insert(kept, at: 0)
                return (kept, true)
            }
            let best = streams.code.indices
                .filter { streams.code[$0].stream.continues(code, language: language) }
                .max { streams.code[$0].stream.finishedLength < streams.code[$1].stream.finishedLength }
            return (best.map { streams.code.remove(at: $0) } ?? CodeStream(stream: CodeHighlighter.Stream(language: language)), false)
        }
        guard !found.same else { return found.kept.drawn }
        var kept = found.kept
        let (final, rest) = kept.stream.advance(to: code)
        if !final.isEmpty { kept.text.append(build(final)) }
        var result = kept.text
        result.append(build(rest))
        kept.code = code
        kept.drawn = result
        let done = kept
        streams.withLock { streams in
            streams.code.insert(done, at: 0)
            streams.code = Array(streams.code.prefix(codeKept))
        }
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
                        // Keyed by what the block shows, as `CodeBlockView` asks for it.
                        _ = highlighted(CodeBlockLayout.shown(code).text, language: language, build: CodeBlockView.attributed)
                    }
                }
            }
        }.value
    }
}
