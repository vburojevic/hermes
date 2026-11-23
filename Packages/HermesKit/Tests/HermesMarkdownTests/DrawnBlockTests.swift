import Foundation
import Testing
@testable import HermesMarkdown

/// Which blocks of a reply are drawn as pictures (`DrawnBlock`), and the display math delimiters
/// (`DisplayMath`): `docs/chat.md` §3b.
@Suite("Drawn blocks")
struct DrawnBlockTests {
    private func blocks(_ markdown: String) -> [MarkdownBlock] {
        MarkdownDocument(parsing: markdown).blocks
    }

    private func drawn(_ markdown: String) -> [DrawnBlock] {
        blocks(markdown).compactMap(DrawnBlock.init)
    }

    @Test func fencesAreDrawnByTheirLanguage() {
        let reply = """
        Here:

        ```mermaid
        flowchart LR
          A --> B
        ```

        ```Math
        E = mc^2
        ```

        ```svg
        <svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>
        ```

        ```swift
        let a = 1
        ```
        """
        let found = drawn(reply)
        #expect(found.map(\.kind) == [.mermaid, .math, .svg])
        #expect(found[0].source == "flowchart LR\n  A --> B")
        #expect(found[1].source == "E = mc^2")
    }

    @Test func otherFencesAndEmptyOnesStayCode() {
        #expect(drawn("```mermaidx\ngraph TD\n```").isEmpty)
        #expect(drawn("```mermaid\n\n```").isEmpty)
        #expect(drawn("```\ngraph TD\n```").isEmpty)
        // An SVG fence that isn't one whole element is code.
        #expect(drawn("```svg\nM0 0 L10 10\n```").isEmpty)
        #expect(drawn("```svg\n<svg><g/></svg> and more\n```").isEmpty)
        // Too long to draw.
        let long = "graph TD\n" + String(repeating: "A-->B\n", count: 10_000)
        #expect(drawn("```mermaid\n\(long)```").isEmpty)
    }

    @Test func anSVGInTheProseIsDrawnOnlyWhenItIsTheWholeBlock() {
        let alone = drawn("Look:\n\n<svg width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>\n\nDone.")
        #expect(alone.map(\.kind) == [.svg])
        // Its namespace address is autolinked in the prose; it's still the SVG as written.
        let named = "<svg width=\"120\" height=\"24\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"120\" height=\"24\"/></svg>"
        #expect(drawn("Badge:\n\n\(named)\n\nDone.") == [DrawnBlock(kind: .svg, source: named)])
        #expect(drawn("<svg width=\"20\"><rect/></svg> trailing words").isEmpty)
        #expect(drawn("<div><svg><rect/></svg></div>").isEmpty)
        #expect(DrawnBlock.isWholeSVG("<?xml version=\"1.0\"?>\n<!-- made by hand -->\n<SVG><g/></SVG>"))
        #expect(!DrawnBlock.isWholeSVG("<svgfoo></svg>"))
    }

    @Test func displayMathBecomesAMathFence() {
        let reply = """
        The area is

        $$
        A = \\pi r^2
        $$

        and also \\[ \\int_0^1 x\\,dx = \\frac{1}{2} \\]
        """
        // The `$$` block is drawn; the `\\[` inside a sentence stays words.
        #expect(drawn(reply).map(\.source) == ["A = \\pi r^2"])
        let found = drawn("The area is\n\n$$\nA = \\pi r_1^2 * 2\n$$\n\nDone.")
        #expect(found == [DrawnBlock(kind: .math, source: "A = \\pi r_1^2 * 2")])
        #expect(drawn("$$ e^{i\\pi} + 1 = 0 $$") == [DrawnBlock(kind: .math, source: "e^{i\\pi} + 1 = 0")])
        #expect(drawn("\\[\n\\sum_{n=1}^\\infty \\frac{1}{n^2}\n\\]") == [DrawnBlock(kind: .math, source: "\\sum_{n=1}^\\infty \\frac{1}{n^2}")])
        #expect(drawn("$$x = 1\ny = 2$$").map(\.source) == ["x = 1\ny = 2"])
    }

