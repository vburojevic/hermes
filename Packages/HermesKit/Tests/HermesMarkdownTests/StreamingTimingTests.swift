import Foundation
import Testing
@testable import HermesMarkdown

/// How long a long reply takes to parse and tint while it streams, redraw by redraw: a whole parse
/// of every prefix, the cut-and-cache path the app had before `MarkdownDocument.Stream`, and the
/// streams. Slow, so it runs only when asked, in release:
///
///     HERMES_STREAMING_TIMING=1 swift test -c release -Xswiftc -enable-testing --filter StreamingTiming
@Suite("Streaming timing", .enabled(if: ProcessInfo.processInfo.environment["HERMES_STREAMING_TIMING"] != nil))
struct StreamingTimingTests {
    @Test func aLongReplyStreamedDeltaByDelta() {
        let reply = Self.longReply()
        let prefixes = Self.prefixes(of: reply)
        #expect(reply.utf8.count >= 40_000)

        // The streams give what a whole parse gives at every prefix.
        var check = Incremental()
        for prefix in prefixes {
            let blocks = check.blocks(for: prefix)
            #expect(blocks == MarkdownDocument(parsing: prefix).blocks, "at \(prefix.utf8.count) bytes")
            for (language, code) in Self.codeBlocks(in: blocks) {
                #expect(Self.drawn(check.tokens(code, language: language)) == Self.drawn(CodeHighlighter.tokenize(code, language: language)))
            }
        }

        var lines = ["Reply: \(reply.utf8.count) bytes, \(prefixes.count) prefixes, \(Self.codeBlocks(in: MarkdownDocument(parsing: reply).blocks).count) code blocks"]
        lines.append(Self.time("whole parse", prefixes) { Whole() })
        lines.append(Self.time("before (cut + cache)", prefixes) { CutAndCache() })
        lines.append(Self.time("streams", prefixes) { Incremental() })
        print(lines.joined(separator: "\n"))
    }

    // MARK: The three paths

    private protocol Path {
        mutating func blocks(for text: String) -> [MarkdownBlock]
        mutating func tokens(_ code: String, language: String?) -> [CodeHighlighter.Token]
    }

    /// Parses and tints everything again on each redraw.
    private struct Whole: Path {
        mutating func blocks(for text: String) -> [MarkdownBlock] { MarkdownDocument(parsing: text).blocks }
        mutating func tokens(_ code: String, language: String?) -> [CodeHighlighter.Token] {
            CodeHighlighter.tokenize(code, language: language)
        }
    }

    /// The app's streaming path before the streams: the latest safe cut found by looking back
    /// from the end and counting fences over the whole head, the head parsed once per cut, and a
    /// code block's finished lines tinted once per new line. Its caches never evict here, which
    /// favours it.
    private struct CutAndCache: Path {
        var heads: [String: [MarkdownBlock]] = [:]
        var codeHeads: [String: [CodeHighlighter.Token]] = [:]

        mutating func blocks(for text: String) -> [MarkdownBlock] {
            guard let cut = Self.cut(in: text) else { return MarkdownDocument(parsing: text).blocks }
            let head = String(text[..<cut])
            let headBlocks = heads[head] ?? MarkdownDocument(parsing: head).blocks
            heads[head] = headBlocks
            return headBlocks + MarkdownDocument(parsing: String(text[cut...])).blocks
        }

        mutating func tokens(_ code: String, language: String?) -> [CodeHighlighter.Token] {
            guard let cut = code.lastIndex(of: "\n") else { return CodeHighlighter.tokenize(code, language: language) }
            let head = String(code[...cut])
            let key = "\(language ?? "")\u{0}\(head)"
            let headTokens = codeHeads[key] ?? CodeHighlighter.tokenize(head, language: language)
            codeHeads[key] = headTokens
            return headTokens + CodeHighlighter.tokenize(String(code[code.index(after: cut)...]), language: language)
        }

