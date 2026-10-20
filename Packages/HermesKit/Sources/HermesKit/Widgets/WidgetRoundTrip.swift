import Foundation

/// What a chat's own rows say about its widgets (`docs/widgets.md` §5, §7). It comes from the
/// transcript, so it holds on every device and after a restart: answers sent from any device,
/// questions the person moved past by typing, and where each widget is.
public struct WidgetChatFacts: Hashable, Sendable {
    /// An answer message in the chat.
    public struct Answer: Hashable, Sendable {
        public var rowID: String
        public var rev: Int
        public var action: String
        public var mid: String
        public var device: String?
        public var at: Date?
        /// The message as sent: Try Again sends exactly this again.
        public var text: String

        public init(rowID: String, rev: Int, action: String, mid: String, device: String? = nil, at: Date? = nil, text: String) {
            self.rowID = rowID
            self.rev = rev
            self.action = action
            self.mid = mid
            self.device = device
            self.at = at
            self.text = text
        }
    }

    /// Answer messages by widget id, oldest first.
    public var answers: [String: [Answer]] = [:]
    /// Widgets shown before a message the person typed (not a widget's answer).
    public var movedPast: Set<String> = []
    /// Widget ids in the order the chat shows them.
    public var shown: [String] = []
    /// The widgets of the newest reply, when nothing came after it (suggestions show only then).
    public var lastReplyWidgets: Set<String> = []

    public init() {}

    /// - Parameter inlineIDs: the ids of the inline widgets a row draws (a routine delivery the
    ///   plugin processed).
    public static func build(_ items: [TranscriptItem], inlineIDs: (UserEntry) -> [String] = { _ in [] }) -> WidgetChatFacts {
        var facts = WidgetChatFacts()
        var seen: Set<String> = []
        func show(_ ids: [String]) {
            for id in ids where seen.insert(id).inserted { facts.shown.append(id) }
        }
        for (index, item) in items.enumerated() {
            switch item {
            case .assistant(let turn):
                let ids = widgetIDs(in: turn)
                show(ids)
                if index == items.count - 1 { facts.lastReplyWidgets = Set(ids) }
            case .user(let entry):
                if let answer = WidgetAnswer.parse(entry.text) {
                    facts.answers[answer.widgetID, default: []].append(Answer(
                        rowID: entry.id, rev: answer.rev, action: answer.action, mid: answer.mid,
                        device: answer.device, at: entry.timestamp, text: entry.text))
                } else if entry.sender == nil, entry.routineName == nil {
                    facts.movedPast.formUnion(seen) // the person wrote something else
                } else {
                    show(inlineIDs(entry))
                }
            case .notice, .command:
                break
            }
        }
        return facts
    }

    /// A Bot group chat's facts (`docs/widgets.md` §7): members' messages carry their widgets as
    /// inline blocks (the plugin writes them for rooms the app marked), the person's carry answers.
    public static func build(room items: [RoomItem]) -> WidgetChatFacts {
        var facts = WidgetChatFacts()
        var seen: Set<String> = []
        for (index, item) in items.enumerated() {
            switch item {
            case .member(_, _, let text, _):
                let ids = ReplySplitter.split(text, inlineWidgets: true).compactMap { segment -> String? in
                    switch segment {
                    case .widget(let directive): directive.id
                    case .inline(let json): json["id"]?.stringValue
                    case .markdown: nil
                    }
                }
                for id in ids where seen.insert(id).inserted { facts.shown.append(id) }
                if index == items.count - 1 { facts.lastReplyWidgets = Set(ids) }
            case .user(let id, let text, let date):
                if let answer = WidgetAnswer.parse(text) {
                    facts.answers[answer.widgetID, default: []].append(Answer(
                        rowID: id, rev: answer.rev, action: answer.action, mid: answer.mid, device: answer.device, at: date, text: text))
                } else {
                    facts.movedPast.formUnion(seen)
                }
            default:
                break
            }
        }
        return facts
    }

    /// The widgets a reply points at: its answer, and what it said between steps.
    public static func widgetIDs(in turn: AssistantTurn) -> [String] {
        var ids: [String] = []
        for step in turn.steps {
            if case .narration(_, let text) = step { ids += ReplySplitter.directiveIDs(in: text) }
        }
        return ids + ReplySplitter.directiveIDs(in: turn.answer)
    }

    /// A row that sends again an answer an earlier row sent (Try Again: the same mid). The chat
    /// shows the answer once.
    public func isRepeat(rowID: String, of answer: WidgetAnswer) -> Bool {
        guard !answer.mid.isEmpty, let first = answers[answer.widgetID]?.first(where: { $0.mid == answer.mid }) else { return false }
        return first.rowID != rowID
    }

    /// The newest answer to this revision.
    public func answer(to id: String, rev: Int) -> Answer? {
        answers[id]?.last { $0.rev == rev }
    }
}

