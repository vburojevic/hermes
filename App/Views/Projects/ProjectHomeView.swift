import HermesKit
import SwiftUI

/// A project's home (`projectHome`, `ipadProjectHome`, `macProjectHome`): the header, its chats by
/// lane (main checkout, worktrees, card worktrees), what Hermes knows about it, and a composer that
/// starts a chat in it. iPad and Mac put the facts (and on the Mac, the folders) in a right column.
struct ProjectHomeView: View {
    let workspace: BotWorkspace
    let projectID: String
    var onToggleSidebar: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var composerFocused = false
    @State private var expandedLanes: Set<String> = []
    /// The toolbar names the project once its header has scrolled away.
    @State private var headerScrolledAway = false
    @State private var width: CGFloat = 0

    private var projects: ProjectsModel { workspace.projects }
    private var node: ProjectNode? { projects.node(projectID) }
    private var project: HermesProject? { projects.project(projectID) }
    private var name: String { project?.name ?? node?.label ?? "" }
    private var primaryPath: String? { project?.primaryPath ?? node?.path }

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if node == nil, project == nil {
                missing
            } else {
                content
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .safeAreaBar(edge: .bottom) {
            if node != nil || project != nil {
                ComposerView(conversation: workspace.projectDraft(for: projectID), workspace: workspace, focused: $composerFocused, onVoiceMode: voiceMode)
                    .frame(maxWidth: Theme.readableWidth + 40)
                    .padding(.horizontal, isWide ? 20 : 10)
                    .padding(.bottom, isWide ? 14 : 6)
            }
        }
        .safeAreaBar(edge: .top) {
            ConnectionBanner(workspace: workspace)
        }
        .toolbar { toolbar }
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        #if os(macOS)
        .navigationTitle(name)
        #else
        .navigationTitle(headerScrolledAway ? name : "")
        #endif
        .toolbarTitleDisplayMode(.inline)
        // Again once the socket is up: a home opened at launch loads before it connects.
        .task(id: "\(projectID)|\(projects.isAvailable)") { await load() }
        .refreshable { await load() }
    }

    /// Voice mode starts a new chat in the project and opens it there.
    private var voiceMode: (() -> Void)? {
        #if os(iOS)
        return {
            workspace.startNewChat(inProject: projectID)
            workspace.voiceModeRequested = true
        }
        #else
        return nil
        #endif
    }

    private func load() async {
        await projects.loadDetail(projectID)
        if let primaryPath {
            async let facts: Void = projects.loadFacts(primaryPath)
            async let branch: Void = projects.loadBranch(primaryPath)
            _ = await (facts, branch)
        }
    }

