import Foundation

/// A card Hermes added from a chat (`kanban_create`), for the turn's `cardsAddedNote`.
public struct BoardAddedCard: Sendable, Hashable, Identifiable {
    /// The gateway's id (`t_<hex>`).
    public var id: String
    public var title: String
    /// Where it landed: `ready`, `todo` (waiting for cards before it), `triage`, …
    public var column: String
    public var assignee: String?
    /// How many cards it waits for (the call's `parents`).
    public var parentCount: Int
    /// It waits for a card that isn't done yet.
    public var isWaiting: Bool
    public var projectID: String?
    public var board: String?

    public init(id: String, title: String, column: String, assignee: String? = nil, parentCount: Int = 0, isWaiting: Bool = false,
                projectID: String? = nil, board: String? = nil) {
        self.id = id
        self.title = title
        self.column = column
        self.assignee = assignee
        self.parentCount = parentCount
        self.isWaiting = isWaiting
        self.projectID = projectID
        self.board = board
    }
}

extension ToolActivity {
    /// The card this step added, when it was a `kanban_create` that succeeded.
    public var addedCard: BoardAddedCard? {
        guard name == "kanban_create", status == .succeeded else { return nil }
        let args = arguments ?? .object([:])
        guard let text = output ?? result, let data = text.data(using: .utf8),
              let reply = JSONValue.parse(data),
              reply["ok"]?.boolValue != false, let id = reply["task_id"]?.stringValue,
              let title = args["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let parents = args["parents"].items.compactMap(\.stringValue)
        let column = reply["status"]?.stringValue ?? "ready"
        return BoardAddedCard(
            id: id,
            title: title,
            column: column,
            assignee: args["assignee"]?.stringValue,
            parentCount: parents.count,
            isWaiting: reply["gated"]?.boolValue == true || (column == "todo" && !parents.isEmpty),
            projectID: reply["project_id"]?.stringValue ?? args["project_id"]?.stringValue ?? args["project"]?.stringValue,
            board: args["board"]?.stringValue
        )
    }
}

extension AssistantTurn {
    /// Every card the turn added, in order.
    public var addedCards: [BoardAddedCard] {
        steps.compactMap { step in
            if case .tool(let tool) = step { return tool.addedCard }
            return nil
        }
    }
}
