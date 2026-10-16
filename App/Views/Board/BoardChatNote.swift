import HermesKit
import SwiftUI

/// Cards Hermes added from a chat (`cardsAddedNote`): each with where it landed, and Open Board.
struct CardsAddedNote: View {
    let cards: [BoardAddedCard]
    let context: MemoryNoteContext

    private var workspace: BotWorkspace { context.workspace }

    /// The project whose board they're on: the cards', else the chat's.
    private var projectID: String? {
        if let id = cards.compactMap(\.projectID).first { return id }
        if let id = context.conversation.placement?.projectID { return id }
        return context.conversation.sessionID.flatMap { workspace.projects?.projectID(forSessionID: $0) }
    }

    private var title: String {
        let count = BoardCopy.cards(cards.count)
        if let projectID, let name = workspace.projects?.project(projectID)?.name {
            return String(localized: "Added \(count) to the \(name) board")
        }
        return String(localized: "Added \(count) to the board")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cards) { card in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.tertiaryText)
                            .frame(width: 5, height: 5)
                        Text(card.title)
                            .font(.footnote)
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(place(of: card))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 3)
            if let projectID, workspace.roster != nil {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                Button {
                    workspace.sidebarMode = .chats
                    workspace.selection = .board(projectID)
                } label: {
                    Text("Open Board")
                        .font(.subheadline)
                        .foregroundStyle(Theme.link)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// "Ready · Ada", "Ready", "After 2 cards": as it is now when the board is loaded.
    private func place(of card: BoardAddedCard) -> String {
        let board = projectID.map { workspace.board(for: $0) }
        let live = board?.card(card.id)
        let column = live?.column ?? card.column
        var waiting = card.isWaiting && column == "todo"
        if let live, let board {
            if case .waiting = board.state(of: live) { waiting = true } else { waiting = false }
        }
        if waiting {
            let count = live?.parentCount ?? card.parentCount
            return count == 1 ? String(localized: "After 1 card") : String(localized: "After \(count) cards")
        }
        let columnTitle = board?.columnTitle(column) ?? BoardColumn(key: column, label: column).title
        let assignee = live?.assignee ?? card.assignee
        let isHermes = assignee == nil || assignee == "default" || workspace.roster?.bot(named: assignee ?? "")?.isDefault == true
        guard !isHermes, let assignee else { return columnTitle }
        let name = board?.name(of: assignee) ?? assignee.capitalized
        return "\(columnTitle) · \(name)"
    }
}