    /// Money is never a formula: inline `$…$` isn't math, and a `$$` that never closes is words.
    @Test(arguments: [
        "It costs $5 and $10.",
        "$5 and $10",
        "$$5 and $$10 were the two prices",
        "$$5 is the price\n\nand nothing closes it",
        "Between $x$ and $y$ inline math stays text",
        "$$$\nnot math\n$$$",
        "$$\n$$",
    ])
    func moneyAndInlineDollarsStayWords(_ text: String) {
        #expect(drawn(text).isEmpty)
        #expect(DisplayMath.fenced(text) == text)
    }

    @Test func mathInsideACodeFenceIsCode() {
        let text = "```latex\n$$\nx\n$$\n```"
        #expect(DisplayMath.fenced(text) == text)
        #expect(drawn(text).isEmpty)
        let tilde = "~~~~\n$$ x $$\n~~~~\n\n$$ y $$"
        #expect(drawn(tilde) == [DrawnBlock(kind: .math, source: "y")])
    }

    @Test func aBlankLineEndsAnUnclosedBlock() {
        #expect(drawn("$$\na = b\n\nc = d $$").isEmpty)
    }

    @Test func mathInAListItemStaysInIt() {
        let found = blocks("- first\n\n  $$\n  x^2\n  $$\n- second")
        guard case .list(let list)? = found.first else {
            Issue.record("expected a list, got \(found)")
            return
        }
        #expect(list.items.count == 2)
        #expect(list.items[0].blocks.compactMap(DrawnBlock.init) == [DrawnBlock(kind: .math, source: "x^2")])
    }

    /// A formula still arriving shows as written; once it closes it's one block, the same as a
    /// parse of the whole reply.
    @Test func streamingMathSettlesOnceClosed() {
        let whole = "Intro.\n\n$$\na^2 + b^2 = c^2\n$$\n\nAfter."
        var stream = MarkdownDocument.Stream()
        let partial = stream.blocks(for: "Intro.\n\n$$\na^2 + b^2")
        #expect(partial.compactMap(DrawnBlock.init).isEmpty)
        #expect(stream.blocks(for: whole) == MarkdownDocument(parsing: whole).blocks)
        #expect(stream.blocks(for: whole).compactMap(DrawnBlock.init).map(\.kind) == [.math])
    }

    @Test func diagramsAreNamedForVoiceOver() {
        #expect(DrawnBlock.diagramName("flowchart LR\nA-->B") == "Flowchart")
        #expect(DrawnBlock.diagramName("graph TD;\nA-->B") == "Flowchart")
        #expect(DrawnBlock.diagramName("%%{init: {'theme':'dark'}}%%\nsequenceDiagram\nA->>B: hi") == "Sequence diagram")
        #expect(DrawnBlock.diagramName("---\ntitle: Plan\n---\ngantt\n") == "Gantt chart")
        #expect(DrawnBlock.diagramName("pie title Pets") == "Pie chart")
        #expect(DrawnBlock.diagramName("somethingNew\n") == "Diagram")
        #expect(DrawnBlock(kind: .math, source: "x").name == "Formula")
        #expect(DrawnBlock(kind: .svg, source: "<svg></svg>").name == "Picture")
    }

    /// Copying and the Mac's one-text reply: a drawn SVG is a block of its own, copied as its markup;
    /// a diagram doesn't scroll sideways, so the reply keeps its swipe.
    @Test func drawnBlocksAreWholeInThePlainText() {
        let svg = "<svg width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\"/></svg>"
        let units = ReplyPlainText.units(blocks("Before.\n\n\(svg)\n\nAfter."))
        #expect(units.count == 3)
        #expect(units[1].isWhole)
        #expect(units[1].text == svg)
        #expect(!ReplyPlainText.scrollsSideways(.codeBlock(language: "mermaid", code: "graph TD\nA-->B")))
        #expect(ReplyPlainText.scrollsSideways(.codeBlock(language: "swift", code: "let a = 1")))
    }

    @Test func drawnBlocksAreDescribedWhenReadAloud() {
        let script = MarkdownDocument(parsing: "Here.\n\n```mermaid\ngraph TD\nA-->B\n```\n\n$$ x $$").spokenScript()
        #expect(script.text.contains("I put a diagram in the chat."))
        #expect(script.text.contains("I put a formula in the chat."))
    }
}
