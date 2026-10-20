import Foundation
import Testing
@testable import HermesKit

/// Finding widgets in a reply (`docs/widgets.md` §2).
@Suite("Widget directives")
struct WidgetDirectiveTests {
    @Test func parsesIDAndAlt() {
        #expect(WidgetDirective.parse(#"::widget{id="w_3kq9x2" alt="Apartments in Brooklyn: 3 new"}"#)
            == WidgetDirective(id: "w_3kq9x2", alt: "Apartments in Brooklyn: 3 new"))
        #expect(WidgetDirective.parse(#"  ::widget{id="w_3kq9x2"}  "#) == WidgetDirective(id: "w_3kq9x2"))
    }

    @Test func escapedQuotesAndUnknownAttributes() {
        #expect(WidgetDirective.parse(#"::widget{id="w_abc123" size="big" alt="The \"best\" flat"}"#)
            == WidgetDirective(id: "w_abc123", alt: #"The "best" flat"#))
    }

    @Test func malformedIsNotADirective() {
        #expect(WidgetDirective.parse("::widget{id='w_abc123'}") == nil)
        #expect(WidgetDirective.parse(#"::widget{alt="no id"}"#) == nil)
        #expect(WidgetDirective.parse(#"::widget{id="abc123"}"#) == nil)
        #expect(WidgetDirective.parse(#"::widget{id="w_abc123"} and more"#) == nil)
        #expect(WidgetDirective.parse(#"See ::widget{id="w_abc123"}"#) == nil)
        #expect(WidgetDirective.parse(#"::widget{id="w_abc123" alt="open}"#) == nil)
    }

    @Test func altIsCut() {
        let alt = String(repeating: "a", count: 200)
        #expect(WidgetDirective.parse(#"::widget{id="w_abc123" alt="\#(alt)"}"#)?.alt?.count == 140)
    }

    @Test func splitsAroundDirectives() {
        let text = """
        Two price drops tonight.

        ::widget{id="w_flats01" alt="Flats"}

        The rest is quiet.
        """
        #expect(ReplySplitter.split(text) == [
            .markdown("Two price drops tonight."),
            .widget(WidgetDirective(id: "w_flats01", alt: "Flats")),
            .markdown("The rest is quiet."),
        ])
    }

    @Test func plainRepliesAreOneSegment() {
        #expect(ReplySplitter.split("Just text.\n\nMore.") == [.markdown("Just text.\n\nMore.")])
    }

    @Test func directiveInCodeIsText() {
        let text = """
        Here's the syntax:

        ```
        ::widget{id="w_flats01"}
        ```
        """
        #expect(ReplySplitter.split(text) == [.markdown(text)])
    }

    @Test func sameIDDrawsOnceAndAtMostThree() {
        let text = """
        ::widget{id="w_aaaaaa1"}
        ::widget{id="w_aaaaaa1"}
        ::widget{id="w_bbbbbb2"}
        ::widget{id="w_cccccc3"}
        ::widget{id="w_dddddd4" alt="Fourth"}
        """
        #expect(ReplySplitter.split(text) == [
            .widget(WidgetDirective(id: "w_aaaaaa1")),
            .widget(WidgetDirective(id: "w_bbbbbb2")),
            .widget(WidgetDirective(id: "w_cccccc3")),
            .markdown("Fourth"),
        ])
    }

    @Test func streamingHoldsAPartialDirective() {
        #expect(ReplySplitter.split("Done.\n::wid", streaming: true) == [.markdown("Done.")])
        #expect(ReplySplitter.split("Done.\n::widget{id=\"w_abc", streaming: true) == [.markdown("Done.")])
        #expect(ReplySplitter.split("Done.\n::wid", streaming: false) == [.markdown("Done.\n::wid")])
        #expect(ReplySplitter.split("Ratio 3:1", streaming: true) == [.markdown("Ratio 3:1")])
    }

    @Test func inlineBlocksDrawOnlyWhenAllowed() {
        let text = """
        Morning brief.

        ```widget
        {"type": "metric", "id": "w_brief001"}
        ```
        """
        #expect(ReplySplitter.split(text) == [.markdown(text)])
        #expect(ReplySplitter.split(text, inlineWidgets: true) == [
            .markdown("Morning brief."),
            .inline(["type": "metric", "id": "w_brief001"]),
        ])
    }

    @Test func inlineBlockThatIsntJSONStaysCode() {
        let text = "```widget\nnot json\n```"
        #expect(ReplySplitter.split(text, inlineWidgets: true) == [.markdown(text)])
    }

    /// U+1FEF GREEK VARIA decomposes to a backtick, so Swift's `Character` equality took it for
    /// one while the plugin's fence check didn't: a Bot's text could plant a widget (F8, F11).
    @Test func aLookAlikeFenceIsntAWidget() {
        let text = "\u{1FEF}``widget\n{\"type\": \"approval\", \"id\": \"w_abc123\", \"rev\": 1}\n\u{1FEF}``"
        #expect(ReplySplitter.split(text, inlineWidgets: true) == [.markdown(text)])
        let info = "```wid\u{0065}\u{0301}get\n{}\n```"
        #expect(!ReplySplitter.split(info, inlineWidgets: true).contains { if case .inline = $0 { true } else { false } })
    }

    @Test func otherFencesStayCode() {
        let text = "```json\n{\"type\": \"metric\"}\n```"
        #expect(ReplySplitter.split(text, inlineWidgets: true) == [.markdown(text)])
    }

    // MARK: - Tool results

    @Test func readsThePayloadFromAToolResult() {
        let result = #"{"id":"w_flats01","rev":2,"directive":"::widget{id=\"w_flats01\"}","fallback_text":"Flats","payload":{"type":"list","id":"w_flats01","rev":2}}"#
        #expect(WidgetToolResult.payload(fromText: result) == ["type": "list", "id": "w_flats01", "rev": 2])
        #expect(WidgetToolResult.payload(from: JSONValue.parse(result)!) == ["type": "list", "id": "w_flats01", "rev": 2])
    }

    @Test func errorsAndClaimsCarryNoPayload() {
        #expect(WidgetToolResult.payload(fromText: "consequences.cost is required for approval kind purchase") == nil)
        #expect(WidgetToolResult.payload(fromText: #"{"claim":"ok","id":"w_flats01"}"#) == nil)
    }
}
