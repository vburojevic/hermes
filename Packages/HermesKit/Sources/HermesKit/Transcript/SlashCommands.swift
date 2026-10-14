import Foundation

/// What the app knows about Hermes's slash commands (`docs/commands-and-references.md`): what
/// each does in plain words, its symbol, its menu group and argument. Commands the app doesn't
/// know still work and still render, with ``fallbackSymbol`` and the raw command.
public struct SlashCommandInfo: Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case session, working, info, settings, more

        public var title: String {
            switch self {
            case .session: "Session"
            case .working: "While Hermes works"
            case .info: "Info"
            case .settings: "Settings"
            case .more: "More"
            }
        }
    }

    public var name: String
    /// What it does, as a card title ("Usage", "New Chat").
    public var title: String
    /// The menu line ("Start a new session").
    public var summary: String
    public var symbol: String
    public var group: Group
    /// "[name]" when optional, "<text>" when required.
    public var argument: String?
    /// The argument is one of a list (models, reasoning levels): the menu offers them.
    public var takesOptions: Bool

    public init(name: String, title: String, summary: String, symbol: String, group: Group, argument: String? = nil, takesOptions: Bool = false) {
        self.name = name
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.group = group
        self.argument = argument
        self.takesOptions = takesOptions
    }

    /// Runs as soon as it's chosen: no argument to type.
    public var runsImmediately: Bool { argument == nil || argument?.hasPrefix("[") == true && !takesOptions }

    /// The argument is required.
    public var needsArgument: Bool { argument?.hasPrefix("<") == true }
}

public enum SlashCommands {
    public static let fallbackSymbol = "slash.circle"

    /// The commands the app describes, in menu order within each group.
    public static let all: [SlashCommandInfo] = [
        .init(name: "new", title: "New Chat", summary: "Start a new session", symbol: "square.and.pencil", group: .session, argument: "[name]"),
        .init(name: "retry", title: "Retry", summary: "Resend your last message", symbol: "arrow.clockwise", group: .session),
        .init(name: "undo", title: "Undo", summary: "Remove the last exchange", symbol: "arrow.uturn.backward", group: .session),
        .init(name: "title", title: "Rename", summary: "Rename this chat", symbol: "pencil", group: .session, argument: "[name]"),
        .init(name: "branch", title: "Branch", summary: "Continue in a copy of this chat", symbol: "arrow.triangle.branch", group: .session),
        .init(name: "compress", title: "Compact Chat", summary: "Summarise the chat to free up context", symbol: "rectangle.compress.vertical", group: .session),
        .init(name: "steer", title: "Steer", summary: "Add a note after the next tool call", symbol: "arrow.turn.up.right", group: .working, argument: "<note>"),
        .init(name: "queue", title: "Queue", summary: "Send this next, without interrupting", symbol: "text.line.first.and.arrowtriangle.forward", group: .working, argument: "<prompt>"),
        .init(name: "btw", title: "Aside", summary: "Ask a side question while Hermes works", symbol: "questionmark.bubble", group: .working, argument: "<question>"),
        .init(name: "stop", title: "Stop", summary: "Stop the running turn", symbol: "stop.circle", group: .working),
        .init(name: "goal", title: "Goal", summary: "Set a standing goal Hermes works toward", symbol: "target", group: .working, argument: "<text>"),
        .init(name: "plan", title: "Plan", summary: "Plan the work before doing it", symbol: "list.bullet.clipboard", group: .working, argument: "<task>"),
        .init(name: "bg", title: "Background Task", summary: "Run a prompt in the background", symbol: "tray.and.arrow.down", group: .working, argument: "<prompt>"),
        .init(name: "usage", title: "Usage", summary: "Tokens, cost and context for this chat", symbol: "chart.bar", group: .info),
        .init(name: "status", title: "Status", summary: "What Hermes is doing and with which model", symbol: "info.circle", group: .info),
        .init(name: "context", title: "Context", summary: "What fills the context window", symbol: "rectangle.stack", group: .info),
        .init(name: "tools", title: "Tools", summary: "The tools Hermes can use here", symbol: "wrench.and.screwdriver", group: .info),
        .init(name: "skills", title: "Skills", summary: "The skills Hermes knows", symbol: "book.closed", group: .info),
        .init(name: "help", title: "Help", summary: "Every command, explained", symbol: "questionmark.circle", group: .info),
        .init(name: "model", title: "Model", summary: "Switch the model for this chat", symbol: "cpu", group: .settings, argument: "[model]", takesOptions: true),
        .init(name: "reasoning", title: "Reasoning", summary: "How hard Hermes thinks", symbol: "lightbulb", group: .settings, argument: "[level]", takesOptions: true),
        .init(name: "fast", title: "Fast Mode", summary: "Faster replies from the same model", symbol: "hare", group: .settings),
        .init(name: "yolo", title: "Run Without Asking", summary: "Approve every command in this chat", symbol: "bolt.shield", group: .settings),
        .init(name: "personality", title: "Personality", summary: "How Hermes talks", symbol: "theatermasks", group: .settings, argument: "[name]"),
        .init(name: "review", title: "Review", summary: "Review the last turn", symbol: "checkmark.seal", group: .more),
        .init(name: "memory", title: "Memory", summary: "What Hermes remembers", symbol: "brain", group: .more),
        .init(name: "save", title: "Save Chat", summary: "Save this chat to a file", symbol: "square.and.arrow.down", group: .more),
        .init(name: "version", title: "Version", summary: "The Hermes version on the gateway", symbol: "number", group: .more),
    ]

