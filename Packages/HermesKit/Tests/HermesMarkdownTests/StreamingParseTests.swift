import Testing
@testable import HermesMarkdown

/// A reply parsed as it streams (`MarkdownDocument.Stream`) and code tinted as it streams
/// (`CodeHighlighter.Stream`) give what a parse of the whole text gives, at every step.
@Suite("Streaming parse")
struct StreamingParseTests {
    static let reply = """
    Here's what I found about **Swift 6.4 concurrency** and how it applies to your project.

    ## Highlights

    - `@concurrent` functions now run on the global executor by default
    - Default actor isolation can be set per module
      - nested under it, with *emphasis*
        1. and deeper, numbered
        2. still deeper

    1. Turn on complete checking
    2. Adopt `MainActor` default isolation for the app target

    > Tip: enable the upcoming features one at a time.
    > A second quoted line.

    ```swift
    @MainActor
    final class FeedModel {
        /* A comment
           over two lines */
        private(set) var items: [Item] = []

        func refresh() async throws {
            items = try await api.items(page: 0x1F)
        }
    }
    ```

    Some prose between the fences, with a link to https://swift.org and `inline code`.

    ```python
    def summarize(rows):
        \"\"\"Sum the rows,
        a docstring over lines.\"\"\"
        return sum(r["total"] for r in rows)  # a comment
    ```

    | Setting | Before | After |
    |:---|:---:|---:|
    | Strict concurrency | minimal | complete |
    | Isolation | none | `MainActor` |

    ```js
    const total = rows.reduce((sum, row) => sum + row.total, 0);
    const label = `total: ${total}
    across lines`;
    ```

    ```json
    {"name": "hermes", "count": 3, "ok": true}
    ```

    ```diff
    - let a = 1
    + let a = 2
    ```

    ```
    plain code with no language
    ```

    Then *run the tests* and ship it. See [the guide](https://swift.org) for more.

    ---

    # A heading after a rule

    That's all, ünïcödé and 😀 included.
    """

    // MARK: Markdown

    private func expectStreams(_ chunks: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        var stream = MarkdownDocument.Stream()
        var text = ""
        var parsed = 0
        for chunk in chunks {
            text += chunk
            let blocks = stream.blocks(for: text)
            #expect(blocks == MarkdownDocument(parsing: text).blocks, "at \(text.utf8.count) bytes", sourceLocation: sourceLocation)
            #expect(stream.parsedLength >= parsed, "the parsed part never shrinks while the text grows", sourceLocation: sourceLocation)
            parsed = stream.parsedLength
        }
        // Most of the reply was parsed once and kept, not parsed again on every step.
        #expect(stream.parsedLength > text.utf8.count / 2, sourceLocation: sourceLocation)
    }

    @Test func oneCharacterAtATime() {
        expectStreams(Self.reply.map { String($0) })
    }

    @Test func lineByLine() {
        expectStreams(Self.reply.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { $0 == 0 ? String($1) : "\n" + $1 })
    }

    @Test(arguments: [1, 7, 42, 2026])
    func randomChunks(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        expectStreams(Self.chunks(of: Self.reply, generator: &generator))
    }

    @Test func aFenceOpenedInOneChunkAndClosedInALaterOne() {
        expectStreams([
            "Intro paragraph.\n\n```swift\nlet a = 1\n",
            "\nlet b = 2\n\nWords inside the fence\n",
            "```\n\nAfter the fence.\n\nMore",
        ])
        var stream = MarkdownDocument.Stream()
        _ = stream.blocks(for: "Intro.\n\n```swift\nlet a = 1\n\nInside")
        #expect(stream.parsedLength == "Intro.\n\n".utf8.count, "no cut inside the open fence")
    }

    @Test func aShorterTextStartsTheSearchAgain() {
        var stream = MarkdownDocument.Stream()
        for text in ["One.\n\nTwo **bo", "One.\n\nTwo ", "One.\n\nTwo **bold** and\n\nThree", "Something else entirely.\n\nNew"] {
            #expect(stream.blocks(for: text) == MarkdownDocument(parsing: text).blocks, "\(text)")
        }
    }

