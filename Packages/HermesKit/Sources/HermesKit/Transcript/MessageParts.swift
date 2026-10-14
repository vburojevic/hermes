import Foundation

/// A Bot or a gateway file named inline in a message (`docs/commands-and-references.md`): drawn
/// as a pill where it was typed, sent to Hermes in its plain form (`@writer`, `@file:path`).
public struct MessageReference: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case bot, file, folder
    }

    public var kind: Kind
    /// The Bot's handle without "@", or the path on the gateway.
    public var value: String
    /// Where the plain form starts in the message body, in UTF-16 units.
    public var location: Int

    public init(kind: Kind, value: String, location: Int = 0) {
        self.kind = kind
        self.value = value
        self.location = location
    }

    /// What Hermes is sent: `@writer`, `@file:Sources/App.swift`, `@folder:Sources/`
    /// (`complete.path` items use the `@file:` / `@folder:` forms).
    public var plainText: String {
        switch kind {
        case .bot: "@" + value
        case .file: "@file:" + value
        case .folder: "@folder:" + value
        }
    }

    public var length: Int { plainText.utf16.count }
    public var range: NSRange { NSRange(location: location, length: length) }

    /// A completion's text (`@file:path`, `@folder:path/`, `@name`) as a reference.
    public init?(plainText text: String, location: Int = 0) {
        if text.hasPrefix("@file:"), text.count > 6 {
            self.init(kind: .file, value: String(text.dropFirst(6)), location: location)
        } else if text.hasPrefix("@folder:"), text.count > 8 {
            self.init(kind: .folder, value: String(text.dropFirst(8)), location: location)
        } else {
            return nil
        }
    }
}

/// What a message is made of, kept at send time so the transcript doesn't re-parse it
/// (`docs/commands-and-references.md` §4): a command and its argument, or skills and a body
/// with Bots and files inline.
public struct MessageParts: Hashable, Sendable, Codable {
    public struct Command: Hashable, Sendable, Codable {
        public var name: String
        public var argument: String?

