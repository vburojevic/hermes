import Foundation

/// A row's second line when nothing is happening (`docs/inbox.md` §2): the last message, one
/// line, with who said it when it wasn't Hermes ("You:", a Bot's name).
public struct LastLine: Hashable, Sendable {
    public enum Speaker: Hashable, Sendable {
        case hermes
        case you
        /// A Bot in the chat, or a routine.
        case named(String)
    }

    public var speaker: Speaker
    public var text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }

    /// The last message worth showing, newest first: replies, messages and commands; notices are
    /// skipped.
    public static func of(_ items: [TranscriptItem]) -> LastLine? {
        for item in items.reversed() {
            switch item {
            case .assistant(let turn):
                let text = flatten(turn.previewText)
                if !text.isEmpty { return LastLine(speaker: .hermes, text: text) }
            case .user(let entry):
                // A widget answer reads as what it did ("Approved"), without its words: they may be private.
                let text = WidgetAnswer.parse(entry.text).map { WidgetAnswer.pastTense($0.action) ?? String(localized: "Answered a widget") }
                    ?? flatten(entry.text)
                guard !text.isEmpty else { continue }
                if let sender = entry.sender { return LastLine(speaker: .named(sender.name), text: text) }
                if let routine = entry.routineName { return LastLine(speaker: .named(routine), text: text) }
                return LastLine(speaker: .you, text: text)
            case .command(let command):
                return LastLine(speaker: .you, text: "/" + command.name + (command.argument.map { " " + $0 } ?? ""))
            case .notice:
                continue
            }
        }
        return nil
    }

    /// One line of plain words: Markdown marks and line breaks go, at most 120 characters. Reads
    /// only as far as it needs: a long reply isn't split into all its lines for its first few.
    public static func flatten(_ text: String) -> String {
        var result = ""
        var rest = text[...]
        while !rest.isEmpty, result.count <= 120 {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            var line = rest[..<end].trimmingCharacters(in: .whitespaces)
            rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[rest.endIndex...]
            if line.hasPrefix("```") { continue }
            while let first = line.first, "#>-*+".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "__", with: "")
            if !line.isEmpty { result += result.isEmpty ? line : " " + line }
        }
        return String(result.prefix(120))
    }
}
