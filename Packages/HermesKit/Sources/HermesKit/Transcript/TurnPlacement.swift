import Foundation

/// One turn, one place (`docs/chat.md` §2). A turn this device showed live that ended before its
/// stored rows were whole (a busy database writes the reply late; a lost run never writes it) is
/// kept on screen until they are. Meanwhile a read of the chat brings the part Hermes did store:
/// the same turn, which is never drawn a second time, above or below it.
public enum TurnPlacement {
    /// `built`, folded from `messages`, with the turn on screen (`shown`: the person's message
    /// while it isn't stored, then the reply) where its stored rows are. Those are found by the
    /// contract's ids, never by words or by being last: the row of the message the turn answers
    /// (`userRowID`, from `persisted_turn`), else the first message from the person stored after
    /// `after`, the newest row from before the turn. Nothing of it stored yet, it goes at the end.
    ///
    /// The turn on screen takes the stored copy's place. A finished one is whole already; one
    /// that ended without hearing how (failed, stopped, lost) keeps the stored copy's steps when
    /// those went further than what it heard.
    public static func place(_ shown: [TranscriptItem], userRowID: Int?, after: Int?,
                             in built: [TranscriptItem], messages: [SessionMessage]) -> [TranscriptItem] {
        guard let askID = askRowID(userRowID: userRowID, after: after, in: messages),
              let ask = built.firstIndex(where: { $0.id == "m\(askID)" })
        else { return built + shown }
        // The stored copy: the replies after the message, up to the person's next one.
        let end = built[(ask + 1)...].firstIndex(where: isPersonsMessage) ?? built.endIndex
        let copies = built[(ask + 1)..<end].indices.filter { if case .assistant = built[$0] { true } else { false } }
        var placed = built
        for case .assistant(var turn) in shown {
            if let first = copies.first, case .assistant(let stored) = built[first] {
                turn = keeping(turn, over: stored)
            }
            for index in copies.reversed() { placed.remove(at: index) }
            placed.insert(.assistant(turn), at: copies.first ?? end)
        }
        return placed
    }

    /// The stored row of the message the turn answers.
    static func askRowID(userRowID: Int?, after: Int?, in messages: [SessionMessage]) -> Int? {
        if let userRowID { return messages.contains { $0.id == userRowID } ? userRowID : nil }
        return messages.first { message in
            guard message.role == "user", message.displayKind != "hidden", message.displayKind != "steer",
                  let id = message.id else { return false }
            return after.map { id > $0 } ?? true
        }?.id
    }

    private static func isPersonsMessage(_ item: TranscriptItem) -> Bool {
        if case .user(let entry) = item { !entry.isSteer } else { false }
    }

    /// A finished turn is whole; one that ended without hearing how keeps whichever copy went
    /// further, with its own identity and ending.
    private static func keeping(_ shown: AssistantTurn, over stored: AssistantTurn) -> AssistantTurn {
        guard shown.state != .complete, stored.steps.count > shown.steps.count else { return shown }
        var turn = shown
        turn.steps = stored.steps
        turn.plan = turn.plan.isEmpty ? stored.plan : turn.plan
        if turn.answer.isEmpty { turn.answer = stored.answer }
        return turn
    }
}
