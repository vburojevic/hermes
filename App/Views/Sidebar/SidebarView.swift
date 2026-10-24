import HermesKit
import SwiftUI

/// The sidebar (iPad, Mac) and drawer (iPhone): the gateway, Chats | Bots, search, the
/// navigation rows, then the history or the roster, and the connection footer
/// (Elyx `blocks/sidebar.elyx`, `screens/iphone/drawer*.elyx`).
struct SidebarView: View {
    enum Style { case split, drawer }

    @Bindable var workspace: BotWorkspace
    let style: Style
    /// Called after the person picks something, so a drawer can close.
    var onNavigate: () -> Void = {}

    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(AppModel.self) private var app
    @State private var renaming: HermesSession?
    @State private var renameText = ""
    @State private var deleting: HermesSession?
    @State private var actionError: HermesError?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String { workspace.searchText.trimmingCharacters(in: .whitespaces) }
    private var isSearching: Bool { !query.isEmpty }

    /// The history: chats outside a project, plus any pinned chat (`docs/projects.md` §2). A
    /// search covers every chat.
    private var filteredSessions: [HermesSession] {
        guard isSearching else {
            let projects = workspace.projects!
            return workspace.sessions.filter { $0.pinned || !projects.isScoped($0) }
        }
        return workspace.sessions.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.preview?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Bots mode, when this gateway has a Hermes backend linked.
    private var botRoster: BotRoster? {
        workspace.sidebarMode == .bots ? workspace.roster : nil
    }

    /// The roster order, only in Bots mode, so reorders animate without Chats mode
    /// observing the roster.
    private var botOrder: [String] {
        botRoster?.visibleBots.map(\.name) ?? []
    }

    /// The chats in order, only in Chats mode: a chat with new activity springs to the top
    /// (`docs/inbox.md` §3).
    private var chatOrder: [String] {
        botRoster == nil && !isSearching ? workspace.inboxSessions.map(\.stableID) : []
    }

    /// A `List` keeps the rows it drops alive, hidden for reuse, and their animations run on: a
    /// live dot pulsed out of sight at the display's frame rate after a switch to Bots mode. A
    /// new mode, filter or search swaps nearly every row, so it gets a new list instead.
    private var listIdentity: String {
        "\(workspace.sidebarMode)-\(workspace.inboxFilter)-\(isSearching)"
    }

    private var listMotion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85)
    }

    var body: some View {
        rows
        .animation(listMotion, value: botOrder)
        .animation(listMotion, value: chatOrder)
        .onAppear { workspace.activity.listAppeared() }
        .onDisappear { workspace.activity.listDisappeared() }
        .modifier(ArchivedToast(workspace: workspace) { actionError = $0 })
        .sensoryFeedback(.selection, trigger: workspace.sidebarMode)
        .refreshable { await refresh() }
        // Bars, not insets: rows scrolling under the header and footer get the soft scroll-edge effect.
        .safeAreaBar(edge: .top, spacing: 0) { header }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            SidebarFooter(workspace: workspace, isOpaque: style == .drawer, onNavigate: onNavigate)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .overlay {
            stateView
                .padding(.top, isSearching ? 0 : navigationHeight)
        }
        // The chats search follows the field; Bots mode filters the roster itself.
        .onChange(of: workspace.searchText, initial: true) {
            let text = botRoster == nil ? workspace.searchText : ""
            if workspace.search.query != text { workspace.search.query = text }
        }
        .onChange(of: workspace.sidebarMode) {
            if botRoster != nil { workspace.search.clear() }
        }
        .alert("Rename Chat", isPresented: renameBinding) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
                .keyboardShortcut(.defaultAction)
        }
        .alert(
            deleting.map { String(localized: "Delete “\($0.displayTitle)”?") } ?? "",
            isPresented: deleteBinding,
            presenting: deleting
        ) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete(session) }
        } message: { session in
            if workspace.waitingChat(forKey: session.stableID) != nil {
                Text("Its message waits for \(workspace.bot.name) and won't be sent.")
            } else {
                Text("The conversation is removed from Hermes on every device.")
            }
        }
        .alert("Something went wrong", isPresented: errorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch style {
        case .split:
            List { rowContent }
                // Plain rows on the system's (glass) sidebar: the sidebar list style adds its own
                // insets and selection, which the design doesn't use.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 10)
                .id(listIdentity)
        case .drawer:
            // A lazy stack, not a List: a List is a collection view that lays out, sizes and
            // configures (separators, swipe actions) every visible row again on each change, so
            // picking a chat cost a long frame right as the drawer started to close. Here only
            // the rows whose highlight changed redraw.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { rowContent }
            }
            // Scrolling closes a row's open swipe actions, as in the system's lists.
            .modifier(DrawerSwipeContainer())
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, DrawerSwipe.shared.openRow != nil { DrawerSwipe.shared.openRow = nil }
            }
            .background(Theme.sidebar)
            .environment(\.sidebarRowsInStack, true)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if !isSearching {
            navigationRows
            if botRoster == nil {
                InboxFilterChips(workspace: workspace)
                if workspace.inboxFilter == .all {
                    ProjectSidebarSection(workspace: workspace, onNavigate: onNavigate)
                }
            }
        }
        if let botRoster {
            BotRosterSections(roster: botRoster, workspace: workspace, onNavigate: onNavigate)
        } else if isSearching {
            // What was said, not only titles (`docs/search.md`).
            SearchResultsSection(workspace: workspace, onNavigate: onNavigate)
        } else {
            sessionSections
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: style == .drawer ? 12 : 10) {
            BotSwitcher(workspace: workspace)
            if workspace.roster != nil {
                SidebarModeSwitcher(mode: $workspace.sidebarMode, unread: workspace.unread)
            }
            SearchField(text: $workspace.searchText, prompt: botRoster == nil ? "Search chats" : "Search Bots", focusRequest: router?.sidebarSearchFocus ?? 0)
        }
        #if os(macOS)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        #else
        .padding(.horizontal, 16)
        .padding(.top, 8)
        #endif
        .padding(.bottom, 8)
        .background {
            if style == .drawer { Theme.sidebar.ignoresSafeArea(edges: .top) }
        }
    }

    // MARK: Navigation rows

    @ViewBuilder
    private var navigationRows: some View {
        if let roster = botRoster {
            DestinationRow(workspace: workspace, title: "All Bots", symbol: "square.grid.2x2", item: nil, onNavigate: onNavigate)
            SidebarNavRow(title: "New Bot", symbol: "plus", shortcut: "⇧⌘N") {
                roster.isCreatingBot = true
            }
            .disabled(!roster.isConnected)
            if roster.groupRooms.isAvailable {
                SidebarNavRow(title: "New Group Chat", symbol: "person.3") {
                    roster.isCreatingGroup = true
                }
                .disabled(!roster.isConnected || roster.visibleBots.count < 2)
            }
            destinationRows
        } else {
            SidebarNavRow(title: "New Chat", symbol: "square.and.pencil", shortcut: "⌘N") {
                workspace.startNewChat()
                onNavigate()
            }
            destinationRows
        }
    }

    @ViewBuilder
    private var destinationRows: some View {
        DestinationRow(workspace: workspace, title: "Tasks", symbol: "calendar.badge.clock", item: .tasks, shortcut: "⇧⌘1", onNavigate: onNavigate)
        DestinationRow(workspace: workspace, title: "Skills", symbol: "book.closed", item: .skills, shortcut: "⇧⌘2", onNavigate: onNavigate)
    }

    /// The navigation rows' height (and the Projects section's), so states centre in the space
    /// below them.
    private var navigationHeight: CGFloat {
        guard botRoster == nil else { return 4 * SidebarMetrics.rowHeight }
        // The filters, under the navigation rows.
        guard workspace.inboxFilter == .all else { return 3 * SidebarMetrics.rowHeight + InboxFilterChips.height }
        let projects = workspace.projects!
        guard projects.isAvailable else { return 3 * SidebarMetrics.rowHeight }
        let expanded = UserDefaults.standard.object(forKey: "sidebar.projectsExpanded") as? Bool ?? false
        let rows = expanded ? projects.sidebarProjects.count + 1 : 0
        return CGFloat(3 + rows) * SidebarMetrics.rowHeight + 38 + InboxFilterChips.height
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSections: some View {
        let shown = workspace.inboxSessions
        ForEach(shown, id: \.stableID) { session in
            sessionRow(session)
        }
        if workspace.inboxFilter == .unread, !shown.isEmpty {
            // Mark All as Read, at the end of the Unread list (`docs/inbox.md` §5).
            Button("Mark All as Read") {
                Task { await workspace.unread.markAllRead(workspace.unreadChatKeys) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .modifier(SidebarRowInsets())
        }
        if workspace.hasMoreSessions && workspace.inboxFilter == .all {
            SkeletonRows(count: 2)
                .padding(.vertical, 8)
                .modifier(SidebarRowInsets())
                .task { await workspace.loadMoreSessions() }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: HermesSession) -> some View {
        if workspace.waitingChat(forKey: session.stableID) != nil {
            waitingRow(session)
        } else {
            listedRow(session)
        }
    }

    /// A new chat whose first message waits for the gateway (`docs/chat.md` §4): nothing to mark,
    /// pin or archive on Hermes yet, so Delete is all it offers.
    @ViewBuilder
    private func waitingRow(_ session: HermesSession) -> some View {
        SessionRow(session: session, workspace: workspace, onNavigate: onNavigate)
            .contextMenu {
                Button("Delete…", systemImage: "trash", role: .destructive) { deleting = session }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if style == .split || DrawerSwipe.isSystems {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
                }
            }
            .modifier(DrawerSwipeActions(
                isInDrawer: style == .drawer,
                leading: [],
                trailing: [SwipeTile(title: String(localized: "Delete"), symbol: "trash") { deleting = session }]
            ))
            .accessibilityAction(named: Text("Delete")) { deleting = session }
    }

    @ViewBuilder
    private func listedRow(_ session: HermesSession) -> some View {
        let key = session.stableID
        let isUnread = workspace.unread.badge(for: key).isUnread || workspace.unread.readMark(for: key) == .markedUnread
        let muted = workspace.unread.isMuted(key)
        SessionRow(session: session, workspace: workspace, onNavigate: onNavigate)
            .contextMenu { contextMenu(for: session) }
            // The system's swipes everywhere from iOS 27; before it the drawer's rows, which
            // aren't in a List, swipe on their own (`DrawerSwipeActions`).
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if style == .split || DrawerSwipe.isSystems {
                    Button(isUnread ? "Read" : "Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") { toggleRead(key, isUnread: isUnread) }
                        .tint(Theme.swipeAction)
                    Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") { togglePin(session) }
                        .tint(Theme.swipeActionQuiet)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if style == .split || DrawerSwipe.isSystems {
                    Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") { toggleMute(key, muted: muted) }
                        .tint(Theme.swipeActionQuiet)
                    Button("Archive", systemImage: "archivebox") { archive(session) }
                        .tint(Theme.swipeActionQuiet)
                }
            }
            .modifier(DrawerSwipeActions(
                isInDrawer: style == .drawer,
                leading: [
                    SwipeTile(title: isUnread ? String(localized: "Read") : String(localized: "Unread"), symbol: isUnread ? "envelope.open" : "envelope.badge", isInk: true) { toggleRead(key, isUnread: isUnread) },
                    SwipeTile(title: session.pinned ? String(localized: "Unpin") : String(localized: "Pin"), symbol: session.pinned ? "pin.slash" : "pin") { togglePin(session) },
                ],
                trailing: [
                    SwipeTile(title: muted ? String(localized: "Unmute") : String(localized: "Mute"), symbol: muted ? "bell" : "bell.slash") { toggleMute(key, muted: muted) },
                    SwipeTile(title: String(localized: "Archive"), symbol: "archivebox") { archive(session) },
                ]
            ))
            .modifier(DrawerSwipeState(isInDrawer: style == .drawer, value: [isUnread, session.pinned, muted]))
            .accessibilityAction(named: isUnread ? Text("Mark as Read") : Text("Mark as Unread")) { toggleRead(key, isUnread: isUnread) }
            .accessibilityAction(named: session.pinned ? Text("Unpin") : Text("Pin")) { togglePin(session) }
            .accessibilityAction(named: muted ? Text("Unmute") : Text("Mute")) { toggleMute(key, muted: muted) }
            .accessibilityAction(named: Text("Archive")) { archive(session) }
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
        Task { await run { try await workspace.archive(session) } }
    }

    @ViewBuilder
    private func contextMenu(for session: HermesSession) -> some View {
        let key = session.stableID
        let isUnread = workspace.unread.badge(for: key).isUnread || workspace.unread.readMark(for: key) == .markedUnread
        Button(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") {
            toggleRead(key, isUnread: isUnread)
        }
        Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") {
            togglePin(session)
        }
        MuteMenu(unread: workspace.unread, key: key)
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renameText = session.title ?? ""
            renaming = session
        }
        if workspace.projects.isAvailable {
            Button("Move to Project…", systemImage: "folder") {
                workspace.projects.movingSession = session
            }
        }
        if workspace.capabilities?.features.sessionFork != false {
            Button("Branch", systemImage: "arrow.triangle.branch") {
                Task {
                    await run { try await workspace.fork(session) }
                    onNavigate()
                }
            }
        }
        // Checkpoints live on the gateway's socket (Bot Mode).
        if workspace.roster?.isConnected == true {
            Button("Checkpoints…", systemImage: "clock.arrow.circlepath") {
                workspace.showCheckpoints(for: session)
                onNavigate()
            }
        }
        Button("Copy Session ID", systemImage: "number") {
            Pasteboard.copy(session.id)
        }
        #if os(macOS)
        // No swipe without a trackpad: Archive is here too.
        Button("Archive", systemImage: "archivebox") {
            archive(session)
        }
        #endif
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            deleting = session
        }
    }

    // MARK: States

    @ViewBuilder
    private var stateView: some View {
        if let roster = botRoster {
            botsState(roster)
        } else if isSearching {
            if workspace.search.isEmpty {
                SearchEmptyState(search: workspace.search)
            }
        } else if workspace.inboxFilter != .all {
            if workspace.inboxSessions.isEmpty {
                CaughtUpState(filter: workspace.inboxFilter)
            }
        } else if workspace.sessions.isEmpty, !workspace.isLoadingSessions {
            switch workspace.connection {
            case .online:
                SidebarState(
                    symbol: "bubble.left.and.bubble.right",
                    title: String(localized: "No chats yet"),
                    message: String(localized: "Your conversations with \(workspace.bot.name) appear here, including ones from Telegram, Discord and the CLI.")
                )
            case .connecting, .idle:
                SidebarState(isLoading: true, title: String(localized: "Connecting to \(workspace.bot.name)…"))
            case .failed(let error):
                SidebarState(
                    symbol: "wifi.slash",
                    title: String(localized: "Can't reach \(workspace.bot.name)"),
                    message: error.errorDescription,
                    actionTitle: String(localized: "Retry")
                ) {
                    Task { await workspace.connect() }
                }
            }
        }
    }

    @ViewBuilder
    private func botsState(_ roster: BotRoster) -> some View {
        switch roster.state {
        case .connecting, .idle:
            if !roster.hasLoaded {
                SidebarState(isLoading: true, title: String(localized: "Connecting to your Bots…"))
            }
        case .signInRequired(let message):
            SidebarState(
                symbol: "person.badge.key",
                title: String(localized: "Sign in to see your Bots"),
                message: message,
                actionTitle: String(localized: "Sign In…")
            ) {
                router?.sheet = .editGateway(workspace.bot)
            }
        case .failed(let reason) where !roster.hasLoaded:
            // With Bots already listed the footer says "offline" and the chat a banner; drawing
            // this over the rows only hid them. The roster's reason first (`docs/setup.md` §4.1).
            SidebarState(
                symbol: "wifi.slash",
                title: String(localized: "Bots are offline"),
                message: reason.isEmpty ? String(localized: "Check that hermes serve is running on \(workspace.bot.name), then try again.") : reason,
                actionTitle: String(localized: "Retry")
            ) {
                Task { await roster.reconnectNow() }
            }
        case .failed:
            EmptyView()
        case .online:
            if roster.hasLoaded, roster.profiles.isEmpty {
                SidebarState(
                    symbol: "face.smiling",
                    title: String(localized: "No Bots yet"),
                    message: String(localized: "Create one to give it a name, a face and its own chat."),
                    actionTitle: String(localized: "New Bot")
                ) {
                    roster.isCreatingBot = true
                }
            } else if isSearching, !roster.profiles.contains(where: { BotRosterSections.matches($0, query) }) {
                SidebarState(symbol: "magnifyingglass", title: String(localized: "No Bots match “\(query)”"))
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        if let botRoster {
            await botRoster.refresh()
        } else {
            await workspace.refreshSessions()
        }
    }

    private func commitRename() {
        guard let session = renaming else { return }
        let title = renameText
        Task { await run { try await workspace.rename(session, to: title) } }
    }

    private func delete(_ session: HermesSession) {
        Task { await run { try await workspace.delete(session) } }
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            actionError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}

/// A chat in the list. It reads the selection and its state itself, so picking a chat redraws
/// rows, not the whole sidebar.
private struct SessionRow: View {
    let session: HermesSession
    let workspace: BotWorkspace
    let onNavigate: () -> Void

    var body: some View {
        let item = SidebarItem.session(session.stableID)
        let isSelected = workspace.selection == item
        SidebarRow(isSelected: isSelected, height: InboxMetrics.rowHeight) {
            workspace.selection = item
            onNavigate()
        } label: {
            ChatInboxRow(session: session, workspace: workspace, isSelected: isSelected)
        }
    }
}

/// All Bots, Tasks, Skills: reads the selection itself, like `SessionRow`.
private struct DestinationRow: View {
    let workspace: BotWorkspace
    let title: LocalizedStringKey
    let symbol: String
    let item: SidebarItem?
    var shortcut: String?
    let onNavigate: () -> Void

    var body: some View {
        SidebarNavRow(title: title, symbol: symbol, isSelected: workspace.selection == item, shortcut: shortcut) {
            workspace.selection = item
            onNavigate()
        }
    }
}

/// The gateway in front, and a menu to switch or add one.
struct BotSwitcher: View {
    let workspace: BotWorkspace
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.displayScale) private var displayScale
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    private var statusLine: String {
        switch workspace.connection {
        case .online where workspace.isBusy: String(localized: "Connected · \(workspace.bot.name) is busy, replies are slow")
        case .online(let version): version.map { String(localized: "Connected to Hermes \($0)") } ?? String(localized: "Connected")
        case .connecting where workspace.isBusy: String(localized: "Waiting for \(workspace.bot.name), it's busy…")
        case .connecting, .idle: String(localized: "Connecting…")
        case .failed: String(localized: "Offline")
        }
    }

    var body: some View {
        Menu {
            Section("Hermes Gateways") {
                ForEach(app.bots) { bot in
                    Toggle(isOn: Binding(get: { bot.id == app.selectedBotID }, set: { if $0 { app.select(bot.id) } })) {
                        Label {
                            Text(bot.name)
                            Text(subtitle(for: bot))
                        } icon: {
                            GatewayAvatarImage(bot: bot, scale: displayScale)
                        }
                    }
                }
            }
            Divider()
            Button("Add Gateway…", systemImage: "plus") {
                router?.sheet = .addGateway
            }
            Button("Pair a Device…", systemImage: "qrcode") {
                router?.sheet = .pairing(workspace.bot.id)
            }
            Button("Manage Gateways…", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                router?.sheet = .settings
                #endif
            }
        } label: {
            HStack(spacing: 10) {
                BotAvatar(bot: workspace.bot, size: SidebarMetrics.avatarSize)
                Text(workspace.bot.name)
                    .font(SidebarMetrics.gatewayFont)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .frame(minHeight: SidebarMetrics.avatarSize + 12)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Gateway: \(workspace.bot.name), \(statusLine)")
        .accessibilityHint("Switch Hermes gateways")
    }

    /// "Connected · Bot Mode" for the current gateway; the address for the others.
    private func subtitle(for bot: BotConfiguration) -> String {
        guard bot.id == app.selectedBotID else { return bot.displayAddress }
        let state: String = switch workspace.connection {
        case .online: String(localized: "Connected")
        case .connecting, .idle: String(localized: "Connecting…")
        case .failed: String(localized: "Offline")
        }
        return bot.backend == nil ? state : String(localized: "\(state) · Bot Mode")
    }
}

/// A gateway's avatar as an image, for menus (which only draw images and symbols). Drawn with
/// Core Graphics: rendering a SwiftUI view while SwiftUI builds the menu wedges the display.
private struct GatewayAvatarImage: View {
    let bot: BotConfiguration
    let scale: CGFloat

    var body: some View {
        GatewayAvatarRasterizer.image(for: BotAccent(rawValue: bot.accent) ?? .graphite, scale: scale)
    }
}

enum GatewayAvatarRasterizer {
    private static var cache: [String: Image] = [:]

    static func image(for accent: BotAccent, size: CGFloat = 22, scale: CGFloat) -> Image {
        let key = "\(accent.rawValue)-\(scale)"
        if let cached = cache[key] { return cached }
        let image = draw(accent, size: size, scale: scale)
        cache[key] = image
        return image
    }

    private static func paint(_ context: CGContext, accent: BotAccent, size: CGFloat, top: CGColor, bottom: CGColor, flipped: Bool) {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        context.addEllipse(in: rect)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            let start = CGPoint(x: size / 2, y: flipped ? size : 0)
            let end = CGPoint(x: size / 2, y: flipped ? 0 : size)
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        let wing = size * 0.56
        var transform = flipped
            ? CGAffineTransform(translationX: 0, y: size).scaledBy(x: 1, y: -1)
            : .identity
        if let path = HermesMarkPath.path(in: CGRect(x: (size - wing) / 2, y: (size - wing) / 2, width: wing, height: wing)).copy(using: &transform) {
            context.addPath(path)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
    }

    private static func draw(_ accent: BotAccent, size: CGFloat, scale: CGFloat) -> Image {
        #if os(macOS)
        // Drawn now, into a bitmap: an NSImage drawing handler runs whenever and on whatever
        // thread the image is drawn (menus draw off main), and this one is main-actor code.
        let pixels = max(1, Int((size * max(scale, 2)).rounded()))
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Image(systemName: "circle.fill") }
        context.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
        paint(context, accent: accent, size: size,
              top: NSColor(accent.color).cgColor, bottom: NSColor(accent.deep).cgColor, flipped: true)
        guard let cgImage = context.makeImage() else { return Image(systemName: "circle.fill") }
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: size, height: size)))
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            paint(context.cgContext, accent: accent, size: size,
                  top: UIColor(accent.color).cgColor, bottom: UIColor(accent.deep).cgColor, flipped: false)
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
        #endif
    }
}

/// How the gateway (and in Bots mode, Bot Mode) is doing: a status dot and one line.
struct ConnectionStatusLabel: View {
    let workspace: BotWorkspace

    var body: some View {
        HStack(spacing: 8) {
            if workspace.sidebarMode == .bots, let roster = workspace.roster {
                botStatus(roster)
            } else {
                gatewayStatus
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var gatewayStatus: some View {
        switch workspace.connection {
        case .online where workspace.isBusy:
            // Its Mac is overloaded: everything still works, only slowly.
            StatusDot(color: Theme.warning)
            Text("Connected · busy, replies are slow")
        case .online(let version):
            StatusDot(color: Theme.success)
            Text(version.map { String(localized: "Connected · Hermes \($0)") } ?? String(localized: "Connected"))
        case .connecting where workspace.isBusy:
            StatusDot(color: Theme.warning)
            Text("Waiting for a busy Mac…")
        case .connecting, .idle:
            StatusDot(color: Theme.warning)
            Text("Connecting…")
        case .failed:
            StatusDot(color: Theme.danger)
            Text("Offline")
        }
    }

    @ViewBuilder
    private func botStatus(_ roster: BotRoster) -> some View {
        switch roster.state {
        case .online where roster.isBusy:
            StatusDot(color: Theme.warning)
            Text("\(workspace.bot.name) is busy · Bots are slow")
        case .online(let version):
            StatusDot(color: Theme.success)
            Text(version.map { String(localized: "Connected · Hermes \($0)") } ?? String(localized: "Connected"))
        case .connecting, .idle:
            StatusDot(color: Theme.warning)
            if roster.isBusy {
                Text("\(workspace.bot.name) is busy · Bots will catch up")
            } else {
                Text(roster.hasLoaded ? "Reconnecting…" : "Connecting…")
            }
        case .signInRequired:
            StatusDot(color: Theme.warning)
            Text("Sign-in needed")
        case .failed:
            StatusDot(color: Theme.danger)
            Text("Bots offline · chats still work")
        }
    }
}

/// The search field at the top of the sidebar and drawer.
struct SearchField: View {
    @Binding var text: String
    var prompt: LocalizedStringKey = "Search chats"
    /// Bumped to put the field in focus (⌥⌘F, Show All Results).
    var focusRequest = 0

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($focused)
                .onChange(of: focusRequest) { focused = true }
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        #if os(macOS)
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        #else
        .font(.body)
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Theme.controlFill, in: Capsule())
        #endif
    }
}
