import HermesKit
import HermesPush
import SwiftUI

/// A chat in the list, two lines (`chatRow` and its variants, `docs/inbox.md` §2): the title and
/// the time, then the last message or what's happening, then what's new.
struct ChatInboxRow: View {
    let session: HermesSession
    let workspace: BotWorkspace
    var isSelected = false

    var body: some View {
        let key = session.stableID
        let unread = workspace.unread
        let line = workspace.activity.line(for: key)
        // The open chat is read as it's shown; a running turn shows no count until it ends.
        let running = line.map { $0.isLive && !$0.needsYou } ?? false
        let badge: UnreadBadge = isSelected || running ? .none : unread.badge(for: key)
        let muted = unread.isMuted(key)
        // The open chat's draft is in its composer; the others' show on their row.
        let draft = isSelected ? nil : workspace.loadedConversation(forKey: key).flatMap { $0.hasDraftText ? $0.draft : nil }
        let lastLine = unread.lastLines[key]
        let strong = badge.isUnread || (line?.isLive ?? false)
        InboxRowLayout(
            title: session.displayTitle,
            date: session.activityDate,
            strong: strong,
            live: line?.isLive == true && line?.needsYou == false,
            muted: muted,
            pinned: session.pinned,
            badge: badge,
            needsYou: line?.needsYou ?? false
        ) {
            if let line {
                ActivityLineView(line: line)
            } else if let draft {
                RowPreview(prefix: String(localized: "Draft:"), prefixIsInk: true, text: LastLine.flatten(draft), bright: false)
            } else if let lastLine {
                RowPreview(lastLine, bright: badge.isUnread)
            } else {
                RowPreview(prefix: nil, text: session.preview ?? "", bright: badge.isUnread)
                    .onAppear { unread.needsLastLine(session) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(title: session.displayTitle, badge: badge, muted: muted, pinned: session.pinned, line: line,
                                        date: session.activityDate, preview: lastLine?.text ?? session.preview))
    }

    /// "Release notes for 1.3, 3 unread, 14:21, 23 merged PRs" (`docs/inbox.md` §6).
    static func spoken(title: String, badge: UnreadBadge, muted: Bool, pinned: Bool, line: ActivityLine?, date: Date?, preview: String?) -> String {
        var parts = [title]
        if muted { parts.append(String(localized: "muted")) }
        switch badge {
        case .count(let count): parts.append(count == 1 ? String(localized: "1 unread") : String(localized: "\(UnreadCounter.label(count)) unread"))
        case .dot: parts.append(String(localized: "marked unread"))
        case .none: break
        }
        if pinned { parts.append(String(localized: "pinned")) }
        if let line {
            parts.append(line.spoken)
        } else {
            if let date { parts.append(InboxTimeText.spoken(date)) }
            if let preview, !preview.isEmpty { parts.append(LastLine.flatten(preview)) }
        }
        return parts.joined(separator: ", ")
    }
}

/// A Bot in the list (`botInboxRow` and its variants): its face in the mood of what it's doing,
/// the name, then the same second line and marks as a chat.
struct BotInboxRow: View {
    let roster: BotRoster
    let bot: BotProfile
    let workspace: BotWorkspace
    var isSelected = false

    var body: some View {
        let key = UnreadStore.botKey(bot.name)
        let unread = workspace.unread
        let badge: UnreadBadge = isSelected ? .none : unread.badge(for: key)
        let muted = unread.isMuted(key)
        let line = workspace.activity.line(for: key)
        let lastLine = unread.lastLines[key]
        let mood = ActivityLine.faceMood(for: line, justReplied: workspace.activity.justReplied.contains(bot.name), muted: muted,
                                         otherwise: roster.faceMood(for: bot.name))
        HStack(spacing: 12) {
            BotFace(appearance: roster.appearance(for: bot), size: InboxMetrics.faceSize, mood: mood, needsYou: line?.needsYou ?? false)
                .opacity(bot.meta.isHidden ? 0.75 : 1)
            InboxRowLayout(
                title: bot.title,
                date: bot.lastActive,
                strong: true,
                emphasizeTime: badge.isUnread || (line?.isLive ?? false),
                live: false,
                routine: { if case .routine = line { true } else { false } }(),
                muted: muted,
                pinned: bot.meta.isPinned,
                badge: badge,
                needsYou: line?.needsYou ?? false
            ) {
                if let line {
                    ActivityLineView(line: line)
                } else if let lastLine {
                    RowPreview(lastLine, bright: badge.isUnread)
                } else {
                    RowPreview(prefix: nil, text: bot.preview ?? bot.role ?? String(localized: "Say hi to \(bot.title)"), bright: badge.isUnread)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatInboxRow.spoken(title: bot.title, badge: badge, muted: muted, pinned: bot.meta.isPinned, line: line,
                                                date: bot.lastActive, preview: lastLine?.text ?? bot.preview))
    }
}

/// A group chat (`groupInboxRow`): the members' faces (who's working in front), who's doing
/// what, a mention and the count.
struct GroupInboxRow: View {
    let room: GroupRoom
    let roster: BotRoster
    let workspace: BotWorkspace
    var isSelected = false

    var body: some View {
        let key = UnreadStore.groupKey(room.id)
        let unread = workspace.unread
        let badge: UnreadBadge = isSelected ? .none : unread.badge(for: key)
        let muted = unread.isMuted(key)
        let summary = roster.groupRooms.summary(for: room.id)
        let mentioned = !isSelected && roster.groupRooms.mentions[room.id] != nil
        let working = roster.groupRooms.workingMembers(room.id)
        let faces = Self.faces(room: room, working: working, roster: roster)
        HStack(spacing: 12) {
            GroupAvatar(front: faces.front, back: faces.back, size: InboxMetrics.faceSize)
            InboxRowLayout(
                title: room.name,
                date: room.updatedAt,
                strong: true,
                emphasizeTime: badge.isUnread || !working.isEmpty,
                live: false,
                muted: muted,
                pinned: false,
                badge: badge,
                needsYou: summary.needsYou,
                mentioned: mentioned
            ) {
                if !working.isEmpty {
                    ShimmerText(text: Self.workingLine(working, room: room, roster: roster), font: InboxMetrics.lineFont, tone: .row)
                } else {
                    RowPreview(prefix: nil, text: summary.preview ?? String(localized: "\(room.members.count) Bots"), bright: badge.isUnread)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatInboxRow.spoken(title: room.name, badge: badge, muted: muted, pinned: false, line: nil,
                                                date: room.updatedAt, preview: summary.preview)
                            + (mentioned ? ", " + String(localized: "mentions you") : "")
                            + (summary.needsYou ? ", " + String(localized: "waiting for your approval") : ""))
    }

    /// The member at work in front, the next behind.
    private static func faces(room: GroupRoom, working: [String], roster: BotRoster) -> (front: BotAppearance?, back: BotAppearance?) {
        let ordered = working + room.members.map(\.memberID).filter { !working.contains($0) }
        let appearances = ordered.prefix(2).compactMap { id in
            room.members.first { $0.memberID == id }.flatMap { roster.bot(named: $0.profile) }.map(roster.appearance(for:))
        }
        return (appearances.first, appearances.count > 1 ? appearances[1] : nil)
    }

    /// "Ada is working…", "Ada and Ops are working…".
    private static func workingLine(_ working: [String], room: GroupRoom, roster: BotRoster) -> String {
        let names = working.prefix(2).map { id in
            room.members.first { $0.memberID == id }.map { $0.displayName ?? roster.bot(named: $0.profile)?.title ?? $0.profile } ?? id
        }
        return names.count == 1 ? String(localized: "\(names[0]) is working…") : String(localized: "\(names[0]) and \(names[1]) are working…")
    }
}

// MARK: - Layout

/// Two lines: the title and the time; the second line and what's new.
struct InboxRowLayout<Line: View>: View {
    let title: String
    let date: Date?
    /// Semibold: unread, running, or a Bot's name.
    let strong: Bool
    var emphasizeTime: Bool?
    let live: Bool
    var routine = false
    let muted: Bool
    let pinned: Bool
    let badge: UnreadBadge
    let needsYou: Bool
    var mentioned = false
    @ViewBuilder let line: Line

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: InboxMetrics.lineSpacing) {
            HStack(spacing: 6) {
                if live {
                    LiveDot()
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .font(strong ? InboxMetrics.unreadTitleFont : InboxMetrics.titleFont)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if routine { mark("clock") }
                if muted { mark("bell.slash.fill") }
                if pinned { mark("pin.fill") }
                if let date {
                    InboxTimeText(date: date, emphasized: emphasizeTime ?? strong)
                }
            }
            HStack(spacing: 6) {
                line
                    .frame(maxWidth: .infinity, alignment: .leading)
                RowTrailingMarks(badge: badge, muted: muted, needsYou: needsYou, mentioned: mentioned)
            }
        }
        .animation(.easeOut(duration: 0.2), value: strong)
        .animation(.easeOut(duration: 0.2), value: live)
        .frame(minHeight: InboxMetrics.rowHeight - 18)
    }

    private func mark(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: InboxMetrics.glyphSize * 0.9))
            .foregroundStyle(Theme.tertiaryText)
            .accessibilityHidden(true)
    }
}

/// The last message on one line: "You:" (or a Bot's name, or "Draft:") before it.
struct RowPreview: View {
    var prefix: String?
    var prefixIsInk = false
    let text: String
    let bright: Bool

    init(prefix: String?, prefixIsInk: Bool = false, text: String, bright: Bool) {
        self.prefix = prefix
        self.prefixIsInk = prefixIsInk
        self.text = text
        self.bright = bright
    }

    init(_ line: LastLine, bright: Bool) {
        switch line.speaker {
        case .hermes: prefix = nil
        case .you: prefix = String(localized: "You:")
        case .named(let name): prefix = "\(name):"
        }
        text = line.text
        self.bright = bright
    }

    var body: some View {
        HStack(spacing: 4) {
            if let prefix {
                Text(prefix)
                    .fontWeight(prefixIsInk ? .semibold : .regular)
                    .foregroundStyle(prefixIsInk ? Theme.primaryText : Theme.tertiaryText)
                    .layoutPriority(1)
            }
            Text(text)
                .foregroundStyle(bright ? Theme.primaryText : Theme.secondaryText)
        }
        .font(InboxMetrics.lineFont)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