        static func cut(in text: String) -> String.Index? {
            var searchEnd = text.endIndex
            for _ in 0..<24 {
                guard let gap = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<searchEnd) else { return nil }
                var start = gap.upperBound
                while start < text.endIndex, text[start] == "\n" { start = text.index(after: start) }
                if start < text.endIndex, text[start].isLetter || "#`\"“‘(".contains(text[start]),
                   text[..<gap.lowerBound].countBytes("```") % 2 == 0, !text[..<gap.lowerBound].containsBytes("~~~") {
                    return start
                }
                searchEnd = gap.lowerBound
            }
            return nil
        }
    }

    /// `MarkdownDocument.Stream` and `CodeHighlighter.Stream`, kept as the app keeps them
    /// (`MarkdownCache`): a block drawn as it is now is answered as it was.
    private struct Incremental: Path {
        struct Code {
            var stream: CodeHighlighter.Stream
            var final: [CodeHighlighter.Token] = []
            var code = ""
            var drawn: [CodeHighlighter.Token] = []
        }

        var stream = MarkdownDocument.Stream()
        var code: [Code] = []

        mutating func blocks(for text: String) -> [MarkdownBlock] { stream.blocks(for: text) }

        mutating func tokens(_ code: String, language: String?) -> [CodeHighlighter.Token] {
            if let same = self.code.first(where: { $0.code == code && $0.stream.language == language }) { return same.drawn }
            var entry = self.code.indices
                .filter { self.code[$0].stream.continues(code, language: language) }
                .max { self.code[$0].stream.finishedLength < self.code[$1].stream.finishedLength }
                .map { self.code.remove(at: $0) } ?? Code(stream: CodeHighlighter.Stream(language: language))
            let (final, rest) = entry.stream.advance(to: code)
            entry.final += final
            entry.code = code
            entry.drawn = entry.final + rest
            self.code.insert(entry, at: 0)
            return entry.drawn
        }
    }

    /// The best of five runs' totals is no use for a spread, so all five are kept.
    private static func time(_ name: String, _ prefixes: [String], _ make: () -> some Path) -> String {
        var parse: [Duration] = []
        var tint: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<5 {
            var path = make()
            var parsing = Duration.zero
            var tinting = Duration.zero
            for prefix in prefixes {
                var blocks: [MarkdownBlock] = []
                parsing += clock.measure { blocks = path.blocks(for: prefix) }
                let codes = codeBlocks(in: blocks)
                tinting += clock.measure {
                    for (language, code) in codes { _ = path.tokens(code, language: language) }
                }
            }
            parse.append(parsing)
            tint.append(tinting)
        }
        let total = zip(parse, tint).map { $0 + $1 }
        return "\(name): parse \(summary(parse)), tint \(summary(tint)), total \(summary(total))"
    }

    private static func summary(_ runs: [Duration]) -> String {
        let ms = runs.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }.sorted()
        return String(format: "median %.1f ms (%.1f–%.1f)", ms[ms.count / 2], ms.first!, ms.last!)
    }

    // MARK: The reply

    /// What a code block draws, as `CodeBlockView` asks for it, for each top-level code block.
    private static func codeBlocks(in blocks: [MarkdownBlock]) -> [(String?, String)] {
        blocks.compactMap { block in
            guard case .codeBlock(let language, let code) = block else { return nil }
            return (language, CodeBlockLayout.shown(code).text)
        }
    }

    private static func drawn(_ tokens: [CodeHighlighter.Token]) -> [CodeHighlighter.Token] {
        var result: [CodeHighlighter.Token] = []
        for token in tokens where !token.text.isEmpty {
            if let last = result.last, last.kind == token.kind {
                result[result.count - 1].text += token.text
            } else {
                result.append(token)
            }
        }
        return result
    }

    /// The text after each delta, six words at a time as the mock gateway streams (`stream_text`).
    private static func prefixes(of text: String) -> [String] {
        let words = text.matches(of: /\S+\s*|\s+/).map { String($0.output) }
        var result: [String] = []
        var prefix = ""
        for start in stride(from: 0, to: words.count, by: 6) {
            prefix += words[start..<min(start + 6, words.count)].joined()
            result.append(prefix)
        }
        return result
    }

    /// About 50 KB: twelve sections of prose, nested lists, a table, a quote and code in four
    /// languages, and one long Swift file in the middle.
    static func longReply() -> String {
        var parts = ["Here's the whole migration, section by section, with the code for each step.\n"]
        let languages = ["swift", "python", "js", "json"]
        for section in 0..<12 {
            parts.append("## Step \(section + 1): \(["Turn on checking", "Isolate the models", "Move the networking", "Clean up the views"][section % 4])\n")
            for paragraph in 0..<3 {
                parts.append("Paragraph \(paragraph + 1) of step \(section + 1) explains **why this matters** for the app, what changes in `FeedModel` and its callers, and which warnings to expect once the flag is on. Read [the guide](https://swift.org/migration) for the background; the short version is that every type crossing an actor boundary has to be `Sendable`, and the compiler now says so instead of letting a race through. It takes a morning for a small module and a week for a big one.\n")
            }
            parts.append("- First, the setting:\n  - `SWIFT_STRICT_CONCURRENCY = complete` in *every* target\n    1. the app\n    2. the extensions\n- Then the warnings, one module at a time\n- Last, the tests\n")
            parts.append("| Module | Warnings | Fixed |\n|:---|---:|:---:|\n| App | \(section * 7 + 3) | yes |\n| Kit | \(section * 3 + 1) | no |\n| Push | 0 | yes |\n")
            parts.append(Self.code(language: languages[section % 4], lines: 36, seed: section))
            parts.append("> Tip: commit after each module, so a bad change is one revert away.\n> Step \(section + 1) of 12.\n")
            if section == 5 {
                parts.append("The whole file, as it ends up:\n")
                parts.append(Self.code(language: "swift", lines: 240, seed: 99))
            }
        }
        parts.append("That's everything. Run the tests after each step and ship it.\n")
        return parts.joined(separator: "\n")
    }

    private static func code(language: String, lines: Int, seed: Int) -> String {
        var body: [String] = []
        for line in 0..<lines {
            let n = seed * 100 + line
            switch language {
            case "swift":
                body.append([
                    "/// Loads page \(n) of the feed.",
                    "func loadPage\(n)(_ id: Int) async throws -> [Item] {",
                    "    let items = try await api.items(page: \(n), limit: 0x\(String(n, radix: 16)))",
                    "    return items.filter { $0.isVisible && $0.score > \(n % 10).5 } // keep the visible ones",
                    "}",
                    "",
                ][line % 6])
            case "python":
                body.append([
                    "def load_page_\(n)(rows):",
                    "    \"\"\"Sum the rows of page \(n).\"\"\"",
                    "    total = sum(r[\"total\"] for r in rows)  # the running total",
                    "    return {'page': \(n), 'total': total, 'ok': True}",
                    "",
                ][line % 5])
            case "js":
                body.append([
                    "const page\(n) = rows.filter((row) => row.page === \(n));",
                    "const label\(n) = `page ${page\(n).length} of \(n)`; // shown in the header",
                    "function total\(n)(rows) { return rows.reduce((sum, row) => sum + row.total, 0) }",
                    "",
                ][line % 4])
            default:
                body.append(line == 0 ? "{" : line == lines - 1 ? "  \"end\": true\n}" : "  \"key\(n)\": {\"page\": \(n), \"label\": \"page \(n)\", \"ok\": \(n % 2 == 0)},")
            }
        }
        return "```\(language)\n\(body.joined(separator: "\n"))\n```\n"
    }
}
