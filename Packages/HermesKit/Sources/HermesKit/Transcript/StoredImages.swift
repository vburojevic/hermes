import Foundation

/// How Hermes stores the photos a message carried, so the bubble shows them again (`docs/chat.md` §2).
///
/// A turn with photos stores the words, then an `@image:<path>` line per photo (quoted when the path
/// has spaces or brackets), then, when a vision model got the photos themselves, a `[screenshot]` line
/// per photo (`tui_gateway/session_history.py` `_build_persist_user_message`, `_durable_content`).
/// It is the same for a photo sent while Hermes was idle and one it held for the next turn. Both
/// lines name the same photos, and the context an `@file:` attached sits between the words and them.
public enum StoredImages {
    /// The text without its trailing photo lines, and how many photos they name.
    public static func split(_ text: String) -> (text: String, count: Int) {
        var lines = text.components(separatedBy: "\n")
        var references = 0
        var placeholders = 0
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            if line == "[screenshot]" {
                placeholders += 1
            } else if isReference(line) {
                references += 1
            } else if !line.isEmpty {
                break
            }
            lines.removeLast()
        }
        guard references + placeholders > 0 else { return (text, 0) }
        return (lines.joined(separator: "\n"), max(references, placeholders))
    }

    /// `@image:` and a path: bare, or in backticks or quotes (`format_reference_value`).
    static func isReference(_ line: String) -> Bool {
        guard line.hasPrefix("@image:") else { return false }
        let value = line.dropFirst("@image:".count)
        guard let first = value.first else { return false }
        if "`\"'".contains(first) {
            let inside = value.dropFirst().dropLast()
            return value.count > 2 && value.last == first && !inside.contains(first)
        }
        return !value.contains(where: \.isWhitespace)
    }
}
