import HermesKit
import SwiftUI

/// A project in a picker (`projectPickRow*`): tile, name, primary folder, and a check when picked.
struct ProjectPickRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let tile: AnyView
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Run In (`projectPicker`): where a new chat runs — a project, No Project (the gateway's default
/// folder) or a new project — and, in a git project, the branch or a new worktree. Picking a
/// project also makes it the active one, so the next new chat starts there too.
struct RunInSheet: View {
    let workspace: BotWorkspace
    let conversation: ConversationModel
    let onDone: () -> Void

    @State private var projectID: String?
    @State private var worktree: GitWorktree?
    @State private var newWorktree = false
    @State private var worktrees: [GitWorktree] = []
    @State private var creating = false

    private var projects: ProjectsModel { workspace.projects }
    private var primaryPath: String? { projectID.flatMap { projects.project($0)?.primaryPath } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    ForEach(projects.activeProjects) { project in
                        ProjectPickRow(
                            title: project.name,
                            subtitle: projects.displayPath(project.primaryPath),
                            isSelected: projectID == project.id,
                            tile: AnyView(ProjectTile(appearance: ProjectAppearance(project), size: 32))
                        ) {
                            select(project.id)
                        }
                    }
                    ProjectPickRow(
                        title: String(localized: "No Project"),
                        subtitle: String(localized: "The gateway's default folder"),
                        isSelected: projectID == nil,
                        tile: AnyView(OutlineTile(symbol: "folder", size: 32))
                    ) {
                        select(nil)
                    }
                    Button("New Project…") { creating = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.link)
                }
                if projectID != nil, primaryPath != nil {
                    Section("Branch") {
                        Picker("Run on", selection: $worktree) {
                            ForEach(worktrees) { tree in
                                Text(tree.branch ?? ProjectPath.lastComponent(tree.path)).tag(Optional(tree))
                            }
                        }
                        .disabled(newWorktree || worktrees.count < 2)
                        Toggle(isOn: $newWorktree) {
                            Text("Work in a new worktree")
                            Text("Keeps this chat's edits off \(worktrees.first(where: \.isMain)?.branch ?? "main") until you merge.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Run In")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    #if os(macOS)
                    Button("Cancel", action: onDone)
                    #else
                    Button(role: .cancel, action: onDone)
                    #endif
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(macOS)
                    Button("Done", action: apply)
                        .keyboardShortcut(.defaultAction)
                    #else
                    Button(role: .confirm, action: apply)
                        .tint(Theme.ink)
                    #endif
                }
            }
            .task { populate() }
            .task(id: primaryPath) { await loadWorktrees() }
            .sheet(isPresented: $creating) {
                ProjectEditorSheet(workspace: workspace, target: .new(folder: nil)) { id in
                    creating = false
                    if let id { select(id) }
                }
                #if os(macOS)
                .frame(width: 480).frame(minHeight: 560)
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 440).frame(minHeight: 420)
        #endif
    }

    private func populate() {
        let current = conversation.placement ?? projects.defaultPlacement
        projectID = current.projectID
        newWorktree = current.newWorktree
    }

    private func select(_ id: String?) {
        projectID = id
        worktree = nil
        newWorktree = false
    }

    private func loadWorktrees() async {
        guard let primaryPath else { worktrees = []; return }
        let found = await projects.worktrees(of: primaryPath)
        worktrees = found.isEmpty ? [GitWorktree(path: primaryPath, branch: projects.branch(of: primaryPath), isMain: true)] : found
        let current = conversation.placement
        worktree = worktrees.first { $0.path == current?.cwd } ?? worktrees.first(where: \.isMain) ?? worktrees.first
    }

    private func apply() {
        if let projectID {
            var placement = projects.placement(in: projectID)
            if newWorktree {
                placement.newWorktree = true
                placement.branch = nil
            } else if let worktree, !worktree.isMain {
                placement.cwd = worktree.path
                placement.branch = worktree.branch
            }
            conversation.placement = placement
        } else {
            conversation.placement = .noProject
        }
        Task { await projects.setActive(projectID) }
        onDone()
    }
}

/// Move to Project… (`moveToProject`): moves a chat's workspace to another project's primary
/// folder (`session.workspace.move`). A running turn follows it there.
struct MoveToProjectSheet: View {
    let workspace: BotWorkspace
    let session: HermesSession
    let onDone: () -> Void

    @State private var target: String?
    @State private var isMoving = false
    @State private var error: String?
    @State private var creating = false

    private var projects: ProjectsModel { workspace.projects }
    private var current: String? { projects.projectID(forSession: session) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Text("“\(session.displayTitle)”")
                            .font(.headline)
                            .foregroundStyle(Theme.primaryText)
                            .multilineTextAlignment(.center)
                        Text("Hermes moves its workspace; a running turn follows.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(projects.activeProjects) { project in
                        ProjectPickRow(
                            title: project.name,
                            subtitle: projects.displayPath(project.primaryPath),
                            isSelected: target == project.id,
                            tile: AnyView(ProjectTile(appearance: ProjectAppearance(project), size: 32))
                        ) {
                            target = project.id
                            error = nil
                        }
                        .disabled(project.primaryPath == nil)
                    }
                    Button("New Project…") { creating = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.link)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .font(.subheadline)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Move to Project")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    #if os(macOS)
                    Button("Cancel", action: onDone)
                    #else
                    Button(role: .cancel, action: onDone)
                    #endif
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        #if os(macOS)
                        Button("Move", action: move)
                            .keyboardShortcut(.defaultAction)
                            .disabled(target == nil || target == current)
                        #else
                        Button(role: .confirm, action: move)
                            .tint(Theme.ink)
                            .disabled(target == nil || target == current)
                            .accessibilityLabel("Move")
                        #endif
                    }
                }
            }
            .onAppear { if target == nil { target = current } }
            .interactiveDismissDisabled(isMoving)
            .sheet(isPresented: $creating) {
                ProjectEditorSheet(workspace: workspace, target: .new(folder: nil)) { id in
                    creating = false
                    if let id { target = id }
                }
                #if os(macOS)
                .frame(width: 480).frame(minHeight: 560)
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 440).frame(minHeight: 380)
        #endif
    }

    private func move() {
        guard let target, target != current else { return }
        isMoving = true
        Task {
            defer { isMoving = false }
            do {
                try await projects.move(session, to: target)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
