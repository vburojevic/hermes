#if os(iOS)
import ActivityKit
import HermesKit
import HermesPush
import UIKit

/// The Live Activity for a long turn (`docs/notifications.md` §4): started when a turn has run 15 s
/// and the app goes to the background, one per gateway (the newest running turn wins). Its push
/// token goes to the gateway's plugin, which sends the updates; the app ends it with the result,
/// dismissed after 4 minutes.
@MainActor
final class TurnActivityController {
    struct Running {
        weak var conversation: ConversationModel?
        var gatewayID: UUID
        var startedAt: Date
    }

    private unowned let center: PushCenter
    /// Turns running now, by conversation.
    private var running: [ObjectIdentifier: Running] = [:]
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    /// How the newest approval on each gateway's activity is answered (from the plugin's state).
    private var routes: [UUID: PushNotice.Answer] = [:]
    private var pendingStart: Task<Void, Never>?
    private var isBackground = false

    init(center: PushCenter) {
        self.center = center
    }

    private var enabled: Bool {
        center.preferences.liveActivity && ActivityAuthorizationInfo().areActivitiesEnabled && center.deviceToken != nil
    }

    // MARK: Turns

    func turnStarted(in conversation: ConversationModel, gatewayID: UUID, at date: Date) {
        running[ObjectIdentifier(conversation)] = Running(conversation: conversation, gatewayID: gatewayID, startedAt: date)
        if isBackground { scheduleStart() }
    }

    func turnFinished(in conversation: ConversationModel, ok: Bool, result: String?) {
        guard running.removeValue(forKey: ObjectIdentifier(conversation)) != nil, let session = conversation.sessionID else { return }
        for activity in Activity<TurnActivityAttributes>.activities where activity.attributes.sessionID == session {
            let current = activity.content.state.state(key: try? center.shared.deviceKey())
            var state = TurnActivityState(phase: .done, startedAt: current.startedAt, title: current.title, result: result, ok: ok)
            state.endedAt = .now
            let id = activity.id
            Task { await Self.end(id, with: state, dismissal: .after(.now.addingTimeInterval(240))) }
            forget(activity)
        }
    }

    func requestsResolved(_ ids: Set<String>) {
        requestsResolved(Array(ids))
    }

    /// An approval on the activity was answered: back to working until the gateway says more.
    func requestsResolved(_ ids: [String]) {
        let key = try? center.shared.deviceKey()
        for activity in Activity<TurnActivityAttributes>.activities {
            let state = activity.content.state.state(key: key)
            guard state.phase == .needsYou, let request = state.requestID, ids.contains(request) else { continue }
            var next = state
            next.phase = .working
            next.command = nil
            next.question = nil
            next.requestID = nil
            next.step = String(localized: "Continuing")
            let id = activity.id
            Task { await Self.update(id, to: next) }
        }
    }

    func answerRoute(gatewayID: UUID) -> PushNotice.Answer? {
        let key = try? center.shared.deviceKey()
        let state = Activity<TurnActivityAttributes>.activities.first { $0.attributes.gatewayID == gatewayID }?.content.state.state(key: key)
        return state?.answer ?? routes[gatewayID]
    }

    // MARK: App state

    func appDidEnterBackground() {
        isBackground = true
        scheduleStart()
    }

    func appDidBecomeActive() {
        isBackground = false
        pendingStart?.cancel()
        pendingStart = nil
    }

