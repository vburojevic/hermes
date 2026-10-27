import HermesKit
import SwiftUI

/// The Bots half of the sidebar: "Your Bots", pinned first, then by recency; hidden Bots fold
/// away under their own row (Elyx `Sidebar.sidebarBots`).
struct BotRosterSections: View {
    let roster: BotRoster
    @Bindable var workspace: BotWorkspace
    var onNavigate: () -> Void = {}

    @State private var showsHidden = false
    @State private var actionError: HermesError?
    @Environment(\.sidebarRowsInStack) private var inStack

    private var query: String {
        workspace.searchText.trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ bot: BotProfile, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return bot.title.localizedCaseInsensitiveContains(query)
            || bot.handle.localizedCaseInsensitiveContains(query)
            || (bot.role?.localizedCaseInsensitiveContains(query) ?? false)
    }

    var body: some View {
        let visible = roster.visibleBots.filter { Self.matches($0, query) }
        let hidden = roster.hiddenBots.filter { Self.matches($0, query) }
        Group {
            let rooms = roster.groupRooms.rooms.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            if !visible.isEmpty || !rooms.isEmpty {
                SidebarSectionTitle(title: String(localized: "Your Bots"))
                ForEach(rooms) { room in
                    groupRow(room)
                }
                ForEach(visible) { bot in
                    botRow(bot)
                }
            }
            if !hidden.isEmpty {
                hiddenToggle(count: hidden.count)
                if showsHidden || !query.isEmpty {
                    ForEach(hidden) { bot in
                        botRow(bot)
                    }
                }
            }
        }
        .alert("Something went wrong", isPresented: errorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
    }

    // MARK: Rows

    private func botRow(_ bot: BotProfile) -> some View {
        let item = SidebarItem.bot(bot.name)
        let key = UnreadStore.botKey(bot.name)
        let isSelected = workspace.selection == item
        let isUnread = workspace.unread.badge(for: key).isUnread
        let muted = workspace.unread.isMuted(key)
        return SidebarRow(isSelected: isSelected, height: InboxMetrics.botRowHeight) {
            workspace.pick(item)
            onNavigate()
        } label: {
            BotInboxRow(roster: roster, bot: bot, workspace: workspace, isSelected: isSelected)
        }
        .contextMenu { BotActions(roster: roster, bot: bot, onError: { actionError = $0 }) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !inStack || DrawerSwipe.isSystems {
                Button(isUnread ? "Read" : "Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") { toggleRead(key, isUnread: isUnread) }
                    .tint(Theme.swipeAction)
                Button(bot.meta.isPinned ? "Unpin" : "Pin", systemImage: bot.meta.isPinned ? "pin.slash" : "pin") { togglePin(bot) }
                    .tint(Theme.swipeActionQuiet)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !inStack || DrawerSwipe.isSystems {
                Button(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash") { toggleMute(key, muted: muted) }
                    .tint(Theme.swipeActionQuiet)
            }
        }
        .modifier(DrawerSwipeActions(
            isInDrawer: inStack,
            leading: [
                SwipeTile(title: isUnread ? String(localized: "Read") : String(localized: "Unread"), symbol: isUnread ? "envelope.open" : "envelope.badge", isInk: true) { toggleRead(key, isUnread: isUnread) },
                SwipeTile(title: bot.meta.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), symbol: bot.meta.isPinned ? "pin.slash" : "pin") { togglePin(bot) },
            ],
            trailing: [
                SwipeTile(title: muted ? String(localized: "Unmute") : String(localized: "Mute"), symbol: muted ? "bell" : "bell.slash") { toggleMute(key, muted: muted) },
            ]
        ))
        .modifier(DrawerSwipeState(isInDrawer: inStack, value: [isUnread, bot.meta.isPinned, muted]))
        .accessibilityAction(named: isUnread ? Text("Mark as Read") : Text("Mark as Unread")) { toggleRead(key, isUnread: isUnread) }
        .accessibilityAction(named: bot.meta.isPinned ? Text("Unpin") : Text("Pin")) { togglePin(bot) }
        .accessibilityAction(named: muted ? Text("Unmute") : Text("Mute")) { toggleMute(key, muted: muted) }
    }

    private func toggleRead(_ key: String, isUnread: Bool) {
        if isUnread { workspace.unread.markRead(key) } else { workspace.unread.markUnread(key) }
    }

    private func togglePin(_ bot: BotProfile) {
        Task {
            do {
                try await roster.setPinned(bot.name, !bot.meta.isPinned)
            } catch {
                actionError = HermesError.botMode(error)
            }
        }
    }

    private func toggleMute(_ key: String, muted: Bool) {
        if muted { workspace.unread.unmute(key) } else { workspace.unread.mute(key, for: .untilTurnedOff) }
    }

    /// A group chat (`groupInboxRow`).
    private func groupRow(_ room: GroupRoom) -> some View {
        let item = SidebarItem.group(room.id)
        let key = UnreadStore.groupKey(room.id)
        let isSelected = workspace.selection == item
        let muted = workspace.unread.isMuted(key)
        return SidebarRow(isSelected: isSelected, height: InboxMetrics.botRowHeight) {
            workspace.pick(item)
            onNavigate()
        } label: {
            GroupInboxRow(room: room, roster: roster, workspace: workspace, isSelected: isSelected)
        }
        .contextMenu {
            if workspace.unread.badge(for: key).isUnread {
                Button("Mark as Read", systemImage: "envelope.open") { workspace.unread.markRead(key) }
            }
            MuteMenu(unread: workspace.unread, key: key)
        }
        .accessibilityAction(named: muted ? Text("Unmute") : Text("Mute")) { toggleMute(key, muted: muted) }
    }

    /// "Hidden · 2": folds the hidden Bots away.
    private func hiddenToggle(count: Int) -> some View {
        Button {
            withAnimation(Theme.spring) { showsHidden.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("Hidden · \(count)")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsHidden ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .font(SidebarMetrics.sectionFont)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(showsHidden ? Text("Expanded") : Text("Collapsed"))
        .modifier(SidebarRowInsets())
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}

/// The actions every Bot offers, in context menus and the chat's More menu.
struct BotActions: View {
    let roster: BotRoster
    let bot: BotProfile
    var onError: (HermesError) -> Void = { _ in }

    var body: some View {
        // Read state, Pin and Mute first (`botMenu`, `docs/inbox.md` §5).
        if let unread = roster.workspace?.unread {
            let key = UnreadStore.botKey(bot.name)
            let isUnread = unread.badge(for: key).isUnread || roster.markedUnread.contains(bot.name)
            Button(isUnread ? "Mark as Read" : "Mark as Unread", systemImage: isUnread ? "envelope.open" : "envelope.badge") {
                if isUnread { unread.markRead(key) } else { unread.markUnread(key) }
            }
        }
        Button(bot.meta.isPinned ? "Unpin" : "Pin", systemImage: bot.meta.isPinned ? "pin.slash" : "pin") {
            run { try await roster.setPinned(bot.name, !bot.meta.isPinned) }
        }
        if let unread = roster.workspace?.unread {
            MuteMenu(unread: unread, key: UnreadStore.botKey(bot.name))
        }
        Divider()
        Button("Edit Bot…", systemImage: "slider.horizontal.3") {
            roster.editingBot = bot.name
        }
        Button("Routines…", systemImage: "alarm") {
            roster.routinesBot = bot.name
        }
        Button(bot.meta.isHidden ? "Show in Roster" : "Hide from Roster", systemImage: bot.meta.isHidden ? "eye" : "eye.slash") {
            run { try await roster.setHidden(bot.name, !bot.meta.isHidden) }
        }
        Button("Copy @\(bot.mentionTag)", systemImage: "at") {
            Pasteboard.copy("@\(bot.mentionTag)")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                onError(HermesError.botMode(error))
            }
        }
    }
}

/// Why Bot Mode isn't available right now, with the way out.
struct BotModeProblem: View {
    let roster: BotRoster
    let message: String?
    let needsSignIn: Bool

    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(needsSignIn ? "Sign in to see your Bots" : "Bots are offline", systemImage: needsSignIn ? "person.badge.key" : "bolt.horizontal.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if needsSignIn {
                    Button("Sign In…") {
                        if let bot = app.bots.first(where: { $0.id == roster.botID }) {
                            router?.sheet = .editGateway(bot)
                        }
                    }
                } else {
                    Button("Retry") {
                        Task { await roster.reconnectNow() }
                    }
                }
            }
            .glassButton()
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .padding(.vertical, 4)
    }
}
