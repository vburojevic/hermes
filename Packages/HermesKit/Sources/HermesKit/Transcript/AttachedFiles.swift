import Foundation

/// How files attached to a message travel inside its text, and how they're found again so a
/// sent message shows file chips instead of raw markup.
///
/// - Over the gateway protocol, `file.attach` uploads the file and returns `@file:<path>`,
///   which goes into the prompt; Hermes reads it from there.
/// - A PDF sent with `pdf.attach` arrives as page images; `[Attached PDF: name]` names it.
/// - The API server has no upload, so a readable file is inlined as `<file name="…">…</file>`.
public enum AttachedFiles {
    /// A file inlined into the message text.
    public static func inline(name: String, contents: String) -> String {
        "<file name=\"\(escape(name))\">\n\(contents)\n</file>"
    }

    /// The line that names a PDF sent as page images.
    public static func pdfNote(name: String) -> String {
        "[Attached PDF: \(name)]"
    }

    /// The text without file markup, and the names of the files it carried, in order.
    public static func extract(from text: String) -> (text: String, names: [String]) {
        var names: [String] = []
        var remaining = text

        // <file name="…">…</file> blocks.
        while let open = remaining.range(of: "<file name=\""),
              let nameEnd = remaining.range(of: "\">", range: open.upperBound..<remaining.endIndex),
              let close = remaining.range(of: "</file>", range: nameEnd.upperBound..<remaining.endIndex) {
            names.append(unescape(String(remaining[open.upperBound..<nameEnd.lowerBound])))
            remaining.removeSubrange(open.lowerBound..<close.upperBound)
        }

        var lines: [String] = []
        for line in remaining.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[Attached PDF: "), trimmed.hasSuffix("]") {
                names.append(String(trimmed.dropFirst("[Attached PDF: ".count).dropLast()))
                continue
            }
            // A line of nothing but @file:<path> references (what `file.attach` adds) becomes
            // chips; a reference inside a sentence stays where it was, tinted.
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            let prefixes = ["@file:", "@folder:"]
            if !words.isEmpty, words.allSatisfy({ word in prefixes.contains { word.hasPrefix($0) && word.count > $0.count } }) {
                for word in words {
                    let prefix = prefixes.first { word.hasPrefix($0) }!
                    let path = word.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                    names.append((path as NSString).lastPathComponent)
                }
                continue
            }
            lines.append(line)
        }
        let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, names)
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescape(_ name: String) -> String {
        name.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}
