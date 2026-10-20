import Foundation

/// A helper's live transcript, from `subagent.tail` (`tools/delegation_live_log.py`): a header,
/// then one `HH:MM:SS role | text` line per event.
public enum HelperTranscript {
    public enum Line: Hashable, Sendable {
        /// What it said (`assistant`).
        case text(String)
        /// Its reasoning (`think`).
        case thinking(String)
        /// A tool it started (`tool | -> name(args)`).
        case tool(name: String, arguments: String)
        /// What came back (`result | name ok 1.2s: text`).
        case result(name: String, text: String, isError: Bool)
    }

    /// The lines worth showing. When the text was cut to its last 16 KB the first line may be
    /// partial, so it goes; the header, the kickoff and the start and final markers say nothing
    /// the page doesn't already.
    public static func parse(_ text: String, truncated: Bool = false) -> [Line] {
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if truncated, !rows.isEmpty { rows.removeFirst() }
        return rows.compactMap(line)
    }

    static func line(_ row: String) -> Line? {
        // "12:04:31 assistant| I'll find…": a time, the role padded to nine, a bar.
        guard row.count > 10, isTime(row.prefix(8)), let bar = row.firstIndex(of: "|") else { return nil }
        let role = row[row.index(row.startIndex, offsetBy: 8)..<bar].trimmingCharacters(in: .whitespaces)
        var body = String(row[row.index(after: bar)...])
        if body.hasPrefix(" ") { body.removeFirst() }
        guard !body.isEmpty else { return nil }
        switch role {
        case "assistant":
            return .text(body)
        case "think":
            return .thinking(body)
        case "tool":
            return tool(body)
        case "result":
            return result(body)
        default:
            // user (the kickoff), start, final: in the header already.
            return nil
        }
    }

    private static func isTime(_ text: Substring) -> Bool {
        let chars = Array(text)
        guard chars.count == 8, chars[2] == ":", chars[5] == ":" else { return false }
        return [0, 1, 3, 4, 6, 7].allSatisfy { chars[$0].isNumber }
    }

    /// `-> read_file(Hermes.xcodeproj/project.pbxproj)`.
    private static func tool(_ body: String) -> Line {
        var text = Substring(body)
        if text.hasPrefix("-> ") { text = text.dropFirst(3) }
        guard let open = text.firstIndex(of: "(") else { return .tool(name: String(text), arguments: "") }
        let name = String(text[..<open])
        var arguments = text[text.index(after: open)...]
        if arguments.hasSuffix(")") { arguments = arguments.dropLast() }
        return .tool(name: name, arguments: String(arguments))
    }

    /// `grep ok 0.4s: 3 minimal, 1 complete` or `terminal ERROR 600.0s: …`.
    private static func result(_ body: String) -> Line {
        let head = body.split(separator: ":", maxSplits: 1).first.map(String.init) ?? body
        let words = head.split(separator: " ")
        let name = words.first.map(String.init) ?? ""
        let isError = words.dropFirst().first == "ERROR"
        let text = body.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return .result(name: name, text: text, isError: isError)
    }
}
