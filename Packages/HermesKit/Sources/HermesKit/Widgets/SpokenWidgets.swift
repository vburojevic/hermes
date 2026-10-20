import Foundation

/// Widgets as words for Listen (`docs/voice.md` §3, `docs/widgets.md` §10). Prose is read as
/// written; a widget as its own `fallback_text`; a scheduled report (`stack`) as a brief: a
/// one-line intro ("Your Friday brief: Morning brief.") and each widget's words in order, never the
/// stack's own text, which repeats them.
///
/// Private widgets are read: the person asked, on their own device, and Now Playing shows only the
/// chat and the Bot. `isPrivate` tells the mini player not to show their sentences, which the app
/// switcher would keep.
public enum SpokenWidgets {
    public struct Words: Equatable, Sendable {
        public var text: String
        public var isPrivate: Bool

        public init(text: String, isPrivate: Bool = false) {
            self.text = text
            self.isPrivate = isPrivate
        }
    }

    /// A reply's or a routine delivery's words. `stored` finds a widget by id: a directive's
    /// payload, or a stack child's newer revision.
    public static func words(of text: String, inlineWidgets: Bool, stored: (String) -> WidgetPayload?, locale: Locale = .current) -> Words {
        guard text.contains("::widget{") || text.contains("```widget") else { return Words(text: text) }
        var isPrivate = false
        let parts = ReplySplitter.split(text, inlineWidgets: inlineWidgets).compactMap { segment -> String? in
            let words: Words?
            switch segment {
            case .markdown(let markdown):
                words = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Words(text: markdown)
            case .widget(let directive):
                words = stored(directive.id).map { self.words(of: $0, stored: stored, locale: locale) } ?? directive.alt.map { Words(text: $0) }
            case .inline(let json):
                if case .ready(let payload) = WidgetReader.read(json) {
                    words = self.words(of: payload, stored: stored, locale: locale)
                } else {
                    // Unreadable payloads fail closed: private unless they say otherwise.
                    words = json["fallback_text"]?.stringValue.map { Words(text: $0, isPrivate: json["sensitivity"]?.stringValue != "normal") }
                }
            }
            if words?.isPrivate == true { isPrivate = true }
            return words?.text
        }
        return Words(text: parts.joined(separator: "\n\n"), isPrivate: isPrivate)
    }

    /// One widget's words, or a stack's brief.
    public static func words(of payload: WidgetPayload, stored: (String) -> WidgetPayload? = { _ in nil }, locale: Locale = .current) -> Words {
        guard case .stack(let stack) = payload.content else {
            return Words(text: payload.envelope.fallbackText, isPrivate: payload.isPrivate)
        }
        var isPrivate = payload.isPrivate
        var parts = [intro(payload, locale: locale)]
        for child in stack.children {
            switch child {
            case .payload(let child):
                let newest = stored(child.id).flatMap { $0.rev >= child.rev ? $0 : nil } ?? child
                if newest.isPrivate { isPrivate = true }
                parts.append(newest.envelope.fallbackText)
            case .unreadable(let json):
                if let text = json["fallback_text"]?.stringValue { parts.append(text) }
            }
        }
        return Words(text: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), isPrivate: isPrivate)
    }

    /// "Your Friday brief: Morning brief.", the day the report is as of, in its own time zone.
    public static func intro(_ stack: WidgetPayload, locale: Locale = .current) -> String {
        let title = stack.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (date, zone) = WidgetFormatter.parse(stack.envelope.asOf) else { return title.isEmpty ? "" : "\(title)." }
        var style = Date.FormatStyle.dateTime.weekday(.wide)
        style.timeZone = zone
        style.locale = locale
        let day = date.formatted(style)
        return title.isEmpty ? String(localized: "Your \(day) brief.") : String(localized: "Your \(day) brief: \(title).")
    }
}
