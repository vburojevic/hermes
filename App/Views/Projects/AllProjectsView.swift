import HermesKit
import SwiftUI

/// All Projects (`allProjects`): projects by their chats' newest message (`ProjectsModel.rowTime`),
/// the git folders Hermes found that aren't projects yet ("Found on Studio Mac"), then Archived.
struct AllProjectsView: View {
    let workspace: BotWorkspace

    @State private var adding: Set<String> = []
    @State private var error: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
        grid
        #else
        if horizontalSizeClass == .regular { grid } else { list }
        #endif
    }

    /// Cards fill the width. On iPad at the accessibility sizes they stack in one column of
    /// readable width; the Mac keeps its grid (`docs/projects.md` §5).
    private var stacksCards: Bool {
        #if os(macOS)
        false
        #else
        dynamicTypeSize.isAccessibilitySize
        #endif
    }

    private var gridColumns: [GridItem] {
        stacksCards
            ? [GridItem(.flexible(), spacing: 14)]
            : [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 14)]
    }

    /// The Mac and iPad (`macAllProjects`, `ipadAllProjects*`): a grid of project cards, then the
    /// folders Hermes found and Archived.
    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                #if os(macOS)
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                #endif
                if projects.projectsByActivity.isEmpty, projects.hasLoaded {
                    Text("No projects yet. A project groups the chats that run in its folders.")
                        .foregroundStyle(Theme.secondaryText)
                }
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    if !projects.hasLoaded, projects.projectsByActivity.isEmpty {
                        // Three cards, read as one "Loading".
                        ProjectCardSkeleton()
                        ProjectCardSkeleton().accessibilityHidden(true)
                        ProjectCardSkeleton().accessibilityHidden(true)
                    } else {
                        ForEach(projects.projectsByActivity) { node in
                            ProjectCard(workspace: workspace, node: node, subtitle: subtitle(node))
                        }
                    }
                }
                .padding(.top, 6)
                if !projects.suggestedRepos.isEmpty {
                    foundOnCard
                }
                if !projects.archivedProjects.isEmpty {
                    archivedLink
                }
            }
            #if os(macOS)
            .padding(.horizontal, 36)
            .padding(.vertical, 20)
            #else
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
            #endif
            .frame(maxWidth: stacksCards ? 640 : 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: stacksCards ? .center : .leading)
        }
        .background(Theme.groupedBackground)
        #if os(macOS)
        // The grid draws its own large title.
        .toolbar(removing: .title)
        #endif
    }

    #if os(macOS)
    private static let groupRadius: CGFloat = 12
    #else
    private static let groupRadius: CGFloat = 26
    #endif

    /// "Found on Studio Mac": the git folders that aren't a project yet, in one grouped cell.
    private var foundOnCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Found on \(workspace.bot.name)")
                #if os(macOS)
                .font(.subheadline.weight(.semibold))
                #else
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 16)
                #endif
                .foregroundStyle(Theme.secondaryText)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(projects.suggestedRepos.enumerated()), id: \.element.id) { index, repo in
                    if index > 0 { Divider().padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 50) }
                    RepoSuggestionRow(repo: repo, displayPath: projects.displayPath(repo.root), isAdding: adding.contains(repo.root)) {
                        add(repo)
                    }
                    #if os(macOS)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    #else
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 60)
                    #endif
                }
            }
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
            #if !os(macOS)
            Text("Git folders Hermes has worked in that aren't a project yet. Add one to group its chats.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            #endif
        }
        .padding(.top, 8)
    }

    /// Archived: a link on the Mac (`macAllProjects`), a cell row on iPad.
    @ViewBuilder
    private var archivedLink: some View {
        #if os(macOS)
        NavigationLink {
            ArchivedProjectsView(workspace: workspace)
        } label: {
            Label("Archived · \(projects.archivedProjects.count)", systemImage: "archivebox")
        }
        .buttonStyle(.link)
        .padding(.top, 4)
        #else
        NavigationLink {
            ArchivedProjectsView(workspace: workspace)
        } label: {
            HStack(spacing: 12) {
                Text("Archived")
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text(projects.archivedProjects.count, format: .number)
                    .foregroundStyle(Theme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(Theme.groupedCell, in: RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        #endif
    }

    private var list: some View {
        List {
            Section {
                if !projects.hasLoaded, projects.projectsByActivity.isEmpty {
                    ProjectRowSkeletons()
                } else if projects.projectsByActivity.isEmpty {
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

    /// One project on iPhone (`projectListRow`). At the accessibility sizes the tile sits above the
    /// name, the details wrap and the working dot goes below; the row itself opens the project.
    private func projectRow(_ node: ProjectNode) -> some View {
        let project = projects.project(node.id)
        let working = projects.isWorking(node.id)
        let name = project?.name ?? node.label
        return Button {
            projects.focusLane = nil
            workspace.selection = .project(node.id)
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        ProjectTile(appearance: projects.appearance(node.id), size: 40)
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(subtitle(node))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                        if working { StatusDot(color: Theme.warning) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                } else {
                    HStack(spacing: 12) {
                        ProjectTile(appearance: projects.appearance(node.id), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
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
                    .frame(minHeight: 44)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ProjectMenuItems(workspace: workspace, projectID: node.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectRowLabel.accessibilityText(name: name, count: node.sessionCount, working: working))
        .accessibilityHint(subtitle(node))
        .accessibilityAddTraits(.isButton)
    }

    /// "~/Code/hermes-app · 9 chats · now".
    private func subtitle(_ node: ProjectNode) -> String {
        var parts: [String] = []
        if let path = projects.project(node.id)?.primaryPath ?? node.path { parts.append(projects.displayPath(path)) }
        parts.append(ProjectCount.chats(node.sessionCount))
        if let date = projects.shownTime(node) { parts.append(LaneChatRow.time(date)) }
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

/// A project card on the Mac and iPad (`macProjectCard`): tile and working dot, name, folder in
/// mono, then chats and when. On the Mac it lifts to the raised surface under the pointer.
struct ProjectCard: View {
    let workspace: BotWorkspace
    let node: ProjectNode
    let subtitle: String

    @State private var isHovered = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var projects: ProjectsModel { workspace.projects }

    var body: some View {
        let project = projects.project(node.id)
        let working = projects.isWorking(node.id)
        let wraps = dynamicTypeSize.isAccessibilitySize
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {
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
                    .lineLimit(wraps ? nil : 1)
                if let path = project?.primaryPath ?? node.path {
                    Text(projects.displayPath(path))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(wraps ? nil : 1)
                        .truncationMode(.middle)
                }
                Text([ProjectCount.chats(node.sessionCount), projects.shownTime(node).map(LaneChatRow.time)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(isHovered ? Theme.surfaceRaised : Theme.groupedCell, in: shape)
            #if os(macOS)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            #endif
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .contextMenu { ProjectMenuItems(workspace: workspace, projectID: node.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProjectRowLabel.accessibilityText(name: project?.name ?? node.label, count: node.sessionCount, working: working))
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(.isButton)
    }
}

/// A project card while the list loads (`macProjectCardSkeleton`): tile and three bars.
struct ProjectCardSkeleton: View {
    @State private var shows = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.controlFill)
                .frame(width: 36, height: 36)
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(Theme.controlFill).frame(width: proxy.size.width * 0.52, height: 12)
                    Capsule().fill(Theme.controlFill).frame(width: proxy.size.width * 0.7, height: 9)
                    Capsule().fill(Theme.controlFill).frame(width: proxy.size.width * 0.34, height: 9)
                }
            }
            .frame(height: 12 + 9 + 9 + 16)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(Theme.groupedCell, in: shape)
        #if os(macOS)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        #endif
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
        .task {
            // Like `SkeletonRows`: a list that loads at once never flashes.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.25)) { shows = true }
        }
    }
}

/// Four project rows while the list loads on iPhone (`projectListRowSkeleton`), read as one
/// "Loading".
struct ProjectRowSkeletons: View {
    @State private var shows = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, 52) }
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.controlFill)
                        .frame(width: 40, height: 40)
                    GeometryReader { proxy in
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(Theme.controlFill).frame(width: proxy.size.width * 0.46, height: 11)
                            Capsule().fill(Theme.controlFill).frame(width: proxy.size.width * 0.78, height: 9)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 40)
                }
                .frame(minHeight: 64)
            }
        }
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.25)) { shows = true }
        }
    }
}

/// A folder Hermes found (`repoSuggestionRow`): its name, path and chats, and Add. At the
/// accessibility sizes the glyph sits above, the name and path wrap and Add goes below.
struct RepoSuggestionRow: View {
    let repo: DiscoveredRepo
    let displayPath: String
    let isAdding: Bool
    let add: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                glyph
                texts(lineLimit: nil)
                addButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 12) {
                glyph
                    .frame(width: 28)
                texts(lineLimit: 1)
                Spacer(minLength: 8)
                addButton
            }
        }
    }

    private var glyph: some View {
        Image(systemName: "folder")
            .font(.body)
            .foregroundStyle(Theme.secondaryText)
            .accessibilityHidden(true)
    }

    private func texts(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(repo.label)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(lineLimit)
            Text("\(displayPath) · \(ProjectCount.chats(repo.sessions))")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private var addButton: some View {
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
