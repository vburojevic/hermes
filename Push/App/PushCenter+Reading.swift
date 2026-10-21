import HermesKit
import HermesPush
import os
import UserNotifications

/// What the badge counts as the app leaves (`presence away`).
typealias AwayBadge = (unread: AppPushClient.ChatLists, muted: AppPushClient.ChatLists)

/// Read chats leave no notifications behind (`docs/notifications.md` §2 Reading): this device
/// sweeps them as reads land, tells the gateway what it read so the person's other devices follow,
/// and follows reads that gateway pushes from them.
extension PushCenter {
    struct ReadReport {
        var chats: Set<String> = []
        var rooms: Set<String> = []
        var task: Task<Void, Never>?
    }

    /// A chat's read state may have moved (the list, a read mark, the chat on screen): its
    /// delivered notifications are swept soon, once for a burst of changes.
    func readMayHaveMoved(in workspace: BotWorkspace) {
        let id = workspace.id
        guard readSweeps[id] == nil else { return }
        readSweeps[id] = Task { [weak self, weak workspace] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.readSweeps[id] = nil
            guard let workspace else { return }
            await self.removeDelivered(gateway: id, readAt: workspace.unread.readThrough)
        }
    }

    /// Back in the app: rooms the plugin said were read elsewhere (in a push or a notice) are read
    /// here too, and every gateway's read chats are swept.
    func catchUpOnReads() {
        for workspace in model?.workspaces.values.map({ $0 }) ?? [] {
            workspace.roster?.groupRooms.readElsewhere(shared.reads(gateway: workspace.id).rooms)
            readMayHaveMoved(in: workspace)
        }
    }

    /// Chats or rooms read on this device (opened, or Mark as Read): their notifications go here
    /// now, and the gateway hears of them a second later, all at once.
    func didRead(chats: [String], rooms: [String], in workspace: BotWorkspace) {
        let id = workspace.id
        var report = readReports[id] ?? ReadReport()
        report.chats.formUnion(chats.filter { !$0.isEmpty })
        report.rooms.formUnion(rooms.filter { !$0.isEmpty })
        if report.task == nil {
            report.task = Task { [weak self, weak workspace] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let sent = self.readReports.removeValue(forKey: id), let workspace else { return }
                await self.sendRead(sent, in: workspace)
            }
        }
        readReports[id] = report
        readMayHaveMoved(in: workspace)
    }

    /// Chats read on another device (a `read` background push): their notifications go, and the
    /// badge follows, before the app's own read marks have caught up.
    func read(_ notice: PushNotice) async {
        if let gateway = notice.gateway?.id, let open = notice.open {
            shared.recordOpen(open, gateway: gateway, at: notice.sentAt ?? .now)
        }
        if let appID = shared.gateway(notice.gateway?.id)?.appID {
            let marks = ReadMarks(notice)
            shared.noteRead(marks, gateway: appID)
            model?.workspaces[appID]?.roster?.groupRooms.readElsewhere(marks.rooms)
            await removeDelivered(gateway: appID, readAt: marks.readAt)
        }
        await applyBadge()
    }

    /// Removes this gateway's delivered news (replies, Bot and group messages) for chats read
    /// since it was sent (`ReadNotices`).
    func removeDelivered(gateway appID: UUID, readAt: (ReadNotices.Chat) -> Date?) async {
        let center = UNUserNotificationCenter.current()
        let gone = await center.deliveredNotifications().compactMap { notification -> String? in
            let remote = notification.request.trigger is UNPushNotificationTrigger
            guard let opened = PushUserInfo.opened(notification.request.content.userInfo, isRemote: remote, shared: shared),
                  opened.gateway == appID,
                  ReadNotices.isRead(opened.notice, deliveredAt: notification.date, readAt: readAt)
            else { return nil }
            return notification.request.identifier
        }
        guard !gone.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: gone)
        ConnectionLog.logger.notice("push: cleared \(gone.count, privacy: .public) notifications for read chats")
    }

    private func sendRead(_ report: ReadReport, in workspace: BotWorkspace) async {
        guard !(report.chats.isEmpty && report.rooms.isEmpty), let roster = workspace.roster, roster.state.isOnline,
              hasPushPlugin(workspace.id)
        else { return }
        let client = AppPushClient { try await roster.request($0, $1, timeout: .seconds(10)) }
        do {
            let open = try await client.read(deviceID: shared.deviceID, chats: report.chats.sorted(), rooms: report.rooms.sorted())
            if let installation = installationID(for: workspace.id) { shared.recordOpen(open, gateway: installation) }
        } catch {
            // An older plugin doesn't know `read`: the other devices catch up when their app runs.
            let failure = error as NSError
            ConnectionLog.logger.notice("push: the gateway didn't take a read (\(failure.domain, privacy: .public) \(failure.code, privacy: .public))")
        }
    }

    /// The gateway has the plugin, whether or not this device gets its pushes (the Mac never does,
    /// an iPhone without permission doesn't): a read here still reaches the other devices.
    private func hasPushPlugin(_ id: UUID) -> Bool {
        switch gatewayStates[id] {
        case .on?, .notRegistered?: true
        default: false
        }
    }
}
