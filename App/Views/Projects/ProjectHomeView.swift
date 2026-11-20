import HermesKit
import SwiftUI

/// A project's home (`projectHome`, `ipadProjectHome`, `macProjectHome`): the header, its chats by
/// lane (main checkout, worktrees, card worktrees), what Hermes knows about it, and a composer that
/// starts a chat in it. iPad and Mac put the facts (and on the Mac, the folders) in a right column.
struct ProjectHomeView: View {
    let workspace: BotWorkspace
    let projectID: String

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// A narrow Mac window (`docs/chat.md` §4): one column at the usual 20 pt margins, with the
    /// folders under the facts.
    @Environment(\.windowIsNarrow) private var windowIsNarrow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerFocused = false
    /// Where the top bar ends: the composer's menus stop there.
    @State private var ceiling: CGFloat?
    @State private var expandedLanes: Set<String> = []
    /// The toolbar names the project once its header has scrolled away.
    @State private var headerScrolledAway = false
    @State private var width: CGFloat = 0
    @State private var actionError: HermesError?
    /// The lane row whose swipe actions show; a tap or a scroll shuts it.
    @State private var swipedRow: String?
    #if os(macOS)
    /// The chat the arrow keys have selected (`docs/projects.md` §2), drawn while the lanes have
    /// the keyboard.
    @State private var laneSelection = LaneSelection()
    @FocusState private var lanesFocused: Bool
    #endif

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

    // The right column (`macProjectHome`, `ipadProjectHome`): 300 pt at 28 from the lanes inside
    // 40 pt margins on the Mac, 280 at 24 inside 32 on iPad, so landscape iPad keeps two columns.
    #if os(macOS)
    private static let sideColumnWidth: CGFloat = 300
    private static let columnGap: CGFloat = 28
    private static let wideMargin: CGFloat = 40
    #else
    private static let sideColumnWidth: CGFloat = 280
    private static let columnGap: CGFloat = 24
    private static let wideMargin: CGFloat = 32
    #endif

    /// Two columns where there's room. On iPad never at the accessibility text sizes, where the
    /// lanes need the whole width; the Mac keeps its columns (`docs/projects.md` §5).
    private var showsTwoColumns: Bool {
        #if os(macOS)
        isWide && width >= 860
        #else
        isWide && !dynamicTypeSize.isAccessibilitySize && width >= 860
        #endif
    }

