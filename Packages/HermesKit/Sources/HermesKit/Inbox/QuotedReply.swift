import Foundation

/// A reply with a quote (`replyBar`, `quotedBubble`, `docs/inbox.md` §4): the passage as a
/// Markdown block quote before the person's words. Hermes needs nothing new to read it; the app
/// draws the quote as a block in the bubble, never as a raw ">".
public struct QuotedReply: Hashable, Sendable {
    public var quote: String
    public var message: String

    public init(quote: String, message: String) {
        self.quote = quote
        self.message = message
    }

    /// The longest quote sent: a passage, not the whole reply.
    public static let maxQuote = 280

    /// `> Two options: back off and retry…\n\nBack off and retry, up to 5 seconds.`
    public var text: String {
        let lines = Self.trimmed(quote).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { "> " + $0 }.joined(separator: "\n") + "\n\n" + message
    }

    /// The quote sent for a passage: whitespace tidied, at most `maxQuote` characters, cut at a
    /// word with "…".
    public static func trimmed(_ passage: String) -> String {
        let lines = passage.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxQuote else { return joined }
        let cut = joined.prefix(maxQuote)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    /// A message that starts with a block quote followed by words of its own; nil otherwise.
    public static func parse(_ text: String) -> QuotedReply? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix(">") else { return nil }
        var quote: [String] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var line = lines[index].dropFirst()
            if line.first == " " { line = line.dropFirst() }
            quote.append(String(line))
            index += 1
        }
        let message = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty, !message.isEmpty else { return nil }
        return QuotedReply(quote: joined, message: message)
    }

    /// A short stable key for a quote, so this device can remember where it came from without
    /// keeping its words (FNV-1a over the trimmed quote).
    public static func key(_ quote: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in trimmed(quote).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

extension QuotedReply {
    /// Why a row flashes in the transcript (`docs/inbox.md` §4).
    public enum Flash: Sendable {
        /// The passage was just quoted, by its swipe or its menu: it is on screen, however little
        /// of a tall reply shows.
        case quoted
        /// A row shown from somewhere else in the chat, such as a finished step's source.
        case shown

        /// Whether the chat scrolls to the row before it flashes. A quoted passage flashes where
        /// it is: the chat's visible rows count only one that is 40% on screen, so a tall reply
        /// read near its top would otherwise jump to the middle as it was quoted.
        public func scrolls(rowOnScreen: Bool) -> Bool {
            switch self {
            case .quoted: false
            case .shown: !rowOnScreen
            }
        }
    }
}

extension QuotedReply {
    /// Whether a selection holds words to quote. One of only spaces and line breaks gets no Reply.
    public static func quotes(_ selection: String) -> Bool {
        !trimmed(selection).isEmpty
    }

    /// Where Reply floats beside words selected in a finished reply on the Mac
    /// (`selectionReplyButton`, `docs/inbox.md` §4), in the coordinates of the view it floats in,
    /// y running down.
    public struct SelectionPlacement: Equatable, Sendable {
        /// The selection's first and last lines, as wide as the words selected on them.
        public var firstLine: CGRect
        public var lastLine: CGRect
        /// Where the selected words end, along the last line.
        public var end: CGFloat
        /// The transcript column's left and right edges: the button stays between them.
        public var column: ClosedRange<CGFloat>

        /// The room between the button and the selection's line.
        public static let gap: CGFloat = 6

        public init(firstLine: CGRect, lastLine: CGRect, end: CGFloat, column: ClosedRange<CGFloat>) {
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.end = end
            self.column = column
        }

        /// The selection's lines from the text's selection segments, in reading order. A
        /// selection that runs past a line break ends with an empty segment at the start of the
        /// next line; the words end before it.
        public init?(segments: [CGRect], column: ClosedRange<CGFloat>) {
            let drawn = segments.filter { $0.width >= 1 }
            let rects = drawn.isEmpty ? segments : drawn
            guard let first = rects.first, let last = rects.last else { return nil }
            func line(of rect: CGRect) -> CGRect {
                rects.filter { $0.minY < rect.maxY && $0.maxY > rect.minY }.reduce(rect) { $0.union($1) }
            }
            self.init(firstLine: line(of: first), lastLine: line(of: last), end: last.maxX, column: column)
        }

        /// The button's top-left corner: under the last line with its leading edge at the end of
        /// the words, or above the first line when below would leave the visible band (the
        /// composer and the scroll edge's fade). Nil when neither fits, so the button never
        /// floats over the bars or away from words scrolled out of sight.
        public func origin(for size: CGSize, visible: ClosedRange<CGFloat>) -> CGPoint? {
            let x = max(column.lowerBound, min(end, column.upperBound - size.width))
            let below = lastLine.maxY + Self.gap
            if below >= visible.lowerBound, below + size.height <= visible.upperBound {
                return CGPoint(x: x, y: below)
            }
            let above = firstLine.minY - Self.gap - size.height
            if above >= visible.lowerBound, above + size.height <= visible.upperBound {
                return CGPoint(x: x, y: above)
            }
            return nil
        }
    }
}
