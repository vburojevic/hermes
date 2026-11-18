import Foundation
import Testing
@testable import HermesMarkdown

@Suite("Reply plain text")
struct ReplyPlainTextTests {
    private func plain(_ markdown: String) -> String {
        ReplyPlainText.text(MarkdownDocument(parsing: markdown).blocks)
    }

    private func units(_ markdown: String) -> [ReplyPlainText.Unit] {
        ReplyPlainText.units(MarkdownDocument(parsing: markdown).blocks)
    }

    @Test func blocksAreSeparatedByABlankLine() {
        #expect(plain("First **bold** and *soft*\nline.\n\nSecond with `code`.") == "First bold and soft line.\n\nSecond with code.")
    }

    @Test func headingsAreTheirWords() {
        #expect(plain("# Title\n\nBody.\n\n### Small *one*") == "Title\n\nBody.\n\nSmall one")
    }

    @Test func linksAreTheirWordsAndImagesTheirAltText() {
        #expect(plain("See [the notes](https://example.com/notes).") == "See the notes.")
        #expect(plain("Before.\n\n![A chart](https://example.com/c.png)\n\nAfter.") == "Before.\n\nA chart\n\nAfter.")
        #expect(plain("Before.\n\n![](https://example.com/c.png)\n\nAfter.") == "Before.\n\nAfter.")
    }

    @Test func listItemsKeepTheirMarkers() {
        #expect(plain("Steps:\n\n- one\n- two\n\nDone.") == "Steps:\n\n• one\n• two\n\nDone.")
        #expect(plain("- [x] shipped\n- [ ] tested") == "☑ shipped\n☐ tested")
    }

    @Test func orderedListsCountFromTheirStart() {
        #expect(plain("1. one\n2. two\n3. three") == "1. one\n2. two\n3. three")
        #expect(plain("4. four\n5. five") == "4. four\n5. five")
    }

    @Test func nestedListsIndentWithTabs() {
        let reply = "- outer\n  - inner\n    1. deep\n- next"
        #expect(plain(reply) == "• outer\n\t• inner\n\t\t1. deep\n• next")
    }

    @Test func secondParagraphsInAnItemAreIndented() {
        let reply = "- first\n\n  more about it\n- second"
        #expect(plain(reply) == "• first\n\tmore about it\n• second")
    }

    @Test func quotesAreTheirWords() {
        #expect(plain("Said:\n\n> one\n>\n> two\n\nOk.") == "Said:\n\none\n\ntwo\n\nOk.")
        #expect(plain("- > quoted\n  > on\n- plain") == "• quoted on\n• plain")
    }

    @Test func tablesAreTabSeparatedRows() {
        let reply = "| Day | GB |\n|---|---:|\n| Mon | **3** |\n| Tue | 4 |"
        #expect(plain(reply) == "Day\tGB\nMon\t3\nTue\t4")
    }

    @Test func codeBlocksAreTheirCode() {
        let reply = "Run:\n\n```sh\nls -la\ncd ~\n```\n\nThen."
        #expect(plain(reply) == "Run:\n\nls -la\ncd ~\n\nThen.")
    }

    @Test func rulesAddNothing() {
        #expect(plain("Above.\n\n---\n\nBelow.") == "Above.\n\nBelow.")
    }

    @Test func codeInsideAListStaysOnTheItemsLines() {
        let reply = "- run\n\n  ```\n  make\n  ```\n- done"
        #expect(plain(reply) == "• run\n\tmake\n• done")
    }

    @Test func unitsKnowTheirBlockGapAndMarkers() {
        let found = units("Intro.\n\n- a\n  - b\n- c\n\n```\nx\n```")
        #expect(found.map(\.block) == [0, 1, 1, 1, 2])
        #expect(found.map(\.gap) == [.none, .block, .block, .item, .block])
        #expect(found.map(\.markers) == [[], [0], [1], [0], []])
        #expect(found.map(\.isWhole) == [false, false, false, false, true])
        #expect(found[2].levels == [.item(.bullet), .item(.bullet)])
    }

