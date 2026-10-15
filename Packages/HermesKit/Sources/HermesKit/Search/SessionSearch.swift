import Foundation

// Search (`docs/search.md`): chats found by what was said in them, not only by title.
// `GET /api/sessions/search` on the `hermes serve` dashboard (`hermes_cli/web_routers/sessions.py`,
// `hermes_state_search.py`). The API server has no search; without Bot Mode only titles can be
// matched (`TitleSearch`).

/// One chat a search found. Compressed segments are folded into one (`lineage_root`); branches
/// stay separate.
public struct SessionSearchResult: Identifiable, Hashable, Sendable {
    /// The live chat to open: the newest segment of a compressed chat.
    public var sessionID: String
    /// The first segment, which stays the same as the chat is compressed.
    public var lineageRoot: String?
    public var title: String?
    public var preview: String?
    /// About 40 tokens around the match, with matched words between `>>>` and `<<<`.
    public var snippet: String
    /// Who wrote the matched message: `user`, `assistant`, or nil for an ID or title match.
    public var role: String?
    /// Where the chat came from: `api_server`, `cli`, `telegram`, `cron`…
    public var source: String?
    public var model: String?
    public var sessionStarted: Date?
    /// Null on content matches; fall back to `sessionStarted`.
    public var lastActive: Date?
    public var messageCount: Int
    public var archived: Bool
    /// The profile it was found in (a Bot's, or `default`).
    public var profile: String?

    public var id: String { "\(profile ?? "default")|\(lineageRoot ?? sessionID)" }

    /// The time to show on the right.
    public var date: Date? { lastActive ?? sessionStarted }

    /// A scheduled task's run (`source == "cron"`, as Hermes stores them).
    public var isTaskRun: Bool { source == SessionSearch.taskSource }

    public init(sessionID: String, lineageRoot: String? = nil, title: String? = nil, preview: String? = nil, snippet: String = "",
                role: String? = nil, source: String? = nil, model: String? = nil, sessionStarted: Date? = nil,
                lastActive: Date? = nil, messageCount: Int = 0, archived: Bool = false, profile: String? = nil) {
        self.sessionID = sessionID
        self.lineageRoot = lineageRoot
        self.title = title
        self.preview = preview
        self.snippet = snippet
        self.role = role
        self.source = source
        self.model = model
        self.sessionStarted = sessionStarted
        self.lastActive = lastActive
        self.messageCount = messageCount
        self.archived = archived
        self.profile = profile
    }

    init?(json: JSONValue) {
        guard let id = json["session_id"]?.stringValue ?? json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(
            sessionID: id,
            lineageRoot: json["lineage_root"]?.stringValue,
            title: json["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            preview: json["preview"]?.stringValue,
            snippet: json["snippet"]?.stringValue ?? "",
            role: json["role"]?.stringValue,
            source: json["source"]?.stringValue,
            model: json["model"]?.stringValue,
            sessionStarted: Self.date(json["session_started"] ?? json["started_at"]),
            lastActive: Self.date(json["last_active"]),
            messageCount: json["message_count"]?.doubleValue.map { Int($0) } ?? 0,
            archived: json["archived"]?.boolValue ?? false,
            profile: json["profile"]?.stringValue
        )
    }

    /// Epoch seconds, or an ISO string.
    static func date(_ value: JSONValue?) -> Date? {
        if let seconds = value?.doubleValue { return HermesDate.fromEpoch(seconds) }
        return HermesDate.fromISO(value?.stringValue)
    }

    /// The snippet as plain and matched runs, markers removed.
    public var snippetRuns: [SnippetRun] { SnippetRun.parse(snippet) }

    /// The words the search matched, for finding the message in the chat.
    public var matchedWords: [String] {
        var seen: [String] = []
        for run in snippetRuns where run.isMatch {
            let word = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, !seen.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { seen.append(word) }
        }
        return seen
    }
}

/// Part of a snippet: matched words (between `>>>` and `<<<`) or the text around them.
public struct SnippetRun: Hashable, Sendable {
    public var text: String
    public var isMatch: Bool

    public init(text: String, isMatch: Bool) {
        self.text = text
        self.isMatch = isMatch
    }