    /// A cut is safe because of the character after it: another reply that matches up to the cut
    /// but has a list item there (a retry of the same prompt) doesn't keep it.
    @Test func aDifferentCharacterAtTheCutStartsOver() {
        var stream = MarkdownDocument.Stream()
        _ = stream.blocks(for: "- a\n- b\n\nThen more.")
        let retry = "- a\n- b\n\n- c"
        #expect(!stream.continues(retry))
        #expect(stream.blocks(for: retry) == MarkdownDocument(parsing: retry).blocks)
        #expect(stream.blocks(for: "- a\n- b\n\n- c\n\nThen more.") == MarkdownDocument(parsing: "- a\n- b\n\n- c\n\nThen more.").blocks)
        #expect(stream.continues("- a\n- b\n\n- c\n\nThen more, and more."))
    }

    /// A "~~~" fence isn't counted, so once one appears nothing after it is cut.
    @Test func aTildeFenceStopsTheCuts() {
        let text = "Intro.\n\nMore intro.\n\n~~~\ncode\n\nstill code\n~~~\n\nAfter.\n\nMore"
        var stream = MarkdownDocument.Stream()
        var prefix = ""
        for character in text {
            prefix.append(character)
            #expect(stream.blocks(for: prefix) == MarkdownDocument(parsing: prefix).blocks)
        }
        #expect(stream.parsedLength == "Intro.\n\n".utf8.count)
    }

    // MARK: Code

    static let code: [(language: String?, code: String)] = [
        ("swift", "@MainActor\nfinal class Feed {\n    /* open\n       comment */\n    let s = \"\"\"\n    multi\n    \"\"\"\n    func load(_ id: Int) -> [Item] { items.filter { $0.id == 0x2A } }\n}\n"),
        ("python", "def f(rows):\n    \"\"\"Doc\n    more doc.\"\"\"\n    return {\"a\": 1, 'b': 2.5}  # note\n@decorator\nclass A: pass\n"),
        ("js", "const a = `template\nacross ${lines}`;\nfunction go(x) { return x * 2 } // done\nlet s = 'unterminated\nnext();\n"),
        ("json", "{\n  \"key\": \"value\",\n  \"n\": 12,\n  \"list\": [true, null]\n}\n"),
        ("bash", "#!/bin/sh\necho $# ${#arr} # count\nif [ -f x ]; then\n  exit 1\nfi\n"),
        ("c", "#include <stdio.h>\nint main(void) {\n  /* block */ printf(\"%d\\n\", 42);\n}\n"),
        ("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n context\n"),
        (nil, "no language\nat all\n"),
        ("brainfuck", "+++[>++<-]\n>.\n"),
    ]

    /// Adjacent tokens of one kind merged: how they draw.
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

    @Test(arguments: 0..<code.count)
    func codeTintsAsTheWholeAtEveryStep(index: Int) {
        let (language, code) = Self.code[index]
        var stream = CodeHighlighter.Stream(language: language)
        var final: [CodeHighlighter.Token] = []
        var prefix = ""
        for character in code {
            prefix.append(character)
            #expect(stream.continues(prefix, language: language))
            let (new, rest) = stream.advance(to: prefix)
            final += new
            #expect(Self.drawn(final + rest) == Self.drawn(CodeHighlighter.tokenize(prefix, language: language)),
                    "\(language ?? "plain") at \(prefix.count) characters")
        }
        // The lines before the last two were tokenized once and handed out, not again.
        let finalLength = final.map(\.text.count).reduce(0, +)
        #expect(finalLength >= code.count / 2, "\(language ?? "plain"): \(finalLength) of \(code.count) final")
    }

    @Test func codeThatChangesIsNotContinued() {
        var stream = CodeHighlighter.Stream(language: "swift")
        _ = stream.advance(to: "let a = 1\nlet b = 2\nlet c")
        #expect(stream.continues("let a = 1\nlet b = 2\nlet c = 3", language: "swift"))
        #expect(!stream.continues("let x = 1\nlet b = 2\n", language: "swift"))
        #expect(!stream.continues("let a = 1\nlet b = 2\nlet c", language: "python"))
    }

    // MARK: Helpers

    private static func chunks(of text: String, generator: inout SeededGenerator) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let size = Int.random(in: 1...80, using: &generator)
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return result
    }
}

/// SplitMix64: random chunk sizes that are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
