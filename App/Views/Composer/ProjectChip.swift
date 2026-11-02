import HermesKit
import SwiftUI

/// The composer's project chip (`projectChip` in `composerProject`): the project a chat runs in.
/// On a new chat it opens Run In; on a chat that's running in a project it opens a menu with Open
/// Project and Move to Project…. The branch shows on iPad and Mac (no room on iPhone).
struct ProjectChip: View {
    let conversation: ConversationModel
    let workspace: BotWorkspace

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var projects: ProjectsModel { workspace.projects }

    private var showsBranch: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    /// A chat that hasn't started yet.
    private var isNew: Bool { conversation.sessionID == nil }

    /// The project an existing chat runs in.
    private var runningProjectID: String? {
        if let id = conversation.liveWorkspace?.projectID { return id }
        if let id = conversation.sessionID, let project = projects.projectID(forSessionID: id) { return project }
        return conversation.stableKey.flatMap { projects.projectID(forSessionID: $0) }
    }

    var body: some View {
        if projects.isAvailable, !conversation.isBotChat {
            if isNew {
                let placement = conversation.placement ?? projects.defaultPlacement
                let branch = placement.newWorktree ? String(localized: "new worktree") : placement.branch ?? projects.branch(of: placement.cwd)
                Button {
                    projects.runInConversation = conversation
                } label: {
                    label(projectID: placement.projectID, branch: branch)
                }
                .buttonStyle(.plain)
                .help("Where this chat runs")
                .accessibilityLabel("Runs in")
                .accessibilityValue(accessibilityValue(projectID: placement.projectID))
                .accessibilityHint("Choose a project or folder for this chat")
                .accessibilityShowsLargeContentViewer {
                    Label(largeContentTitle(projectID: placement.projectID, branch: branch), systemImage: "folder")
                }
            } else if let projectID = runningProjectID {
                let branch = conversation.liveWorkspace?.branch ?? projects.branch(of: conversation.liveWorkspace?.cwd)
                Menu {
                    Button("Open Project", systemImage: "folder") {
                        projects.focusLane = nil
                        workspace.selection = .project(projectID)
                    }
                    Button("Move to Project…", systemImage: "arrow.right.doc.on.clipboard") {
                        projects.movingSession = currentSession
                    }
                } label: {
                    label(projectID: projectID, branch: branch)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Runs in")
                .accessibilityValue(accessibilityValue(projectID: projectID))
                .accessibilityShowsLargeContentViewer {
                    Label(largeContentTitle(projectID: projectID, branch: branch), systemImage: "folder")
                }
            }
        }
    }

    private var currentSession: HermesSession? {
        guard let key = conversation.stableKey else { return nil }
        return workspace.session(forKey: key) ?? conversation.sessionID.map { HermesSession(id: $0) }
    }

    private func label(projectID: String?, branch: String?) -> some View {
        HStack(spacing: 6) {
            if let projectID {
                ProjectTile(appearance: projects.appearance(projectID), size: 20)
                Text(projects.project(projectID)?.name ?? String(localized: "Project"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if showsBranch, let branch, !branch.isEmpty {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                    // Where room runs out, the branch gives way before the project's name.
                    Text(branch)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Text("No Project")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.leading, projectID == nil ? 11 : 6)
        .padding(.trailing, 11)
        .frame(minHeight: 32)
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .contentShape(Capsule())
    }

    /// What a long press shows large: the name and branch the chip draws, since the branch is the
    /// first part to truncate (docs/composer.md §1).
    private func largeContentTitle(projectID: String?, branch: String?) -> String {
        guard let projectID else { return String(localized: "No Project") }
        let name = projects.project(projectID)?.name ?? String(localized: "Project")
        guard showsBranch, let branch, !branch.isEmpty else { return name }
        return "\(name) · \(branch)"
    }

    private func accessibilityValue(projectID: String?) -> String {
        guard let projectID else { return String(localized: "No Project") }
        return projects.project(projectID)?.name ?? ""
    }
}
