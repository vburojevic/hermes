import Foundation

/// How a fenced code block draws in a chat (`CodeBlockView`). Its code is one text run, and a run
/// is one layer, which draws nothing past a few thousand points: a 5,800-character line (a widget
/// payload a Bot repeated as JSON) came out as an empty frame on the iPhone. So a block with a long
/// line wraps instead of scrolling sideways, and a very long block shows its start, with Copy for
/// all of it.
public enum CodeBlockLayout {
    /// Longest line that still scrolls sideways (about 3,000 points of code on a phone).
    public static let longestScrollingLine = 400
    /// How much of a block shows before the rest is left to Copy.
    public static let shownCharacters = 3_000

    /// Whether the block wraps its lines rather than scrolling sideways.
    public static func wraps(_ code: String) -> Bool {
        code.split(separator: "\n", omittingEmptySubsequences: false).contains { $0.count > longestScrollingLine }
    }

    /// What the block shows, cut at a line end where there is one near the limit, and how many
    /// characters are left out.
    public static func shown(_ code: String) -> (text: String, hidden: Int) {
        guard code.count > shownCharacters else { return (code, 0) }
        var end = code.index(code.startIndex, offsetBy: shownCharacters)
        if let newline = code[code.startIndex..<end].lastIndex(of: "\n"),
           code.distance(from: code.startIndex, to: newline) > shownCharacters / 2 {
            end = newline
        }
        return (String(code[..<end]), code.distance(from: end, to: code.endIndex))
    }
}
