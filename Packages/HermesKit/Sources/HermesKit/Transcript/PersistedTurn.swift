import Foundation

/// Where a turn's rows are in the stored chat, as Hermes reports them when the turn ends
/// (`message.complete.persisted_turn`, agent/persisted_turn_receipt.py): the row of the message it
/// answers, every row it committed, and its reply's row once that is committed. Hermes keys a
/// streamed reply to its stored rows by these ids, "instead of comparing words"; so does the app
/// (`docs/chat.md` §2, one turn in one place).
public struct PersistedTurn: Sendable, Equatable {
    /// The stored row of the message the turn answers.
    public var userRowID: Int?
    /// The turn's committed rows, in order.
    public var rowIDs: [Int]
    /// The reply's row, when it was committed by the time the turn ended. A busy database queues
    /// the write, and the reply lands a moment later without it.
    public var finalAssistantRowID: Int?
    /// Every row of the turn was committed, the reply included.
    public var complete: Bool

    public init(userRowID: Int? = nil, rowIDs: [Int] = [], finalAssistantRowID: Int? = nil, complete: Bool = false) {
        self.userRowID = userRowID
        self.rowIDs = rowIDs
        self.finalAssistantRowID = finalAssistantRowID
        self.complete = complete
    }

    public init?(_ value: JSONValue?) {
        guard let value, case .object = value else { return nil }
        let rows: [Int]
        if case .array(let list)? = value["row_ids"] { rows = list.compactMap(\.truncatedIntValue) } else { rows = [] }
        let user = value["user_row_id"]?.truncatedIntValue
        guard !rows.isEmpty || user != nil else { return nil }
        self.init(userRowID: user, rowIDs: rows, finalAssistantRowID: value["final_assistant_row_id"]?.truncatedIntValue,
                  complete: value["complete"]?.boolValue ?? false)
    }

    /// Whether `messages` hold the whole turn: its reply's row is there. `nil` when the receipt
    /// can't say (the reply wasn't committed as the turn ended); the stored rows decide then
    /// (`TranscriptBuilder.holdsTurn`).
    public func isStored(in messages: [SessionMessage]) -> Bool? {
        guard let final = finalAssistantRowID else { return nil }
        return messages.contains { $0.id == final }
    }
}