    @Test func emptyItemsKeepTheirMarker() {
        #expect(plain("1. one\n2.\n3. three") == "1. one\n2. \n3. three")
    }

    @Test func partsOfAReplyReadTheSame() {
        let all = units("A.\n\n- b\n- c\n\nD.")
        #expect(ReplyPlainText.text(all[1...2]) == "• b\n• c")
        #expect(ReplyPlainText.text(all[2...]) == "• c\n\nD.")
    }

    @Test func emptyFencesHaveNoParagraphButKeepTheirPlace() {
        let reply = "```\n```\n\nFirst.\n\n```sh\n  \n```\n\n```\n```\n\nSecond.\n\n```\n```"
        let found = units(reply)
        #expect(found.map(\.block) == [1, 4])
        #expect(found.map(\.gap) == [.none, .block])
        #expect(found.map(\.blanks) == [1, 2])
        #expect(ReplyPlainText.trailingBlanks(MarkdownDocument(parsing: reply).blocks) == 1)
        #expect(ReplyPlainText.trailingBlanks(MarkdownDocument(parsing: "```\n```").blocks) == 0)
        #expect(plain(reply) == "First.\n\nSecond.")
    }

    @Test func aQuoteOrListWithAnEmptyFenceIsDrawnWhole() {
        let found = units("Intro.\n\n- ```\n  ```\n- two\n\n> said\n>\n> ```\n> ```")
        #expect(found.map(\.isWhole) == [false, true, true])
        #expect(found.map(\.block) == [0, 1, 2])
        #expect(plain("- ```\n  ```\n- two") == "• \n• two")
        #expect(plain("> said\n>\n> ```\n> ```\n\nOk.") == "said\n\nOk.")
    }

    @Test func anItemThatStartsWithAQuoteIsOneWholeList() {
        let found = units("- one\n- > quoted\n  > on\n- three")
        #expect(found.map(\.isWhole) == [false, true, false])
        #expect(found[1].gap == .item)
        #expect(found[1].markers == [])
        #expect(found[1].levels == [])
        guard case .block(.list(let list)) = found[1].content else {
            Issue.record("not a list")
            return
        }
        #expect(list.items.count == 1)
        #expect(plain("1. one\n2. > quoted\n3. three") == "1. one\n2. quoted\n3. three")
    }

    @Test func markersOfNestedItemsThatStartTogetherShareALine() {
        let found = units("- - inner\n  - next")
        #expect(found.first?.markers == [0, 1])
        #expect(plain("- - inner\n  - next") == "• • inner\n\t• next")
    }

    private func placed(_ markdown: String) -> (placed: [ReplyPlainText.Placed], drawn: NSString) {
        // Drawn as the Mac draws it: markers then a tab, each paragraph on its own line.
        var drawn = ""
        var result: [ReplyPlainText.Placed] = []
        for unit in units(markdown) {
            if !drawn.isEmpty { drawn += "\n" }
            let start = (drawn as NSString).length
            if unit.isWhole {
                drawn += "\u{FFFC}"
                result.append(.init(unit: unit, range: NSRange(location: start, length: 1), content: start, isWhole: true))
            } else {
                let marks = unit.markers.isEmpty ? "" : "\t" + unit.prefix.trimmingCharacters(in: .whitespaces) + "\t"
                drawn += marks + unit.text
                let end = (drawn as NSString).length
                result.append(.init(unit: unit, range: NSRange(location: start, length: end - start),
                                    content: start + (marks as NSString).length, isWhole: false))
            }
        }
        return (result, drawn as NSString)
    }