    private var hasProject: Bool { node != nil || project != nil }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    var body: some View {
        Group {
            if node == nil, project == nil, workspace.botModeIsDown {
                // Projects come over Bot Mode (`docs/setup.md` §4.9).
                BotModeSetupMessage(workspace: workspace, feature: GatewaySetup.ID.projects, title: String(localized: "Projects"), symbol: "folder")
            } else if node == nil, project == nil, !workspace.projects.hasLoaded {
                // Not "not found" before the list has come.
                SkeletonRows()
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if node == nil, project == nil {
                missing
            } else {
                content
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        // Undo for a chat archived here, above the composer (`docs/projects.md` §2). The chat
        // list keeps its own, so a window shows one.
        .modifier(ArchivedToast(workspace: workspace, place: .project, bottomPadding: 12) { actionError = $0 })
        .alert("Something went wrong", isPresented: errorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
        // Where the top bar ends: the composer's menus stop there.
        .overlay { CeilingMarker(ceiling: $ceiling) }
        .safeAreaBar(edge: .bottom) {
            if node != nil || project != nil {
                ComposerView(conversation: workspace.projectDraft(for: projectID), workspace: workspace, focused: $composerFocused, onVoiceMode: voiceMode)
                    .environment(\.composerCeiling, ceiling)
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
        .navigationTitle(name)
        #if os(iOS)
        // Shown once the header has scrolled away, but always the title: a chat or the Board
        // pushed over the project names it on its back button, for VoiceOver too.
        .toolbar(removing: headerScrolledAway ? nil : .title)
        #endif
        .toolbarTitleDisplayMode(.inline)
        // Again once the socket is up: a home opened at launch loads before it connects.
        .task(id: "\(projectID)|\(projects.isAvailable)") { await load() }
        .refreshable { await load() }
    }

    /// Talk starts a new chat in the project and opens it there.
    private var voiceMode: (() -> Void)? {
        #if os(iOS)
        return {
            workspace.startNewChat(inProject: projectID, fromHome: true)
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
                    if showsTwoColumns {
                        HStack(alignment: .top, spacing: Self.columnGap) {
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
                            .frame(width: Self.sideColumnWidth)
                            .padding(.top, 92)
                        }
                        .frame(maxWidth: 900)
                        .padding(.horizontal, Self.wideMargin)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            boardRow
                            lanes
                            factsCard
                                .padding(.top, 16)
                            #if os(macOS)
                            if windowIsNarrow {
                                foldersCard
                                    .padding(.top, 16)
                            }
                            #endif
                        }
                        .frame(maxWidth: 640)
                        .padding(.horizontal, isWide && !windowIsNarrow ? 32 : 20)
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
            // A scroll shuts a row's swipe actions, as in the chat list.
            .onScrollPhaseChange { _, phase in
                if phase != .idle, swipedRow != nil { swipedRow = nil }
            }
            .onChange(of: projects.focusLane, initial: true) { _, lane in
                guard let lane else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    // Reduce Motion jumps to the lane instead of gliding there.
                    withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(lane, anchor: .top) }
                }
            }
            #if os(macOS)
            // The selected chat stays in view as the arrow keys move it.
            .onChange(of: laneSelection.rowID) { _, id in
                guard let id, lanesFocused else { return }
                withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(id) }
            }
            #endif
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
                    pathLine(primaryPath)
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

    /// The folder and branch on one line, the path shortened in its middle. At the accessibility
    /// sizes the whole path wraps, without glyphs, and the branch takes its own line
    /// (`projectHomeLarge`).
    @ViewBuilder
    private func pathLine(_ primaryPath: String) -> some View {
        let branch = projects.branch(of: primaryPath)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(projects.displayPath(primaryPath))
                if let branch {
                    Text(branch)
                        .accessibilityLabel(String(localized: "on \(branch)"))
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                Text(projects.displayPath(primaryPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch {
                    Image(systemName: "arrow.triangle.branch")
                        .padding(.leading, 2)
                        .accessibilityHidden(true)
                    Text(branch)
                        .lineLimit(1)
                        .accessibilityLabel(String(localized: "on \(branch)"))
                }
            }
        }
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
                let lanes = VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { lane in
                        laneSection(lane)
                            .id(lane.id)
                    }
                }
                #if os(macOS)
                laneKeys(lanes, shown: shown)
                #else
                lanes
                #endif
            }
        } else if node?.sessionCount == 0 {
            emptyLanes
        } else {
            SkeletonRows()
                .padding(.vertical, 12)
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

    /// A lane's chats newest first, its times, and the rows it shows: three until Show All.
    private func laneRows(_ lane: ProjectLane) -> (sorted: [ProjectSessionRow], shown: [ProjectSessionRow], times: [String: Date]) {
        let times = Dictionary(lane.sessions.compactMap { row in workspace.rowTime(row).map { (row.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let sorted = RowTime.ordered(lane.sessions, pinned: { _ in false }, time: { times[$0.id] })
        let shown = expandedLanes.contains(lane.id) ? sorted : Array(sorted.prefix(3))
        return (sorted, shown, times)
    }

    private func laneSection(_ lane: ProjectLane) -> some View {
        let (sorted, rows, times) = laneRows(lane)
        let isExpanded = expandedLanes.contains(lane.id)
        return VStack(alignment: .leading, spacing: 8) {
            LaneHeader(lane: lane, count: lane.sessions.count)
            ForEach(rows) { row in
                LaneChatRow(row: row, time: times[row.id], muted: isMuted(row),
                            isWorking: projects.isRunning(sessionID: row.id) || projects.isRunning(sessionID: row.stableID),
                            isSelected: isSelected(row)) {
                    // A tap while a row shows its swipe actions shuts them, as in the chat list.
                    if swipedRow != nil { swipedRow = nil } else { open(row) }
                }
                .id(row.id)
                .contextMenu { chatMenu(row) }
                .modifier(rowActions(row))
                .onAppear { workspace.unread.needsLastLine(row.session) }
            }
            if sorted.count > 3 {
                Button {
                    withAnimation(Theme.snappy) {
                        if isExpanded { expandedLanes.remove(lane.id) } else { expandedLanes.insert(lane.id) }
                    }
                } label: {
                    Text(isExpanded ? String(localized: "Show Less") : String(localized: "Show All \(sorted.count)"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Self.showAllColor)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func isSelected(_ row: ProjectSessionRow) -> Bool {
        #if os(macOS)
        lanesFocused && laneSelection.rowID == row.id
        #else
        false
        #endif
    }

    #if os(macOS)
    /// The arrow keys on the Mac (`docs/projects.md` §2): Up and Down within a lane, Left and Right
    /// between lanes, Return opens the chat. The lanes take the keyboard with Tab, and the first
    /// chat is selected as they do.
    private func laneKeys(_ lanes: some View, shown: [ProjectLane]) -> some View {
        let order = shown.map { laneRows($0).shown }
        let ids = order.map { $0.map(\.id) }
        return lanes
            .focusable()
            .focused($lanesFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(.up, in: ids) }
            .onKeyPress(.downArrow) { move(.down, in: ids) }
            .onKeyPress(.leftArrow) { move(.left, in: ids) }
            .onKeyPress(.rightArrow) { move(.right, in: ids) }
            .onKeyPress(.return) {
                guard let id = laneSelection.rowID, let row = order.joined().first(where: { $0.id == id }) else { return .ignored }
                open(row)
                return .handled
            }
            .onChange(of: lanesFocused) { _, focused in
                if focused, laneSelection.position(in: ids) == nil { laneSelection.move(.down, in: ids) }
            }
    }

    private func move(_ move: LaneSelection.Move, in ids: [[String]]) -> KeyPress.Result {
        laneSelection.move(move, in: ids) ? .handled : .ignored
    }
    #endif

    @ViewBuilder
    private func chatMenu(_ row: ProjectSessionRow) -> some View {
        let session = workspace.session(forKey: row.stableID) ?? row.session
        let key = session.stableID
        let isUnread = workspace.unread.badge(for: key).isUnread || workspace.unread.readMark(for: key) == .markedUnread
        // The chat list's row actions, in its order (`docs/projects.md` §2). Pin is the one that
        // also brings a project chat back into the flat list (`inboxSessions`).
        Button(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") {
            toggleRead(key, isUnread: isUnread)
        }
        Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") {
            togglePin(session)
        }
        MuteMenu(unread: workspace.unread, key: key)
        Divider()
        Button("Move to Project…", systemImage: "folder") {
            projects.movingSession = session
        }
        if workspace.roster?.isConnected == true {
            Button("Checkpoints…", systemImage: "clock.arrow.circlepath") {
                workspace.showCheckpoints(for: session)
            }
        }
        Button("Copy Session ID", systemImage: "number") {
            Pasteboard.copy(row.id)
        }
        #if os(macOS)
        // No swipe without a trackpad: Archive is here too, as in the chat list.
        Button("Archive", systemImage: "archivebox") {
            archive(session)
        }
        #endif
    }

    /// The chat list's trailing swipe, Mute then Archive (`docs/inbox.md` §5), on iPhone and iPad,
    /// and its two actions for VoiceOver on every platform: a swipe outside a `List` isn't one the
    /// system offers as the row's actions.
    private func rowActions(_ row: ProjectSessionRow) -> LaneRowActions {
        let session = workspace.session(forKey: row.stableID) ?? row.session
        let key = session.stableID
        let muted = isMuted(row)
        return LaneRowActions(
            id: row.stableID,
            muted: muted,
            openRow: $swipedRow,
            toggleMute: { toggleMute(key, muted: muted) },
            archive: { archive(session) }
        )
    }

    /// Muted as the chat list reads it: by the chat's stable key, whichever of its ids the lane has.
    private func isMuted(_ row: ProjectSessionRow) -> Bool {
        workspace.unread.isMuted((workspace.session(forKey: row.stableID) ?? row.session).stableID)
    }

    private func toggleRead(_ key: String, isUnread: Bool) {
        if isUnread { workspace.unread.markRead(key) } else { workspace.unread.markUnread(key) }
    }

    private func togglePin(_ session: HermesSession) {
        Task { await run { try await workspace.setPinned(session, !session.pinned) } }
    }

    /// Swiped: until turned back on (a swipe undoes it); the menu offers the shorter ones.
    private func toggleMute(_ key: String, muted: Bool) {
        if muted { workspace.unread.unmute(key) } else { workspace.unread.mute(key, for: .untilTurnedOff) }
    }

    private func archive(_ session: HermesSession) {
        Task { await run { try await workspace.archive(session, from: .project) } }
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { actionError = error as? HermesError ?? .invalidResponse(error.localizedDescription) }
    }

    private func open(_ row: ProjectSessionRow) {
        workspace.open(row.session, fromProject: projectID)
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

    /// Show All sits in ink on the Mac (`macProjectHome`), grey on iPhone and iPad.
    private static var showAllColor: Color {
        #if os(macOS)
        Theme.primaryText
        #else
        Theme.secondaryText
        #endif
    }

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
        #if os(macOS)
        // Without a centred item the Mac lines items up from the leading edge.
        ToolbarSpacer(.flexible)
        #endif
        // A project that isn't there has nothing to act on: only the sidebar button stays
        // (`projectNotFound`).
        if hasProject {
            #if os(macOS)
            // New Chat before the menu (`macProjectHome`): a chat in this project, as the composer
            // below starts one.
            ToolbarItem(placement: Self.menuPlacement) {
                Button {
                    workspace.startNewChat(inProject: projectID, fromHome: true)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New chat")
                .help(String(localized: "New chat in \(name)"))
            }
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
}

/// A lane's title (`laneHeader*`): branch or worktree in monospace with a tag, or "Card worktrees".
/// At the accessibility sizes the name, its tag and the count stack (`laneHeaderLarge`).
struct LaneHeader: View {
    let lane: ProjectLane
    let count: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        glyph
                        name
                    }
                    if lane.kind != .tasks { tag }
                    countText
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 7) {
                    glyph
                    name
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if lane.kind != .tasks { tag }
                    Spacer(minLength: 8)
                    countText
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
    }

    private var glyph: some View {
        Image(systemName: lane.kind == .tasks ? "checklist" : "arrow.triangle.branch")
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder
    private var name: some View {
        if lane.kind == .tasks {
            Text(lane.displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
        } else {
            Text(lane.displayName)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
        }
    }

    private var kindName: String {
        lane.kind == .main ? String(localized: "Main checkout") : String(localized: "Worktree")
    }

    private var tag: some View {
        Text(kindName)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var countLabel: String {
        lane.kind == .tasks ? ProjectCount.cards(count) : ProjectCount.chats(count)
    }

    private var countText: some View {
        Text(countLabel)
            .font(.footnote)
            .foregroundStyle(Theme.tertiaryText)
    }

    /// "main, main checkout, 3 chats", "Card worktrees, 2 cards".
    private var accessibilityText: String {
        lane.kind == .tasks
            ? String(localized: "\(lane.displayName), \(countLabel)")
            : String(localized: "\(lane.displayName), \(kindName.lowercased()), \(countLabel)")
    }
}

/// A lane row's Mute and Archive: swiped from the trailing edge on iPhone and iPad, and named
/// actions for VoiceOver everywhere (`docs/projects.md` §2).
struct LaneRowActions: ViewModifier {
    let id: String
    let muted: Bool
    @Binding var openRow: String?
    let toggleMute: () -> Void
    let archive: () -> Void

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .modifier(TrailingSwipeActions(id: id, actions: [
                RowSwipeAction(title: muted ? String(localized: "Unmute") : String(localized: "Mute"), symbol: muted ? "bell" : "bell.slash", tint: Theme.swipeActionQuiet, perform: toggleMute),
                RowSwipeAction(title: String(localized: "Archive"), symbol: "archivebox", tint: Theme.swipeActionQuiet, perform: archive),
            ], openRow: $openRow))
            #endif
            .accessibilityAction(named: muted ? Text("Unmute") : Text("Mute"), toggleMute)
            .accessibilityAction(named: Text("Archive"), archive)
    }
}

/// A chat in a lane (`laneChatRow`, `macLaneChatRow`): title, its first line, the time and a
/// working dot. iPhone and iPad draw it as a card; the Mac as a plain row that greys on hover. At
/// the accessibility sizes the title and line wrap and the marks and time go below
/// (`laneChatRowLarge`).
struct LaneChatRow: View {
    let row: ProjectSessionRow
    /// The row's time (`RowTime`): its last message's, as in the chat list.
    let time: Date?
    /// The chat list's slashed bell before the time (`docs/inbox.md` §5).
    let muted: Bool
    let isWorking: Bool
    /// The arrow keys' chat on the Mac (`macLaneChatRowSelected`).
    var isSelected = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(macOS)
    @State private var isHovered = false
    private static let radius: CGFloat = 8
    #else
    private static let radius: CGFloat = 16
    #endif

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        texts(lineLimit: nil)
                        HStack(spacing: 8) { marks }
                    }
                } else {
                    HStack(spacing: 10) {
                        texts(lineLimit: 1)
                        Spacer(minLength: 8)
                        marks
                    }
                }
            }
            #if os(macOS)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .background(isSelected ? Theme.surfaceRaised : isHovered ? Theme.controlFill : .clear,
                        in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            #else
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            #endif
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var preview: String? {
        guard let preview = row.listPreview, !preview.isEmpty, preview != row.title else { return nil }
        return preview
    }

    private func texts(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.displayTitle)
                .font(Self.titleFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(lineLimit)
            if let preview {
                Text(preview)
                    .font(Self.previewFont)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(lineLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var marks: some View {
        if isWorking {
            StatusDot(color: Theme.warning)
        }
        if muted {
            RowMark("bell.slash.fill")
        }
        if let date = time {
            Text(Self.time(date))
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    // The Mac row's title is body and its line subheadline; the card's callout and footnote.
    #if os(macOS)
    private static let titleFont = Font.body.weight(.medium)
    private static let previewFont = Font.subheadline
    #else
    private static let titleFont = Font.callout.weight(.medium)
    private static let previewFont = Font.footnote
    #endif

    /// "Fix the build, muted, working, 2 hours ago, its last line": the state before the line.
    private var accessibilityText: String {
        var parts = [row.displayTitle]
        if muted { parts.append(String(localized: "muted")) }
        if isWorking { parts.append(String(localized: "working")) }
        if let date = time { parts.append(Formatting.relativePhrase(date)) }
        if let preview { parts.append(preview) }
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Chips wrap onto lines; at the accessibility sizes they take a line each (`factsCardLarge`).
    private var chipLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(FlowLayout(spacing: 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What Hermes knows about this project", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .labelStyle(FactsTitleLabelStyle())
            let builtWith = facts.manifests.map(Self.manifest) + facts.packageManagers.map { ($0, "shippingbox") }
            if !builtWith.isEmpty {
                section(String(localized: "Built with")) {
                    chipLayout {
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
                    chipLayout {
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

/// A project folder (`folderRow*`): its name, path, and a Primary tag. At the accessibility sizes
/// the glyph goes, the path wraps and the tag sits below (`folderRowLarge`).
struct FolderRow: View {
    let folder: HermesProject.Folder
    let displayPath: String
    let isPrimary: Bool
    var annotation: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    texts(lineLimit: nil)
                    if isPrimary { primaryTag }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: isPrimary ? "folder.fill" : "folder")
                        .font(.body)
                        .foregroundStyle(isPrimary ? Theme.primaryText : Theme.secondaryText)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    texts(lineLimit: 1)
                    Spacer(minLength: 8)
                    if isPrimary { primaryTag }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func texts(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(annotation.map { "\(folder.name) · \($0)" } ?? folder.name)
                .font(.body)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(lineLimit)
            Text(displayPath)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
        }
    }

    private var primaryTag: some View {
        TagLabel(title: String(localized: "Primary"), style: .ink)
    }
}
