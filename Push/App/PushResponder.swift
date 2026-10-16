import HermesKit
import HermesPush
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Answers from a notification without opening the app (`docs/notifications.md` §3): Allow Once and
/// Deny, a question's choice or typed answer, and Reply…. The app wakes in the background, opens a
/// fresh connection to that gateway and answers; only a failure leaves a (quiet) notification.
enum PushResponder {
    /// What the person did, copied out of `UNNotificationResponse` (which isn't Sendable).
    struct Response: Sendable {
        var action: String
        var text: String?
        var identifier: String
        var notice: PushNotice?
        /// A local (Mac) notification: its gateway, as the app's id.
        var localGateway: UUID?

        nonisolated init(_ response: UNNotificationResponse) {
            action = response.actionIdentifier
            text = (response as? UNTextInputNotificationResponse)?.userText
            identifier = response.notification.request.identifier
            let info = response.notification.request.content.userInfo
            notice = NotificationDelegate.notice(from: info)
            localGateway = (info[PushUserInfo.localGateway] as? String).flatMap(UUID.init(uuidString:))
        }
    }

    enum Failure: Error {
        case unknownGateway, noBackend, expired
    }

    @MainActor
    static func handle(_ response: Response, center: PushCenter) async {
        #if os(macOS)
        if response.localGateway != nil {
            MacNotifier.shared.handle(response)
            return
        }
        #endif
        guard let notice = response.notice else { return }
        let action = response.action
        switch action {
        case UNNotificationDismissActionIdentifier:
            return
        case NotificationCatalog.Action.allowOnce, NotificationCatalog.Action.deny:
            await answer(notice, center: center, identifier: response.identifier) {
                try await approve(notice, choice: action == NotificationCatalog.Action.allowOnce ? .once : .deny, center: center)
            }
        case NotificationCatalog.Action.reply:
            let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            await answer(notice, center: center, identifier: response.identifier) {
                if notice.kind == .question {
                    try await answerQuestion(notice, with: text, center: center)
                } else {
                    try await reply(notice, with: text, center: center)
                }
            }
        default:
            if let index = NotificationCatalog.Action.choiceIndex(action), notice.actionChoices.indices.contains(index) {
                await answer(notice, center: center, identifier: response.identifier) {
                    try await answerQuestion(notice, with: notice.actionChoices[index], center: center)
                }
            } else {
                // A tap, More Options…, or Open: the chat with its card docked.
                center.open(notice)
            }
        }
    }

    /// Runs one answer, keeping the app alive for it, and says so only if it failed.
    @MainActor
    private static func answer(_ notice: PushNotice, center: PushCenter, identifier: String, _ work: @escaping @MainActor () async throws -> Void) async {
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Hermes answer")
        defer { UIApplication.shared.endBackgroundTask(task) }
        #endif
        do {
            try await work()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            if let request = notice.requestID { await center.removeDelivered(requests: [request]) }
            await center.refreshBadge()
        } catch {
            await reportFailure(notice, error: error, center: center)
        }
    }

    // MARK: - Approvals

    @MainActor
    static func approve(_ notice: PushNotice, choice: ApprovalChoice, center: PushCenter) async throws {
        guard let requestID = notice.requestID else { throw Failure.expired }
        if notice.isExpired() { throw Failure.expired }
        let (workspace, apiKey) = try gateway(for: notice, center: center)
        if notice.answer?.via == "run", let runID = notice.answer?.runID {
            // An API server run: its approval queue lives in the gateway process.
            guard let apiKey else { throw Failure.unknownGateway }
            let client = HermesClient(baseURL: workspace.bot.baseURL, apiKey: apiKey)
            do {
                try await client.respondToApproval(runID: runID, requestID: requestID, choice: choice)
            } catch HermesError.server(409, _, _) {
                throw Failure.expired
            }
            return
        }
        let session = notice.answer?.sessionID ?? notice.chatID ?? ""
        let result = try await withSocket(workspace) { request in
            try await request("approval.respond", [
                "session_id": .string(session), "choice": .string(choice.rawValue), "request_id": .string(requestID),
            ])
        }
        // `resolved` counts the approvals this settled: 0 means it was already answered or timed out.
        if let resolved = result["resolved"]?.doubleValue, resolved < 1 { throw Failure.expired }
    }

