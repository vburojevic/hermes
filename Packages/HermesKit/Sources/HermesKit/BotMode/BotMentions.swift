import Foundation

/// `@mention` handling for Bot Chats, matching Hermes Desktop's composer middleware:
/// mentions are resolved against the roster and explained to the agent in a note
/// appended to the prompt; the agent then messages teammates with `message_agent`.
public enum BotMentions {
    /// Tokens no Bot may claim as a friendly name.
    static let reserved: Set<String> = ["all", "everyone", "user", "default", "hermes"]

    static let noteOpener = "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: "

    /// `Research Buddy` → `research-buddy`.
    public static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            let character = Character(scalar)
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == "_" {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Every form a person may type for this Bot.
    static func forms(of bot: BotProfile) -> [String] {
        var forms = [bot.name.lowercased(), bot.handle]
        for friendly in [bot.meta.title, bot.displayName].compactMap({ $0 }) {
            let slug = slug(friendly)
            guard !slug.isEmpty, !reserved.contains(slug) else { continue }
            forms.append(slug)
            forms.append(slug.replacingOccurrences(of: "-", with: ""))
        }
        if bot.isDefault { forms.append("default") }
        return forms
    }

    /// `@tokens` in prose (code spans and fences excluded).
    static func mentionTokens(in text: String) -> [String] {
        var prose = text
        for pattern in ["```[\\s\\S]*?(```|$)", "`[^`\\n]*`"] {
            prose = prose.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let range = NSRange(prose.startIndex..., in: prose)
        return mentionPattern.matches(in: prose, range: range).compactMap { match in
            Range(match.range(at: 2), in: prose).map { prose[$0].lowercased() }
        }
    }

    /// Resolves mentions to Bots: unique forms only, the current Bot excluded, in order of appearance.
    public static func resolve(_ text: String, roster: [BotProfile], excluding activeBot: String?) -> [(token: String, bot: BotProfile)] {
        var owners: [String: String?] = [:] // form -> bot name, or nil when ambiguous
        for bot in roster {
            for form in Set(forms(of: bot)) {
                if let existing = owners[form], existing != bot.name {
                    owners[form] = .some(nil)
                } else {
                    owners[form] = bot.name
                }
            }
        }
        // Previous names only fill gaps.
        for bot in roster {
            for old in bot.previousNames.map({ $0.lowercased() }) where owners[old] == nil {
                owners[old] = bot.name
            }
        }
        var seen: Set<String> = []
        var result: [(String, BotProfile)] = []
        for token in mentionTokens(in: text) where !["all", "everyone", "user"].contains(token) {
            guard let owner = owners[token] ?? nil, owner != activeBot, !seen.contains(owner),
                  let bot = roster.first(where: { $0.name == owner }) else { continue }
            seen.insert(owner)
            result.append((token, bot))
        }
        return result
    }

    /// The prompt as sent: the user's text plus the roster note when anything resolved.
    public static func prompt(for text: String, roster: [BotProfile], activeBot: String?) -> String {
        let resolved = resolve(text, roster: roster, excluding: activeBot)
        guard !resolved.isEmpty else { return text }
        let lines = resolved.map { token, bot in
            let target = bot.handle
            let title = bot.meta.title ?? (bot.displayName.isEmpty ? nil : bot.displayName)
            let titlePart = title.map { " (\"\($0)\")" } ?? ""
            let wherePart = token == target ? "" : " (message_agent target: \"\(target)\")"
            return "@\(token) = agent profile \"\(bot.name)\"\(titlePart)\(wherePart)"
        }
        return text + noteOpener + lines.joined(separator: "; ")
            + ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool; never forward the user’s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
    }

    /// Removes the roster note from a stored user message before display.
    public static func stripNote(_ text: String) -> String {
        guard let range = text.range(of: noteOpener) else { return text }
        return String(text[..<range.lowerBound])
    }

    /// A message one Bot sent another: `Message from 🤖 Name (@handle): body`.
    public struct AgentMessage: Hashable, Sendable {
        public var senderName: String
        public var senderHandle: String
        public var body: String
    }

    private static let mentionPattern = try! NSRegularExpression(pattern: #"(^|\s)@([a-z0-9][a-z0-9_-]*)"#, options: [.caseInsensitive])
    private static let agentPattern = try! NSRegularExpression(pattern: #"^Message from (?:🤖 )?(.+?) \(@([^)\s]+)\):\s*"#, options: [.dotMatchesLineSeparators])
    private static let legacyAgentPattern = try! NSRegularExpression(pattern: #"^Message from agent '([^']+)':\s*"#)

    public static func parseAgentMessage(_ text: String) -> AgentMessage? {
        guard text.hasPrefix("Message from ") else { return nil }
        guard let match = agentPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nameRange = Range(match.range(at: 1), in: text),
              let handleRange = Range(match.range(at: 2), in: text),
              let whole = Range(match.range, in: text)
        else {
            // Legacy form: Message from agent 'name': body
            guard let match = legacyAgentPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let whole = Range(match.range, in: text)
            else { return nil }
            let name = String(text[nameRange])
            return AgentMessage(senderName: name, senderHandle: name, body: String(text[whole.upperBound...]))
        }
        return AgentMessage(senderName: String(text[nameRange]), senderHandle: String(text[handleRange]), body: String(text[whole.upperBound...]))
    }

    /// Routine output delivered into a Bot Chat: `[Cronjob "<name>" output — scheduled job, …]\n\n<output>`.
    public struct RoutineDelivery: Hashable, Sendable {
        /// The routine's name without its `[bot:<name>]` tag.
        public var name: String
        public var output: String
    }

    public static func parseRoutineDelivery(_ text: String) -> RoutineDelivery? {
        guard text.hasPrefix("[Cronjob \""),
              let nameEnd = text.range(of: "\" output", range: text.index(text.startIndex, offsetBy: 10)..<text.endIndex)
        else { return nil }
        let rawName = String(text[text.index(text.startIndex, offsetBy: 10)..<nameEnd.lowerBound])
        let output: String
        if let close = text.range(of: "]", range: nameEnd.upperBound..<text.endIndex) {
            output = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            output = "" // a preview cut short inside the header
        }
        return RoutineDelivery(name: BotRoutine.parse(name: rawName).1, output: output)
    }

    /// Hermes' "the agent chose not to reply" markers (`LIVE_GATEWAY_SILENT_MARKERS` in
    /// gateway/response_filters.py). Bot Mode never renders a reply that is only one of these.
    static let silenceMarkers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY", "[静默]", "静默", "[沉默]", "沉默"]

    /// True only when the whole reply is a silence marker, allowing stray edge punctuation
    /// (`*NO_REPLY*`, `.SILENT`), like Hermes' `is_intentional_silence_response`. Prose that merely
    /// mentions a marker, and blank replies, are not silence.
    public static func isSilenceMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        let edge = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "[]"))
        let depunctuated = trimmed.trimmingCharacters(in: edge).trimmingCharacters(in: .whitespaces)
        return [trimmed, depunctuated].contains { form in
            silenceMarkers.contains(form.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
    }

    /// A reply of 30 words or more whose three-word runs come mostly (60%) from `delivery`: the
    /// delivery again, whatever its formatting, addresses or line breaks. Bots' own write-ups of a
    /// delivery share under a fifth; quoting it while acting on it, under half.
    public static func repeats(_ reply: String, of delivery: String) -> Bool {
        let words = runWords(reply)
        guard words.count >= 30 else { return false }
        return mostlyFrom(runs(of: words), runs(of: runWords(delivery)))
    }

    /// For a reply that `repeats` the delivery, the lines it adds (a note under the brief), empty
    /// when it adds none; nil for a reply of its own. A fenced block is kept or left out whole, by
    /// what it holds: a brief repeated as JSON (its widget fence turned into json) lost its JSON
    /// line and its closing fence as repeats while "```json" stayed, and drew an empty code frame.
    public static func linesAdded(by reply: String, to delivery: String) -> String? {
        guard repeats(reply, of: delivery) else { return nil }
        let deliveredWords = runWords(delivery)
        let delivered = runs(of: deliveredWords)
        let vocabulary = Set(deliveredWords)
        func repeated(_ text: String) -> Bool {
            let words = runWords(text)
            let textRuns = runs(of: words)
            return textRuns.isEmpty ? words.allSatisfy(vocabulary.contains) : mostlyFrom(textRuns, delivered)
        }
        var kept: [Substring] = []
        var fence: (marker: Character, length: Int, lines: [Substring])?
        func closeFence() {
            guard let open = fence else { return }
            fence = nil
            let body = open.lines.dropFirst().filter { fenceMarker($0).map { $0.marker != open.marker || $0.length < open.length } ?? true }
            if !repeated(body.joined(separator: "\n")) { kept += open.lines }
        }
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                fence?.lines.append(line)
                if let marker = fenceMarker(line), marker.marker == open.marker, marker.length >= open.length,
                   line.drop(while: { $0 == " " }).dropFirst(marker.length).allSatisfy(\.isWhitespace) {
                    closeFence()
                }
                continue
            }
            if let marker = fenceMarker(line) {
                fence = (marker.marker, marker.length, [line])
                continue
            }
            if line.allSatisfy(\.isWhitespace) {
                if kept.last?.isEmpty == false { kept.append("") }
                continue
            }
            if !repeated(String(line)) { kept.append(line) }
        }
        closeFence()
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fence line's mark (three or more backticks or tildes after up to three spaces), by
    /// Unicode scalar like the reply splitter.
    private static func fenceMarker(_ line: Substring) -> (marker: Character, length: Int)? {
        let scalars = line.unicodeScalars
        let rest = scalars.drop(while: { $0 == " " })
        guard scalars.count - rest.count <= 3, let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix(while: { $0 == first }).count
        return length >= 3 ? (Character(first), length) : nil
    }

    private static func mostlyFrom(_ runs: Set<String>, _ source: Set<String>) -> Bool {
        Double(runs.intersection(source).count) >= 0.6 * Double(runs.count)
    }

    private static func runWords(_ text: String) -> [Substring] {
        text.lowercased()
            .replacing(/(?:https?:\/\/|www\.)[^\s)\]>]+/, with: " ")
            .split { !$0.isLetter && !$0.isNumber }
    }

    private static func runs(of words: [Substring]) -> Set<String> {
        guard words.count >= 3 else { return [] }
        return Set((0...(words.count - 3)).map { words[$0..<$0 + 3].joined(separator: " ") })
    }

    /// A light Markdown strip for one-line previews and spoken labels. Hermes flattens previews by turning
    /// newlines into spaces, so a list also arrives as "…is in: - First item".
    public static func stripMarkdown(_ text: String) -> String {
        var output = text
        for (regex, template) in markdownRules {
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: template)
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Compiled once: the roster builds every Bot's preview on each poll, and compiling eight
    /// patterns per Bot per poll was most of that work. NSRegularExpression is thread-safe.
    private static let markdownRules: [(NSRegularExpression, String)] = [
        ("(?m)^\\s*(?:[-*+•]|\\d{1,3}[.)])\\s+", ""),  // list markers starting a line
        ("(?m)^\\s*>\\s?", ""),                       // block quotes
        ("(?m)^\\s*#{1,6}\\s+", ""),                   // headings
        ("([:.!?])\\s+[-*+•]\\s+", "$1 "),             // a list flattened onto one line
        ("`{1,3}", ""), ("\\*\\*|__", ""), ("(^|\\s)[*_]([^*_]+)[*_]", "$1$2"),
        ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"), ("\\s+", " "),
    ].map { pattern, template in
        (try! NSRegularExpression(pattern: pattern), template)
    }
}
