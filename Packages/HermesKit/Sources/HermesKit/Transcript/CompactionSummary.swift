import Foundation

/// Hermes' handoff summary from compacting a chat (`agent/context_compressor.py`). It's stored as an
/// ordinary message, the person's or Hermes', but nobody wrote it: it's never a row's last line, its
/// time or sort key, and never unread (`docs/inbox.md` §2).
public enum CompactionSummary {
    /// Mirrors Hermes Agent's `_COMPACTION_PREFIXES` and `_is_compaction_summary`
    /// (`tools/session_search_tool.py`), which leave the summaries out of session search.
    static let prefixes = ["[CONTEXT COMPACTION", "[CONTEXT SUMMARY]:"]

    public static func matches(_ text: String) -> Bool {
        let head = text.drop(while: \.isWhitespace)
        return prefixes.contains { head.hasPrefix($0) }
    }
}

extension TranscriptItem {
    /// A compaction summary, as the person's message or as Hermes' reply.
    public var isCompactionSummary: Bool {
        switch self {
        case .user(let entry): CompactionSummary.matches(entry.text)
        case .assistant(let turn): CompactionSummary.matches(turn.answer)
        case .notice, .command: false
        }
    }
}