    @Test func aSelectionInPartCopiesItsWords() {
        let (found, drawn) = placed("First line here.\n\n- one\n- two\n\n```\ncode\n```")
        let all = NSRange(location: 0, length: drawn.length)
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [], selection: all) == "First line here.\n\n• one\n• two\n\ncode")
        // Mid-paragraph: only the words, no separator before them.
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [], selection: NSRange(location: 6, length: 4)) == "line")
        // From the start of an item: its marker comes along.
        let item = found[1].range
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [], selection: NSRange(location: item.location, length: item.length + 5)) == "• one\n• t")
        // From inside a marker: the item's words, without the marker.
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [], selection: NSRange(location: item.location + 1, length: 3)) == "o")
        // Into a code block: it comes whole.
        let code = found[3].range
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [], selection: NSRange(location: code.location - 2, length: 3)) == "o\n\ncode")
    }

    @Test func hiddenCharactersAreNeverCopied() {
        // Inline code drawn with a padding character on each side, which is never copied.
        let unit = units("Run `make` now.")[0]
        let drawn = "Run \u{2009}make\u{2009} now." as NSString
        let found = [ReplyPlainText.Placed(unit: unit, range: NSRange(location: 0, length: drawn.length), content: 0, isWhole: false)]
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [4, 9], selection: NSRange(location: 2, length: 10)) == "n make n")
        #expect(ReplyPlainText.text(found, drawn: drawn, hidden: [4, 9], selection: NSRange(location: 0, length: drawn.length)) == "Run make now.")
    }

    private func hosted(_ markdown: String, names: Bool = false) -> [MarkdownBlock?] {
        units(markdown).map { ReplyPlainText.hosted($0, names: names) }
    }

    @Test func theTextDrawsParagraphsHeadingsAndPlainItems() {
        #expect(hosted("# Title\n\nBody.\n\n- one\n- two\n\n1. first\n\n> quoted") == [nil, nil, nil, nil, nil, nil])
    }

    @Test func blocksAreDrawnByTheirOwnViews() {
        let code = hosted("Before.\n\n```swift\nlet a = 1\n```\n\n---\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(code[0] == nil)
        #expect(code[1] == .codeBlock(language: "swift", code: "let a = 1"))
        #expect(code[2] == .thematicBreak)
        guard case .table = code[3] else { Issue.record("a table is drawn by its view"); return }
        // A lone image is its own view; html outside a list is drawn by the text.
        guard case .paragraph = hosted("![A chart](https://example.com/c.png)")[0] else {
            Issue.record("a lone image is drawn by its view"); return
        }
        #expect(hosted("<br>")[0] == nil)
    }

    @Test func itemsTheTextCannotDrawAreTheirOwnList() {
        // A checklist item's words are the text's; only its box is a view beside them.
        #expect(hosted("- [x] shipped\n- [ ] tested") == [nil, nil])
        // An empty item is its marker alone; an item opening two lists at once is both of them.
        guard case .list(let empty) = hosted("- \n- two")[0] else { Issue.record("an empty item is a list of its own"); return }
        #expect(empty.items[0].blocks.isEmpty)
        guard case .list(let outer) = hosted("1. - inner")[0] else { Issue.record("nested markers are a list of their own"); return }
        #expect(outer.isOrdered)
        guard case .list(let inner) = outer.items[0].blocks.first else { Issue.record("the inner list sits in the outer item"); return }
        #expect(!inner.isOrdered)
        // Html in an item sits on the code font's baseline beside the marker.
        guard case .list(let html) = hosted("- <div>boxed</div>")[0], case .html = html.items[0].blocks.first else {
            Issue.record("html in an item is drawn by its view"); return
        }
    }

    @Test func wordsTheTextCannotDrawAreTheirOwnView() {
        // Names drawn as pills, and a tab, which would land on a list's tab stops.
        #expect(hosted("Ask @scout.", names: true)[0] == .paragraph([.text("Ask @scout.")]))
        #expect(hosted("a\tb")[0] != nil)
    }

    @Test func codeAndTablesScrollSideways() {
        let blocks = MarkdownDocument(parsing: "Text.\n\n```\ncode\n```\n\n> | A |\n> |---|\n> | 1 |\n\n- item\n\n---").blocks
        #expect(blocks.map(ReplyPlainText.scrollsSideways) == [false, true, true, false, false])
        let nested = MarkdownDocument(parsing: "- item\n\n  ```\n  code\n  ```").blocks
        #expect(nested.map(ReplyPlainText.scrollsSideways) == [true])
    }
}