        public init(name: String, argument: String? = nil) {
            self.name = name
            let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.argument = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public enum Segment: Hashable, Sendable {
        case text(String)
        case reference(MessageReference)
    }

    /// The most skills one message can carry (the gateway's `_MAX_STACKED_SKILLS`).
    public static let maxSkills = 5

    public var command: Command?
    public var skills: [String]
    /// The text, with each reference in its plain form at its ``MessageReference/location``.
    public var body: String
    public var references: [MessageReference]

    public init(body: String = "", references: [MessageReference] = [], skills: [String] = [], command: Command? = nil) {
        self.body = body
        self.references = references.sorted { $0.location < $1.location }
        self.skills = skills
        self.command = command
    }

    /// What Hermes is sent: `/goal Ship it`, or `/skill-a /skill-b` prefixes then the body.
    public var plainText: String {
        if let command {
            return "/" + command.name + (command.argument.map { " " + $0 } ?? "")
        }
        let prefixes = skills.map { "/" + $0 }.joined(separator: " ")
        if prefixes.isEmpty { return body }
        return body.isEmpty ? prefixes : prefixes + " " + body
    }

    public var isEmpty: Bool {
        command == nil && skills.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Anything to draw beyond plain text.
    public var hasStructure: Bool {
        command != nil || !skills.isEmpty || !references.isEmpty
    }

    /// The references whose plain form is still where they say, in order and not overlapping.
    public static func valid(_ references: [MessageReference], in body: String) -> [MessageReference] {
        let utf16 = body.utf16
        var end = 0
        var kept: [MessageReference] = []
        for reference in references.sorted(by: { $0.location < $1.location }) {
            guard reference.location >= end, reference.location + reference.length <= utf16.count else { continue }
            let start = utf16.index(utf16.startIndex, offsetBy: reference.location)
            let stop = utf16.index(start, offsetBy: reference.length)
            guard String(utf16[start..<stop]) == reference.plainText else { continue }
            kept.append(reference)
            end = reference.location + reference.length
        }
        return kept
    }

    /// The body as runs of text and references.
    public var segments: [Segment] {
        let valid = Self.valid(references, in: body)
        guard !valid.isEmpty else { return body.isEmpty ? [] : [.text(body)] }
        let utf16 = body.utf16
        var segments: [Segment] = []
        var cursor = 0
        for reference in valid {
            if reference.location > cursor {
                let start = utf16.index(utf16.startIndex, offsetBy: cursor)
                let stop = utf16.index(utf16.startIndex, offsetBy: reference.location)
                segments.append(.text(String(utf16[start..<stop]) ?? ""))
            }
            segments.append(.reference(reference))
            cursor = reference.location + reference.length
        }
        if cursor < utf16.count {
            segments.append(.text(String(utf16[utf16.index(utf16.startIndex, offsetBy: cursor)...]) ?? ""))
        }
        return segments
    }

    /// The body without leading and trailing whitespace, references moved to match.
    public func trimmed() -> MessageParts {
        let leading = body.prefix { $0.isWhitespace || $0.isNewline }
        let shift = String(leading).utf16.count
        var copy = self
        copy.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.references = Self.valid(references.map { var moved = $0; moved.location -= shift; return moved }, in: copy.body)
        return copy
    }

    /// Text that arrived as plain text (from the CLI, Telegram, a Bot's reply): a leading
    /// `/word` that names a known command or skill becomes the command or skill chips; known
    /// `@handles` and `@file:` / `@folder:` paths become references. Anything unrecognised
    /// stays text.
    public static func parse(_ text: String, vocabulary: ReferenceVocabulary, leading: Bool = true) -> MessageParts {
        var body = text
        var skills: [String] = []
        if leading, text.hasPrefix("/") {
            let found = SlashCommands.leadingSkills(in: text, skills: vocabulary.skills)
            if !found.skills.isEmpty {
                skills = Array(found.skills.prefix(maxSkills))
                body = found.body
            } else if let command = SlashCommands.parse(text), vocabulary.commands.contains(command.name.lowercased()) || SlashCommands.known(command.name) != nil {
                return MessageParts(command: Command(name: command.name, argument: command.argument))
            }
        }
        return MessageParts(body: body, references: vocabulary.references(in: body), skills: skills)
    }
}

/// The names a message can refer to here: the roster's Bot handles, the gateway's commands and
/// skills. Used to upgrade plain text that came from elsewhere into pills and cards.
public struct ReferenceVocabulary: Hashable, Sendable {
    /// Lowercased handles that name a Bot (without the `@`).
    public var handles: Set<String>
    /// Command names (without the `/`).
    public var commands: Set<String>
    /// Skill names (without the `/`).
    public var skills: Set<String>

    public init(handles: Set<String> = [], commands: Set<String> = ReferenceVocabulary.knownCommands, skills: Set<String> = []) {
        self.handles = handles
        self.commands = commands
        self.skills = skills
    }

    /// The app's own command names and their aliases.
    public static let knownCommands: Set<String> = Set(SlashCommands.all.map(\.name)).union(SlashCommands.aliases.keys)

    /// `@handle` Bots and `@file:` / `@folder:` paths in `text`, in order. A reference starts the
    /// text or follows a space or an opening bracket, so emails aren't caught.
    public func references(in text: String) -> [MessageReference] {
        var found: [MessageReference] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "@" else {
                index = text.index(after: index)
                continue
            }
            if index > text.startIndex {
                let previous = text[text.index(before: index)]
                guard previous.isWhitespace || "([{\"'“‘".contains(previous) else {
                    index = text.index(after: index)
                    continue
                }
            }
            let wordStart = text.index(after: index)
            let location = text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.startIndex)
            let rest = text[wordStart...]
            if let prefix = ["file:", "folder:"].first(where: { rest.hasPrefix($0) }) {
                // A path runs to the next whitespace; sentence punctuation after it isn't part of it.
                let pathStart = text.index(wordStart, offsetBy: prefix.count)
                var end = pathStart
                while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
                while end > pathStart, ",;:!?)\"'”’".contains(text[text.index(before: end)]) { end = text.index(before: end) }
                if end > pathStart {
                    let path = String(text[pathStart..<end])
                    found.append(MessageReference(kind: prefix == "file:" ? .file : .folder, value: path, location: location))
                }
                index = max(end, wordStart)
                continue
            }
            var end = wordStart
            while end < text.endIndex, text[end].isLetter || text[end].isNumber || "-_.".contains(text[end]) {
                end = text.index(after: end)
            }
            // A trailing dot is punctuation ("ask @writer.").
            while end > wordStart, text[text.index(before: end)] == "." { end = text.index(before: end) }
            let word = String(text[wordStart..<end])
            if !word.isEmpty, handles.contains(word.lowercased()) {
                found.append(MessageReference(kind: .bot, value: word, location: location))
            }
            index = end > wordStart ? end : wordStart
        }
        return found
    }
}
