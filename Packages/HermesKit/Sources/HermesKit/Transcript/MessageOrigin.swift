import Foundation

/// What delivered a message into a chat when the person didn't write it (`docs/chat.md` §2a).
/// Hermes stores these as the person's rows, with no author on the row: the text, and for some its
/// `display_kind`, are all that say where they came from.
public enum DeliverySource: Hashable, Sendable {
    /// A routine's output (a cron job): `[Cronjob "<name>" output …]` into a Bot Chat,
    /// `[Cron delivery: <name>]` mirrored into the chat that made it, or `Cronjob Response: <name>`.
    case routine(String)
    /// A webhook's event mirrored into a chat: `[Webhook delivery: <route>]`.
    case webhook(String)
    /// Something Hermes delivered as its own (`internal_notification`) without saying what sent it:
    /// a script's `hermes peer dm`, a `/v1/runs` call, a plugin's `inject_message`.
    case automation

    /// The routine's or the route's name.
    public var name: String? {
        switch self {
        case .routine(let name), .webhook(let name): name
        case .automation: nil
        }
    }

    /// Who it reads as in a row's last line or a notification: the name, else "Automation".
    public var speaker: String { name ?? String(localized: "Automation") }
}

public enum Delivery {
    static let mirroredRoutine = "[Cron delivery: "
    static let mirroredWebhook = "[Webhook delivery: "
    static let platformRoutine = "Cronjob Response: "
    /// The line Hermes ends a platform delivery with (`cron/scheduler.py`, `wrap_response`).
    static let platformFooter = "To stop or manage this job"

