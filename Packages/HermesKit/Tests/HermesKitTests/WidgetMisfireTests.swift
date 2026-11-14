import Foundation
import Testing
@testable import HermesKit

/// A widget the agent didn't make the way the app expects (`docs/widgets.md` §2): a directive
/// written with commas, a payload typed into a routine's delivery, a reply that shares its message
/// with the widget call. The reply's words always show.
@Suite("Widget misfires")
struct WidgetMisfireTests {
    // MARK: Directives written with commas

    @Test func attributesSeparatedByCommasStillParse() {
        #expect(WidgetDirective.parse(#"::widget{id="w_today01", alt="Today: stretch, then water the plants."}"#)
            == WidgetDirective(id: "w_today01", alt: "Today: stretch, then water the plants."))
        #expect(WidgetDirective.parse(#"::widget{id="w_today01",alt="Today"}"#) == WidgetDirective(id: "w_today01", alt: "Today"))
    }

    @Test func aStrayCommaIsStillNotADirective() {
        #expect(WidgetDirective.parse(#"::widget{, id="w_today01"}"#) == nil)
        #expect(WidgetDirective.parse(#"::widget{id="w_today01",, alt="Today"}"#) == nil)
        #expect(WidgetDirective.parse(#"::widget{id="w_today01",}"#) == nil)
    }

    /// A widget that was never stored still has its place: the split names it, and the slot shows
    /// its alt (`WidgetMissingCard`). The words around it stay.
    @Test func aCommaDirectiveSplitsWithTheWordsAroundIt() {
        let text = """
        Here's today's list.

        ::widget{id="w_today01", alt="Today: stretch, then water the plants."}

        Tick them off as you go.
        """
        #expect(ReplySplitter.split(text) == [
            .markdown("Here's today's list."),
            .widget(WidgetDirective(id: "w_today01", alt: "Today: stretch, then water the plants.")),
            .markdown("Tick them off as you go."),
        ])
        #expect(ReplySplitter.readableText(text) == "Here's today's list.\n\nToday: stretch, then water the plants.\n\nTick them off as you go.")
    }

    // MARK: Payloads typed into a routine's delivery

    private static let typed = """
    Morning brief.

    ```json
    {"type":"summary","v":1,"title":"Morning","fallback_text":"Two meetings, then a free afternoon.","sensitivity":"private","body":"Two meetings."}
    ```

    Have a good day.
    """

    @Test func aTypedPayloadInADeliveryReadsAsItsWords() {
        let segments = ReplySplitter.split(Self.typed, inlineWidgets: true, typedAsText: true)
        #expect(segments.count == 3)
        #expect(segments.first == .markdown("Morning brief."))
        #expect(segments.last == .markdown("Have a good day."))
        guard case .typed(let json) = segments[1] else {
            Issue.record("the payload should be shown as its words, not code")
            return
        }
        #expect(json["fallback_text"]?.stringValue == "Two meetings, then a free afternoon.")
        #expect(ReplySplitter.readableText(Self.typed, typedAsText: true)
            == "Morning brief.\n\nTwo meetings, then a free afternoon.\n\nHave a good day.")
    }

    /// Only a delivery reads a typed payload as words: a chat reply may show JSON on purpose.
    @Test func outsideADeliveryItStaysCode() {
        #expect(ReplySplitter.split(Self.typed, inlineWidgets: true) == [.markdown(Self.typed)])
    }

    @Test func aWidgetFenceTheAppWontDrawReadsAsItsWordsToo() {
        let text = """
        ```widget
        {"type":"summary","v":1,"title":"Morning","fallback_text":"Two meetings."}
        ```
        """
        guard case .typed(let json)? = ReplySplitter.split(text, typedAsText: true).first else {
            Issue.record("a widget fence that doesn't draw should read as its words")
            return
        }
        #expect(json["title"]?.stringValue == "Morning")
        // Where blocks draw, the plugin's block is the card, as before.
        #expect(ReplySplitter.split(text, inlineWidgets: true, typedAsText: true).first.map {
            if case .inline = $0 { true } else { false }
        } == true)
    }

    /// A routine's plan as an agent types it: a private stack whose second part is a guide with
    /// its producer, as_of, needs_kind and needs with amounts. `ids` are the agent's own (with
    /// underscores) or the plugin's.
    private static func plan(ids: (String, String, String)) -> String {
        """
        {
          "type": "stack", "v": 1, "id": "\(ids.0)", "rev": 1, "title": "Day plan", "sensitivity": "private",
          "as_of": "2026-11-14T07:00:00Z", "producer": {"name": "Planner", "bot": "planner"},
          "children": [
            {"type": "summary", "v": 1, "id": "\(ids.1)", "title": "Today", "kind": "brief",
             "sensitivity": "private", "as_of": "2026-11-14T07:00:00Z",
             "tldr": "A quiet day with soup for lunch.",
             "fallback_text": "Today: a quiet day with soup for lunch."},
            {"type": "guide", "v": 1, "id": "\(ids.2)", "title": "Lunch: lentil soup", "sensitivity": "private",
             "as_of": "2026-11-14T07:00:00Z", "producer": {"name": "Planner", "bot": "planner"},
             "servings": 2, "needs_kind": "ingredients",
             "needs": [
               {"label": "Red lentils", "amount": {"value": 1, "unit": "cup"}},
               {"label": "Carrot", "amount": {"value": 2}},
               {"label": "Salt", "amount": {"value": null, "display": "to taste"}, "scales": false}
             ],
             "steps": [{"id": "chop", "title": "Chop the carrots."},
                       {"id": "cook", "title": "Simmer everything for 20 minutes.", "timer": 1200}],
             "fallback_text": "Lunch: lentil soup. You'll need a cup of red lentils, 2 carrots and salt."}
          ],
          "fallback_text": "Day plan. Today: a quiet day with soup for lunch. Lunch: lentil soup."
        }
        """
    }

    /// The reported routine: the agent typed the plan as a json block, so the delivery reads it as
    /// its words, kept private; the plugin's own block of the same plan draws as the card.
    @Test func aTypedPlanWithAGuideReadsAsItsWordsAndTheBlockDraws() throws {
        let typed = "Here's your plan for today.\n\n```json\n" + Self.plan(ids: ("w_dp_sat0700", "w_dp_sat0700_t", "w_dp_sat0700_l"))
            + "\n```\n\nEnjoy the soup."
        for inline in [false, true] {
            // Whether blocks draw (a gateway with the plugin) or not (a release build without it).
            let segments = ReplySplitter.split(typed, inlineWidgets: inline, typedAsText: true)
            #expect(segments.count == 3)
            guard case .typed(let json) = segments[1] else {
                Issue.record("the typed plan should read as its words, not code")
                return
            }
            #expect(json["fallback_text"]?.stringValue == "Day plan. Today: a quiet day with soup for lunch. Lunch: lentil soup.")
        }
        #expect(ReplySplitter.readableText(typed, typedAsText: true)
            == "Here's your plan for today.\n\nDay plan. Today: a quiet day with soup for lunch. Lunch: lentil soup.\n\nEnjoy the soup.")
        let words = SpokenWidgets.words(of: typed, inlineWidgets: true, typedAsText: true) { _ in nil }
        #expect(words.isPrivate)
        #expect(!words.text.contains("{"))

        let block = "Here's your plan for today.\n\n```widget\n" + Self.plan(ids: ("w_dpsat0700", "w_dpsat0700t", "w_dpsat0700l")) + "\n```"
        guard case .inline(let json) = ReplySplitter.split(block, inlineWidgets: true, typedAsText: true).last else {
            Issue.record("the plugin's block should draw where blocks draw")
            return
        }
        let payload = try #require(WidgetReader.read(json).payload)
        #expect(payload.isPrivate)
        #expect(payload.children.count == 2)
        // Without the plugin in a release build, the same block reads as its words.
        guard case .typed = ReplySplitter.split(block, inlineWidgets: false, typedAsText: true).last else {
            Issue.record("an undrawn plugin block should read as its words")
            return
        }
    }

    @Test func jsonThatIsntAWidgetStaysCode() {
        for body in [
            #"{"type":"commit","sha":"abc123"}"#,  // a type but nothing a widget carries
            #"{"sha":"abc123","fallback_text":"x"}"#,  // no type
            #"["type","summary"]"#,
            "not json",
        ] {
            let text = "```json\n\(body)\n```"
            #expect(ReplySplitter.split(text, typedAsText: true) == [.markdown(text)], "\(body)")
        }
        let unclosed = "```json\n{\"type\":\"commit\",\"sha\":\"abc123\"}"
        #expect(ReplySplitter.split(unclosed, typedAsText: true) == [.markdown(unclosed)])
    }

    // MARK: Payloads that can't be read

    /// A smaller model can stop halfway through a payload, or leave its words out. The reply's
    /// words stay, and the widget keeps its place as a plain line: never raw JSON, never blank.
    @Test func aBrokenPayloadInADeliveryKeepsItsPlace() {
        for block in [
            "```json\n{\"type\":\"summary\",\"v\":1,\"title\":\"Morning\",\"fallback_text\":\"Two meet\n```",  // cut off
            "```json\n{\"type\": \"summary\", \"v\": 1}\n```",  // nothing to read
            "```widget\nnot json\n```",  // a widget fence the app won't draw
            "```widget\n{\"type\":\"summary\"\n```",
        ] {
            let text = "Morning brief.\n\n\(block)\n\nHave a good day."
            #expect(ReplySplitter.split(text, inlineWidgets: false, typedAsText: true)
                == [.markdown("Morning brief."), .unreadable, .markdown("Have a good day.")], "\(block)")
            #expect(ReplySplitter.readableText(text, typedAsText: true) == "Morning brief.\n\nHave a good day.", "\(block)")
        }
    }

    /// Where the plugin's blocks draw, a block that isn't an object can't be a card either.
    @Test func aBrokenInlineBlockKeepsItsPlace() {
        for block in ["```widget\n{\"type\":\"summary\",\"v\":1,\n```", "```widget\n[1, 2]\n```", "```widget\n```"] {
            let text = "Here's today.\n\n\(block)\n\nThat's all."
            #expect(ReplySplitter.split(text, inlineWidgets: true)
                == [.markdown("Here's today."), .unreadable, .markdown("That's all.")], "\(block)")
        }
    }

    /// A reply that ends inside a payload was cut off: once it's whole, the payload keeps its
    /// place; while it streams, it waits.
    @Test func aPayloadCutOffAtTheEndKeepsItsPlace() {
        let delivery = "Morning brief.\n\n```json\n{\"type\":\"summary\",\"v\":1,\"fallback_text\":\"Two"
        #expect(ReplySplitter.split(delivery, typedAsText: true) == [.markdown("Morning brief."), .unreadable])
        let inline = "Here's today.\n\n```widget\n{\"type\":\"summary\""
        #expect(ReplySplitter.split(inline, inlineWidgets: true) == [.markdown("Here's today."), .unreadable])
        #expect(ReplySplitter.split(inline, inlineWidgets: true, streaming: true) == [.markdown("Here's today.")])
    }

    /// Listen reads the words around it and nothing of the payload.
    @Test func listenSkipsABrokenPayload() {
        let text = "Morning brief.\n\n```json\n{\"type\":\"summary\",\"v\":1,\"fallback_text\":\"secret\n```\n\nHave a good day."
        let words = SpokenWidgets.words(of: text, inlineWidgets: true, typedAsText: true) { _ in nil }
        #expect(words.text == "Morning brief.\n\nHave a good day.")
    }

    /// A plain chat reply shows a ` ```widget ` block as code, as before: nothing new draws there.
    @Test func aChatReplyStillShowsAWidgetFenceAsCode() {
        let text = "```widget\nnot json\n```"
        #expect(ReplySplitter.split(text) == [.markdown(text)])
    }

    @Test func listenReadsATypedPayloadAsPrivateUnlessItSaysNormal() {
        let words = SpokenWidgets.words(of: Self.typed, inlineWidgets: true, typedAsText: true) { _ in nil }
        #expect(words.text == "Morning brief.\n\nTwo meetings, then a free afternoon.\n\nHave a good day.")
        #expect(words.isPrivate)
        let normal = Self.typed.replacingOccurrences(of: "private", with: "normal")
        #expect(!SpokenWidgets.words(of: normal, inlineWidgets: true, typedAsText: true) { _ in nil }.isPrivate)
    }

    // MARK: A reply in the same message as its widget call

    private func turn(_ rows: [SessionMessage]) -> AssistantTurn? {
        for case .assistant(let turn) in TranscriptBuilder.build(rows) { return turn }
        return nil
    }

    private static let reply = """
    Here's today's list.

    ::widget{id="w_today01", alt="Today: stretch, then water the plants."}

    Tick them off as you go.
    """

    /// The model wrote its reply and called the tool in one message, and the call was refused:
    /// the reply is the answer, never dimmed narration.
    @Test func wordsBesideOnlyAWidgetCallAreTheAnswer() {
        let rows = [
            SessionMessage(id: 1, role: "user", content: .text("widget refused inline")),
            SessionMessage(id: 2, role: "assistant", content: .text(Self.reply),
                           toolCalls: [ToolCall(id: "c1", name: "widget", arguments: #"{"op": "create"}"#)]),
            SessionMessage(id: 3, role: "tool", content: .text(#"{"error": "unknown field", "stored": false}"#),
                           toolCallID: "c1", toolName: "widget"),
            SessionMessage(id: 4, role: "assistant", content: .text("")),
        ]
        let stored = turn(rows)
        #expect(stored?.answer == Self.reply)
        #expect(stored?.steps.isEmpty == true)
    }

    /// Words before a real tool call are still narration.
    @Test func wordsBesideAnotherToolAreStillNarration() {
        let rows = [
            SessionMessage(id: 1, role: "user", content: .text("check")),
            SessionMessage(id: 2, role: "assistant", content: .text("Looking."),
                           toolCalls: [ToolCall(id: "c1", name: "widget", arguments: "{}"),
                                       ToolCall(id: "c2", name: "terminal", arguments: #"{"command": "ls"}"#)]),
            SessionMessage(id: 3, role: "tool", content: .text("{}"), toolCallID: "c2", toolName: "terminal"),
            SessionMessage(id: 4, role: "assistant", content: .text("Done.")),
        ]
        let stored = turn(rows)
        #expect(stored?.answer == "Done.")
        guard case .narration(_, let text)? = stored?.steps.first else {
            Issue.record("the words before the terminal call should be narration")
            return
        }
        #expect(text == "Looking.")
    }
}
