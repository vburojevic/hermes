import HermesKit
import SwiftUI

/// All Projects (`allProjects`): projects by last activity, the git folders Hermes found that
/// aren't projects yet ("Found on Studio Mac"), then Archived.
struct AllProjectsView: View {
    let workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var adding: Set<String> = []
    @State private var error: String?

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        content
            .navigationTitle("Projects")
            .toolbar { toolbar }
            .task(id: projects.isAvailable) {
                await projects.loadDiscovered()
            }
            .refreshable {
                async let tree: Void = projects.refresh()
                async let found: Void = projects.loadDiscovered()
                _ = await (tree, found)
            }
            .alert("Couldn't add the folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        // Projects run on Bot Mode and a Hermes that has them (`docs/setup.md` §4.9).
        if workspace.botModeIsDown {
            BotModeSetupMessage(workspace: workspace, feature: GatewaySetup.ID.projects, title: String(localized: "Projects"), symbol: "folder")
        } else if projects.hasLoaded, !projects.isAvailable {
            SetupMessage(status: GatewaySetup.projects(workspace.setup.facts), symbol: "folder",
                         check: { await projects.refresh() })
        } else if projects.hasLoaded, projects.projectsByActivity.isEmpty, let lastError = projects.lastError {
            StateMessage(symbol: "folder", title: String(localized: "Projects aren't available"), message: lastError,
                         actionTitle: String(localized: "Try Again")) {
                Task { await projects.refresh() }
            }
        } else {
            platformContent
        }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(macOS)
        macGrid
        #else
        list
        #endif
    }

