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
