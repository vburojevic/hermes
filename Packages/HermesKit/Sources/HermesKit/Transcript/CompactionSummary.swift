import Foundation

/// Hermes' handoff summary from compacting a chat (`agent/context_compressor.py`). It's stored as an
/// ordinary message, the person's or Hermes', but nobody wrote it: in the chat it's a quiet divider
/// that opens to the summary (`docs/chat.md` §2a), and it's never a row's last line, its time or
/// sort key, and never unread (`docs/inbox.md` §2).
public enum CompactionSummary {
    /// Mirrors Hermes Agent's `_COMPACTION_PREFIXES` and `_is_compaction_summary`
    /// (`tools/session_search_tool.py`), which leave the summaries out of session search.
    static let prefixes = ["[CONTEXT COMPACTION", "[CONTEXT SUMMARY]:"]

    /// Hermes keeps an older message the summary was folded into before it, between these
    /// (`_MERGED_PRIOR_CONTEXT_HEADER`, `_MERGED_SUMMARY_DELIMITER`).
    static let priorContextHeader = "[PRIOR CONTEXT — for reference only; not a new message]"
    static let mergedDelimiter = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"
    /// Ends the summary; a message the summary leads may go on after it (`_SUMMARY_END_MARKER`).
    static let endMarker = "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"
    /// A request still running when Hermes compacted, restated after the summary in place of the
    /// original (`_INFLIGHT_TASK_REPLAY_HEADER`).
    static let restatedHeader = "[STILL IN PROGRESS — this is the active request, restated after the compaction boundary because it was not finished yet. Continue it; do not start over.]"
    /// Every shipped preamble (`SUMMARY_PREFIX`, `_HISTORICAL_SUMMARY_PREFIXES`) ends with these
    /// words; the legacy one is only its tag.
    static let preambleEnd = "avoid repeating it:"
    static let legacyPrefix = "[CONTEXT SUMMARY]:"

    public static func matches(_ text: String) -> Bool {
        let head = text.drop(while: \.isWhitespace)
        return prefixes.contains { head.hasPrefix($0) }
    }

    /// A stored message that holds a summary, in its parts: what came before it (an older message
    /// Hermes folded it into), the summary's own words without Hermes' instructions to the model,
    /// and what follows it (the message it leads). Nil for any other message. Mirrors
    /// `ContextCompressor.classify_summary_content` and `_strip_summary_prefix`.
    public struct Parts: Hashable, Sendable {
        public var before: String
        public var summary: String
        public var after: String
    }

    public static func parse(_ text: String) -> Parts? {
        var rest = Substring(text.drop(while: \.isWhitespace))
        var before = ""
        if let delimiter = rest.range(of: mergedDelimiter) {
            let after = rest[delimiter.upperBound...].drop(while: \.isWhitespace)
            guard prefixes.contains(where: { after.hasPrefix($0) }) else { return nil }
            var prior = rest[..<delimiter.lowerBound]
            if prior.hasPrefix(priorContextHeader) { prior = prior.dropFirst(priorContextHeader.count) }
            before = prior.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = after
        } else if !prefixes.contains(where: { rest.hasPrefix($0) }) {
            return nil
        }
        rest = withoutPreamble(rest)
        var after = ""
        if let marker = rest.range(of: endMarker) {
            after = String(rest[marker.upperBound...])
            rest = rest[..<marker.lowerBound]
        }
        // The restated request stands for the person's message it replaced.
        if let restated = after.range(of: restatedHeader, options: .backwards) {
            after = String(after[restated.upperBound...])
        }
        return Parts(
            before: before,
            summary: rest.trimmingCharacters(in: .whitespacesAndNewlines),
            after: after.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A request Hermes restated after a compaction, in place of the person's message it
    /// replaced: its words without the header. Nil for any other message.
    public static func restatedRequest(_ text: String) -> String? {
        let head = text.drop(while: \.isWhitespace)
        guard head.hasPrefix(restatedHeader) else { return nil }
        let words = head.dropFirst(restatedHeader.count)
        let last = words.range(of: restatedHeader, options: .backwards).map { words[$0.upperBound...] } ?? words
        return last.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The summary after Hermes' preamble: every version of it ends "…avoid repeating it:", the
    /// legacy one is only its tag. A preamble this app doesn't know loses its first line.
    static func withoutPreamble(_ text: Substring) -> Substring {
        if text.hasPrefix(legacyPrefix) { return text.dropFirst(legacyPrefix.count) }
        if let end = text.range(of: preambleEnd) { return text[end.upperBound...] }
        guard let newline = text.firstIndex(where: \.isNewline) else { return "" }
        return text[text.index(after: newline)...]
    }
}

extension CompactionSummary {
    /// The summary as the opened divider shows it (`compactionDividerOpen`): plain text, read-only.
    /// Hermes writes it in Markdown for the model; its headings, emphasis, code marks and links
    /// lose their syntax, list items become "• " lines, and the line breaks stay.
    public static func plainText(_ summary: String) -> String {
        summary.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            for (regex, template) in plainRules {
                line = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: template)
            }
            return line
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let plainRules: [(NSRegularExpression, String)] = [
        ("^\\s*#{1,6}\\s+", ""),                    // headings
        ("^(\\s*)[-*+]\\s+", "$1• "),                  // list items
        ("^\\s*>\\s?", ""),                          // block quotes
        ("`{1,3}", ""), ("\\*\\*|__", ""), ("(^|[\\s(])[*_]([^*_\\s][^*_]*)[*_]", "$1$2"),
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
    ].map { pattern, template in
        (try! NSRegularExpression(pattern: pattern), template)
    }
}

extension TranscriptItem {
    /// A compaction summary: its divider, or (before it was built into one) the person's message
    /// or Hermes' reply that holds it.
    public var isCompactionSummary: Bool {
        switch self {
        case .user(let entry): CompactionSummary.matches(entry.text)
        case .assistant(let turn): CompactionSummary.matches(turn.answer)
        case .notice(let notice): notice.kind == Notice.compactionKind
        case .command: false
        }
    }
}

extension Notice {
    /// The divider a compaction leaves (`compactionDivider`): its text is the summary.
    public static let compactionKind = "compaction_summary"
}