    /// Splits on the markers and drops them; a marker left open runs to the end. Markers never
    /// survive, even unbalanced ones.
    public static func parse(_ snippet: String) -> [SnippetRun] {
        var runs: [SnippetRun] = []
        var rest = Substring(snippet)
        var matching = false
        while !rest.isEmpty {
            let marker = matching ? "<<<" : ">>>"
            if let range = rest.range(of: marker) {
                let text = String(rest[..<range.lowerBound])
                if !text.isEmpty { runs.append(SnippetRun(text: text, isMatch: matching)) }
                rest = rest[range.upperBound...]
                matching.toggle()
            } else {
                runs.append(SnippetRun(text: String(rest), isMatch: matching))
                rest = ""
            }
        }
        // A stray closing marker in plain text, or an opening one inside a match.
        return runs.compactMap { run in
            let text = run.text.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: "")
            return text.isEmpty ? nil : SnippetRun(text: text, isMatch: run.isMatch)
        }
    }

    /// The snippet with the markers removed.
    public static func plain(_ snippet: String) -> String {
        parse(snippet).map(\.text).joined()
    }
}

public enum SessionSearch {
    /// How Hermes marks a scheduled task's runs (`cron/scheduler_delivery.py`, and the live store).
    public static let taskSource = "cron"
    /// The API server's own default: at most this many results.
    public static let defaultLimit = 20

    /// Chats whose title matches every word of `query` (prefix match, case and diacritics
    /// ignored). For offline and gateways without Bot Mode.
    public static func titleMatches(_ query: String, in sessions: [HermesSession]) -> [HermesSession] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return sessions.filter { session in
            let title = (session.title ?? session.preview ?? "")
            let titleWords = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return words.allSatisfy { word in
                titleWords.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
                    || title.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

/// Where an opened search result lands: the first message with the snippet's words.
public struct SearchFocus: Equatable, Sendable {
    public let id = UUID()
    /// The matched words, as the snippet highlighted them.
    public let words: [String]
    /// A few words around the first match, to tell apart messages that share the words.
    public let phrase: String

    public init(words: [String], phrase: String) {
        self.words = words
        self.phrase = phrase
    }

    public init(result: SessionSearchResult) {
        let runs = result.snippetRuns
        var phrase = ""
        if let index = runs.firstIndex(where: \.isMatch) {
            let before = index > 0 ? runs[index - 1].text.split(whereSeparator: \.isWhitespace).suffix(2).joined(separator: " ") : ""
            let after = index + 1 < runs.count ? runs[index + 1].text.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ") : ""
            let joinsBefore = index > 0 && !(runs[index - 1].text.last?.isWhitespace ?? true)
            let joinsAfter = index + 1 < runs.count && !(runs[index + 1].text.first?.isWhitespace ?? true)
            phrase = before + (joinsBefore || before.isEmpty ? "" : " ") + runs[index].text + (joinsAfter || after.isEmpty ? "" : " ") + after
        }
        self.init(words: result.matchedWords, phrase: phrase.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// What a row says: the person's message, or the reply and what Hermes said between steps.
    public static func text(of item: TranscriptItem) -> String? {
        switch item {
        case .user(let entry): entry.text
        case .assistant(let turn):
            ([turn.answer] + turn.steps.compactMap { step in
                if case .narration(_, let text) = step { text } else { nil }
            }).joined(separator: "\n")
        default: nil
        }
    }

    /// The rows that say `text` (in-chat find), oldest first.
    public static func rows(saying text: String, in items: [TranscriptItem]) -> [TranscriptItem] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return items.filter { item in
            Self.text(of: item)?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The first message (oldest first) that has the phrase, else all the words, else any of them.
    public func target(in items: [TranscriptItem]) -> TranscriptItem? {
        let texts = items.compactMap { item in Self.text(of: item).map { (item, $0) } }
        func has(_ needle: String, _ text: String) -> Bool {
            text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if !phrase.isEmpty, let hit = texts.first(where: { has(phrase, normalized($0.1)) }) { return hit.0 }
        guard !words.isEmpty else { return nil }
        if let hit = texts.first(where: { text in words.allSatisfy { has($0, text.1) } }) { return hit.0 }
        return texts.first(where: { text in words.contains { has($0, text.1) } })?.0
    }
}
