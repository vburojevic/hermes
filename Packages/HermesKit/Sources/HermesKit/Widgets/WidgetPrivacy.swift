import Foundation

/// Where a widget's content may go (`docs/widgets.md` §8, contract §9). A private widget
/// (health, money, family) stays out of the chat list, notifications and the Live Activity, and
/// is kept on the device only sealed; what a reply says around its widgets is what those show.
public enum WidgetPrivacy {
    /// A payload is private unless it says `normal`, read failing closed; a stack is private when
    /// one of its widgets is.
    public static func isPrivate(_ json: JSONValue) -> Bool {
        if let sensitivity = json["sensitivity"], sensitivity.stringValue != "normal" { return true }
        if case .array(let children)? = json["children"] { return children.contains(where: isPrivate) }
        return false
    }

    // MARK: - Previews

    /// A reply as the chat list, a notification or the Live Activity shows it: its words without
    /// its widgets, empty when it's only widgets. Never a widget's `alt`: a private widget's
    /// title is still private, and the directive doesn't say which ones are.
    public static func previewText(_ text: String) -> String {
        guard text.containsBytes("::widget{") || text.containsBytes("```widget") || text.containsBytes("~~~widget") else { return text }
        return ReplySplitter.split(text, inlineWidgets: true).compactMap { segment -> String? in
            if case .markdown(let markdown) = segment { markdown } else { nil }
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reply had widgets that `previewText` left out.
    public static func hasWidgets(_ text: String) -> Bool {
        ReplySplitter.split(text, inlineWidgets: true).contains { segment in
            if case .markdown = segment { false } else { true }
        }
    }

    // MARK: - At rest

    /// Chat rows as the device keeps them (the transcript cache): a private widget's payload
    /// leaves its tool row, its inline block becomes a directive to the sealed copy, and an
    /// answer to it keeps only its action and mid. `payloads` are the private payloads taken
    /// out, for the sealed widget cache.
    public static func atRest(_ messages: [SessionMessage]) -> (messages: [SessionMessage], payloads: [JSONValue]) {
        var privateIDs: Set<String> = []
        var payloads: [JSONValue] = []

        func note(_ json: JSONValue) {
            guard isPrivate(json), let id = json["id"]?.stringValue else { return }
            privateIDs.insert(id)
            payloads.append(json)
            if case .array(let children)? = json["children"] {
                for child in children { if let childID = child["id"]?.stringValue { privateIDs.insert(childID) } }
            }
        }

        // Which widgets are private: their tool rows and inline blocks say.
        for message in messages {
            if message.role == "tool", message.toolName == WidgetToolResult.widgetTool,
               let json = WidgetToolResult.payload(fromText: message.content.text) {
                note(json)
            } else if message.role == "assistant", hasInlineBlock(message.content.text) {
                for case .inline(let json) in ReplySplitter.split(message.content.text, inlineWidgets: true) { note(json) }
            }
        }
        guard !privateIDs.isEmpty else { return (messages, []) }

        let kept = messages.map { message -> SessionMessage in
            var message = message
            let text = message.content.text
            switch message.role {
            case "tool" where message.toolName == WidgetToolResult.widgetTool:
                if let json = WidgetToolResult.payload(fromText: text), let id = json["id"]?.stringValue, privateIDs.contains(id) {
                    message.content = .text(WidgetAnswer.canonical(.object(["id": .string(id), "rev": json["rev"] ?? .number(1), "private": .bool(true)])))
                }
            case "assistant" where hasInlineBlock(text):
                message.content = .text(directivesForPrivateBlocks(text, privateIDs))
            case "user":
                if let answer = WidgetAnswer.parse(text), privateIDs.contains(answer.widgetID) {
                    let kept = WidgetAnswer(widgetID: answer.widgetID, rev: answer.rev, action: answer.action, mid: answer.mid, device: answer.device)
                    message.content = .text(kept.message)
                    message.displayContent = nil
                }
            default:
                break
            }
            return message
        }
        return (kept, payloads)
    }

    private static func hasInlineBlock(_ text: String) -> Bool {
        text.containsBytes("```widget") || text.containsBytes("~~~widget")
    }

    /// The reply with each private inline block as a directive line naming it.
    private static func directivesForPrivateBlocks(_ text: String, _ privateIDs: Set<String>) -> String {
        let segments = ReplySplitter.split(text, inlineWidgets: true)
        guard segments.contains(where: { if case .inline(let json) = $0 { privateIDs.contains(json["id"]?.stringValue ?? "") } else { false } }) else {
            return text
        }
        return segments.map { segment -> String in
            switch segment {
            case .markdown(let markdown): markdown
            case .widget(let directive): directive.line
            case .inline(let json):
                if let id = json["id"]?.stringValue, privateIDs.contains(id) {
                    WidgetDirective(id: id, alt: json["title"]?.stringValue).line
                } else {
                    "```widget\n" + WidgetAnswer.canonical(json) + "\n```"
                }
            }
        }.joined(separator: "\n\n")
    }
}

extension WidgetDirective {
    /// The directive as a line of a reply.
    public var line: String {
        let attributes = ["id=\"\(id)\""] + (alt.map { ["alt=\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""] } ?? [])
        return "::widget{" + attributes.joined(separator: " ") + "}"
    }
}
