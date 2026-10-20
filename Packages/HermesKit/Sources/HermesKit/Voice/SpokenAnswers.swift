import Foundation

/// Answering Hermes by voice in Talk (`docs/voice.md` §4.3).
public enum SpokenAnswers {
    /// What a spoken answer to an approval means.
    public enum Approval: Equatable, Sendable {
        case allow(ApprovalChoice)
        case deny
        /// It can only be answered on the card, with a tap (and Face ID).
        case needsTap(NeedsTap)
        /// A yes said before the card had been there 2 s.
        case tooSoon
        case notUnderstood
    }

    public enum NeedsTap: Equatable, Sendable {
        /// Always Allow is never given by voice.
        case always
        /// Hermes's safety check flagged the command (`smart_denied`).
        case flagged
        /// It deletes, wipes, kills or spends: nothing to take back.
        case irreversible
    }

    /// A yes counts only once the request has been on screen this long.
    public static let readingTime: TimeInterval = 2

    /// "Allow once", "allow in this chat", "deny". A no can be said any way, at any time; a yes
    /// has to be one of a few short answers, said whole, for a request that's been there 2 s.
    public static func approval(_ words: String, for request: ApprovalRequest, shownFor: TimeInterval) -> Approval {
        let said = normalized(words)
        let saidWords = Set(said.split(separator: " ").map(String.init))
        guard !said.isEmpty else { return .notUnderstood }
        if !saidWords.isDisjoint(with: ["deny", "no", "nope", "dont", "not", "stop", "cancel", "block", "reject"]) {
            return .deny
        }
        if saidWords.contains("always") { return .needsTap(.always) }
        let isYes = yeses.contains(said) || (said.hasPrefix("allow") && saidWords.count <= 6)
        guard isYes else { return .notUnderstood }
        if request.smartDenied { return .needsTap(.flagged) }
        if isIrreversible(request) { return .needsTap(.irreversible) }
        if shownFor < readingTime { return .tooSoon }
        if said.hasPrefix("allow"), saidWords.contains("chat") || saidWords.contains("session") {
            return .allow(request.choices.contains(.session) ? .session : .once)
        }
        return .allow(.once)
    }

    private static let yeses: Set<String> = [
        "allow", "allow once", "allow it", "allow it once", "allow this", "allow this once", "approve", "approve it",
        "yes", "yes allow", "yes allow once", "yes allow it", "yes please", "go ahead", "yes go ahead", "run it", "do it",
        "yeah", "yep", "sure", "ok", "okay",
    ]

    /// Deletes, wipes, kills or spends: a request whose effect can't be taken back needs a tap
    /// with Face ID, however it's answered by voice.
    public static func isIrreversible(_ request: ApprovalRequest) -> Bool {
        let text = [request.command, request.description, request.title, request.toolName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
            + " " + request.patternKeys.joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        if text.range(of: #"\brm\s+(-[a-z]*[rf]|--recursive|--force)"#, options: .regularExpression) != nil { return true }
        return irreversibleWords.contains { text.range(of: #"\b\#($0)"#, options: .regularExpression) != nil }
    }

    private static let irreversibleWords = [
        "delete", "wipe", "format", "drop", "truncate", "destroy", "shred", "kill", "overwrite", "partition",
        "block device", "disk copy", "fork bomb", "reset --hard", "push --force", "push -f",
        "purchase", "payment", "pay ", "spend", "charge", "transfer", "buy ", "checkout", "subscribe", "invoice",
    ]

    /// Which option a spoken answer to a clarify question picks: "the second one", "number 2",
    /// "the last", or the option's own words. `nil` when it isn't one of them (it's then sent as
    /// a free answer where the question allows one).
    public static func choice(_ words: String, among options: [String]) -> Int? {
        let said = normalized(words)
        guard !said.isEmpty, !options.isEmpty else { return nil }
        let saidWords = said.split(separator: " ").map(String.init)
        for (index, option) in options.enumerated() where normalized(option) == said {
            return index
        }
        if saidWords.contains("last"), saidWords.count <= 4 { return options.count - 1 }
        if saidWords.count <= 5 {
            var named = Set(saidWords)
            // "The second one": "one" is a word there, not a number.
            if named.count > 1, ordinals.dropFirst().contains(where: { !$0.isDisjoint(with: named) }) { named.remove("one") }
            let picked = ordinals.indices.filter { $0 < options.count && !ordinals[$0].isDisjoint(with: named) }
            if picked.count == 1 { return picked[0] }
        }
        // The option's words said within a longer answer: the longest one that fits.
        let matches = options.enumerated()
            .filter { said.contains(normalized($0.element)) && !normalized($0.element).isEmpty }
            .max { normalized($0.element).count < normalized($1.element).count }
        return matches?.offset
    }

    private static let ordinals: [Set<String>] = [
        ["first", "one", "1", "1st"], ["second", "two", "2", "2nd"], ["third", "three", "3", "3rd"],
        ["fourth", "four", "4", "4th"], ["fifth", "five", "5", "5th"], ["sixth", "six", "6", "6th"],
    ]

    /// Lowercased words without punctuation: "Yes, allow it." → "yes allow it".
    /// The end of a caption that has to fit `limit` characters (a Live Activity's line): whole
    /// words from where it's cut, after "…".
    public static func tail(_ text: String, limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -(limit - 1))
        let cut = text[start...]
        // Cut inside a word: start at the next one.
        if !text[text.index(before: start)].isWhitespace, let space = cut.firstIndex(where: \.isWhitespace) {
            return "…" + cut[cut.index(after: space)...]
        }
        return "…" + cut
    }

    /// Something was said: a transcriber can hear "." in a room's noise, which isn't a turn.
    public static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    public static func normalized(_ words: String) -> String {
        let kept = words.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }
}