    // MARK: - Questions

    /// A `clarify` answer: the open request is found through the session's resume snapshot (the
    /// plugin's request id is the human-input id, not the socket request's), then answered.
    @MainActor
    static func answerQuestion(_ notice: PushNotice, with text: String, center: PushCenter) async throws {
        if notice.isExpired() { throw Failure.expired }
        let (workspace, _) = try gateway(for: notice, center: center)
        let session = notice.answer?.sessionID ?? notice.chatID ?? ""
        _ = try await withSocket(workspace) { request in
            var resume: [String: JSONValue] = ["session_id": .string(session), "omit_messages": .bool(true)]
            if let profile = notice.profile { resume["profile"] = .string(profile) }
            let snapshot = try await request("session.resume", resume)
            guard case .array(let open)? = snapshot["open_requests"] else { throw Failure.expired }
            let questions = open.compactMap { row -> HermesRequest? in
                guard let id = row["id"]?.stringValue, row["method"]?.stringValue == "clarify" else { return nil }
                return HermesRequest.parse(GatewayServerRequest(id: id, method: "clarify", params: row["params"] ?? .object([:])))
            }
            let wanted = notice.questions.first?.question ?? notice.body
            guard let target = questions.first(where: { request in
                if case .clarify(let items) = request.kind { return items.first?.question == wanted }
                return false
            }) ?? questions.first, case .clarify(let items) = target.kind else { throw Failure.expired }
            var answers: [String: JSONValue] = [:]
            for (index, item) in items.enumerated() {
                answers[item.id] = index == 0 ? .string(text) : .null
            }
            let answered = try await request("request.answer", ["id": .string(target.id), "result": .object(["answers": .object(answers)])])
            if answered["status"]?.stringValue == "expired" { throw Failure.expired }
            return answered
        }
    }

    // MARK: - Replies

    /// Reply…: a new message in that chat (or room). The turn runs on the gateway; the reply
    /// notifies like any other.
    @MainActor
    static func reply(_ notice: PushNotice, with text: String, center: PushCenter) async throws {
        let (workspace, apiKey) = try gateway(for: notice, center: center)
        if let room = notice.roomID {
            _ = try await withSocket(workspace) { request in
                try await request("groups.send", [
                    "room_id": .string(room), "event_id": .string(UUID().uuidString),
                    "payload": .object(["text": .string(text), "thread_id": .string("main")]),
                ])
            }
            return
        }
        guard let chat = notice.chatID else { throw Failure.unknownGateway }
        if let profile = notice.profile {
            // A Bot Chat: its session lives in the Bot's profile, on the backend.
            _ = try await withSocket(workspace) { request in
                let resumed = try await request("session.resume", [
                    "session_id": .string(chat), "profile": .string(profile), "omit_messages": .bool(true),
                ])
                guard let runtime = resumed["session_id"]?.stringValue else { throw Failure.expired }
                return try await request("prompt.submit", ["session_id": .string(runtime), "text": .string(text)])
            }
            return
        }
        guard let apiKey else { throw Failure.unknownGateway }
        let client = HermesClient(baseURL: workspace.bot.baseURL, apiKey: apiKey)
        _ = try await client.startRun(
            sessionID: chat, input: text, model: nil, reasoningEffort: nil, idempotencyKey: UUID().uuidString
        )
    }

    // MARK: - Connections

    @MainActor
    private static func gateway(for notice: PushNotice, center: PushCenter) throws -> (BotWorkspace, String?) {
        guard let model = center.model,
              let appID = center.shared.gateway(notice.gateway?.id)?.appID,
              let workspace = model.workspaces[appID]
        else { throw Failure.unknownGateway }
        return (workspace, model.apiKey(for: appID))
    }

