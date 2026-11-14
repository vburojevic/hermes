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

/// Show's choices, as the filter menu names them (`inboxFilterMenu`, `docs/inbox.md` §5).
extension InboxShow {
    var title: String {
        switch self {
        case .thisApp: String(localized: "This App")
        case .all: String(localized: "All Chats")
        case .otherPlatforms: String(localized: "Other Platforms")
        case .scheduled: String(localized: "Scheduled Tasks")
        }
    }

    /// Each launch starts with this app's chats. `-HERMES_INBOX_SHOW all|otherPlatforms|scheduled`
    /// starts with another choice, for screenshots.
    static var atLaunch: InboxShow {
        #if DEBUG
        UserDefaults.standard.string(forKey: "HERMES_INBOX_SHOW").flatMap(InboxShow.init(rawValue:)) ?? .thisApp
        #else
        .thisApp
        #endif
    }
}

extension BotWorkspace {
    /// The chats in the list: pinned first, then by activity, newest first; no date sections
    /// (`docs/inbox.md` §2). Show picks where they come from, this app's by default
    /// (`docs/inbox.md` §5). In the whole list (This App or All Chats, no Only), chats in a project
    /// stay in the project (pinned ones show here too); a narrower list covers every chat it holds.
    var inboxSessions: [HermesSession] {
        let projects = projects!
        let held = sessions.filter(shows)
        let shown = showsProjects
            ? held.filter { $0.pinned || !projects.isScoped($0) }
            : held.filter { matches(inboxFilter, key: $0.stableID) }
        let ordered = RowTime.ordered(shown, pinned: \.pinned) { self.rowTime($0) }
        // New chats whose first message waits for the gateway, under the pinned ones (`docs/chat.md` §4).
        // They are this app's, so they show wherever this app's chats do.
        guard inboxFilter == .all, inboxShow.includes(.thisApp), !waitingChats.isEmpty else { return ordered }
        let waiting = WaitingChat.rows(waitingChats, listed: Set(sessions.map(\.stableID)))
        let pinned = ordered.prefix { $0.pinned }.count
        return Array(ordered[..<pinned]) + waiting + ordered[pinned...]
    }

    /// A chat's time on its row and in the order (`RowTime`, `docs/inbox.md` §2): its last line's
    /// message, standing at its activity only while a turn runs in it.
    /// A project chat's time, by the same rule.
    func rowTime(_ row: ProjectSessionRow) -> Date? {
        let key = row.stableID
        return RowTime.of(line: unread.lastLines[key], live: activity.line(for: key)?.isLive == true,
                          activity: row.lastActive, created: row.startedAt)
    }

    func rowTime(_ session: HermesSession) -> Date? {
        let key = session.stableID
        return RowTime.of(line: unread.lastLines[key], live: activity.line(for: key)?.isLive == true,
                          activity: session.lastActive, created: session.startedAt)
    }

    /// Whether Show holds a chat (`docs/inbox.md` §5).
    func shows(_ session: HermesSession) -> Bool {
        inboxShow.shows(session.origin, pinned: session.pinned)
    }

    /// The list is whole: this app's chats or all of them, nothing narrowed to a state. Only then
    /// do projects keep their chats in the Projects section.
    var showsProjects: Bool {
        inboxFilter == .all && (inboxShow == .thisApp || inboxShow == .all)
    }

    /// Show holds no chat at all, projects' and new ones' included, while the gateway has some: the
    /// Show empty state (`caughtUpThisApp`…). With no chats at all, "No chats yet" says so instead.
    var showHoldsNothing: Bool {
        !sessions.isEmpty && !hasMoreSessions && !sessions.contains(where: shows)
            && (waitingChats.isEmpty || !inboxShow.includes(.thisApp))
    }

    func matches(_ filter: InboxFilter, key: String) -> Bool {
        switch filter {
        case .all: true
        case .unread: unread.badge(for: key).isUnread
        case .needsYou: activity.line(for: key)?.needsYou == true
        case .running: activity.line(for: key).map { $0.isLive && !$0.needsYou } ?? false
        }
    }

    /// How many of the chats Show holds a filter would show.
    func count(for filter: InboxFilter) -> Int {
        sessions.reduce(0) { shows($1) && matches(filter, key: $1.stableID) ? $0 + 1 : $0 }
    }

    /// The unread chats Show holds, for Mark All as Read.
    var unreadChatKeys: [String] {
        sessions.filter(shows).map(\.stableID).filter { unread.badge(for: $0).isUnread }
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
