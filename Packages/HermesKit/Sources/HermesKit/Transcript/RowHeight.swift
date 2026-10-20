import Foundation

extension TranscriptItem {
    /// The row's height at the least, from its text, before it's laid out: each line at 18 points,
    /// a prose line wrapping every 110 characters (wider than the widest column), a code line never
    /// (code scrolls sideways), blank lines nothing, over a 40-point row. Low on purpose: a chat opens
    /// with as many of its latest rows as cover the screen, and rows guessed too tall would leave it
    /// short (`docs/chat.md` §4, Long history).
    public var leastHeight: CGFloat {
        let text: String = switch self {
        case .user(let entry): entry.text
        case .assistant(let turn): turn.answer
        case .notice, .command: ""
        }
        var lines = 0
        var inCode = false
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.starts(with: "```".utf8) {
                inCode.toggle()
                continue
            }
            if inCode {
                lines += 1
            } else if !line.isEmpty {
                lines += 1 + line.count / 110
            }
        }
        return 40 + CGFloat(lines) * 18
    }
}
