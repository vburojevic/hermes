import HermesPush
import Intents
import os
import UserNotifications

/// Opens each notice the gateway sealed for this device and fills the notification
/// (`docs/notifications.md` §1.5): text in the device's language with the app's gateway name, the
/// per-gateway category (so a locked phone says only "Needs your OK on Home Server"), the badge
/// (open requests across gateways), and a Bot's face for its messages (a communication
/// notification). It also clears notices the gateway says were answered elsewhere.
///
/// If anything fails, the notification keeps the relay's kind-only text ("Hermes needs your OK ·
/// Open Hermes to see it."), never content.
nonisolated final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "push")
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    /// UserNotifications types aren't Sendable; the extension hands each one to exactly one task.
    private struct Box<Value>: @unchecked Sendable {
        let value: Value
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        Self.log.info("notice \(request.identifier, privacy: .public) arrived")
        lock.withLock {
            handler = contentHandler
            fallback = request.content
        }
        let content = Box(value: request.content)
        let identifier = request.identifier
        Task {
            let filled = await Self.fill(content.value, identifier: identifier)
            self.deliver(Box(value: filled))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(nil)
    }

    /// Hands over the filled content once: whichever of the fill and the deadline comes first.
    private func deliver(_ content: Box<UNNotificationContent>?) {
        let (handler, fallback) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNNotificationContent?) in
            defer { self.handler = nil }
            return (self.handler, self.fallback)
        }
        guard let handler, let fallback else { return }
        handler(content?.value ?? fallback)
    }

    static func fill(_ original: UNNotificationContent, identifier: String) async -> UNNotificationContent {
        let shared = PushShared.current
        guard let content = original.mutableCopy() as? UNMutableNotificationContent,
              let envelope = PushEnvelope(payload: original.userInfo[PushUserInfo.envelope])
        else { return original }
        var notice: PushNotice
        do {
            guard let key = try shared.deviceKey() else { return original }
            notice = try key.open(PushNotice.self, from: envelope)
        } catch {
            log.error("couldn't open a notice: \(String(describing: error), privacy: .public)")
            return original
        }
        let gateway = shared.gateway(notice.gateway?.id)
        // A Bot Chat's notice knows the profile; the app keeps the Bots' names for us.
        if notice.bot == nil, let profile = notice.profile, let gateway {
            notice.bot = shared.botNames(gateway: gateway.appID)[profile]
        }
        let presentation = NoticePresentation(
            notice, gatewayName: gateway?.name, slot: gateway?.slot,
            showDetails: shared.preferences.showDetails
        )
        presentation.apply(to: content)
        content.userInfo.merge(PushUserInfo.values(for: notice)) { _, new in new }
        if let id = notice.gateway?.id, let open = notice.open {
            content.badge = NSNumber(value: shared.recordOpen(open, gateway: id, at: notice.sentAt ?? .now))
        }
        await clearAnswered(notice.resolved, keeping: identifier)

        guard notice.kind == .message || (notice.kind == .reply && notice.bot != nil), !presentation.hidesDetails else {
            return content
        }
        return (try? await communicate(notice, content: content, gateway: gateway, shared: shared)) ?? content
    }

    /// Removes delivered notices for requests answered elsewhere, and approvals past their deadline.
    static func clearAnswered(_ resolved: [String], keeping identifier: String) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let now = Date.now
        let gone = delivered.compactMap { notification -> String? in
            let info = notification.request.content.userInfo
            guard notification.request.identifier != identifier else { return nil }
            if let request = info[PushUserInfo.request] as? String, resolved.contains(request) {
                return notification.request.identifier
            }
            if let notice = PushUserInfo.notice(in: info), notice.kind.needsYou, notice.isExpired(now: now.addingTimeInterval(-60)) {
                return notification.request.identifier
            }
            return nil
        }
        if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: gone) }
    }

    /// A Bot's message as a communication notification: its face and name, in its group.
    static func communicate(_ notice: PushNotice, content: UNMutableNotificationContent, gateway: PushShared.Gateway?, shared: PushShared) async throws -> UNNotificationContent {
        let name = notice.bot ?? notice.title
        let handle = notice.memberID ?? notice.profile ?? name
        var image: INImage?
        if let gateway, let url = shared.faceURL(gateway: gateway.appID, bot: handle), let data = try? Data(contentsOf: url) {
            image = INImage(imageData: data)
        }
        let sender = INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown), nameComponents: nil, displayName: name,
            image: image, contactIdentifier: nil, customIdentifier: "\(notice.gateway?.id ?? "")/\(handle)"
        )
        let room = notice.kind == .message && !notice.subtitle.isEmpty ? notice.subtitle : nil
        var recipients: [INPerson]?
        if room != nil {
            let me = INPerson(
                personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil,
                image: nil, contactIdentifier: nil, customIdentifier: "me", isMe: true, suggestionType: .none
            )
            recipients = [me, sender]
        }
        let intent = INSendMessageIntent(
            recipients: recipients, outgoingMessageType: .outgoingMessageText, content: content.body,
            speakableGroupName: room.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: content.threadIdentifier, serviceName: nil, sender: sender, attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return try content.updating(from: intent)
    }
}
