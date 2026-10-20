import Foundation
import HermesKit

enum Formatting {
    /// "4s", "1m 12s", "2h 5m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// Short relative time for lists: "now", "5m", "3h", "Tue", "12 Oct".
    static func shortRelative(_ date: Date, now: Date = .now) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return String(localized: "now") }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if Calendar.current.isDateInToday(date) { return "\(Int(interval / 3600))h" }
        if interval < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func relativePhrase(_ date: Date, now: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// The last path segment of a model id: `anthropic/claude-sonnet-4.6` → `claude-sonnet-4.6`.
    static func modelShortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

/// Date buckets for the session list, like Grok's history.
enum SessionGroup: Hashable, Comparable {
    case pinned
    case today
    case yesterday
    case previousWeek
    case previousMonth
    case month(year: Int, month: Int)

    var title: String {
        switch self {
        case .pinned: String(localized: "Pinned")
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .previousWeek: String(localized: "Previous 7 Days")
        case .previousMonth: String(localized: "Previous 30 Days")
        case .month(let year, let month):
            Calendar.current.date(from: DateComponents(year: year, month: month)).map {
                $0.formatted(.dateTime.month(.wide).year())
            } ?? ""
        }
    }

    private var rank: (Int, Int) {
        switch self {
        case .pinned: (0, 0)
        case .today: (1, 0)
        case .yesterday: (2, 0)
        case .previousWeek: (3, 0)
        case .previousMonth: (4, 0)
        case .month(let year, let month): (5, -(year * 12 + month))
        }
    }

    static func < (lhs: SessionGroup, rhs: SessionGroup) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Where the buckets start, worked out once for a whole list rather than per session.
    private struct Bounds {
        let calendar: Calendar
        let startOfTomorrow: Date
        let startOfToday: Date
        let startOfYesterday: Date
        let weekAgo: Date
        let monthAgo: Date

        init(now: Date, calendar: Calendar) {
            self.calendar = calendar
            startOfToday = calendar.startOfDay(for: now)
            startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
            startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
            monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        }
    }

    static func group(for session: HermesSession, now: Date = .now, calendar: Calendar = .current) -> SessionGroup {
        group(for: session, in: Bounds(now: now, calendar: calendar))
    }

    private static func group(for session: HermesSession, in bounds: Bounds) -> SessionGroup {
        if session.pinned { return .pinned }
        let date = session.activityDate
        if date >= bounds.startOfToday, date < bounds.startOfTomorrow { return .today }
        if date >= bounds.startOfYesterday, date < bounds.startOfToday { return .yesterday }
        if date >= bounds.weekAgo { return .previousWeek }
        if date >= bounds.monthAgo { return .previousMonth }
        let components = bounds.calendar.dateComponents([.year, .month], from: date)
        return .month(year: components.year ?? 1970, month: components.month ?? 1)
    }

    static func grouped(_ sessions: [HermesSession], now: Date = .now) -> [(SessionGroup, [HermesSession])] {
        let bounds = Bounds(now: now, calendar: .current)
        return Dictionary(grouping: sessions) { group(for: $0, in: bounds) }
            .map { ($0.key, $0.value.sorted { $0.activityDate > $1.activityDate }) }
            .sorted { $0.0 < $1.0 }
    }
}

/// Where a session came from, for the little badge in the sidebar.
struct SessionSource {
    let label: String
    let symbol: String

    init?(_ source: String?) {
        guard let source, source != "api_server" else { return nil }
        switch source {
        case "telegram": (label, symbol) = ("Telegram", "paperplane")
        case "discord": (label, symbol) = ("Discord", "gamecontroller")
        case "slack": (label, symbol) = ("Slack", "number")
        case "whatsapp": (label, symbol) = ("WhatsApp", "phone.bubble")
        case "signal": (label, symbol) = ("Signal", "bubble.left.and.text.bubble.right")
        case "email": (label, symbol) = ("Email", "envelope")
        case "sms": (label, symbol) = ("SMS", "message")
        case "cli", "tui": (label, symbol) = ("Terminal", "terminal")
        // This app starts chats as the desktop platform (Hermes's Inspector tools), so Desktop's
        // chats and its own read alike.
        case "desktop", "hermes_app": (label, symbol) = ("Hermes App", "bubble.left.and.bubble.right")
        case "dashboard", "hermes_browser": (label, symbol) = ("Dashboard", "safari")
        case "cron": (label, symbol) = ("Scheduled task", "calendar.badge.clock")
        case "acp": (label, symbol) = ("Editor", "chevron.left.forwardslash.chevron.right")
        case "matrix", "mattermost", "teams", "line": (label, symbol) = (source.capitalized, "bubble.left.and.bubble.right")
        default: (label, symbol) = (source.replacingOccurrences(of: "_", with: " ").capitalized, "bubble.left.and.bubble.right")
        }
    }
}
