import Foundation

/// Web addresses written out in plain text (`https://…`, `http://…`, `www.…`), found the way
/// GitHub's Markdown finds them (its extended autolinks, which swift-markdown doesn't turn on):
/// at the start or after a space, a quote or an opening bracket, up to the next space, without
/// the punctuation that ends a sentence or a closing bracket the address didn't open. Only the
/// web: what such a link may open is still `WebLink`'s to say.
public enum AutoLink {
    public struct Match: Equatable, Sendable {
        /// Where the address is in the text.
        public var range: Range<String.Index>
        /// What it opens: the address, with `https://` before a bare `www.`.
        public var destination: String
    }

    /// The longest address linked. A longer run of text without spaces stays text, which also
    /// keeps a reply built to be slow (thousands of `)` or `(http://` in a row) linear: every
    /// start reads at most this far (security scan F30).
    static let maxLength = 2048

    public static func matches(in text: String) -> [Match] {
        var reads = 0
        return matches(in: text, reads: &reads)
    }

    /// `matches(in:)`, adding to `reads` the bytes of `text` each step reads, so a test can
    /// tell the work grows with the text rather than with its square without timing it.
    static func matches(in text: String, reads: inout Int) -> [Match] {
        guard text.contains("://") || text.localizedCaseInsensitiveContains("www.") else { return [] }
        var found: [Match] = []
        var starts = Starts(text: text)
        defer { reads += starts.reads }
        var index = text.startIndex
        // Where the run without spaces around the last start ends (later starts in it share it),
        // and from where on what's left of it is short enough to be an address.
        var runEnd = text.startIndex
        var shortFrom = text.startIndex
        while index < text.endIndex {
            guard let start = starts.next(from: index) else { break }
            if start >= runEnd {
                runEnd = start
                while runEnd < text.endIndex, !text[runEnd].isWhitespace, text[runEnd] != "<" { runEnd = text.index(after: runEnd) }
                reads += text.utf8.distance(from: start, to: runEnd)
                shortFrom = text.index(runEnd, offsetBy: -maxLength, limitedBy: start) ?? start
            }
            guard start >= shortFrom else {
                index = text.index(after: start)
                continue
            }
            let end = trimmedEnd(text[start..<runEnd], reads: &reads)
            let candidate = String(text[start..<end])
            reads += candidate.utf8.count
            if let destination = destination(of: candidate) {
                found.append(Match(range: start..<end, destination: destination))
                index = end
            } else {
                index = text.index(after: start)
            }
        }
        return found
    }

    /// The places an address can start: `http://`, `https://` or `www.` where a word starts. The
    /// next "http" and "www." are remembered until passed, so the text is searched once.
    private struct Starts {
        let text: String
        private var web: String.Index?
        private var www: String.Index?
        /// The bytes the searches for "http" and "www." have read.
        private(set) var reads = 0

        init(text: String) {
            self.text = text
        }

        mutating func next(from index: String.Index) -> String.Index? {
            var at = index
            while at < text.endIndex {
                if web.map({ $0 < at }) ?? true {
                    web = text.range(of: "http", options: .caseInsensitive, range: at..<text.endIndex)?.lowerBound ?? text.endIndex
                    reads += text.utf8.distance(from: at, to: web ?? text.endIndex)
                }
                if www.map({ $0 < at }) ?? true {
                    www = text.range(of: "www.", options: .caseInsensitive, range: at..<text.endIndex)?.lowerBound ?? text.endIndex
                    reads += text.utf8.distance(from: at, to: www ?? text.endIndex)
                }
                guard let next = [web, www].compactMap({ $0 }).min(), next < text.endIndex else { return nil }
                let rest = text[next...]
                let opens = rest.range(of: "https://", options: [.caseInsensitive, .anchored]) != nil
                    || rest.range(of: "http://", options: [.caseInsensitive, .anchored]) != nil
                    || rest.range(of: "www.", options: [.caseInsensitive, .anchored]) != nil
                if opens, next == text.startIndex || AutoLink.startsAfter(text[text.index(before: next)]) { return next }
                at = text.index(after: next)
            }
            return nil
        }
    }

    fileprivate static func startsAfter(_ character: Character) -> Bool {
        character.isWhitespace || "*_~([{<\"'“‘".contains(character)
    }

    /// Without what ends the sentence around the address: `.`, `,`, `?`, `!`, `:`, quotes and
    /// emphasis marks, a `)` it didn't open, an entity like `&amp;`. The brackets are counted
    /// once, not again for every `)` taken off.
    private static func trimmedEnd(_ text: Substring, reads: inout Int) -> String.Index {
        var end = text.endIndex
        let opens = text.count { $0 == "(" }
        var closes = text.count { $0 == ")" }
        reads += 2 * text.utf8.count
        while end > text.startIndex {
            let last = text[text.index(before: end)]
            reads += 1
            if "?!.,:*_~'\"”’;".contains(last) {
                if last == ";" {
                    reads += text.utf8.distance(from: text.startIndex, to: end)
                    if let entity = text[..<end].range(of: #"&[A-Za-z0-9]+;$"#, options: .regularExpression) {
                        end = entity.lowerBound
                        continue
                    }
                }
                end = text.index(before: end)
                continue
            }
            if last == ")", closes > opens {
                end = text.index(before: end)
                closes -= 1
                continue
            }
            break
        }
        return end
    }

    /// What the address opens, if its host is a real one: a domain with a dot (no underscore in
    /// its last two parts), `localhost`, or an IP address.
    private static func destination(of candidate: String) -> String? {
        let lower = candidate.lowercased()
        let afterScheme: Substring
        let destination: String
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            afterScheme = candidate[candidate.index(candidate.startIndex, offsetBy: lower.hasPrefix("https://") ? 8 : 7)...]
            destination = candidate
        } else {
            afterScheme = candidate[...]
            destination = "https://" + candidate
        }
        let host = afterScheme.prefix { !"/?#:".contains($0) }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let isAddress = parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
        if host.lowercased() != "localhost", !isAddress {
            // `www.` is the start of a name, not a whole one: it needs a dot after it too.
            let named = lower.hasPrefix("www.") ? parts.dropFirst() : parts[...]
            guard named.count >= 2, !named.contains(where: \.isEmpty),
                  !named.suffix(2).contains(where: { $0.contains("_") }) else { return nil }
        }
        guard URL(string: destination) != nil else { return nil }
        return destination
    }
}

extension MarkdownInline {
    /// `inlines` with the web addresses in their plain text as links (`AutoLink`), their words
    /// the address as written. Runs inside emphasis were linked when they were converted.
    static func autolinked(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        inlines.flatMap { inline -> [MarkdownInline] in
            switch inline {
            case .text(let text):
                let matches = AutoLink.matches(in: text)
                guard !matches.isEmpty else { return [inline] }
                var pieces: [MarkdownInline] = []
                var at = text.startIndex
                for match in matches {
                    if at < match.range.lowerBound { pieces.append(.text(String(text[at..<match.range.lowerBound]))) }
                    pieces.append(.link(destination: match.destination, content: [.text(String(text[match.range]))]))
                    at = match.range.upperBound
                }
                if at < text.endIndex { pieces.append(.text(String(text[at...]))) }
                return pieces
            default: return [inline]
            }
        }
    }
}