    /// Other names Hermes accepts for these.
    public static let aliases: [String: String] = [
        "reset": "new", "clear": "new", "compact": "compress", "q": "queue",
        "background": "bg", "effort": "reasoning", "rename": "title",
    ]

    private static let byName: [String: SlashCommandInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func canonical(_ name: String) -> String {
        let lower = name.lowercased()
        return aliases[lower] ?? lower
    }

    /// The app's description of a command, if it has one.
    public static func known(_ name: String) -> SlashCommandInfo? {
        byName[canonical(name)]
    }

    /// The app's description, or a plain fallback for a command it doesn't know.
    public static func info(_ name: String, summary: String? = nil) -> SlashCommandInfo {
        known(name) ?? SlashCommandInfo(name: name, title: "/\(name)", summary: summary ?? "", symbol: fallbackSymbol, group: .more)
    }

    /// A leading `/word` and what follows it, for text that starts with a command.
    public static func parse(_ text: String) -> (name: String, argument: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_:.".contains($0) }) else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(name), rest.isEmpty ? nil : rest)
    }

    /// Up to five leading `/skill` tokens and the message after them.
    public static func leadingSkills(in text: String, skills: Set<String>) -> (skills: [String], body: String) {
        var found: [String] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while found.count < 5, rest.hasPrefix("/") {
            let name = rest.dropFirst().prefix { !$0.isWhitespace }
            guard skills.contains(String(name)) else { break }
            found.append(String(name))
            rest = rest.dropFirst(name.count + 1).drop { $0.isWhitespace }
        }
        return (found, String(rest))
    }
}

/// A command run in the chat: the card on the person's side and what came of it.
public struct CommandEntry: Identifiable, Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case running(String?)
        /// One quiet line ("Model changed to Claude Opus 4.6").
        case note(String)
        /// An info command's data, as label / value rows, or text when it doesn't parse.
        case result(rows: [Row], text: String?)
        case failed(String)
    }

    public struct Row: Hashable, Sendable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var id: String
    public var name: String
    public var argument: String?
    public var outcome: Outcome
    public var timestamp: Date

    public init(id: String = "command-\(UUID().uuidString)", name: String, argument: String?, outcome: Outcome, timestamp: Date = .now) {
        self.id = id
        self.name = name
        self.argument = argument
        self.outcome = outcome
        self.timestamp = timestamp
    }

    /// Command output as rows when it's mostly `Label: value` lines.
    public static func outcome(fromOutput output: String) -> Outcome {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .note("Done") }
        if lines.count == 1 { return .note(lines[0]) }
        var rows: [Row] = []
        var other: [String] = []
        for line in lines {
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 24 {
                let label = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " *-•"))
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty, !value.isEmpty {
                    rows.append(Row(label: label, value: value))
                    continue
                }
            }
            other.append(line)
        }
        guard rows.count >= 2, rows.count >= other.count else { return .result(rows: [], text: output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .result(rows: rows, text: other.isEmpty ? nil : other.joined(separator: "\n"))
    }
}
