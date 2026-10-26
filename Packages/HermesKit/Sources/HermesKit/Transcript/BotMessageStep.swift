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

    /// The message `tool` sent another Bot, or nil for any other step: a `message_agent` call, or
    /// a `terminal` call running `hermes -p <bot> chat -q …` itself (`ProcessNaming.botMessage`).
    public init?(_ tool: ToolActivity) {
        if tool.name == "terminal" {
            guard let command = tool.startedCommand, let sent = ProcessNaming.botMessage(in: command) else { return nil }
            target = sent.profile
            text = sent.text
            return
        }
        guard tool.name == "message_agent" else { return nil }
        let arguments = Self.arguments(tool.arguments)
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

    /// The call's arguments as an object. A stored row holds them as a JSON string, which a
    /// provider can encode twice (a string holding the object); a live event holds the object.
    static func arguments(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .object?: return value
        case .string(let text)?:
            let parsed = JSONValue.parse(text)
            if case .object? = parsed { return parsed }
            return nil
        default: return nil
        }
    }

    /// Whether its step draws anything under the title row (`processStepMessage`): the words it
    /// sent, the answer, or while it waits the line saying where the answer will show. With none
    /// of them, the title row alone, never an empty box.
    public func showsBody(hasAnswer: Bool, delivery: Delivery?) -> Bool {
        !text.isEmpty || hasAnswer || delivery == .waiting
    }

    /// The name to show: the Bot's own title when the roster knows the profile, else its profile
    /// as the app writes one ("Engineer").
    public func name(botName: (String) -> String?) -> String {
        let profile = target.isEmpty ? recipientName ?? "" : target
        return profile.isEmpty ? String(localized: "a Bot") : ProcessNaming.bot(profile, botName: botName)
    }

    /// Where a message stands, as its step's title row says it (`processStepMessage`,
    /// `docs/background-processes.md` §4): what came back, not the delivery process's own state.
    public enum Delivery: Hashable, Sendable {
        /// Delivered and no reply yet: still, nothing shimmers.
        case waiting
        case replied
        case notDelivered
    }

    /// From the delivery process's state, when the chat knows it, and what came back. A delivery
    /// that ended some other way (stopped, finished without a reply, no longer listed) has none:
    /// the step says what the process did.
    public static func delivery(state: BackgroundProcess.State?, replied: Bool, failed: Bool) -> Delivery? {
        if failed || state == .failed { return .notDelivered }
        if replied { return .replied }
        if state == .running { return .waiting }
        return nil
    }

    /// "Replied · 4 min", "Waiting · 2 min", "Not delivered": the time is the delivery's, from
    /// sending to the reply or to now.
    public static func stateLabel(_ delivery: Delivery, duration: TimeInterval?) -> String {
        let time = duration.map(BackgroundProcess.durationText)
        switch delivery {
        case .waiting: return time.map { String(localized: "Waiting · \($0)") } ?? String(localized: "Waiting")
        case .replied: return time.map { String(localized: "Replied · \($0)") } ?? String(localized: "Replied")
        case .notDelivered: return String(localized: "Not delivered")
        }
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
