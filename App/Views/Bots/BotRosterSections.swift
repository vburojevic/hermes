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
        return SidebarRow(isSelected: workspace.selection == item, height: SidebarMetrics.botRowHeight) {
            workspace.selection = item
            onNavigate()
        } label: {
            BotRowLabel(roster: roster, bot: bot)
        }
        .contextMenu { BotActions(roster: roster, bot: bot, onError: { actionError = $0 }) }
    }

    /// A group chat (`groupRow`).
    private func groupRow(_ room: GroupRoom) -> some View {
        let item = SidebarItem.group(room.id)
        let summary = roster.groupRooms.summary(for: room.id)
        let faces = room.members.prefix(2).compactMap { member in roster.bot(named: member.profile).map(roster.appearance(for:)) }
        return SidebarRow(isSelected: workspace.selection == item, height: SidebarMetrics.botRowHeight) {
            workspace.selection = item
            onNavigate()
        } label: {
            GroupRowLabel(
                name: room.name,
                memberCount: room.members.count,
                preview: summary.preview,
                date: room.updatedAt,
                needsYou: summary.needsYou,
                avatar: GroupAvatar(front: faces.last, back: faces.count > 1 ? faces.first : nil, size: SidebarMetrics.faceSize)
            )
        }
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

/// Face, name (with the "Active now" dot), the latest line, and a pin or unread dot.
struct BotRowLabel: View {
    let roster: BotRoster
    let bot: BotProfile

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isUnread: Bool { roster.unread.contains(bot.name) }
    private var isActive: Bool { roster.isActive(bot.name) }
    private var lines: Int { dynamicTypeSize.isAccessibilitySize ? 3 : 1 }

    /// Name first, then what matters: unread, active, the latest line, how long ago.
    private var spokenSummary: Text {
        var parts = [bot.title]
        if isUnread { parts.append(String(localized: "Unread")) }
        if isActive { parts.append(String(localized: "Active now")) }
        if bot.meta.isPinned { parts.append(String(localized: "Pinned")) }
        parts.append(line)
        if let date = bot.lastActive { parts.append(Formatting.relativePhrase(date)) }
        return Text(parts.joined(separator: ", "))
    }

    private var line: String {
        if roster.chatIsWorking(bot.name) { return String(localized: "Thinking…") }
        return bot.preview ?? bot.role ?? String(localized: "Say hi to \(bot.title)")
    }

    var body: some View {
        HStack(spacing: 12) {
            BotFace(appearance: roster.appearance(for: bot), size: SidebarMetrics.faceSize, mood: roster.faceMood(for: bot.name))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bot.title)
                        .font(SidebarMetrics.nameFont)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(lines)
                    if isActive {
                        ActiveDot()
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(line)
                    .font(SidebarMetrics.previewFont)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(lines)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if bot.meta.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 12, height: 12)
                }
                if isUnread {
                    Circle()
                        .fill(Theme.unread)
                        .frame(width: 9, height: 9)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(bot.meta.isHidden ? 0.75 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isUnread)
        .animation(Theme.gentle, value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }
}

/// The green "Active now" dot. It sends out a few soft rings when it lights up, then rests.
private struct ActiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulses = 0

    var body: some View {
        Circle()
            .fill(Theme.success)
            .frame(width: 7, height: 7)
            .background {
                if !reduceMotion {
                    Circle()
                        .fill(Theme.success.opacity(0.5))
                        .keyframeAnimator(initialValue: 0.0, trigger: pulses) { halo, progress in
                            halo
                                .scaleEffect(1 + progress * 1.3)
                                .opacity(progress == 0 ? 0 : 0.8 * (1 - progress))
                        } keyframes: { _ in
                            MoveKeyframe(0.0)
                            CubicKeyframe(1.0, duration: 1.3)
                            MoveKeyframe(0.0)
                            CubicKeyframe(1.0, duration: 1.3)
                            MoveKeyframe(0.0)
                            CubicKeyframe(1.0, duration: 1.3)
                            MoveKeyframe(0.0)
                        }
                }
            }
            .onAppear { pulses += 1 }
            .accessibilityHidden(true)
    }
}

/// The actions every Bot offers, in context menus and the chat's More menu.
struct BotActions: View {
    let roster: BotRoster
    let bot: BotProfile
    var onError: (HermesError) -> Void = { _ in }

    var body: some View {
        Button("Edit Bot…", systemImage: "slider.horizontal.3") {
            roster.editingBot = bot.name
        }
        Button("Routines…", systemImage: "alarm") {
            roster.routinesBot = bot.name
        }
        Divider()
        Button(bot.meta.isPinned ? "Unpin" : "Pin", systemImage: bot.meta.isPinned ? "pin.slash" : "pin") {
            run { try await roster.setPinned(bot.name, !bot.meta.isPinned) }
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
