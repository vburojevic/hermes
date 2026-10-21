import Foundation

/// A Bot's turn that runs where no events reach the app (`docs/chat.md`, a turn going on
/// elsewhere): Hermes answers another Bot's message, or follows up on a routine's output, in a
/// one-shot `hermes -p <bot> chat`, which `session.active_list` doesn't list. Read from the Bot
/// Chat's stored rows, so its row, tile and face show it working.
public struct ElsewhereTurn: Hashable, Sendable {
    /// The Bot whose message it answers.
    public var answering: String?
    /// The routine whose output it follows up on.
    public var routine: String?
    /// The tool it's running: the last call stored without a result.
    public var runningTool: String?

    public init(answering: String? = nil, routine: String? = nil, runningTool: String? = nil) {
        self.answering = answering
        self.routine = routine
        self.runningTool = runningTool
    }

    /// The stored rows' last turn, when it runs elsewhere: nil when it ended or went quiet too long.
    public static func of(_ messages: [SessionMessage], now: Date = .now) -> ElsewhereTurn? {
        if TranscriptBuilder.awaitsReply(messages, now: now) {
            switch TranscriptBuilder.lastTurnRow(messages).flatMap(TranscriptBuilder.answeredElsewhere) {
            case .bot(let sender): return ElsewhereTurn(answering: sender)
            case .routine(let name): return ElsewhereTurn(routine: name)
            case nil: return ElsewhereTurn()
            }
        }
        guard TranscriptBuilder.endsMidTurn(messages, now: now) else { return nil }
        let answered = Set(messages.compactMap(\.toolCallID))
        let open = messages.last { $0.role == "assistant" && !$0.toolCalls.isEmpty }?
            .toolCalls.last { call in call.id.map { !answered.contains($0) } ?? false }
        var turn = ElsewhereTurn(runningTool: open?.name)
        // The message the turn started from says who it answers, all the way through.
        let start = messages.last { $0.role == "user" && $0.displayKind != "hidden" && $0.displayKind != "steer" }
        switch start.flatMap(TranscriptBuilder.answeredElsewhere) {
        case .bot(let sender): turn.answering = sender
        case .routine(let name): turn.routine = name
        case nil: break
        }
        return turn
    }
}
