import HermesKit
import SwiftUI

/// A new chat inside a project (`projectNewChat`): the project's tile, "New chat in Hermes App",
/// where it runs, and suggestions from what Hermes knows about it.
struct ProjectNewChatHero: View {
    let workspace: BotWorkspace
    @Bindable var conversation: ConversationModel
    let projectID: String
    var composerFocused: Binding<Bool>

    @State private var appeared = false

    private var projects: ProjectsModel { workspace.projects }
    private var placement: ChatPlacement { conversation.placement ?? projects.defaultPlacement }
    private var name: String { projects.project(projectID)?.name ?? "" }

    var body: some View {
        VStack(spacing: 14) {
            ProjectTile(appearance: projects.appearance(projectID), size: 56)
                .scaleEffect(appeared ? 1 : 0.85)
            VStack(spacing: 6) {
                Text("New chat in \(name)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                Text(runsIn)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            CenteredFlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button {
                        conversation.draft = suggestion.prompt
                        composerFocused.wrappedValue = true
                    } label: {
                        ChipLabel(title: suggestion.title, symbol: suggestion.symbol, isActive: true)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 6)
            .opacity(appeared ? 1 : 0)
        }
        .padding(.horizontal, 20)
        .task(id: "\(placement.cwd ?? "")|\(projects.isAvailable)") {
            if let cwd = placement.cwd {
                await projects.loadFacts(projects.project(projectID)?.primaryPath ?? cwd)
                await projects.loadBranch(cwd)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) { appeared = true }
        }
    }

    /// "Runs in ~/Code/hermes-app on main".
    private var runsIn: String {
        let path = projects.displayPath(placement.cwd ?? projects.project(projectID)?.primaryPath)
        if placement.newWorktree { return String(localized: "Runs in a new worktree of \(path)") }
        if let branch = placement.branch ?? projects.branch(of: placement.cwd) {
            return String(localized: "Runs in \(path) on \(branch)")
        }
        return String(localized: "Runs in \(path)")
    }

    private var suggestions: [(title: String, symbol: String, prompt: String)] {
        var list: [(String, String, String)] = []
        let facts = (projects.project(projectID)?.primaryPath).flatMap { projects.facts[$0] ?? nil }
        if let command = facts?.verifyCommands.first {
            list.append((String(localized: "Run the tests"), "checkmark.square", String(localized: "Run `\(command)` and fix anything that fails.")))
        }
        if projects.branch(of: placement.cwd) != nil || placement.branch != nil {
            list.append((String(localized: "Review my changes"), "arrow.triangle.branch", String(localized: "Review my uncommitted changes and point out anything that looks wrong.")))
        }
        list.append((String(localized: "Explain the codebase"), "book.closed", String(localized: "Give me a tour of this codebase: how it's organised and where to start.")))
        return list.map { (title: $0.0, symbol: $0.1, prompt: $0.2) }
    }
}

/// Chips that wrap onto centred lines.
struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
