import HermesKit
import SwiftUI

/// The sidebar's Projects section in Chats mode (`blocks/sidebar.elyx` → `sidebar`, `macSidebar`):
/// pinned and recent projects, at most five, then All Projects. On the Mac each project is a
/// disclosure row whose lanes (branch or worktree) indent under it.
struct ProjectSidebarSection: View {
    let workspace: BotWorkspace
    var onNavigate: () -> Void = {}

    @AppStorage("sidebar.projectsExpanded") private var isExpanded = true

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        if projects.isAvailable {
            header
            if isExpanded {
                ForEach(projects.sidebarProjects) { node in
                    #if os(macOS)
                    MacProjectRows(workspace: workspace, node: node)
                    #else
                    ProjectSidebarRow(workspace: workspace, node: node, onNavigate: onNavigate)
                    #endif
                }
                allProjectsRow
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(Theme.snappy) { isExpanded.toggle() }
        } label: {
            HStack {
                Text("Projects")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .font(SidebarMetrics.sectionFont)
            .foregroundStyle(Theme.tertiaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .listRowInsets(SidebarMetrics.rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityLabel("Projects")
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityHint(isExpanded ? String(localized: "Hides your projects") : String(localized: "Shows your projects"))
        .accessibilityAddTraits(.isHeader)
    }

    private var allProjectsRow: some View {
        SidebarRow(isSelected: workspace.selection == .allProjects) {
            workspace.selection = .allProjects
            onNavigate()
        } label: {
            HStack(spacing: SidebarMetrics.rowPadding) {
                OutlineTile(symbol: "square.grid.2x2", size: ProjectSidebarRow.tileSize)
                    #if os(macOS)
                    .padding(.leading, MacProjectRows.disclosureWidth)
                    #endif
                Text("All Projects")
                    .font(SidebarMetrics.titleFont)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 4)
                Text(projects.activeProjects.count, format: .number)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .accessibilityLabel(String(localized: "All Projects, \(projects.activeProjects.count) projects"))
    }
}

/// One project in the iPhone drawer or iPad sidebar (`projectRow`): tile, name, then a working dot
/// or the chat count. Long-press for the project menu.
struct ProjectSidebarRow: View {
    let workspace: BotWorkspace
    let node: ProjectNode
    var onNavigate: () -> Void = {}

    #if os(macOS)
    static let tileSize: CGFloat = 16
    #else
    static let tileSize: CGFloat = 24
    #endif

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        let isSelected = workspace.selection == .project(node.id)
        SidebarRow(isSelected: isSelected) {
            workspace.selection = .project(node.id)
            onNavigate()
        } label: {
            ProjectRowLabel(workspace: workspace, node: node, isSelected: isSelected)
        }
        .contextMenu {
            ProjectMenuItems(workspace: workspace, projectID: node.id)
        }
    }
}

/// Tile, name, working dot or count, for the sidebar rows.
struct ProjectRowLabel: View {
    let workspace: BotWorkspace
    let node: ProjectNode
    var isSelected = false

    var body: some View {
        let projects = workspace.projects!
        let working = projects.isWorking(node.id)
        HStack(spacing: SidebarMetrics.rowPadding) {
            ProjectTile(appearance: projects.appearance(node.id), size: ProjectSidebarRow.tileSize)
            Text(projects.project(node.id)?.name ?? node.label)
                .font(isSelected ? SidebarMetrics.selectedTitleFont : SidebarMetrics.navFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            if working {
                StatusDot(color: Theme.warning, pulsing: true)
            } else {
                Text(node.sessionCount, format: .number)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectRowLabel.accessibilityText(name: projects.project(node.id)?.name ?? node.label, count: node.sessionCount, working: working))
    }

    /// "Hermes App, project, 9 chats" or "Hermes App, project, working".
    static func accessibilityText(name: String, count: Int, working: Bool) -> String {
        working
            ? String(localized: "\(name), project, working")
            : String(localized: "\(name), project, \(count) chats")
    }
}

#if os(macOS)
/// A project on the Mac (`macProjectRow*`, `macLaneRow`): a disclosure arrow that shows its lanes;
/// a lane opens the project home scrolled to it.
struct MacProjectRows: View {
    let workspace: BotWorkspace
    let node: ProjectNode

    static let disclosureWidth: CGFloat = 16

    private var projects: ProjectsModel { workspace.projects }
    private var isExpanded: Bool { projects.expandedIDs.contains(node.id) }

    var body: some View {
        let isSelected = workspace.selection == .project(node.id) && projects.focusLane == nil
        SidebarRow(isSelected: isSelected) {
            projects.focusLane = nil
            workspace.selection = .project(node.id)
        } label: {
            HStack(spacing: 0) {
                Button {
                    toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: Self.disclosureWidth, height: SidebarMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? String(localized: "Collapse \(node.label)") : String(localized: "Expand \(node.label)"))
                ProjectRowLabel(workspace: workspace, node: node, isSelected: isSelected)
            }
        }
        .contextMenu {
            ProjectMenuItems(workspace: workspace, projectID: node.id)
        }
        .task(id: isExpanded) {
            if isExpanded, projects.details[node.id] == nil { await projects.loadDetail(node.id) }
        }
        if isExpanded {
            ForEach(lanes) { lane in
                laneRow(lane)
            }
        }
    }

    /// Branches and worktrees with chats (task worktrees live on the project home).
    private var lanes: [ProjectLane] {
        (projects.details[node.id] ?? node).lanes.filter { $0.kind != .tasks && (!$0.sessions.isEmpty || projects.details[node.id] == nil) }
    }

    private func laneRow(_ lane: ProjectLane) -> some View {
        let isSelected = workspace.selection == .project(node.id) && projects.focusLane == lane.id
        return SidebarRow(isSelected: isSelected) {
            projects.focusLane = lane.id
            workspace.selection = .project(node.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Text(lane.displayName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !lane.sessions.isEmpty {
                    Text(lane.sessions.count, format: .number)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.leading, Self.disclosureWidth + 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(lane.displayName), \(lane.kind == .main ? String(localized: "branch") : String(localized: "worktree")), \(lane.sessions.count) chats"))
    }

    private func toggle() {
        withAnimation(Theme.snappy) {
            if isExpanded { projects.expandedIDs.remove(node.id) } else { projects.expandedIDs.insert(node.id) }
        }
    }
}
#endif

/// The project menu (`projectMenu`): Edit, Add Folder, Copy Path, Pin, then Archive and Delete.
struct ProjectMenuItems: View {
    let workspace: BotWorkspace
    let projectID: String

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        Button("Edit Project…", systemImage: "pencil") {
            projects.editing = .edit(projectID)
        }
        Button("Add Folder…", systemImage: "folder") {
            projects.addingFolder = projectID
        }
        if let path = projects.project(projectID)?.primaryPath {
            Button("Copy Path", systemImage: "doc.on.doc") {
                Pasteboard.copy(path)
            }
        }
        if projects.isPinned(projectID) {
            Button("Unpin from Sidebar", systemImage: "pin.slash") {
                projects.setPinned(projectID, false)
            }
        } else {
            Button("Pin to Sidebar", systemImage: "pin") {
                projects.setPinned(projectID, true)
            }
        }
        Divider()
        Button("Archive", systemImage: "archivebox") {
            Task { try? await projects.archive(projectID) }
        }
        Button("Delete Project…", systemImage: "trash", role: .destructive) {
            projects.deleting = projectID
        }
    }
}

extension ProjectLane {
    /// What a lane is called: the branch for the main checkout and for a worktree whose chats all
    /// recorded one (the gateway names worktree lanes by folder), "Task worktrees" for kanban.
    var displayName: String {
        switch kind {
        case .main: return label
        case .tasks: return String(localized: "Task worktrees")
        case .worktree:
            let branches = Set(sessions.compactMap(\.gitBranch))
            if branches.count == 1, let branch = branches.first, !branch.isEmpty { return branch }
            return label
        }
    }
}
