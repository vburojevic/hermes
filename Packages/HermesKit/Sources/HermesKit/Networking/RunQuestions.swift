import Foundation

/// The questions a `/v1/runs` turn waits on, as a chat shows them (`docs/quick-actions.md` §3).
///
/// Over the API server Hermes asks a question in two places: the run's events (`clarify.request`,
/// then `clarify.settled` when it stops waiting) and the run's status (`pending_controls`). A
/// gateway that leaves it off the events lists it only in the status, so the chat reads that too
/// while the stream is quiet (`RunStatusWatch`). Each question shows as the card a socket chat's
/// `clarify` gets, by its prompt id, and is answered over HTTP (`RunPromptAnswer`).
public struct RunQuestions: Sendable {
    /// Where a shown question is answered.
    public struct Asked: Sendable, Hashable {
        public var runID: String
        public var generation: Int?
        public var deadline: Date?
        /// When the chat learned of it: a status read that began earlier can't have listed it.
        public var since: Date
    }

    /// What the chat does with a status read or an event.
    public enum Change: Sendable, Equatable {
        case show(HermesRequest)
        /// Hermes stopped waiting while its card was up here.
        case end(id: String, RequestSync.Ending)
        /// The run ended with its card up: it goes without a word (the turn says how it ended).
        case drop(id: String)
    }

    private var asked: [String: Asked] = [:]
    /// Answered here, and possibly not with Hermes yet: a read or event that still lists it
    /// doesn't bring the card back, and one that settles it says nothing.
    private var answered: [String: Asked] = [:]

    public init() {}

    /// Whether `id` is one of these questions, shown or being answered.
    public func owns(_ id: String) -> Bool {
        asked[id] != nil || answered[id] != nil
    }

    /// Whether a card for one of the run's questions is up.
    public func isAsking(in runID: String) -> Bool {
        asked.values.contains { $0.runID == runID }
    }

    /// Hermes asked (`clarify.request`, or a status that lists it): the card to show, or nil when it
    /// already shows, was answered here, or isn't a question.
    public mutating func ask(_ prompt: RunPrompt, runID: String, now: Date = .now) -> HermesRequest? {
        guard !owns(prompt.promptID), let request = prompt.questionRequest(receivedAt: now) else { return nil }
        asked[prompt.promptID] = Asked(runID: runID, generation: prompt.executionGeneration, deadline: request.deadline, since: now)
        return request
    }

    /// The run's status, read from `readAt` on: questions it lists that aren't up yet show, and the
    /// ones up here it no longer lists end. A status that ended the run ends them all.
    public mutating func reconcile(_ status: RunStatus, runID: String, readAt: Date, now: Date = .now) -> [Change] {
        let shown = asked.filter { $0.value.runID == runID && $0.value.since < readAt }
            .sorted { $0.value.since < $1.value.since }
        if status.isTerminal {
            for (id, _) in shown { asked[id] = nil }
            answered = answered.filter { $0.value.runID != runID }
            return shown.map { .drop(id: $0.key) }
        }
        let waiting = status.pendingControls.filter { $0.kind == RunPromptAnswer.Kind.clarify.rawValue }
        let open = Set(waiting.map(\.promptID))
        var changes: [Change] = []
        let ended = RequestSync.ended(shown: shown.map { RequestSync.Card(id: $0.key, deadline: $0.value.deadline) }, open: open, now: now)
        for (id, ending) in ended {
            asked[id] = nil
            changes.append(.end(id: id, ending))
        }
        for id in answered.keys where answered[id]?.runID == runID && !open.contains(id) {
            answered[id] = nil
        }
        for prompt in waiting {
            if let request = ask(prompt, runID: runID, now: now) { changes.append(.show(request)) }
        }
        return changes
    }

    /// Hermes stopped waiting on `id` (`clarify.settled`): how its card ends, or nil when there's
    /// none up here (answered here, or never shown).
    public mutating func settle(_ id: String, now: Date = .now) -> RequestSync.Ending? {
        answered[id] = nil
        guard let card = asked.removeValue(forKey: id) else { return nil }
        return RequestSync.ended(shown: [RequestSync.Card(id: id, deadline: card.deadline)], open: [], now: now).first?.ending
    }

    /// The person answered it here: where the answer goes, or nil when it isn't up.
    public mutating func answer(_ id: String) -> Asked? {
        guard let card = asked.removeValue(forKey: id) else { return nil }
        answered[id] = card
        return card
    }

    /// The answer didn't go: the card comes back. False when Hermes stopped waiting meanwhile.
    public mutating func unanswer(_ id: String) -> Bool {
        guard let card = answered.removeValue(forKey: id) else { return false }
        asked[id] = card
        return true
    }

    /// The turn is over: every question goes with it, its card without a word (the turn says
    /// how it ended). Returns the cards to take down.
    public mutating func endAll() -> [String] {
        defer {
            asked = [:]
            answered = [:]
        }
        return asked.sorted { $0.value.since < $1.value.since }.map(\.key)
    }
}

/// When a chat reads a running `/v1/runs` turn's status for a question its events didn't carry
/// (`RunQuestions`). Hermes sends nothing while a question waits, so a quiet stream is the cue.
public enum RunStatusWatch {
    /// Quiet this long, the stream may be waiting on a question it never announced.
    public static let quiet: TimeInterval = 10
    /// While Hermes's question step runs with no card up: the question is surely there.
    public static let asking: TimeInterval = 2
    /// While a card is up: to notice it was answered elsewhere, or expired.
    public static let cardUp: TimeInterval = 15

    /// Whether Hermes's question step (its `clarify` tool) runs in `turn`: the card is due.
    public static func asks(_ turn: AssistantTurn) -> Bool {
        turn.steps.contains { step in
            if case .tool(let tool) = step { return tool.name == "clarify" && tool.status == .running }
            return false
        }
    }

    /// Whether to read the status now. `heard` is the last event; `read` the last read's start.
    public static func due(now: Date, heard: Date, read: Date?, askingStep: Bool, cardUp: Bool) -> Bool {
        pause(now: now, heard: heard, read: read, askingStep: askingStep, cardUp: cardUp) == 0
    }

    /// How long until the next read is due, as things stand: 0 when it's due now. The watch sleeps
    /// this long, but no more than `longestSleep`, so an event, a question step or a card that comes
    /// meanwhile changes the timing within that, and a quiet run doesn't wake it every second.
    public static func pause(now: Date, heard: Date, read: Date?, askingStep: Bool, cardUp: Bool) -> TimeInterval {
        let interval = cardUp ? Self.cardUp : askingStep ? asking : quiet
        let since = max(heard, read ?? .distantPast)
        return max(0, interval - now.timeIntervalSince(since))
    }

    public static let longestSleep: TimeInterval = 2
}
