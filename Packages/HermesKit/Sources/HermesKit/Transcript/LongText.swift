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
