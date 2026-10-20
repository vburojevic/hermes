import HermesKit
import HermesMarkdown
import SwiftUI

/// A reply's text with its widgets where its directives are (`docs/widgets.md` §2): Markdown as
/// before between them, and a card for each `::widget{…}` line. A reply without widgets is one
/// `MarkdownView`, untouched.
struct ReplyBody: View, Equatable {
    let text: String
    var streaming = false
    var caches = true
    /// Inline ` ```widget ` blocks draw (a delivery the plugin processed, or the developer setting).
    var inlineWidgets = WidgetSettings.rendersInlineBlocks
    /// The sentence Listen is reading (`docs/voice.md` §3), in a reply that's all Markdown.
    var highlight: SpokenSentence?

    var body: some View {
        let segments = ReplySplitter.split(text, inlineWidgets: inlineWidgets, streaming: streaming)
        if segments.count == 1, case .markdown(let markdown) = segments[0] {
            MarkdownView(text: markdown, caches: caches, highlight: highlight)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown): MarkdownView(text: markdown, caches: caches)
                    case .widget(let directive): WidgetSlot(directive: directive)
                    case .inline(let json): InlineWidgetSlot(json: json)
                    }
                }
            }
        }
    }

    /// Whether `text` has anything but Markdown in it.
    static func hasWidgets(_ text: String, inlineWidgets: Bool) -> Bool {
        ReplySplitter.split(text, inlineWidgets: inlineWidgets).contains { segment in
            if case .markdown = segment { false } else { true }
        }
    }
}

/// Your side of a widget's round trip (`Parts.actionBubble`): a small pill where the message
/// would be ("Approved · Lunch order"), never the raw `[widget …]` text.
struct ActionBubble: View {
    let answer: WidgetAnswer

    @Environment(\.widgetHost) private var host

    var body: some View {
        let payload = host?.store.payload(answer.widgetID)
        let detail = [payload?.title, answer.words].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(answer.action))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkForeground)
                .frame(width: 30, height: 30)
                .background(Theme.ink, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(answer, payload: payload)).font(WidgetFont.body.weight(.semibold)).foregroundStyle(Theme.primaryText)
                if !detail.isEmpty {
                    Text(detail).font(WidgetFont.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([Self.label(answer, payload: payload), detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// The answer as a past action, in whole phrases ("Approved"), or the payload's own button label.
    static func label(_ answer: WidgetAnswer, payload: WidgetPayload?) -> String {
        WidgetAnswer.pastTense(answer.action)
            ?? payload.flatMap { label(of: answer.action, in: $0) }
            ?? answer.action.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A payload's own action's label, wherever it is (the action row, a row, a do-first).
    private static func label(of id: String, in payload: WidgetPayload) -> String? {
        func search(_ value: JSONValue) -> String? {
            switch value {
            case .object(let object):
                if object["id"]?.stringValue == id, let label = object["label"]?.stringValue, object["kind"]?.stringValue ?? "reply" == "reply" { return label }
                for child in object.values { if let found = search(child) { return found } }
            case .array(let array):
                for child in array { if let found = search(child) { return found } }
            default:
                break
            }
            return nil
        }
        return search(payload.json["actions"] ?? .null) ?? search(payload.json)
    }

    static func symbol(_ action: String) -> String {
        switch action {
        case "reject", "cancel": "xmark"
        case "edit": "pencil"
        case "undo": "arrow.uturn.backward"
        case "refresh", "retry": "arrow.clockwise"
        case "rate": "star.fill"
        case "set": "slider.horizontal.3"
        default: "checkmark"
        }
    }
}
