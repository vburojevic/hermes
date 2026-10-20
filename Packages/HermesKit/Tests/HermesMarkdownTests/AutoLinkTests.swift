import Foundation
import Testing
@testable import HermesMarkdown

/// Web addresses written out in a reply become links (`AutoLink`): swift-markdown leaves them
/// as plain text, so a blog post's address couldn't be tapped.
@Suite("Autolinks")
struct AutoLinkTests {
    private func inlines(_ markdown: String) -> [MarkdownInline] {
        guard case .paragraph(let inlines)? = MarkdownDocument(parsing: markdown).blocks.first else { return [] }
        return inlines
    }

    private func link(_ url: String, _ words: String? = nil) -> MarkdownInline {
        .link(destination: url, content: [.text(words ?? url)])
    }

    /// A reply built to be slow (thousands of ")" or "(http://" with no space) is read in one pass.
    @Test func aPathologicalRunStaysQuick() {
        let clock = ContinuousClock()
        let started = clock.now
        _ = AutoLink.matches(in: "http://a.co" + String(repeating: ")", count: 30_000))
        _ = AutoLink.matches(in: String(repeating: "(http://", count: 4_000))
        _ = AutoLink.matches(in: String(repeating: "http://x ", count: 4_000))
        #expect(clock.now - started < .seconds(5))
        #expect(AutoLink.matches(in: "see (https://example.com/a_(b)) now").map(\.destination) == ["https://example.com/a_(b)"])
    }

    /// Thousands of nested quotes or emphasis marks parse without running out of stack (F31).
    @Test func deepNestingIsBounded() {
        let quotes = String(repeating: ">", count: 5_000) + " deep"
        #expect(!MarkdownDocument(parsing: quotes).blocks.isEmpty)
        let marks = String(repeating: "*_", count: 3_000) + "x" + String(repeating: "_*", count: 3_000)
        #expect(!MarkdownDocument(parsing: marks).blocks.isEmpty)
        // Code keeps its marks as written.
        let code = "```\n" + String(repeating: "*", count: 300) + "\n```"
        #expect(MarkdownDocument.boundedNesting(code) == code)
        #expect(MarkdownDocument.boundedNesting("> > quote") == "> > quote")
    }

    @Test func anAddressOnItsOwnLine() {
        let url = "https://example.com/blog/ios-provisioning-signing-failures/"
        #expect(inlines(url) == [link(url)])
    }

    @Test func sentencePunctuationStaysOut() {
        #expect(inlines("See https://example.com/a.") == [.text("See "), link("https://example.com/a"), .text(".")])
        #expect(inlines("Is it http://localhost:3000/health?") == [.text("Is it "), link("http://localhost:3000/health"), .text("?")])
        #expect(inlines("“https://example.com”, then") == [.text("“"), link("https://example.com"), .text("”, then")])
    }

    @Test func bracketsTheAddressDidntOpenStayOut() {
        #expect(inlines("(see https://example.com/x)") == [.text("(see "), link("https://example.com/x"), .text(")")])
        let wiki = "https://en.wikipedia.org/wiki/Swift_(programming_language)"
        #expect(inlines("Read \(wiki) first") == [.text("Read "), link(wiki), .text(" first")])
    }

    @Test func wwwOpensOverHTTPS() {
        #expect(inlines("Go to www.example.com now") == [.text("Go to "), link("https://www.example.com", "www.example.com"), .text(" now")])
    }

    @Test func onlyRealHostsAndWordStarts() {
        #expect(inlines("foohttps://example.com") == [.text("foohttps://example.com")])
        #expect(inlines("http://nodot/path") == [.text("http://nodot/path")])
        #expect(inlines("https://a.b_c/x") == [.text("https://a.b_c/x")])
        #expect(inlines("www.example") == [.text("www.example")])
        #expect(inlines("ftp://example.com") == [.text("ftp://example.com")])
        #expect(inlines("http://192.168.1.20:8080/") == [link("http://192.168.1.20:8080/")])
    }

    @Test func markdownLinksAndCodeAreLeftAsTheyAre() {
        #expect(inlines("[the docs](https://example.com/docs)") == [link("https://example.com/docs", "the docs")])
        // A link's words that are an address aren't a second link inside it.
        #expect(inlines("[https://a.example.com](https://b.example.com)") == [link("https://b.example.com", "https://a.example.com")])
        #expect(inlines("[**https://a.example.com**](https://b.example.com)")
            == [.link(destination: "https://b.example.com", content: [.strong([.text("https://a.example.com")])])])
        #expect(inlines("Run `curl https://example.com`") == [.text("Run "), .code("curl https://example.com")])
        #expect(inlines("<https://example.com>") == [link("https://example.com")])
    }

    @Test func insideEmphasisListsAndTables() {
        #expect(inlines("**https://example.com**") == [.strong([link("https://example.com")])])
        guard case .list(let list)? = MarkdownDocument(parsing: "- Live: https://example.com/post").blocks.first,
              case .paragraph(let item)? = list.items.first?.blocks.first else {
            Issue.record("expected a list")
            return
        }
        #expect(item == [.text("Live: "), link("https://example.com/post")])
        guard case .table(let table)? = MarkdownDocument(parsing: "| Site |\n|---|\n| https://example.com |").blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows.first?.first == [link("https://example.com")])
    }

    @Test func twoAddressesInOneLine() {
        #expect(AutoLink.matches(in: "https://a.example.com and https://b.example.com").map(\.destination)
            == ["https://a.example.com", "https://b.example.com"])
    }
}
