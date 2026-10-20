import Foundation

/// The diff a `tool.complete` carries for an edit (`inline_diff`), as Hermes renders it for its
/// terminal (agent/display.py `render_edit_diff_with_delta`): a "┊ review diff" header, each
/// file as "a/path → b/path", and every line wrapped in ANSI colours. Cards and counts read a
/// plain unified diff, so the colours go and each file gets its `---`/`+++` pair back.
public enum InlineDiff {
    /// The diff without Hermes's terminal styling; nil when nothing in it is a diff line.
    public static func unified(_ raw: String) -> String? {
        let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        var lines: [String] = []
        for line in plain.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("┊") { continue } // the "review diff" header
            if !line.hasPrefix("+"), !line.hasPrefix("-"), !line.hasPrefix(" "), !line.hasPrefix("@@"),
               let arrow = line.range(of: " → ") {
                lines.append("--- \(line[..<arrow.lowerBound])")
                lines.append("+++ \(line[arrow.upperBound...])")
                continue
            }
            lines.append(line)
        }
        let changes = lines.contains { line in
            (line.hasPrefix("+") && !line.hasPrefix("+++")) || (line.hasPrefix("-") && !line.hasPrefix("---"))
        }
        return changes ? lines.joined(separator: "\n") : nil
    }
}