    typealias Request = (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    /// The gateway's backend socket: the live one if it's up, else a fresh one just for this.
    @MainActor
    static func withSocket(_ workspace: BotWorkspace, _ body: (Request) async throws -> JSONValue) async throws -> JSONValue {
        guard let roster = workspace.roster else { throw Failure.noBackend }
        if roster.state.isOnline {
            return try await body { method, params in try await roster.request(method, params, timeout: .seconds(20)) }
        }
        let socket = try await makeSocket(workspace)
        defer { Task { await socket.close() } }
        return try await body { method, params in try await socket.request(method, params, timeout: .seconds(20)) }
    }

    /// A one-off connection to the gateway's backend with the saved sign-in (a local backend's
    /// token changes on restart, so an automatic sign-in reads it again once).
    @MainActor
    private static func makeSocket(_ workspace: BotWorkspace) async throws -> GatewaySocket {
        guard let link = workspace.bot.backend else { throw Failure.noBackend }
        let client = BackendClient(baseURL: link.url, credential: PushCenter.shared.model?.backendCredential(for: workspace.id))
        do {
            let socket = GatewaySocket(url: try await client.gatewaySocketURL())
            try await socket.connect()
            return socket
        } catch where link.signIn == .automatic {
            _ = try await client.discoverSessionToken()
            let socket = GatewaySocket(url: try await client.gatewaySocketURL())
            try await socket.connect()
            return socket
        }
    }

    // MARK: - Failure

    /// "Couldn't reach Home Server · Open Hermes to answer." Quiet: no sound.
    @MainActor
    static func reportFailure(_ notice: PushNotice, error: any Error, center: PushCenter) async {
        let name = center.shared.gateway(notice.gateway?.id)?.name ?? notice.gateway?.name ?? "Hermes"
        let content = UNMutableNotificationContent()
        if case Failure.expired? = error as? Failure {
            content.title = String(localized: "Already answered")
            content.body = String(localized: "That request on \(name) was answered elsewhere or timed out.")
        } else {
            content.title = String(localized: "Couldn't reach \(name)")
            content.body = notice.kind.needsYou ? String(localized: "Open Hermes to answer.") : String(localized: "Open Hermes to send it.")
        }
        content.threadIdentifier = notice.thread
        content.categoryIdentifier = NotificationCatalog.Category.open.rawValue
        content.interruptionLevel = .active
        content.userInfo = PushUserInfo.values(for: notice)
        let request = UNNotificationRequest(identifier: "failed-\(notice.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Answers from the Live Activity's buttons (`AnswerFromActivityIntent`).
enum ActivityAnswering {
    @MainActor
    static func answer(gatewayID: UUID?, sessionID: String, requestID: String, allow: Bool) async {
        let center = PushCenter.shared
        guard let gatewayID else { return }
        let installation = center.installationID(for: gatewayID) ?? ""
        #if os(iOS)
        let route = (center.activities as? TurnActivityController)?.answerRoute(gatewayID: gatewayID)
        #else
        let route: PushNotice.Answer? = nil
        #endif
        let notice = PushNotice(
            kind: .approval, id: requestID, thread: sessionID, sessionID: sessionID, requestID: requestID,
            gateway: .init(id: installation, name: center.shared.gateways[installation]?.name ?? ""),
            answer: route ?? .init(via: "socket", sessionID: sessionID)
        )
        do {
            try await PushResponder.approve(notice, choice: allow ? .once : .deny, center: center)
            await center.removeDelivered(requests: [requestID])
            await center.refreshBadge()
            #if os(iOS)
            (center.activities as? TurnActivityController)?.requestsResolved([requestID])
            #endif
        } catch {
            await PushResponder.reportFailure(notice, error: error, center: center)
        }
    }
}

/// Receives notifications while the app runs, and the person's answers.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// The notice behind a notification: what the service extension (or the Mac) stored, else
    /// opened from the envelope here.
    nonisolated static func notice(from userInfo: [AnyHashable: Any]) -> PushNotice? {
        if let notice = PushUserInfo.notice(in: userInfo) { return notice }
        guard let envelope = PushEnvelope(payload: userInfo[PushUserInfo.envelope]),
              let key = try? PushShared.current.deviceKey()
        else { return nil }
        return try? key.open(PushNotice.self, from: envelope)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let notice = Self.notice(from: notification.request.content.userInfo)
        return await PushCenter.shared.presentation(for: notice)
    }

    /// Finishes on the main thread: UIKit updates the app's snapshot in the completion handler and
    /// stops the app if that runs anywhere else. The `async` form called it wherever the handling
    /// finished, and opening a notice crashed the app (TestFlight 2610152328).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let response = PushResponder.Response(response)
        Task { @MainActor in
            await PushCenter.shared.handle(response)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        Task { @MainActor in PushCenter.shared.showSettings = true }
    }
}
