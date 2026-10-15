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

    var body: some View {
        rows
        .animation(Theme.spring, value: botOrder)
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
        } message: { _ in
            Text("The conversation is removed from Hermes on every device.")
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
        case .drawer:
            // A lazy stack, not a List: a List is a collection view that lays out, sizes and
            // configures (separators, swipe actions) every visible row again on each change, so
            // picking a chat cost a long frame right as the drawer started to close. Here only
            // the rows whose highlight changed redraw.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { rowContent }
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
                ProjectSidebarSection(workspace: workspace, onNavigate: onNavigate)
            }
        }
        if let botRoster {
            BotRosterSections(roster: botRoster, workspace: workspace, onNavigate: onNavigate)
        } else {
            sessionSections
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: style == .drawer ? 12 : 10) {
            BotSwitcher(workspace: workspace)
            if let roster = workspace.roster {
                SidebarModeSwitcher(mode: $workspace.sidebarMode, roster: roster)
            }
            SearchField(text: $workspace.searchText, prompt: botRoster == nil ? "Search chats" : "Search Bots")
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
        let projects = workspace.projects!
        guard projects.isAvailable else { return 3 * SidebarMetrics.rowHeight }
        let expanded = UserDefaults.standard.object(forKey: "sidebar.projectsExpanded") as? Bool ?? true
        let rows = expanded ? projects.sidebarProjects.count + 1 : 0
        return CGFloat(3 + rows) * SidebarMetrics.rowHeight + 38
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSections: some View {
        ForEach(SessionGroup.grouped(filteredSessions), id: \.0) { group, sessions in
            SidebarSectionTitle(title: group.title)
            ForEach(sessions) { session in
                sessionRow(session)
            }
        }
        if workspace.hasMoreSessions && !isSearching {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 8)
            .modifier(SidebarRowInsets())
            .task { await workspace.loadMoreSessions() }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: HermesSession) -> some View {
        SessionRow(session: session, workspace: workspace, onNavigate: onNavigate)
        .contextMenu { contextMenu(for: session) }
        // In the drawer a leftward swipe closes the drawer, so actions live in the context menu.
        .swipeActions(edge: .trailing) {
            if style == .split {
                swipeButtons(for: session)
            }
        }
    }

    @ViewBuilder
    private func swipeButtons(for session: HermesSession) -> some View {
        Group {
            Button(role: .destructive) {
                deleting = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                Task { await run { try await workspace.setPinned(session, !session.pinned) } }
            } label: {
                Label(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin")
            }
            .tint(Theme.warning)
        }
    }

    @ViewBuilder
    private func contextMenu(for session: HermesSession) -> some View {
        Button("Rename…", systemImage: "pencil") {
            renameText = session.title ?? ""
            renaming = session
        }
        Button(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : "pin") {
            Task { await run { try await workspace.setPinned(session, !session.pinned) } }
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
        Button("Copy Session ID", systemImage: "number") {
            Pasteboard.copy(session.id)
        }
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
        } else if isSearching, filteredSessions.isEmpty {
            SidebarState(
                symbol: "magnifyingglass",
                title: String(localized: "No chats match “\(query)”"),
                message: workspace.roster == nil ? String(localized: "Try a different word.") : String(localized: "Try a different word, or search Bots instead.")
            )
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
        case .failed where !roster.hasLoaded:
            // With Bots already listed the footer says "offline" and the chat a banner; drawing
            // this over the rows only hid them.
            SidebarState(
                symbol: "wifi.slash",
                title: String(localized: "Bots are offline"),
                message: String(localized: "Check that hermes serve is running on \(workspace.bot.name), then try again."),
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

/// A chat in the history. It reads the selection and the working state itself, so picking a
/// chat redraws rows, not the whole sidebar (grouping the history by date included).
private struct SessionRow: View {
    let session: HermesSession
    let workspace: BotWorkspace
    let onNavigate: () -> Void

    var body: some View {
        let item = SidebarItem.session(session.stableID)
        let isSelected = workspace.selection == item
        SidebarRow(isSelected: isSelected) {
            workspace.selection = item
            onNavigate()
        } label: {
            SessionRowLabel(session: session, isWorking: workspace.isWorking(sessionKey: session.stableID), isSelected: isSelected)
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

/// A row in the history: the title, then what's going on with it: working, branched, pinned,
/// and where it started (only for chats that didn't start in the app).
struct SessionRowLabel: View {
    let session: HermesSession
    let isWorking: Bool
    var isSelected = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.displayTitle)
                .font(isSelected ? SidebarMetrics.selectedTitleFont : SidebarMetrics.titleFont)
                .lineLimit(1)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 4)
            if isWorking {
                StatusDot(color: Theme.warning, pulsing: true)
                    .accessibilityLabel("Working")
            }
            if session.endReason == "branched" {
                indicator("arrow.triangle.branch", size: 13)
                    .accessibilityLabel("Branched")
            }
            if session.pinned {
                indicator("pin.fill", size: 12)
                    .accessibilityLabel("Pinned")
            }
            if let source = SessionSource(session.source) {
                indicator(source.symbol, size: 14)
                    .help(source.label)
                    .accessibilityLabel(String(localized: "From \(source.label)"))
            }
        }
    }

    private func indicator(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.85))
            .foregroundStyle(Theme.tertiaryText)
            .frame(width: size, height: size)
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
        case .online(let version): version.map { String(localized: "Connected to Hermes \($0)") } ?? String(localized: "Connected")
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
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            paint(context, accent: accent, size: size,
                  top: NSColor(accent.color).cgColor, bottom: NSColor(accent.deep).cgColor, flipped: true)
            return true
        }
        return Image(nsImage: image)
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
        case .online(let version):
            StatusDot(color: Theme.success)
            Text(version.map { String(localized: "Connected · Hermes \($0)") } ?? String(localized: "Connected"))
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
        case .online(let version):
            StatusDot(color: Theme.success)
            Text(version.map { String(localized: "Connected · Hermes \($0)") } ?? String(localized: "Connected"))
        case .connecting, .idle:
            StatusDot(color: Theme.warning)
            Text(roster.hasLoaded ? "Reconnecting…" : "Connecting…")
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
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
