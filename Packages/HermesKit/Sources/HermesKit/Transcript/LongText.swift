import Foundation

/// How long machine-made and Bot-to-Bot text shows before Show More (`docs/chat.md` §2a): a Bot's
/// message to another, a helper's result, a process's output in a notice.
public enum LongText {
    /// Lines a Bot's message shows folded.
    public static let messageLines = 6
    /// Characters a line holds, roughly, at the reading width of a phone.
    static let charactersPerLine = 60

    /// Whether `text` runs past `lines` lines at the reading width: its line breaks, and long
    /// paragraphs as the lines they wrap to.
    public static func isLong(_ text: String, lines: Int = messageLines) -> Bool {
        var count = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            count += max(1, (paragraph.count + charactersPerLine - 1) / charactersPerLine)
            if count > lines { return true }
        }
        return false
    }

    /// The last `lines` lines of an output, for a notice's details.
    public static func tail(_ text: String, lines: Int) -> (text: String, hidden: Int) {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines else { return (text, 0) }
        return (all.suffix(lines).joined(separator: "\n"), all.count - lines)
    }
}

/// A machine-style handoff one Bot writes another: a long, structured brief (headings, labelled
/// fields, long lists) rather than a message. It shows as a one-line summary row that opens to
/// the whole text (`docs/bots-groups-skills.md` §1.1), never as a wall in the chat.
public enum HandoffBrief {
    /// Shorter than this, it's a message, however it's laid out.
    static let minimumLength = 400

    /// The summary line for a brief, or nil when `text` reads as a message.
    public static func summary(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumLength else { return nil }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let headings = lines.filter { $0.hasPrefix("#") }
        let fields = lines.filter { $0.range(of: #"^(\*\*)?[A-Z][A-Za-z /_-]{1,30}(\*\*)?:(\*\*)?(\s|$)"#, options: .regularExpression) != nil }
        let items = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil }
        let tagged = text.hasPrefix("[") && (text.firstIndex(of: "]").map { text.distance(from: text.startIndex, to: $0) < 60 } ?? false)
        guard tagged || headings.count >= 2 || fields.count >= 3 || items.count >= 8 else { return nil }
        return line(from: lines)
    }

    /// Its first heading, field or sentence, as one plain line.
    static func line(from lines: [String]) -> String {
        let first = lines.first { !$0.isEmpty && !$0.allSatisfy { $0 == "-" || $0 == "=" || $0 == "*" } } ?? ""
        var line = BotMentions.stripMarkdown(first.drop { $0 == "#" || $0 == " " }.description)
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let tag = line[line.index(after: line.startIndex)..<close]
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            line = rest.isEmpty ? String(tag) : rest
        }
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression), line.distance(from: line.startIndex, to: end.lowerBound) > 20 {
            line = String(line[...end.lowerBound])
        }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}
