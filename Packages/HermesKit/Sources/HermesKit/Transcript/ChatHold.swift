import Foundation

/// Hermes refused a turn because another of its processes holds the chat: it takes one writer per
/// chat (`SESSION_NOT_OWNED`, hermes_cli/active_sessions.py). It says so in the same sentence
/// whether it refuses the send (a 4090's message) or a turn it had already taken (a bare `error`
/// event): "This chat is open in another Hermes window/terminal. Use it there, or start a new chat
/// here.\nDetails: session <id> opened by <surface> <age> ago." Read back, so the app says what
/// holds the chat instead (`docs/chat.md`, a chat another Hermes process holds).
public struct ChatHold: Hashable, Sendable {
    /// Hermes's first line, kept for a chat a terminal or another window holds.
    public var sentence: String
    public var sessionID: String?
    /// `cli` for a `hermes chat` process: a Bot's one-shot turn, a routine's, or a terminal.
    /// `desktop` or `tui` for another window.
    public var surface: String?
    /// How long it had been held when Hermes refused, to the minute.
    public var age: TimeInterval?

    public init(sentence: String, sessionID: String? = nil, surface: String? = nil, age: TimeInterval? = nil) {
        self.sentence = sentence
        self.sessionID = sessionID
        self.surface = surface
        self.age = age
    }

    private static let opener = "This chat is open in another Hermes"
    private static let details = try! NSRegularExpression(
        pattern: #"^Details: session (\S+) opened by (.+?)(?: ((?:\d+h)?(?:\d+m)?) ago)?\.$"#, options: [.anchorsMatchLines])

    /// Hermes's refusal, or nil for any other message.
    public init?(refusal: String) {
        let text = refusal.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix(Self.opener) else { return nil }
        self.init(sentence: first)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.details.firstMatch(in: text, range: range) else { return }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        sessionID = group(1)
        surface = group(2)
        age = group(3).flatMap(Self.minutes)
    }

    /// Hermes's `format_age`: "0m", "45m", "2h", "1h5m".
    static func minutes(_ age: String) -> TimeInterval? {
        var total = 0.0
        var number = ""
        for character in age {
            if character.isNumber {
                number.append(character)
            } else if let value = Double(number), character == "h" || character == "m" {
                total += value * (character == "h" ? 3600 : 60)
                number = ""
            } else {
                return nil
            }
        }
        return number.isEmpty ? total : nil
    }

    /// How long a Bot's one-shot `hermes chat` holds its chat before the message it answers is
    /// stored: it takes the chat as it boots, a few seconds before.
    public static let startingFor: TimeInterval = 2 * 60

    /// What holds the chat, from what its stored rows show running there (`ElsewhereTurn`): a Bot
    /// answering another Bot, a routine's follow-up, a turn of its own going on in another process.
    /// With nothing to show, a Bot Chat's `hermes chat` that took the chat only just now is taken
    /// for a Bot's turn starting; anything else is a terminal or another window.
    public func holder(of turn: ElsewhereTurn?, inBotChat: Bool) -> ChatHolder {
        if let sender = turn?.answering { return .answeringBot(sender) }
        if let routine = turn?.routine { return .routine(routine) }
        if turn != nil { return .working }
        if inBotChat, surface == "cli", (age ?? 0) < Self.startingFor { return .working }
        return .elsewhere(sentence)
    }
}

/// What holds a chat, in the words the app says it in.
public enum ChatHolder: Hashable, Sendable {
    /// The Bot is answering another Bot's message (that Bot's name).
    case answeringBot(String)
    /// The Bot is following up on a routine's output (the routine's name).
    case routine(String)
    /// A turn of its own, running in another Hermes process.
    case working
    /// A terminal or another window: Hermes's own sentence.
    case elsewhere(String)

    /// Hermes's own work, which lets the chat go by itself when it's done.
    public var isHermesWork: Bool {
        if case .elsewhere = self { false } else { true }
    }
}