    #if os(macOS)
    /// The Mac (`macAllProjects`): a grid of project cards, then the folders Hermes found.
    private var macGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                if projects.projectsByActivity.isEmpty, projects.hasLoaded {
                    Text("No projects yet. A project groups the chats that run in its folders.")
                        .foregroundStyle(Theme.secondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(projects.projectsByActivity) { node in
                        projectCard(node)
                    }
                }
                if !projects.suggestedRepos.isEmpty {
                    Text("Found on \(workspace.bot.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(projects.suggestedRepos.enumerated()), id: \.element.id) { index, repo in
                            if index > 0 { Divider().padding(.leading, 40) }
                            RepoSuggestionRow(repo: repo, displayPath: projects.displayPath(repo.root), isAdding: adding.contains(repo.root)) {
                                add(repo)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                    .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if !projects.archivedProjects.isEmpty {
                    NavigationLink {
                        ArchivedProjectsView(workspace: workspace)
                    } label: {
                        Label("Archived · \(projects.archivedProjects.count)", systemImage: "archivebox")
                    }
                    .buttonStyle(.link)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.groupedBackground)
        // The grid draws its own large title.
        .toolbar(removing: .title)
    }

    /// A project card: tile, name, folder in mono, chats and when.
    private func projectCard(_ node: ProjectNode) -> some View {
        let project = projects.project(node.id)
        let working = projects.isWorking(node.id)
        return Button {
            projects.focusLane = nil
            workspace.selection = .project(node.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    ProjectTile(appearance: projects.appearance(node.id), size: 36)
                    Spacer()
                    if working { StatusDot(color: Theme.warning) }
                }
                .padding(.bottom, 8)
                Text(project?.name ?? node.label)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if let path = project?.primaryPath ?? node.path {
                    Text(projects.displayPath(path))
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text([ProjectCount.chats(node.sessionCount), node.lastActive.map(LaneChatRow.time)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu { ProjectMenuItems(workspace: workspace, projectID: node.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectRowLabel.accessibilityText(name: project?.name ?? node.label, count: node.sessionCount, working: working))
        .accessibilityHint(subtitle(node))
        .accessibilityAddTraits(.isButton)
    }
    #endif

    private var list: some View {
        List {
            Section {
                if projects.projectsByActivity.isEmpty, projects.hasLoaded {
                    Text("No projects yet. A project groups the chats that run in its folders.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    ForEach(projects.projectsByActivity) { node in
                        projectRow(node)
                    }
                }
            }
            if !projects.suggestedRepos.isEmpty {
                Section {
                    ForEach(projects.suggestedRepos) { repo in
                        RepoSuggestionRow(repo: repo, displayPath: projects.displayPath(repo.root), isAdding: adding.contains(repo.root)) {
                            add(repo)
                        }
                    }
                } header: {
                    Text("Found on \(workspace.bot.name)")
                } footer: {
                    Text("Git folders Hermes has worked in that aren't a project yet. Add one to group its chats.")
                }
            }
            if !projects.archivedProjects.isEmpty {
                Section {
                    NavigationLink {
                        ArchivedProjectsView(workspace: workspace)
                    } label: {
                        LabeledContent("Archived") {
                            Text(projects.archivedProjects.count, format: .number)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    private func projectRow(_ node: ProjectNode) -> some View {
        let project = projects.project(node.id)
        let working = projects.isWorking(node.id)
        return Button {
            projects.focusLane = nil
            workspace.selection = .project(node.id)
        } label: {
            HStack(spacing: 12) {
                ProjectTile(appearance: projects.appearance(node.id), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? node.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle(node))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if working {
                    StatusDot(color: Theme.warning)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ProjectMenuItems(workspace: workspace, projectID: node.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectRowLabel.accessibilityText(name: project?.name ?? node.label, count: node.sessionCount, working: working))
        .accessibilityHint(subtitle(node))
        .accessibilityAddTraits(.isButton)
    }

    /// "~/Code/hermes-app · 9 chats · now".
    private func subtitle(_ node: ProjectNode) -> String {
        var parts: [String] = []
        if let path = projects.project(node.id)?.primaryPath ?? node.path { parts.append(projects.displayPath(path)) }
        parts.append(ProjectCount.chats(node.sessionCount))
        if let date = node.lastActive, node.sessionCount > 0 { parts.append(LaneChatRow.time(date)) }
        return parts.joined(separator: " · ")
    }

    private func add(_ repo: DiscoveredRepo) {
        adding.insert(repo.root)
        Task {
            defer { adding.remove(repo.root) }
            do {
                _ = try await projects.create(name: repo.label, folders: [repo.root], primary: repo.root, appearance: .suggested(for: repo.label), use: false)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onToggleSidebar {
            ToolbarItem(placement: .navigation) {
                SidebarButton(action: onToggleSidebar)
            }
            .sidebarButtonGlass()
        }
        #if os(macOS)
        // The trailing side on the Mac.
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .automatic) {
            Button("New Project…") {
                projects.editing = .new(folder: nil)
            }
            .inkDefaultButton()
            .buttonBorderShape(.capsule)
        }
        #else
        ToolbarItem(placement: .primaryAction) {
            Button {
                projects.editing = .new(folder: nil)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New Project")
            .help("New Project")
        }
        #endif
    }
}

/// A folder Hermes found (`repoSuggestionRow`): its name, path and chats, and Add.
struct RepoSuggestionRow: View {
    let repo: DiscoveredRepo
    let displayPath: String
    let isAdding: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.label)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text("\(displayPath) · \(ProjectCount.chats(repo.sessions))")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: add) {
                if isAdding {
                    Spinner()
                } else {
                    Text("Add")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(Theme.primaryText)
            .disabled(isAdding)
            .accessibilityLabel("Add \(repo.label) as a project")
        }
    }
}

/// Archived projects, with Restore and Delete.
struct ArchivedProjectsView: View {
    let workspace: BotWorkspace

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        List {
            ForEach(projects.archivedProjects) { project in
                HStack(spacing: 12) {
                    ProjectTile(appearance: ProjectAppearance(project), size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .foregroundStyle(Theme.primaryText)
                        if let path = project.primaryPath {
                            Text(projects.displayPath(path))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Restore") {
                        Task { try? await projects.archive(project.id, restore: true) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                .contextMenu {
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        Task { try? await projects.archive(project.id, restore: true) }
                    }
                    Button("Delete Project…", systemImage: "trash", role: .destructive) {
                        projects.deleting = project.id
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        projects.deleting = project.id
                    }
                }
            }
        }
        .navigationTitle("Archived")
        .overlay {
            if projects.archivedProjects.isEmpty {
                ContentUnavailableView("No Archived Projects", systemImage: "archivebox")
            }
        }
    }
}

extension ProjectAppearance {
    /// A starting look for a project named after a folder: a colour from its name.
    static func suggested(for name: String) -> ProjectAppearance {
        let colours: [ProjectAccent] = [.ocean, .mint, .ember, .violet, .gold, .rose]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return ProjectAppearance(accent: colours[sum % colours.count], glyph: .code)
    }
}
