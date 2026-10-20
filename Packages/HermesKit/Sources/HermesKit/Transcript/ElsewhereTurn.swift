import Foundation

/// A Bot's turn that runs where no events reach the app (`docs/chat.md`, a turn going on
/// elsewhere): Hermes answers another Bot's message in a one-shot `hermes -p <bot> chat`, which
/// `session.active_list` doesn't list. Read from the Bot Chat's stored rows, so its row, tile and
/// face show it working.
public struct ElsewhereTurn: Hashable, Sendable {
    /// The Bot whose message it answers, when its answer hasn't started in the stored rows yet.
    public var answering: String?
    /// The tool it's running: the last call stored without a result.
    public var runningTool: String?

    public init(answering: String? = nil, runningTool: String? = nil) {
        self.answering = answering
        self.runningTool = runningTool
    }

    /// The stored rows' last turn, when it runs elsewhere: nil when it ended or went quiet too long.
    public static func of(_ messages: [SessionMessage], now: Date = .now) -> ElsewhereTurn? {
        if TranscriptBuilder.awaitsReplyToBot(messages, now: now) {
            let sender = TranscriptBuilder.lastTurnRow(messages).flatMap {
                BotMentions.parseAgentMessage($0.content.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return ElsewhereTurn(answering: sender?.senderName)
        }
        guard TranscriptBuilder.endsMidTurn(messages, now: now) else { return nil }
        let answered = Set(messages.compactMap(\.toolCallID))
        let open = messages.last { $0.role == "assistant" && !$0.toolCalls.isEmpty }?
            .toolCalls.last { call in call.id.map { !answered.contains($0) } ?? false }
        return ElsewhereTurn(runningTool: open?.name)
    }
}