/// Where a widget's request stands for this person, on this device (`docs/widgets.md` §5).
public enum WidgetInteraction: Hashable, Sendable {
    /// Its actions work.
    case open
    /// A tap is on its way: being sent, or waiting behind the running turn (Send Next).
    case sending(action: String, queued: Bool)
    /// An answer is in the chat and the agent hasn't updated the widget yet. Locked for everyone.
    case waiting(action: String, mine: Bool, device: String?)
    /// Mine, and 60 s in a turn without an update: the actions come back with Try Again.
    case noAnswer(answer: WidgetChatFacts.Answer)
    /// Not sent: offline, and approvals don't queue.
    case notSent(action: String)
    /// The agent updated it with a `resolution`: the resolution line replaces the actions.
    case resolved
    /// Past `expires_at`: the client turns the actions off itself.
    case expired
    /// A newer widget replaces it; the newer one is the one to answer.
    case superseded(by: String)
    /// A question the person moved past by typing: folded, with Answer Anyway until it expires.
    case notAnswered
    /// A group chat's widget for someone else.
    case readOnly(for: String)

    /// Whether its buttons can be tapped.
    public var acceptsAnswers: Bool {
        switch self {
        case .open, .noAnswer, .notSent: true
        default: false
        }
    }

    /// No answer from the agent within this long after the message entered a turn.
    public static let answerTimeout: TimeInterval = 60

    /// Decides from the newest payload, the chat's rows and this device's own state.
    /// - Parameters:
    ///   - local: a tap not in the chat yet (`sending`), or one that couldn't go (`notSent`).
    ///   - mine: mids this device sent.
    ///   - enteredTurn: when this device's answer entered a turn, by mid (the timer starts there,
    ///     not at the tap: Send Next can wait behind a long turn).
    ///   - supersededBy: the widget that replaces this one, if any.
    ///   - forOther: in a group chat, the name of the person it's for, when that isn't this person.
    public static func evaluate(
        _ payload: WidgetPayload, facts: WidgetChatFacts, local: WidgetInteraction? = nil, mine: Set<String> = [],
        enteredTurn: [String: Date] = [:], supersededBy: String? = nil, forOther: String? = nil, now: Date = .now
    ) -> WidgetInteraction {
        if let supersededBy { return .superseded(by: supersededBy) }
        if payload.envelope.resolution != nil { return .resolved }
        if let expires = WidgetClock.date(payload.envelope.expiresAt), now >= expires { return .expired }
        if let forOther { return .readOnly(for: forOther) }
        if let answer = facts.answer(to: payload.id, rev: payload.rev) {
            let isMine = mine.contains(answer.mid)
            if isMine, let since = enteredTurn[answer.mid] ?? answer.at, now.timeIntervalSince(since) >= answerTimeout {
                return .noAnswer(answer: answer)
            }
            return .waiting(action: answer.action, mine: isMine, device: answer.device)
        }
        if let local { return local }
        if facts.movedPast.contains(payload.id), payload.type == .choice || payload.type == .form {
            return .notAnswered
        }
        return .open
    }
}

/// Checklist ticks kept on the device until they go as one message (contract §6.1: 5 s after the
/// last tick, or on leaving the chat). Each is optimistic and shows pending until an update with a
/// newer revision confirms it.
public struct ChecklistTicks: Hashable, Sendable {
    /// The revision the ticks were made against.
    public var rev: Int
    /// Items flipped from what that revision says, not sent yet.
    public var unsent: Set<String> = []
    /// Items flipped and sent, waiting for the agent's update.
    public var sent: Set<String> = []

    public init(rev: Int) {
        self.rev = rev
    }

    public mutating func toggle(_ id: String) {
        if sent.contains(id) {
            // Sent one way already: flipping it back is a new change on top.
            sent.remove(id)
            unsent.insert(id)
        } else if unsent.contains(id) {
            unsent.remove(id)
        } else {
            unsent.insert(id)
        }
    }

    /// What the person sees: the revision's state, flipped by every pending tick.
    public func isChecked(_ item: ChecklistWidget.Item) -> Bool {
        item.checked != (unsent.contains(item.id) || sent.contains(item.id))
    }

    public func isPending(_ id: String) -> Bool {
        unsent.contains(id) || sent.contains(id)
    }

    /// A newer revision arrived: what was sent is settled by it; ticks not sent yet keep what the
    /// person wanted, measured against the new revision.
    public func rebased(from old: ChecklistWidget, to new: ChecklistWidget, rev: Int) -> ChecklistTicks {
        var ticks = ChecklistTicks(rev: rev)
        for id in unsent {
            guard let before = old.items.first(where: { $0.id == id }), let after = new.items.first(where: { $0.id == id }) else { continue }
            if !before.checked != after.checked { ticks.unsent.insert(id) }
        }
        return ticks
    }

    /// The message for the unsent ticks, and the ticks marked sent; `nil` when there are none.
    public mutating func takeAnswer(_ payload: WidgetPayload, _ widget: ChecklistWidget) -> WidgetAnswer? {
        let items = widget.items.filter { unsent.contains($0.id) }
        guard !items.isEmpty else { return nil }
        let checked = items.filter { !$0.checked }.map(\.id)
        let unchecked = items.filter(\.checked).map(\.id)
        sent.formUnion(unsent)
        unsent.removeAll()
        return .checklist(payload, widget, checked: checked, unchecked: unchecked)
    }
}

/// Times in payloads (RFC 3339 with an offset) and dates (`YYYY-MM-DD`).
public enum WidgetClock {
    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// When the payload's data counts as old: `as_of` + `stale_after`.
    public static func staleAt(_ envelope: WidgetEnvelope) -> Date? {
        guard let staleAfter = envelope.staleAfter, let asOf = date(envelope.asOf) else { return nil }
        return asOf.addingTimeInterval(TimeInterval(staleAfter))
    }
}