    /// Starts each gateway's activity once its newest turn has run 15 s (now, or a little later
    /// while the app still has background time).
    private func scheduleStart() {
        guard enabled else { return }
        pendingStart?.cancel()
        pendingStart = Task { [weak self] in
            while let self, !Task.isCancelled, self.isBackground {
                let waiting = self.startDue()
                guard let wait = waiting, wait > 0 else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Starts what's due; returns how long until the next one is, if any.
    private func startDue() -> Double? {
        var nextWait: Double?
        let newest = Dictionary(grouping: running.values.filter { $0.conversation?.isWorking == true }, by: \.gatewayID)
            .compactMapValues { $0.max { $0.startedAt < $1.startedAt } }
        for (gatewayID, turn) in newest {
            let elapsed = Date.now.timeIntervalSince(turn.startedAt)
            guard elapsed >= 15 else {
                nextWait = min(nextWait ?? .infinity, 15 - elapsed)
                continue
            }
            guard let conversation = turn.conversation, let session = conversation.sessionID else { continue }
            let existing = Activity<TurnActivityAttributes>.activities.filter { $0.attributes.gatewayID == gatewayID }
            if existing.contains(where: { $0.attributes.sessionID == session && $0.activityState == .active }) { continue }
            for old in existing {
                let id = old.id
                Task { await Self.end(id, with: nil, dismissal: .immediate) }
                forget(old)
            }
            start(conversation, session: session, gatewayID: gatewayID, startedAt: turn.startedAt)
        }
        return nextWait
    }

    private func start(_ conversation: ConversationModel, session: String, gatewayID: UUID, startedAt: Date) {
        guard let workspace = center.model?.workspaces[gatewayID] else { return }
        let title = center.chatTitle(of: conversation, in: workspace)
        let attributes = TurnActivityAttributes(
            gatewayID: gatewayID, gatewayName: workspace.bot.name, sessionID: session, chatTitle: title, bot: conversation.botName
        )
        let state = TurnActivityState(
            phase: conversation.pendingApproval == nil ? .working : .needsYou,
            step: conversation.liveStatus ?? String(localized: "Working"), startedAt: startedAt, title: title,
            command: conversation.pendingApproval?.command, requestID: conversation.pendingApproval?.requestID
        )
        do {
            let activity = try Activity.request(
                attributes: attributes, content: .init(state: .init(state), staleDate: .now.addingTimeInterval(900), relevanceScore: 50),
                pushType: .token
            )
            observeToken(of: activity, workspace: workspace, session: session)
        } catch {
            center.recordActivityError(error)
        }
    }

    /// Hands the activity's push token to the gateway, which then sends its updates through the relay.
    private func observeToken(of activity: Activity<TurnActivityAttributes>, workspace: BotWorkspace, session: String) {
        let deviceID = center.shared.deviceID
        let activityID = activity.id
        tokenTasks[activityID] = Task { [weak workspace] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard let workspace else { return }
                _ = try? await PushResponder.withSocket(workspace) { request in
                    try await request("command.dispatch", [
                        "name": .string("app-push"),
                        "arg": .string("activity " + Self.json([
                            "device_id": deviceID, "token": token, "session_id": session, "activity_id": activityID,
                        ])),
                    ])
                }
            }
        }
    }

    private func forget(_ activity: Activity<TurnActivityAttributes>) {
        tokenTasks.removeValue(forKey: activity.id)?.cancel()
        guard let workspace = center.model?.workspaces[activity.attributes.gatewayID] else { return }
        let deviceID = center.shared.deviceID
        Task {
            _ = try? await PushResponder.withSocket(workspace) { request in
                try await request("command.dispatch", [
                    "name": .string("app-push"), "arg": .string("activity " + Self.json(["device_id": deviceID])),
                ])
            }
        }
    }

    // Activities aren't Sendable: tasks look them up by id instead of carrying them.
    nonisolated private static func activity(_ id: String) -> Activity<TurnActivityAttributes>? {
        Activity<TurnActivityAttributes>.activities.first { $0.id == id }
    }

    nonisolated private static func end(_ id: String, with state: TurnActivityState?, dismissal: ActivityUIDismissalPolicy) async {
        await activity(id)?.end(state.map { .init(state: .init($0), staleDate: nil) }, dismissalPolicy: dismissal)
    }

    nonisolated private static func update(_ id: String, to state: TurnActivityState) async {
        await activity(id)?.update(.init(state: .init(state), staleDate: nil))
    }

    private static func json(_ values: [String: String]) -> String {
        (try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "{}"
    }
}
#endif
