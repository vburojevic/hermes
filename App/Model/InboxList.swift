import Foundation
import HermesKit

/// The filters over the chat list (`filterChip`, `docs/inbox.md` §5).
enum InboxFilter: String, CaseIterable {
    case all, unread, needsYou, running

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unread: String(localized: "Unread")
        case .needsYou: String(localized: "Needs You")
        case .running: String(localized: "Running")
        }
    }
}

extension BotWorkspace {
    /// The chats in the list: pinned first, then by activity, newest first; no date sections
    /// (`docs/inbox.md` §2). Without a filter, chats in a project stay in the project (pinned
    /// ones show here too); a filter covers every chat.
    var inboxSessions: [HermesSession] {
        let projects = projects!
        let shown = inboxFilter == .all
            ? sessions.filter { $0.pinned || !projects.isScoped($0) }
            : sessions.filter { matches(inboxFilter, key: $0.stableID) }
        let ordered = Self.inboxOrder(shown)
        // New chats whose first message waits for the gateway, under the pinned ones (`docs/chat.md` §4).
        guard inboxFilter == .all, !waitingChats.isEmpty else { return ordered }
        let waiting = WaitingChat.rows(waitingChats, listed: Set(sessions.map(\.stableID)))
        let pinned = ordered.prefix { $0.pinned }.count
        return Array(ordered[..<pinned]) + waiting + ordered[pinned...]
    }

    static func inboxOrder(_ sessions: [HermesSession]) -> [HermesSession] {
        sessions.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            let (x, y) = (a.element.activityDate, b.element.activityDate)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    func matches(_ filter: InboxFilter, key: String) -> Bool {
        switch filter {
        case .all: true
        case .unread: unread.badge(for: key).isUnread
        case .needsYou: activity.line(for: key)?.needsYou == true
        case .running: activity.line(for: key).map { $0.isLive && !$0.needsYou } ?? false
        }
    }

    /// How many chats a filter would show.
    func count(for filter: InboxFilter) -> Int {
        sessions.reduce(0) { matches(filter, key: $1.stableID) ? $0 + 1 : $0 }
    }

    /// The chats' keys, for Mark All as Read.
    var unreadChatKeys: [String] {
        sessions.map(\.stableID).filter { unread.badge(for: $0).isUnread }
    }

    /// ⌥⌘↓ / ⌥⌘↑: the next or previous unread chat (or Bot) along the list.
    func selectAdjacentUnread(_ step: Int) {
        let order = sidebarOrder
        let unreadItems = order.filter { item in
            switch item {
            case .session(let key): unread.badge(for: key).isUnread
            case .bot(let name): unread.badge(for: UnreadStore.botKey(name)).isUnread
            case .group(let id): unread.badge(for: UnreadStore.groupKey(id)).isUnread
            default: false
            }
        }
        guard !unreadItems.isEmpty else { return }
        let current = selection.flatMap { order.firstIndex(of: $0) } ?? (step > 0 ? -1 : order.count)
        let next = step > 0
            ? unreadItems.first { order.firstIndex(of: $0)! > current } ?? unreadItems.first
            : unreadItems.last { order.firstIndex(of: $0)! < current } ?? unreadItems.last
        selection = next
    }

    /// The open chat's inbox key and whether it's unread, for ⇧⌘U.
    func toggleOpenChatRead() {
        guard let key = unread.openKey else { return }
        if unread.readMark(for: key) == .markedUnread || unread.badge(for: key).isUnread {
            unread.markRead(key)
        } else {
            unread.markUnread(key)
            // Marked unread: it reads as new next time; the chat stays open meanwhile.
        }
    }
}
