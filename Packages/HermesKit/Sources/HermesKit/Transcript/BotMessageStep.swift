import Foundation

/// A message this Bot sent another (`message_agent`, tools/bot_mode_dm.py), as its step shows it:
/// who to, the words it sent, and what came back (`docs/chat.md` §2a). Its step used to show only
/// "Message to @engineer" over an empty preview: the words were in the call's arguments and the
/// answer in a later row.
public struct BotMessageStep: Hashable, Sendable {
    /// The profile it went to (`target`), without an @.
    public var target: String
    /// The recipient's name as Hermes gave it back (`to`), when it did.
    public var recipientName: String?
    /// The words it sent.
    public var text: String
    /// Hermes refused it: the reason, in plain words ("Engineer is busy with another message.").
    public var error: String?

    public init(target: String, recipientName: String? = nil, text: String, error: String? = nil) {
        self.target = target
        self.recipientName = recipientName
        self.text = text
        self.error = error
    }

    /// The `message_agent` call `tool` made, or nil for any other step.
    public init?(_ tool: ToolActivity) {
        guard tool.name == "message_agent" else { return nil }
        let arguments = tool.arguments
        let target = (arguments?["target"]?.stringValue ?? arguments?["to"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespaces)
        let result = tool.result.flatMap(ToolDisplayCache.json)
        self.target = String(target.drop { $0 == "@" })
        recipientName = result?["to"]?.stringValue.map { String($0.drop { $0 == "@" }) }.flatMap { $0.isEmpty ? nil : $0 }
        text = (arguments?["message"]?.stringValue ?? arguments?["text"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        error = tool.result.flatMap { result in
            guard result.contains("\"error\""), let json = ToolDisplayCache.json(result), json["error"]?.stringValue?.isEmpty == false
            else { return nil }
            return ProcessOutput.errorMessage(in: result)
        }
    }

    /// The name to show: the Bot's own title when the roster knows the profile, else its profile
    /// as the app writes one ("Engineer").
    public func name(botName: (String) -> String?) -> String {
        let profile = target.isEmpty ? recipientName ?? "" : target
        return profile.isEmpty ? String(localized: "a Bot") : ProcessNaming.bot(profile, botName: botName)
    }

    /// The recipient's answer: the first message from that Bot in this chat after the turn whose
    /// step `stepID` sent it. Hermes carries a reply back into the sender's chat as the
    /// recipient's message (`reply_delivery`).
    public func reply(in items: [TranscriptItem], sentBy stepID: String) -> UserEntry? {
        let start = items.firstIndex { item in
            if case .assistant(let turn) = item { turn.steps.contains { $0.id == stepID } } else { false }
        }
        guard let start else { return nil }
        for item in items[items.index(after: start)...] {
            guard case .user(let entry) = item, let sender = entry.sender else { continue }
            if Self.sameBot(sender.handle, target) || recipientName.map({ Self.sameBot(sender.name, $0) }) == true { return entry }
        }
        return nil
    }

    static func sameBot(_ a: String, _ b: String) -> Bool {
        let normal = { (name: String) in
            let name = name.lowercased().drop { $0 == "@" }
            return name == "default" ? "hermes" : String(name)
        }
        return !a.isEmpty && normal(a) == normal(b)
    }
}
