import Testing
@testable import HermesMarkdown

@Suite("Spoken text")
struct SpokenTextTests {
    private func spoken(_ markdown: String, detail: SpokenDetail = .describe) -> [String] {
        MarkdownDocument(parsing: markdown).spokenScript(detail: detail).sentences.map(\.text)
    }

    @Test func proseIsReadWithoutMarkup() {
        #expect(spoken("The **NAS** is at *61%*. Snapshots take `148 GB`.") == ["The NAS is at 61%.", "Snapshots take 148 GB."])
    }

    @Test func headingsAndListItemsAreSentences() {
        #expect(spoken("## Results\n\n- Deleted 14 snapshots\n- Kept the weekly ones") == ["Results", "Deleted 14 snapshots", "Kept the weekly ones"])
    }

    @Test func codeAndTablesAreDescribed() {
        let reply = "Here it is:\n\n```swift\nlet x = 1\n```\n\n| Day | GB |\n|---|---|\n| Mon | 3 |\n| Tue | 4 |\n| Wed | 5 |\n| Thu | 6 |\n\nDone."
        #expect(spoken(reply) == ["Here it is:", "I put the Swift code in the chat.", "I put a table with 4 rows in the chat.", "Done."])
        #expect(spoken(reply, detail: .skip) == ["Here it is:", "Done."])
        #expect(spoken("```\nls\n```") == ["I put the code in the chat."])
    }

    @Test func linksReadTheirWordsNeverTheirAddress() {
        #expect(spoken("See [the release notes](https://example.com/notes) for more.") == ["See the release notes for more."])
        #expect(spoken("Open https://example.com/a/very/long/path now.") == ["Open  now."].map { $0.replacingOccurrences(of: "  ", with: " ") }
            || spoken("Open https://example.com/a/very/long/path now.") == ["Open  now."])
        #expect(!spoken("Docs: <https://example.com>.").joined().contains("example.com"))
    }

    @Test func imagesAndRulesAreLeftOut() {
        #expect(spoken("Before.\n\n![chart](chart.png)\n\n---\n\nAfter.") == ["Before.", "After."])
    }

    @Test func sentencesKnowWhereTheyAre() {
        let document = MarkdownDocument(parsing: "First block.\n\nSecond one. And more.")
        let sentences = document.spokenScript().sentences
        #expect(sentences.map(\.block) == [0, 1, 1])
        let text = document.blocks[1].readableText
        let second = sentences[2]
        let start = text.index(text.startIndex, offsetBy: second.range.lowerBound)
        let end = text.index(text.startIndex, offsetBy: second.range.upperBound)
        #expect(text[start..<end].trimmingCharacters(in: .whitespaces) == "And more.")
    }

    @Test func aStreamingReplyGivesEachSentenceOnce() {
        var stream = SpokenStream()
        #expect(stream.update("Hello there. How", isFinished: false).map(\.text) == ["Hello there."])
        #expect(stream.update("Hello there. How are you? I", isFinished: false).map(\.text) == ["How are you?"])
        #expect(stream.update("Hello there. How are you? I checked.\n\nAll good", isFinished: false).map(\.text) == ["I checked."])
        #expect(stream.update("Hello there. How are you? I checked.\n\nAll good.", isFinished: true).map(\.text) == ["All good."])
    }
}
