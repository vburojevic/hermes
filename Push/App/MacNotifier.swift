#if os(macOS)
import AppKit
import HermesKit
import HermesPush
import UserNotifications

/// The Mac's notifications while Hermes runs (`docs/notifications.md` §1.6, `macNotification`): the
/// app hears its chats over its own connections and posts local notifications, only when Hermes
/// isn't in front or the chat isn't on screen. Answers go straight back through the chat.
@MainActor
final class MacNotifier {
    static let shared = MacNotifier()

    private struct Posted {
        weak var conversation: ConversationModel?
        var gatewayID: UUID
        var approval: ApprovalRequest?
        var request: HermesRequest?
    }

    private var posted: [String: Posted] = [:]
    /// Question categories with their choices, registered per question.
    private var questionCategories: [String: [String]] = [:]

    private var center: PushCenter { .shared }

    // MARK: Events

    func approval(_ approval: ApprovalRequest, in conversation: ConversationModel, workspace: BotWorkspace) {
        guard center.preferences.approvals else { return }
        let command = approval.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        var notice = baseNotice(.approval, id: approval.id, conversation: conversation, workspace: workspace)
        notice.requestID = approval.id
        notice.command = command
        notice.detail = approval.description
        notice.bot = conversation.isBotChat ? conversation.askerName : nil
        notice.body = command.map { String(localized: "Run \($0) on \(workspace.bot.name)?") } ?? String(localized: "\(conversation.askerName) needs your permission")
        post(notice, posted: Posted(conversation: conversation, gatewayID: workspace.id, approval: approval))
    }

    func request(_ request: HermesRequest, in conversation: ConversationModel, workspace: BotWorkspace) {
        var notice: PushNotice
        switch request.kind {
        case .clarify(let questions):
            guard center.preferences.approvals else { return }
            notice = baseNotice(.question, id: request.id, conversation: conversation, workspace: workspace)
            notice.body = questions.first?.question ?? ""
            notice.questions = questions.map { .init(question: $0.question, choices: $0.choices, multiSelect: $0.multiSelect) }
        case .secret, .sudo, .vaultUnlock, .vaultSaveLogin, .vaultCode, .connection:
            guard center.preferences.passwords else { return }
            notice = baseNotice(.password, id: request.id, conversation: conversation, workspace: workspace)
            notice.body = ConversationModel.title(of: request)
        case .choose(let choice):
            guard center.preferences.approvals else { return }
            notice = baseNotice(.question, id: request.id, conversation: conversation, workspace: workspace)
            notice.body = choice.question
        }
        notice.requestID = request.id
        notice.bot = conversation.isBotChat ? conversation.askerName : nil
        post(notice, posted: Posted(conversation: conversation, gatewayID: workspace.id, request: request))
    }

    /// A turn finished: worth a notification when it ran past the threshold and nobody watched.
    func turnFinished(in conversation: ConversationModel, workspace: BotWorkspace, seconds: Double, text: String?) {
        let prefs = center.preferences
        guard let text, !text.isEmpty else { return }
        if conversation.isBotChat {
            guard prefs.bots == .all else { return }
        } else {
            guard prefs.replies, seconds >= Double(prefs.replyAfter) else { return }
        }
        var notice = baseNotice(.reply, id: "reply-\(conversation.stableKey ?? conversation.id.uuidString)", conversation: conversation, workspace: workspace)
        notice.body = Self.firstLines(text)
        notice.bot = conversation.isBotChat ? conversation.askerName : nil
        post(notice, posted: Posted(conversation: conversation, gatewayID: workspace.id))
    }

    /// Answered here, on another device, or timed out: the notification goes.
    func resolved(_ id: String) {
        guard posted.removeValue(forKey: id) != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        if questionCategories.removeValue(forKey: "QUESTION.local.\(id)") != nil {
            center.registerCategories(questionChoices: questionCategories)
        }
    }

    // MARK: Posting

    private func baseNotice(_ kind: PushNotice.Kind, id: String, conversation: ConversationModel, workspace: BotWorkspace) -> PushNotice {
        let chat = conversation.sessionID ?? conversation.stableKey ?? ""
        let title = center.chatTitle(of: conversation, in: workspace)
        return PushNotice(kind: kind, id: id, subtitle: title, thread: chat, summary: title, sessionID: chat,
                          gateway: .init(id: workspace.id.uuidString, name: workspace.bot.name))
    }

    private func post(_ notice: PushNotice, posted entry: Posted) {
        guard center.canNotify, !center.isShowing(notice) else { return }
        let presentation = NoticePresentation(notice, gatewayName: entry.conversation.flatMap { _ in notice.gateway?.name },
                                              slot: nil, showDetails: .always, unlocked: true)
        let content = UNMutableNotificationContent()
        presentation.apply(to: content)
        content.userInfo = PushUserInfo.values(for: notice).merging([PushUserInfo.localGateway: entry.gatewayID.uuidString]) { $1 }
        if notice.kind == .question, !notice.actionChoices.isEmpty {
            let category = "QUESTION.local.\(notice.id)"
            questionCategories[category] = notice.actionChoices
            center.registerCategories(questionChoices: questionCategories)
            content.categoryIdentifier = category
        }
        posted[notice.id] = entry
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Answers

    func handle(_ response: PushResponder.Response) {
        guard let notice = response.notice else { return }
        let entry = posted[notice.id]
        let conversation = entry?.conversation
        switch response.action {
        case UNNotificationDismissActionIdentifier:
            return
        case NotificationCatalog.Action.allowOnce, NotificationCatalog.Action.deny:
            if let approval = entry?.approval, let conversation {
                conversation.respond(to: approval, with: response.action == NotificationCatalog.Action.allowOnce ? .once : .deny)
            } else {
                open(notice)
            }
        case NotificationCatalog.Action.reply:
            let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, let conversation else { return open(notice) }
            if let request = entry?.request {
                answer(request, with: text, in: conversation)
            } else {
                conversation.draft = text
                conversation.send()
            }
        default:
            if let index = NotificationCatalog.Action.choiceIndex(response.action), notice.actionChoices.indices.contains(index),
               let request = entry?.request, let conversation {
                answer(request, with: notice.actionChoices[index], in: conversation)
            } else {
                open(notice)
            }
        }
    }

    private func answer(_ request: HermesRequest, with text: String, in conversation: ConversationModel) {
        guard case .clarify(let questions) = request.kind else { return }
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            answers[question.id] = index == 0 ? .string(text) : .null
        }
        conversation.answer(request, with: .object(["answers": .object(answers)]), receipt: String(localized: "Answered · \(text)"))
    }

    private func open(_ notice: PushNotice) {
        NSApp.activate()
        guard let model = center.model, let id = posted[notice.id]?.gatewayID ?? notice.gateway.flatMap({ UUID(uuidString: $0.id) }),
              let workspace = model.workspaces[id]
        else { return }
        model.select(id)
        if let chat = notice.chatID {
            let key = workspace.sessions.first { $0.id == chat || $0.stableID == chat }?.stableID ?? chat
            if let bot = notice.bot, let roster = workspace.roster, let profile = roster.profiles.first(where: { $0.title == bot || $0.name == bot }) {
                workspace.sidebarMode = .bots
                workspace.selection = .bot(profile.name)
            } else {
                workspace.sidebarMode = .chats
                workspace.selection = .session(key)
            }
        }
    }

    static func firstLines(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.prefix(2).joined(separator: " ")
        return joined.count > 240 ? String(joined.prefix(239)) + "…" : joined
    }
}
#endif
