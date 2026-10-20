import Testing
@testable import HermesMarkdown

@Suite("Markdown document")
struct MarkdownDocumentTests {
    @Test func paragraphsWithInlineStyles() {
        let document = MarkdownDocument(parsing: "Hello **bold** and *em* with `code` and [link](https://x.ai).")
        #expect(document.blocks == [
            .paragraph([
                .text("Hello "), .strong([.text("bold")]), .text(" and "), .emphasis([.text("em")]),
                .text(" with "), .code("code"), .text(" and "),
                .link(destination: "https://x.ai", content: [.text("link")]), .text("."),
            ]),
        ])
    }

    @Test func fencedCodeKeepsLanguageAndDropsTrailingNewline() {
        let document = MarkdownDocument(parsing: "```swift\nlet x = 1\n```")
        #expect(document.blocks == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test func unterminatedFenceWhileStreamingIsStillCode() {
        let document = MarkdownDocument(parsing: "Intro\n\n```py\nprint(1)\n")
        #expect(document.blocks.last == .codeBlock(language: "py", code: "print(1)"))
    }

    @Test func taskListsAndOrderedStart() {
        let document = MarkdownDocument(parsing: "3. three\n4. four\n\n- [x] done\n- [ ] todo")
        guard case .list(let ordered) = document.blocks.first, case .list(let tasks) = document.blocks.last else {
            Issue.record("expected two lists")
            return
        }
        #expect(ordered.isOrdered && ordered.startIndex == 3 && ordered.items.count == 2)
        #expect(tasks.items.map(\.isChecked) == [true, false])
    }

    @Test func tablesCarryAlignment() {
        let document = MarkdownDocument(parsing: "| a | b |\n|:-|-:|\n| 1 | 2 |")
        guard case .table(let table) = document.blocks.first else {
            Issue.record("expected table")
            return
        }
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.header == [[.text("a")], [.text("b")]])
        #expect(table.rows == [[[.text("1")], [.text("2")]]])
        #expect(table.columnCount == 2)
    }

    @Test func headingsQuotesAndBreaks() {
        let document = MarkdownDocument(parsing: "## Title\n\n> quoted\n\n---")
        #expect(document.blocks == [
            .heading(level: 2, content: [.text("Title")]),
            .blockQuote([.paragraph([.text("quoted")])]),
            .thematicBreak,
        ])
    }
}

@Suite("Code highlighter")
struct CodeHighlighterTests {
    @Test func tokensRoundTripTheSource() {
        let samples: [(String, String)] = [
            ("swift", "@MainActor\nfinal class A { let s = \"x\\\"y\" // c\n func f() -> Int { 0x1F + 2.5 } }"),
            ("python", "def f(x):\n    \"\"\"doc\"\"\"\n    return x # done"),
            ("bash", "echo ${#arr[@]} # count\nexport A=1"),
            ("json", "{\"key\": [1, true, null, \"v\"]}"),
            ("diff", "@@ -1 +1 @@\n-old\n+new\n same"),
            ("sql", "SELECT * FROM t WHERE a = 'x' -- c"),
        ]
        for (language, code) in samples {
            let tokens = CodeHighlighter.tokenize(code, language: language)
            #expect(tokens.map(\.text).joined() == code, "\(language) tokens must cover the source exactly")
        }
    }

    @Test func classifiesSwift() {
        let tokens = CodeHighlighter.tokenize("let value = \"hi\" // note", language: "swift")
        #expect(tokens.contains(.init(.keyword, "let")))
        #expect(tokens.contains(.init(.string, "\"hi\"")))
        #expect(tokens.contains(.init(.comment, "// note")))
    }

    @Test func jsonKeysAreProperties() {
        let tokens = CodeHighlighter.tokenize("{\"name\": \"Hermes\"}", language: "json")
        #expect(tokens.contains(.init(.property, "\"name\"")))
        #expect(tokens.contains(.init(.string, "\"Hermes\"")))
    }

    @Test func shellLengthExpansionIsNotAComment() {
        let tokens = CodeHighlighter.tokenize("echo ${#items}", language: "sh")
        #expect(!tokens.contains { $0.kind == .comment })
    }

    @Test func unknownLanguageIsPlain() {
        #expect(CodeHighlighter.tokenize("whatever 123", language: nil) == [.init(.plain, "whatever 123")])
    }

    @Test func diffLines() {
        let kinds = CodeHighlighter.tokenize("@@ x\n+a\n-b\n c", language: "diff").map(\.kind)
        #expect(kinds == [.meta, .inserted, .deleted, .plain])
    }
}
