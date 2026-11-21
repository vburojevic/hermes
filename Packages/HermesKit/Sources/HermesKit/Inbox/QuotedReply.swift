import Foundation

/// A reply with quotes (`replyBar`, `replyQuotes`, `quotedBubble`, `docs/inbox.md` §4): each
/// passage as its own Markdown block quote, in the order they were picked, before the person's
/// words. Hermes needs nothing new to read it; the app draws each quote as a block in the bubble,
/// never as a raw ">".
public struct QuotedReply: Hashable, Sendable {
    public var quotes: [String]
    public var message: String

    public init(quotes: [String], message: String) {
        self.quotes = quotes
        self.message = message
    }

    public init(quote: String, message: String) {
        self.init(quotes: [quote], message: message)
    }

    /// The first passage quoted.
    public var quote: String { quotes.first ?? "" }

    /// The longest quote sent: a passage, not the whole reply.
    public static let maxQuote = 280

    /// The most passages one reply quotes (`replyQuotesThree`).
    public static let maxQuotes = 3

    /// `> Two options: back off and retry…\n\n> After sleep…\n\nBack off and retry.`
    public var text: String {
        let blocks = quotes.map { quote in
            Self.trimmed(quote).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        }
        return (blocks + [message]).joined(separator: "\n\n")
    }

    /// What VoiceOver reads for each quote of a sent reply, in order: the passage on one line,
    /// after whose it was when this device knows (`Hermes, “the passage”`).
    public func spokenQuotes(author: (String) -> String?) -> [String] {
        quotes.map { quote in
            let words = "“\(LastLine.flatten(quote))”"
            return author(quote).map { "\($0), \(words)" } ?? words
        }
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

    /// A message that starts with block quotes followed by words of its own; nil otherwise. Each
    /// run of ">" lines is one quote, and blank lines separate one quote from the next, up to
    /// `maxQuotes`: anything after that is the message.
    public static func parse(_ text: String) -> QuotedReply? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix(">") else { return nil }
        var quotes: [String] = []
        var index = 0
        while index < lines.count, quotes.count < maxQuotes {
            var quote: [String] = []
            while index < lines.count, lines[index].hasPrefix(">") {
                var line = lines[index].dropFirst()
                if line.first == " " { line = line.dropFirst() }
                quote.append(String(line))
                index += 1
            }
            let joined = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return nil }
            quotes.append(joined)
            // Another quote only after blank lines; anything else starts the message.
            var next = index
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            guard quotes.count < maxQuotes, next < lines.count, lines[next].hasPrefix(">") else { break }
            index = next
        }
        let message = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return QuotedReply(quotes: quotes, message: message)
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
    /// One passage in the composer's reply bar: who said it and the row it is in.
    public struct Passage: Hashable, Sendable, Identifiable {
        public var author: String
        /// Trimmed with `trimmed(_:)`.
        public var quote: String
        /// The transcript row the passage is in; empty when it isn't known (a queued message
        /// opened to edit, quoting a row this device never saw).
        public var rowID: String

        public init(author: String, quote: String, rowID: String) {
            self.author = author
            self.quote = QuotedReply.trimmed(quote)
            self.rowID = rowID
        }

        /// The same passage of the same row is one quote, whatever the bar shows of it.
        public var id: String { rowID + "|" + QuotedReply.key(quote) }
    }

    /// The passages a message will quote, in the order they were picked (`replyQuotes`,
    /// `docs/inbox.md` §4): Reply adds one, each removes on its own, and Send puts them in front
    /// of the message, whichever way it goes (`docs/follow-ups.md` §1).
    public struct Draft: Equatable, Sendable {
        public private(set) var passages: [Passage]
        /// Reply was chosen with the bar full: the bar says so until a quote goes or the message
        /// does (`replyQuotesLimit`).
        public private(set) var showsLimit = false

        public init(_ passages: [Passage] = []) {
            self.passages = Array(passages.filter { !$0.quote.isEmpty }.prefix(QuotedReply.maxQuotes))
        }

        /// What Reply did.
        public enum Outcome: Equatable, Sendable {
            case added
            /// Only spaces and line breaks: nothing to quote.
            case empty
            /// That passage of that row is already in the bar.
            case alreadyQuoted
            /// The bar holds `maxQuotes`: nothing is added, and the bar says why.
            case full
        }

        /// What the bar says when it is full and Reply is chosen again; VoiceOver reads it out.
        public static var limitNote: String {
            String(localized: "You can quote up to \(QuotedReply.maxQuotes) passages. Remove one to add another.")
        }

        public var isEmpty: Bool { passages.isEmpty }
        public var count: Int { passages.count }
        public var isFull: Bool { passages.count >= QuotedReply.maxQuotes }

        /// Where a passage sits in the bar, counting from 1, so VoiceOver can tell two quotes
        /// of the same words apart ("quote 2 of 3"). Nil when the bar holds only that one.
        public func position(of id: Passage.ID) -> Int? {
            guard passages.count > 1, let index = passages.firstIndex(where: { $0.id == id }) else { return nil }
            return index + 1
        }

        @discardableResult
        public mutating func add(author: String, quote: String, rowID: String) -> Outcome {
            let passage = Passage(author: author, quote: quote, rowID: rowID)
            guard !passage.quote.isEmpty else { return .empty }
            guard !passages.contains(where: { $0.id == passage.id }) else { return .alreadyQuoted }
            guard !isFull else {
                showsLimit = true
                return .full
            }
            passages.append(passage)
            return .added
        }

        public mutating func remove(_ id: Passage.ID) {
            passages.removeAll { $0.id == id }
            showsLimit = false
        }

        public mutating func removeAll() {
            passages = []
            showsLimit = false
        }

        /// This bar's quotes first, then `other`'s that aren't in it yet, while there is room:
        /// a draft set aside to edit a queued message comes back without pushing out quotes that
        /// message left in the bar.
        public func merging(_ other: Draft) -> Draft {
            var merged = Draft(passages)
            for passage in other.passages where !merged.isFull {
                merged.add(author: passage.author, quote: passage.quote, rowID: passage.rowID)
            }
            return merged
        }

        /// The message with the quotes in front, each its own block quote, and how far the
        /// message's own words moved (UTF-16), so its references can follow them. Nil with no
        /// quotes, or with no words of its own: a message is never only quotes.
        public func compose(_ message: String) -> (text: String, shift: Int)? {
            guard !passages.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let text = QuotedReply(quotes: passages.map(\.quote), message: message).text
            return (text, text.utf16.count - message.utf16.count)
        }

        /// A message opened to edit again, such as a queued follow-up: its quotes go back in the
        /// bar, each with the author and row this device remembers for it (`source`), and its own
        /// words go back in the composer. A message without quotes opens as it is.
        public static func opening(
            _ text: String,
            fallbackAuthor: String,
            source: (String) -> (author: String, rowID: String)?
        ) -> (draft: Draft, message: String) {
            guard let reply = QuotedReply.parse(text) else { return (Draft(), text) }
            let passages = reply.quotes.map { quote in
                let known = source(quote)
                return Passage(author: known?.author ?? fallbackAuthor, quote: quote, rowID: known?.rowID ?? "")
            }
            return (Draft(passages), reply.message)
        }
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
