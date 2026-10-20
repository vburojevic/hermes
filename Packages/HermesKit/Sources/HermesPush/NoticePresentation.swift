import Foundation
import UserNotifications

/// How a notice reads on screen (`blocks/notifications.elyx`). The service extension and the
/// Mac's local notifications both build their content here, in the device's language and with
/// the app's own name for the gateway.
public struct NoticePresentation: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var body: String
    public var category: NotificationCatalog.Category
    public var categoryIdentifier: String
    public var threadIdentifier: String
    public var interruptionLevel: UNNotificationInterruptionLevel
    public var relevanceScore: Double
    public var plays: Bool
    /// Only the kind and the gateway are showing.
    public var hidesDetails = false

    /// - Parameters:
    ///   - gatewayName: the app's name for the gateway, else the gateway's own.
    ///   - showDetails: Settings → Notifications → Show Message Text. The Lock Screen is iPhone's:
    ///     with Show Previews at When Unlocked it shows the category's placeholder ("Reply ready on
    ///     Home Server") and the text once Face ID unlocks. Deciding it here, as the notice arrived,
    ///     left a phone that was locked then with the placeholder for good.
    public init(
        _ notice: PushNotice, gatewayName: String?, slot: Int?,
        showDetails: PushPreferences.ShowDetails
    ) {
        let gateway = gatewayName ?? notice.gateway?.name
        let category = Self.category(for: notice)
        self.category = category
        categoryIdentifier = category.identifier(slot: slot)
        threadIdentifier = notice.thread.isEmpty ? (notice.chatID ?? "") : notice.thread
        var chat = notice.summary.isEmpty ? notice.subtitle : notice.summary
        if let bot = notice.bot, chat == bot || chat == "Bot Chat" { chat = "" }
        switch notice.kind {
        case .approval where notice.isMemorySave:
            // "Hermes wants to remember something" · the entry: the one memory text a push carries.
            title = notice.bot.map { String(localized: "\($0) wants to remember something", bundle: .module) } ?? String(localized: "Hermes wants to remember something", bundle: .module)
            subtitle = chat
            body = notice.command.map { Self.clip($0, 240) } ?? notice.body
        case .approval:
            title = notice.bot.map { String(localized: "\($0) needs your OK", bundle: .module) } ?? String(localized: "Hermes needs your OK", bundle: .module)
            subtitle = chat
            if let command = notice.command.map(Self.oneLine), !command.isEmpty, let gateway {
                body = String(localized: "Run \(Self.clip(command, 80)) on \(gateway)?", bundle: .module)
            } else {
                body = notice.body
            }
        case .question:
            title = notice.bot.map { String(localized: "\($0) has a question", bundle: .module) } ?? String(localized: "Hermes has a question", bundle: .module)
            subtitle = chat
            body = notice.body
        case .password:
            title = String(localized: "Hermes needs a password", bundle: .module)
            subtitle = chat
            body = notice.body
        case .reply:
            title = notice.bot ?? (chat.isEmpty ? "Hermes" : chat)
            subtitle = notice.bot == nil ? "" : chat
            body = notice.body
        case .task, .taskFailed:
            title = notice.title.isEmpty ? String(localized: "Scheduled task", bundle: .module) : notice.title
            subtitle = notice.kind == .taskFailed ? String(localized: "Failed", bundle: .module) : ""
            body = notice.body
        case .message:
            title = notice.bot ?? notice.title
            subtitle = notice.subtitle
            body = notice.body
        case .cardNeedsYou:
            // "Ada needs you on “Write the App Store listing”", with the question.
            let card = notice.cardTitle ?? notice.summary
            let who = notice.bot ?? "Hermes"
            title = card.isEmpty ? String(localized: "\(who) needs you", bundle: .module) : String(localized: "\(who) needs you on “\(card)”", bundle: .module)
            subtitle = ""
            body = notice.body
        case .cardReview, .cardStopped, .cardDone:
            title = switch notice.kind {
            case .cardReview: String(localized: "Ready for review", bundle: .module)
            case .cardStopped: String(localized: "Stopped", bundle: .module)
            default: String(localized: "Done", bundle: .module)
            }
            subtitle = notice.cardTitle ?? notice.subtitle
            body = notice.body
        case .tidied:
            // "Hermes tidied its skills" · "Merged 2 overlapping skills and archived 3 unused ones."
            title = notice.bot.map { String(localized: "\($0) tidied its skills", bundle: .module) } ?? String(localized: "Hermes tidied its skills", bundle: .module)
            subtitle = ""
            body = notice.body
        case .widget:
            // "Ops needs your OK" · chat · the widget's title; a private one says only that it came.
            title = notice.title.isEmpty ? String(localized: "Hermes needs your OK", bundle: .module) : notice.title
            subtitle = chat
            body = notice.body
        case .test:
            title = String(localized: "Push notifications are on", bundle: .module)
            subtitle = ""
            body = gateway.map { String(localized: "\($0) can reach this device.", bundle: .module) } ?? notice.body
        case .background, .withdraw, .sync, .unknown:
            title = notice.title.isEmpty ? "Hermes" : notice.title
            subtitle = notice.subtitle
            body = notice.body
        }
        switch notice.kind {
        case .approval where notice.isMemorySave:
            interruptionLevel = .active
            relevanceScore = 0.8
        case .approval, .question, .password:
            interruptionLevel = .timeSensitive
            relevanceScore = notice.kind == .question ? 0.9 : 1
        case .taskFailed:
            interruptionLevel = .active
            relevanceScore = 0.6
        case .cardNeedsYou:
            interruptionLevel = .timeSensitive
            relevanceScore = 1
        case .widget:
            interruptionLevel = notice.widgetType == "approval" ? .timeSensitive : .active
            relevanceScore = notice.widgetType == "approval" ? 1 : 0.8
        case .cardDone:
            interruptionLevel = .passive
            relevanceScore = 0.3
        case .task, .background, .tidied:
            interruptionLevel = .passive
            relevanceScore = notice.kind == .task ? 0.3 : 0.2
        default:
            interruptionLevel = .active
            relevanceScore = notice.kind == .reply ? 0.5 : 0.6
        }
        plays = interruptionLevel != .passive
        // Never: only the kind and the gateway, no content.
        if showDetails == .never {
            hidesDetails = true
            title = "Hermes"
            subtitle = ""
            body = NotificationCatalog.hiddenText(notice.kind == .widget ? .approval : (notice.isMemorySave ? .memory : category), gateway: gateway, failed: notice.kind == .taskFailed)
        }
    }

    public static func category(for notice: PushNotice) -> NotificationCatalog.Category {
        switch notice.kind {
        case .approval:
            if notice.isMemorySave { notice.savesInBanner ? .memory : .open } else { notice.answersInBanner ? .approval : .open }
        case .question: .question
        case .password: .password
        case .reply: .reply
        case .message: .message
        case .task, .taskFailed: .task
        case .cardNeedsYou: .card
        case .cardReview, .cardStopped, .cardDone: .board
        default: notice.category.flatMap { NotificationCatalog.Category(identifier: $0) } ?? .open
        }
    }

    /// Writes the presentation into a notification's content.
    public func apply(to content: UNMutableNotificationContent) {
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = threadIdentifier
        content.interruptionLevel = interruptionLevel
        content.relevanceScore = relevanceScore
        content.sound = plays ? .default : nil
        if !threadIdentifier.isEmpty { content.targetContentIdentifier = threadIdentifier }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension PushNotice {
    /// "It expires in 4 minutes if no one answers." for the expanded approval.
    public func expiryText(now: Date = .now) -> String? {
        guard let expiresAt else { return nil }
        // Any number can arrive as a deadline: a far-off one reads in hours instead of stopping the app.
        let seconds = min(expiresAt.timeIntervalSince(now), 1e15)
        guard seconds > 0 else { return String(localized: "This request has expired.", bundle: .module) }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 {
            return String(localized: "Hermes is paused until you answer. It expires in a minute if no one answers.", bundle: .module)
        }
        if minutes >= 90 {
            let hours = Int((seconds / 3600).rounded())
            return String(localized: "Hermes is paused until you answer. It expires in \(hours) hours if no one answers.", bundle: .module)
        }
        return String(localized: "Hermes is paused until you answer. It expires in \(minutes) minutes if no one answers.", bundle: .module)
    }
}

extension PushNotice {
    /// Whether Allow is offered right on the notification. Never for a command the safety check
    /// flagged, and only for one the notice carries whole (`carriesWholeCommand`). On the Mac,
    /// which has no expanded view, only for one the banner shows whole (`Run … on Studio Mac?`
    /// clips at 80); an iPhone's expanded view shows the whole command the notice carries.
    public var answersInBanner: Bool {
        guard !smartDenied, carriesWholeCommand else { return false }
        #if os(macOS)
        return VisibleText.fitsAtAGlance(command, limit: 80)
        #else
        return true
        #endif
    }

    /// Whether Save is offered right on a "Save to memory?" notification: only when the body
    /// (the entry, clipped at 240) shows all of it. Otherwise the notification opens the chat's
    /// card, which shows the entry whole.
    public var savesInBanner: Bool {
        guard carriesWholeCommand, let command = command.map(NoticePresentation.oneLine) else { return false }
        #if os(macOS)
        return VisibleText.fitsAtAGlance(command, limit: 80)
        #else
        return command.count <= 240
        #endif
    }

    /// The command (or memory entry) arrived whole. The push plugin clips it at 600 characters and
    /// ends the cut with "…", and sends none when its redactor couldn't run: Allow then would
    /// approve text the person never saw (security scan F7).
    var carriesWholeCommand: Bool {
        guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { return false }
        return !command.hasSuffix("…")
    }

    /// A "Save to memory?" request (Ask Before Saving on), not a command.
    public var isMemorySave: Bool {
        category == NotificationCatalog.Category.memory.rawValue || (detail?.hasPrefix("Save to memory") ?? false)
    }
}
