import Foundation

/// A background process's output as the app shows it (`docs/background-processes.md` §3),
/// cleaned once per chunk before anything draws or keeps it:
/// - ANSI escape codes go, even when a chunk ends inside one.
/// - A line rewritten with `\r` (a progress bar) keeps only its last state.
/// - Hermes's working-folder marker lines (`__HERMES_CWD_<hex>__`) go.
/// It keeps the last `limit` characters, trimming only once it has grown past twice that, and works
/// out what the step and the row show (`latestLine`, `errorText`) once per chunk, not per draw.
public struct ProcessOutput: Equatable, Sendable {
    public private(set) var text = ""
    public let limit: Int
    /// The last line with something on it, on one line.
    public private(set) var latestLine: String?
    /// The output is one JSON error: its message, code and later sentences dropped (§3). Profiles
    /// are still named as Hermes wrote them: `plainWords` names the Bots.
    public private(set) var errorText: String?

    private enum Escape: Equatable, Sendable {
        case none
        /// `ESC` seen; the next character says what kind.
        case start
        /// `ESC` and intermediate bytes (`ESC ( B`, `ESC # 8`): until a final byte.
        case intermediate
        /// `ESC [` (or `0x9B`): parameters until a final byte.
        case csi
        /// `ESC ]` and other strings: until BEL or `ESC \`.
        case string
        /// `ESC` inside a string: `\` ends it.
        case stringEscape
    }

    private var escape = Escape.none
    /// A lone `\r` ended the last chunk: the next character rewrites the line, unless it's `\n`.
    private var pendingReturn = false

    public init(limit: Int = 64_000) {
        self.limit = limit
    }

    /// Cleans a whole text at once (`process.list`'s `output_tail`).
    public init(cleaning raw: String, limit: Int = 64_000) {
        self.limit = limit
        append(raw)
    }

    static let marker = "__HERMES_CWD_"

    public mutating func append(_ chunk: String) {
        var added = ""
        for scalar in chunk.unicodeScalars {
            switch escape {
            case .start:
                switch scalar {
                case "[": escape = .csi
                case "]", "P", "X", "^", "_": escape = .string
                case " "..."/": escape = .intermediate
                default: escape = .none  // a two-character sequence (`ESC c`, `ESC 7`…)
                }
                continue
            case .intermediate:
                if !(" "..."/").contains(scalar) { escape = .none }
                continue
            case .csi:
                if (0x40...0x7E).contains(scalar.value) { escape = .none }
                continue
            case .string:
                if scalar.value == 0x07 { escape = .none } else if scalar.value == 0x1B { escape = .stringEscape }
                continue
            case .stringEscape:
                escape = scalar == "\\" ? .none : .string
                continue
            case .none:
                break
            }
            if pendingReturn, scalar.value != 0x0D {
                pendingReturn = false
                if scalar != "\n" {
                    // A progress line redrawn: what follows replaces it.
                    flush(&added)
                    clearLastLine()
                }
            }
            switch scalar.value {
            case 0x1B: escape = .start
            case 0x9B: escape = .csi
            case 0x0D: pendingReturn = true
            case 0x0A: added.unicodeScalars.append(scalar)
            case 0x09: added.unicodeScalars.append(scalar)
            case 0x08:
                // Backspace: take back what it erased.
                if !added.isEmpty, added.last != "\n" {
                    added.removeLast()
                }
            case 0x00...0x1F, 0x7F: continue
            default: added.unicodeScalars.append(scalar)
            }
        }
        flush(&added)
        latestLine = Self.latestLine(in: text)
        errorText = Self.rawError(in: text)
    }

    private mutating func flush(_ added: inout String) {
        guard !added.isEmpty else { return }
        text += added
        added = ""
        if text.contains(Self.marker) { dropMarkerLines() }
        if text.utf8.count > limit * 2 {
            let kept = String(text.unicodeScalars.suffix(limit))
            // From a line's start, not halfway through one.
            text = kept.firstIndex(of: "\n").map { String(kept[kept.index(after: $0)...]) } ?? kept
        }
    }

    private mutating func clearLastLine() {
        if let newline = text.lastIndex(of: "\n") {
            text.removeSubrange(text.index(after: newline)...)
        } else {
            text = ""
        }
    }

    /// Hermes's working-folder marker, whole lines: never shown, never kept. An unfinished last
    /// line keeps it until it ends (then the line goes).
    private mutating func dropMarkerLines() {
        var lines = text.components(separatedBy: "\n")
        let last = lines.removeLast()
        lines.removeAll { $0.contains(Self.marker) }
        lines.append(last)
        text = lines.joined(separator: "\n")
    }

    /// The lines to show: without a marker line still being written.
    public var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(Self.marker) }
    }

    /// The last `count` lines, found from the end (a page of output, not all of it).
    public func lastLines(_ count: Int) -> [Substring] {
        var lines: [Substring] = []
        var end = text.endIndex
        while lines.count < count {
            let start = text[..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end]
            if !line.contains(Self.marker) { lines.append(line) }
            guard start > text.startIndex else { break }
            end = text.index(before: start)
        }
        return lines.reversed()
    }

    static func latestLine(in text: String) -> String? {
        var end = text.endIndex
        while end > text.startIndex {
            let start = text[..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !line.contains(Self.marker) {
                return String(line.prefix(300))
            }
            guard start > text.startIndex else { break }
            end = text.index(before: start)
        }
        return nil
    }

    // MARK: Errors in plain words

    /// When the whole output is one JSON object with `error` (or `message`), that string, in plain
    /// words: no leading `code:` (`target_busy: `), only the first sentence, and `profile '<name>'`
    /// as the Bot's name. "Engineer is busy with another message."
    public static func errorMessage(in output: String, botName: (String) -> String? = { _ in nil }) -> String? {
        rawError(in: output).map { plainWords($0, botName: botName) }
    }

    /// The JSON error's message with its code and later sentences dropped; nil unless the whole
    /// output (at most 16 KB) is one object with `error` or `message`.
    static func rawError(in output: String) -> String? {
        guard output.utf8.count <= 16_384,
              output.first(where: { !$0.isWhitespace }) == "{", output.last(where: { !$0.isWhitespace }) == "}",
              case .object(let object)? = JSONValue.parse(output.trimmingCharacters(in: .whitespacesAndNewlines)),
              var message = (object["error"]?.stringValue ?? object["message"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        if let code = message.range(of: #"^[a-z][a-z0-9_.-]*:\s+"#, options: .regularExpression) {
            message.removeSubrange(code)
        }
        if let end = message.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            message = String(message[..<message.index(after: end.lowerBound)])
        }
        return message
    }

    /// `profile '<name>'` as the Bot's name, and a capital first letter.
    public static func plainWords(_ message: String, botName: (String) -> String? = { _ in nil }) -> String {
        var message = message.replacingOccurrences(of: #"[Pp]rofile '([^']+)'"#, with: "\u{0}$1\u{0}", options: .regularExpression)
        while let start = message.firstIndex(of: "\u{0}"),
              let end = message[message.index(after: start)...].firstIndex(of: "\u{0}") {
            let profile = String(message[message.index(after: start)..<end])
            message.replaceSubrange(start...end, with: ProcessNaming.bot(profile, botName: botName))
        }
        if let first = message.first, first.isLowercase {
            message.replaceSubrange(...message.startIndex, with: String(first).uppercased())
        }
        return message
    }
}
