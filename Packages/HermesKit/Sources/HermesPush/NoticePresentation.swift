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
    ///   - showDetails: Settings → Notifications → Show details.
    ///   - unlocked: whether the device was unlocked when it arrived.
    public init(
        _ notice: PushNotice, gatewayName: String?, slot: Int?,
        showDetails: PushPreferences.ShowDetails, unlocked: Bool
    ) {
        let gateway = gatewayName ?? notice.gateway?.name
        let category = Self.category(for: notice)
        self.category = category
        categoryIdentifier = category.identifier(slot: slot)
        threadIdentifier = notice.thread.isEmpty ? (notice.chatID ?? "") : notice.thread
        let chat = notice.summary.isEmpty ? notice.subtitle : notice.summary
        switch notice.kind {
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
        case .test:
            title = String(localized: "Push notifications are on", bundle: .module)
            subtitle = ""
            body = gateway.map { String(localized: "\($0) can reach this device.", bundle: .module) } ?? notice.body
        case .background, .withdraw, .unknown:
            title = notice.title.isEmpty ? "Hermes" : notice.title
            subtitle = notice.subtitle
            body = notice.body
        }
        switch notice.kind {
        case .approval, .question, .password:
            interruptionLevel = .timeSensitive
            relevanceScore = notice.kind == .question ? 0.9 : 1
        case .taskFailed:
            interruptionLevel = .active
            relevanceScore = 0.6
        case .task, .background:
            interruptionLevel = .passive
            relevanceScore = notice.kind == .task ? 0.3 : 0.2
        default:
            interruptionLevel = .active
            relevanceScore = notice.kind == .reply ? 0.5 : 0.6
        }
        plays = interruptionLevel != .passive
        // Never, or When Unlocked while locked: only the kind and the gateway, no content.
        if showDetails == .never || (showDetails == .unlocked && !unlocked) {
            hidesDetails = true
            title = "Hermes"
            subtitle = ""
            body = NotificationCatalog.hiddenText(category, gateway: gateway, failed: notice.kind == .taskFailed)
        }
    }

    public static func category(for notice: PushNotice) -> NotificationCatalog.Category {
        switch notice.kind {
        case .approval: .approval
        case .question: .question
        case .password: .password
        case .reply: .reply
        case .message: .message
        case .task, .taskFailed: .task
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
        let seconds = expiresAt.timeIntervalSince(now)
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
