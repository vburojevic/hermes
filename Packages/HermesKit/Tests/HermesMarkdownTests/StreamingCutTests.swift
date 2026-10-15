import Testing
@testable import HermesMarkdown

@Suite("Streaming cut")
struct StreamingCutTests {
    /// The halves either side of the cut parse to the same blocks as the whole.
    private func expectSplitParsesTheSame(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let cut = MarkdownDocument.streamingCut(in: text) else { return }
        let split = MarkdownDocument(parsing: String(text[..<cut])).blocks + MarkdownDocument(parsing: String(text[cut...])).blocks
        #expect(split == MarkdownDocument(parsing: text).blocks, "cut at \(text.distance(from: text.startIndex, to: cut)) of \(text.count)", sourceLocation: sourceLocation)
    }

    @Test func cutsBeforeTheParagraphStillArriving() {
        let text = "One **bold** line.\n\nTwo lines\nof prose.\n\nThree, still arriv"
        let cut = MarkdownDocument.streamingCut(in: text)
        #expect(cut.map { String(text[$0...]) } == "Three, still arriv")
        expectSplitParsesTheSame(text)
    }

    @Test func neverInsideAnOpenCodeFence() {
        let text = "Intro\n\n```swift\nlet a = 1\n\nlet b"
        let cut = MarkdownDocument.streamingCut(in: text)
        #expect(cut.map { String(text[$0...]) } == "```swift\nlet a = 1\n\nlet b")
        expectSplitParsesTheSame(text)
    }

    @Test func notBeforeWhatCouldContinueABlock() {
        for text in ["1. a\n\n2. b", "> a\n\n> b", "- item\n\n  more of it", "| a | b |\n\n| c | d |", "<div>\n\n</div>"] {
            #expect(MarkdownDocument.streamingCut(in: text) == nil, "\(text)")
        }
    }

    @Test func listsTablesAndHeadingsBeforeTheCut() {
        expectSplitParsesTheSame("# Title\n\nIntro\n\n- a\n\n- b\n\nAfter the list")
        expectSplitParsesTheSame("| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter the table")
        expectSplitParsesTheSame("> quoted\n> more\n\nAfter the quote")
    }

    /// A reply as it streams in, one character at a time: every prefix splits the same way it
    /// parses whole.
    @Test func everyPrefixOfAReplyParsesTheSameSplit() {
        let reply = """
        Here's what I found about **Swift 6.4 concurrency** and how it applies to your project.

        ## Highlights

        - `@concurrent` functions now run on the global executor by default
        - Default actor isolation can be set per module with `SWIFT_DEFAULT_ACTOR_ISOLATION`

        1. Turn on complete checking
        2. Adopt `MainActor` default isolation for the app target

        > Tip: enable the upcoming features one at a time.

        ```swift
        @MainActor
        final class FeedModel {
            private(set) var items: [Item] = []

            func refresh() async throws {
                items = try await api.items()
            }
        }
        ```

        | Setting | Before | After |
        |---|---|---|
        | Strict concurrency | minimal | complete |

        Then *run the tests* and ship it. See [the guide](https://swift.org) for more.

        ---

        That's all.
        """
        var prefix = ""
        for character in reply {
            prefix.append(character)
            expectSplitParsesTheSame(prefix)
        }
    }
}