    // MARK: Layout

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    // Two columns where there's room (iPad landscape, Mac); one on iPhone and
                    // narrower iPad layouts, with the facts at the end.
                    if isWide, width >= 860 {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                                boardRow
                                lanes
                            }
                            .frame(maxWidth: 560)
                            VStack(spacing: 16) {
                                factsCard
                                #if os(macOS)
                                foldersCard
                                #endif
                            }
                            .frame(width: 300)
                            .padding(.top, 92)
                        }
                        .frame(maxWidth: 900)
                        .padding(.horizontal, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            boardRow
                            lanes
                            factsCard
                                .padding(.top, 16)
                        }
                        .frame(maxWidth: 640)
                        .padding(.horizontal, isWide ? 32 : 20)
                    }
                }
                .padding(.top, isWide ? 24 : 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 140 } action: { _, away in
                if away != headerScrolledAway { withAnimation(.easeOut(duration: 0.2)) { headerScrolledAway = away } }
            }
            .onChange(of: projects.focusLane, initial: true) { _, lane in
                guard let lane else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(Theme.snappy) { proxy.scrollTo(lane, anchor: .top) }
                }
            }
        }
    }

    private var missing: some View {
        StateMessage(
            symbol: "folder.badge.questionmark",
            title: String(localized: "Project not found"),
            message: String(localized: "It may have been archived or deleted on \(workspace.bot.name)."),
            actionTitle: String(localized: "All Projects")
        ) {
            workspace.selection = .allProjects
        }
    }

    // MARK: Header (`projectHeader`)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProjectTile(appearance: projects.appearance(projectID), size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                if let primaryPath {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .accessibilityHidden(true)
                        Text(projects.displayPath(primaryPath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let branch = projects.branch(of: primaryPath) {
                            Image(systemName: "arrow.triangle.branch")
                                .padding(.leading, 2)
                                .accessibilityHidden(true)
                            Text(branch)
                                .lineLimit(1)
                                .accessibilityLabel(String(localized: "on \(branch)"))
                        }
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityElement(children: .combine)
                }
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    /// "9 chats · 2 branches · 3 tasks · Studio Mac".
    private var summary: String {
        let detail = projects.details[projectID]
        var parts = [ProjectCount.chats(node?.sessionCount ?? 0)]
        if let detail {
            if detail.branchCount > 1 { parts.append(ProjectCount.branches(detail.branchCount)) }
            if detail.taskCount > 0 { parts.append(ProjectCount.cards(detail.taskCount)) }
        }
        parts.append(workspace.bot.name)
        return parts.joined(separator: " · ")
    }

    /// The project's Board (`boardSummaryRow`), above the lanes, on gateways with Bot Mode.
    @ViewBuilder
    private var boardRow: some View {
        if workspace.roster != nil {
            BoardSummaryRow(model: workspace.board(for: projectID)) {
                workspace.selection = .board(projectID)
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    // MARK: Lanes

    @ViewBuilder
    private var lanes: some View {
        if let detail = projects.details[projectID] {
            let shown = detail.lanes.filter { !$0.sessions.isEmpty }
            if shown.isEmpty {
                emptyLanes
            } else {
                ForEach(shown) { lane in
                    laneSection(lane)
                        .id(lane.id)
                }
            }
        } else if node?.sessionCount == 0 {
            emptyLanes
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private var emptyLanes: some View {
        VStack(spacing: 6) {
            Text("No chats yet")
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text("Ask about \(name) below. Chats here run in \(projects.displayPath(primaryPath)), and Hermes reads its context files first.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 12)
    }

    private func laneSection(_ lane: ProjectLane) -> some View {
        let sorted = lane.sessions.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
        let isExpanded = expandedLanes.contains(lane.id)
        let rows = isExpanded ? sorted : Array(sorted.prefix(3))
        return VStack(alignment: .leading, spacing: 8) {
            LaneHeader(lane: lane, count: lane.sessions.count)
            ForEach(rows) { row in
                LaneChatRow(row: row, isWorking: projects.isRunning(sessionID: row.id) || projects.isRunning(sessionID: row.stableID)) {
                    open(row)
                }
                .contextMenu { chatMenu(row) }
            }
            if sorted.count > 3 {
                Button {
                    withAnimation(Theme.snappy) {
                        if isExpanded { expandedLanes.remove(lane.id) } else { expandedLanes.insert(lane.id) }
                    }
                } label: {
                    Text(isExpanded ? String(localized: "Show Less") : String(localized: "Show All \(sorted.count)"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func chatMenu(_ row: ProjectSessionRow) -> some View {
        Button("Move to Project…", systemImage: "folder") {
            projects.movingSession = workspace.session(forKey: row.stableID) ?? row.session
        }
        if workspace.roster?.isConnected == true {
            Button("Checkpoints…", systemImage: "clock.arrow.circlepath") {
                workspace.showCheckpoints(for: workspace.session(forKey: row.stableID) ?? row.session)
            }
        }
        Button("Copy Session ID", systemImage: "number") {
            Pasteboard.copy(row.id)
        }
    }

    private func open(_ row: ProjectSessionRow) {
        workspace.open(row.session)
    }

    // MARK: Facts and folders

    @ViewBuilder
    private var factsCard: some View {
        if let primaryPath, case .some(.some(let facts)) = projects.facts[primaryPath], !facts.isEmpty {
            FactsCard(facts: facts)
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var foldersCard: some View {
        if let project, !project.folders.isEmpty {
            VStack(spacing: 0) {
                ForEach(project.orderedFolders, id: \.path) { folder in
                    FolderRow(folder: folder, displayPath: projects.displayPath(folder.path), isPrimary: folder.path == project.primaryPath)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }
    #endif

    // MARK: Toolbar

    /// Top right, as in the design (the Mac puts `.primaryAction` at the leading edge).
    private static var menuPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .primaryAction
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onToggleSidebar {
            ToolbarItem(placement: .navigation) {
                Button(action: onToggleSidebar) {
                    SidebarGlyph()
                }
                .accessibilityLabel("Show sidebar")
            }
        }
        #if os(macOS)
        // Without a centred item the Mac lines items up from the leading edge.
        ToolbarSpacer(.flexible)
        #endif
        ToolbarItem(placement: Self.menuPlacement) {
            Menu {
                ProjectMenuItems(workspace: workspace, projectID: projectID)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Project actions")
            .help("Project actions")
        }
    }
}

/// A lane's title (`laneHeader*`): branch or worktree in monospace with a tag, or "Card worktrees".
struct LaneHeader: View {
    let lane: ProjectLane
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: lane.kind == .tasks ? "checklist" : "arrow.triangle.branch")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(true)
            if lane.kind == .tasks {
                Text(lane.displayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            } else {
                Text(lane.displayName)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(lane.kind == .main ? String(localized: "Main checkout") : String(localized: "Worktree"))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Spacer(minLength: 8)
            Text(lane.kind == .tasks ? ProjectCount.cards(count) : ProjectCount.chats(count))
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A chat in a lane (`laneChatRow`): title, its first line, the time and a working dot.
struct LaneChatRow: View {
    let row: ProjectSessionRow
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayTitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if let preview = row.preview, !preview.isEmpty, preview != row.title {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isWorking {
                    StatusDot(color: Theme.warning, pulsing: true)
                }
                if let date = row.lastActive {
                    Text(Self.time(date))
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [row.displayTitle]
        if isWorking { parts.append(String(localized: "working")) }
        if let date = row.lastActive { parts.append(Formatting.relativePhrase(date)) }
        return parts.joined(separator: ", ")
    }

    /// "now", "2h", "Yesterday", "Mon", "12 Oct".
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInYesterday(date) ? String(localized: "Yesterday") : Formatting.shortRelative(date)
    }
}

/// "What Hermes knows about this project" (`factsCard`, `project.facts`).
struct FactsCard: View {
    let facts: ProjectFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What Hermes knows about this project", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(FactsTitleLabelStyle())
            let builtWith = facts.manifests.map(Self.manifest) + facts.packageManagers.map { ($0, "shippingbox") }
            if !builtWith.isEmpty {
                section(String(localized: "Built with")) {
                    FlowLayout(spacing: 6) {
                        ForEach(builtWith, id: \.0) { item in
                            chip(item.0, symbol: item.1, monospaced: false)
                        }
                    }
                }
            }
            if !facts.verifyCommands.isEmpty {
                section(String(localized: "Checks Hermes runs before saying it's done")) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(facts.verifyCommands, id: \.self) { command in
                            Text(command)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(Theme.primaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !facts.contextFiles.isEmpty {
                section(String(localized: "Reads first")) {
                    FlowLayout(spacing: 6) {
                        ForEach(facts.contextFiles, id: \.self) { file in
                            chip(file, symbol: "doc", monospaced: true)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ title: String, symbol: String, monospaced: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryText)
            Text(title)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption.weight(.medium))
                .foregroundStyle(Theme.primaryText)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A manifest file as people say it: Package.swift → "Swift Package".
    static func manifest(_ file: String) -> (String, String) {
        let lower = file.lowercased()
        if lower == "package.swift" { return (String(localized: "Swift Package"), "shippingbox") }
        if lower.hasSuffix(".xcodeproj") || lower.hasSuffix(".xcworkspace") { return (String(localized: "Xcode project"), "hammer") }
        switch lower {
        case "package.json": return (String(localized: "Node package"), "shippingbox")
        case "tsconfig.json": return (String(localized: "TypeScript"), "curlybraces")
        case "deno.json": return ("Deno", "curlybraces")
        case "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt": return (String(localized: "Python project"), "shippingbox")
        case "cargo.toml": return (String(localized: "Rust crate"), "shippingbox")
        case "go.mod": return (String(localized: "Go module"), "shippingbox")
        case "pom.xml", "build.gradle", "build.gradle.kts": return (String(localized: "Java project"), "shippingbox")
        case "gemfile": return (String(localized: "Ruby project"), "shippingbox")
        case "composer.json": return (String(localized: "PHP project"), "shippingbox")
        case "mix.exs": return (String(localized: "Elixir project"), "shippingbox")
        case "pubspec.yaml": return (String(localized: "Flutter project"), "shippingbox")
        case "cmakelists.txt": return ("CMake", "hammer")
        case "makefile": return ("Makefile", "hammer")
        case "dockerfile": return ("Dockerfile", "shippingbox")
        case "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml": return (String(localized: "Docker Compose"), "shippingbox")
        default: return (file, "doc")
        }
    }
}

private struct FactsTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// A project folder (`folderRow*`): its name, path, and a Primary tag.
struct FolderRow: View {
    let folder: HermesProject.Folder
    let displayPath: String
    let isPrimary: Bool
    var annotation: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPrimary ? "folder.fill" : "folder")
                .font(.body)
                .foregroundStyle(isPrimary ? Theme.primaryText : Theme.secondaryText)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(annotation.map { "\(folder.name) · \($0)" } ?? folder.name)
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(displayPath)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isPrimary {
                TagLabel(title: String(localized: "Primary"), style: .ink)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