    /// Where a message came from and its words without Hermes's wrapper, for the shapes Hermes
    /// writes (`cron/scheduler_delivery.py`, `gateway/platforms/webhook.py`), else for any
    /// `internal_notification` that isn't one of Hermes's own notes. Nil for anything else.
    public static func parse(_ text: String, displayKind: String?) -> (source: DeliverySource, body: String)? {
        let text = String(text.drop(while: \.isWhitespace))
        if let routine = BotMentions.parseRoutineDelivery(text) {
            return (.routine(routine.name), routine.output)
        }
        if let (name, body) = bracketed(text, opener: mirroredRoutine) {
            return (.routine(BotRoutine.parse(name: name).1), body)
        }
        if let (name, body) = bracketed(text, opener: mirroredWebhook) {
            return (.webhook(name), body)
        }
        if text.hasPrefix(platformRoutine), let (name, body) = platformDelivery(text) {
            return (.routine(BotRoutine.parse(name: name).1), body)
        }
        if displayKind == "internal_notification", BotProfile.controlFrame(text) == nil {
            return (.automation, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// `[<opener><name>]\n<body>`.
    private static func bracketed(_ text: String, opener: String) -> (String, String)? {
        guard text.hasPrefix(opener), let close = text.firstIndex(of: "]") else { return nil }
        let name = text[text.index(text.startIndex, offsetBy: opener.count)..<close].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let body = text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, body)
    }

    /// `Cronjob Response: <name>\n(job_id: <id>)\n-------------\n\n<content>\n\nTo stop or manage this job, …`.
    private static func platformDelivery(_ text: String) -> (String, String)? {
        var lines = text.components(separatedBy: "\n")
        let name = lines.removeFirst().dropFirst(platformRoutine.count).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if lines.first?.hasPrefix("(job_id:") == true { lines.removeFirst() }
        if let rule = lines.first, !rule.isEmpty, rule.allSatisfy({ $0 == "-" }) { lines.removeFirst() }
        if let footer = lines.lastIndex(where: { $0.hasPrefix(platformFooter) }) { lines.removeSubrange(footer...) }
        return (name, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A skill used from another device or a channel, as Hermes stores it: the whole skill expanded
/// into the message (`agent/skill_commands.py`). Hermes's clients show it as it was typed, "/name
/// instruction" (`describe_skill_invocation`); here the skill is a chip and the instruction the
/// message.
public enum SkillInvocation {
    static let prefix = "[IMPORTANT: The user has invoked the "
    static let singleMarker = "The full skill content is loaded below.]"
    static let singleInstruction = "The user has provided the following instruction alongside the skill invocation: "
    static let runtimeNote = "\n\n[Runtime note:"
    static let bundleMarker = " skill bundle,"
    static let bundleInstruction = "\nUser instruction: "
    static let bundleFirstSkill = "\n\n[Loaded as part of the "
    static let autoLoadPrefix = "[IMPORTANT: The \""
    static let autoLoadSuffix = "\" skill is auto-loaded."
    /// The last sentence of every skill payload (`_SKILL_DIR_NOTE_END`).
    static let payloadEnd = "then run them with the terminal tool using the absolute path."

    /// The skills and the person's own words, or nil for a message that isn't a skill payload.
    public static func parse(_ text: String) -> (skills: [String], instruction: String)? {
        if text.hasPrefix(autoLoadPrefix), let suffix = text.range(of: autoLoadSuffix) {
            let name = String(text[text.index(text.startIndex, offsetBy: autoLoadPrefix.count)..<suffix.lowerBound])
            let typed = text.range(of: payloadEnd, options: .backwards).map { String(text[$0.upperBound...]) } ?? ""
            return ([name].filter { !$0.isEmpty }, typed.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard text.hasPrefix(prefix) else { return nil }
        let quoted = text.dropFirst(prefix.count)
        guard quoted.hasPrefix("\"") else { return nil }
        let name = quoted.dropFirst().prefix { $0 != "\"" }
        // A bundle names its skills as typed ("/clean /work").
        let skills = name.split(separator: " ").map { String($0.drop { $0 == "/" }) }.filter { !$0.isEmpty }
        let instruction: Substring?
        if text.contains(bundleMarker) {
            instruction = cut(text, after: bundleInstruction, until: bundleFirstSkill, last: false)
        } else if text.contains(singleMarker) {
            // The instruction follows the skill's body, which may quote the marker: the last one.
            instruction = cut(text, after: singleInstruction, until: runtimeNote, last: true)
        } else {
            instruction = nil
        }
        return (skills, instruction.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "")
    }

    private static func cut(_ text: String, after marker: String, until stop: String, last: Bool) -> Substring? {
        guard let found = text.range(of: marker, options: last ? .backwards : []) else { return nil }
        let rest = text[found.upperBound...]
        return rest.range(of: stop).map { rest[..<$0.lowerBound] } ?? rest
    }
}

/// Rows Hermes writes for the model as the person's, which no client shows as theirs
/// (`docs/chat.md` §2a).
enum HermesScaffold {
    /// Untyped `[System: …]` rows (recovery nudges): Hermes's REST projection hides them and its
    /// TUI drops them (`_is_untyped_scaffold_notice`). The task list and planning state that
    /// compaction carries over are scaffolding too (`_is_synthetic_compression_user_turn`).
    static let hiddenPrefixes = ["[System:", "[Your active task list was preserved", "[Planning state preserved"]

    static func isHidden(_ text: String) -> Bool {
        let head = text.drop(while: \.isWhitespace)
        return hiddenPrefixes.contains { head.hasPrefix($0) }
    }

    /// An interrupted turn Hermes picked up again, stored before it was typed `auto_continue`
    /// (`tui_gateway/session_auto_continue.py`, sniffed the same way in `session_history.py`).
    static func isAutoContinue(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix("[System note: Your previous turn was interrupted")
    }

    /// Recalled memory Hermes put in front of a message for the model (`agent/memory_context.py`),
    /// which stays in a message with images: not the person's words.
    static func withoutMemoryContext(_ text: String) -> String {
        guard let open = text.range(of: "<memory-context>"),
              let close = text.range(of: "</memory-context>", range: open.upperBound..<text.endIndex)
        else { return text }
        return String(text[..<open.lowerBound] + text[close.upperBound...])
    }
}

extension Delivery {
    /// The replies that answer a delivery, by turn id: the turn right after it reads as a reply to
    /// the routine or automation, not to the person (`docs/chat.md` §2a).
    public static func replies(in items: [TranscriptItem]) -> [String: DeliverySource] {
        var replies: [String: DeliverySource] = [:]
        var previous: TranscriptItem?
        for item in items {
            if case .assistant(let turn) = item, case .user(let entry)? = previous, let source = entry.delivery {
                replies[turn.id] = source
            }
            previous = item
        }
        return replies
    }
}

/// Who a Bot's turn answers when it isn't the person: a delivery, or another Bot's message.
public enum Answering: Hashable, Sendable {
    case delivery(DeliverySource)
    case bot(AgentSender)
}

extension Delivery {
    /// The turns that answer someone other than the person, by turn id: the turn right after a
    /// delivery reads as a reply to it, and the one right after another Bot's message as a reply
    /// to that Bot ("Replying to Engineer"), as Hermes Desktop folds it (`docs/chat.md` §2a).
    public static func answering(in items: [TranscriptItem]) -> [String: Answering] {
        var answering: [String: Answering] = [:]
        var previous: TranscriptItem?
        for item in items {
            if case .assistant(let turn) = item, case .user(let entry)? = previous {
                if let source = entry.delivery {
                    answering[turn.id] = .delivery(source)
                } else if let sender = entry.sender {
                    answering[turn.id] = .bot(sender)
                }
            }
            previous = item
        }
        return answering
    }
}
