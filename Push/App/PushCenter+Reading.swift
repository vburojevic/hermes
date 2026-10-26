import HermesKit
import HermesPush
import os
import UserNotifications

/// What the badge counts as the app leaves (`presence away`).
typealias AwayBadge = (unread: AppPushClient.ChatLists, muted: AppPushClient.ChatLists, listed: AppPushClient.ChatLists,
                       unmarked: AppPushClient.ChatLists)

/// Read chats leave no notifications behind (`docs/notifications.md` §2 Reading): this device
/// sweeps them as reads land, tells the gateway what it read so the person's other devices follow,
/// and follows reads that gateway pushes from them.
extension PushCenter {
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
    /// now, and the gateway hears of them a second later, all at once. Until it has them they wait
    /// on the device, in front or not (a Mac app that never came to the front), and go once it can
    /// be reached (`PushReadQueue`).
    func didRead(chats: [String], rooms: [String], in workspace: BotWorkspace) {
        let id = workspace.id
        var queue = readQueue(id)
        queue.add(chats: chats, rooms: rooms, lastActive: Self.activity(in: workspace))
        setReadQueue(queue, id)
        scheduleReadFlush(workspace, at: .now.addingTimeInterval(1))
        readMayHaveMoved(in: workspace)
    }

    /// The chat list came in while Bot Mode is online: reads that waited for it are judged against
    /// it now, and the first list since Bot Mode came back sends them at once.
    func chatListFetched(_ workspace: BotWorkspace) {
        let id = workspace.id
        guard workspace.roster?.state.isOnline == true else { return }
        var queue = readQueue(id)
        if listedSinceConnect.insert(id).inserted, !queue.isEmpty {
            queue.retryNow()
            setReadQueue(queue, id)
        }
        rescheduleReads(workspace)
    }

    /// Bot Mode went away: the list it leaves can't judge the reads that wait, until it's fetched again.
    func gatewayWentAway(_ workspace: BotWorkspace) {
        listedSinceConnect.remove(workspace.id)
    }

    /// The gateway was removed: its waiting reads have nowhere to go.
    func forgetReads(of id: UUID) {
        readFlushes.removeValue(forKey: id)?.task.cancel()
        readQueues[id] = nil
        listedSinceConnect.remove(id)
        UserDefaults.standard.removeObject(forKey: Self.readQueueKey(id))
    }

    /// Chats read on another device (a `read` background push): their notifications go, and the
    /// badge follows, before the app's own read marks have caught up.
    func read(_ notice: PushNotice) async {
        await followReads(in: notice)
        await applyBadge()
    }

    /// What a background push (`read`, `withdraw`, `sync`) says was read elsewhere and is open now:
    /// those chats leave the badge's list and their notifications go, before anything sets the badge
    /// from this device's own counts (`PushShared.noteBackground`).
    func followReads(in notice: PushNotice) async {
        let appID = shared.gateway(notice.gateway?.id)?.appID
        let marks = shared.noteBackground(notice, gateway: appID)
        guard let appID, !marks.isEmpty else { return }
        model?.workspaces[appID]?.roster?.groupRooms.readElsewhere(marks.rooms)
        await removeDelivered(gateway: appID, readAt: marks.readAt)
    }

    /// The reads a gateway's plugin answered `presence` or `status` with (plugin 1.4.6): a group chat
    /// read on another device, whose message no notice carried, is read here too, unless it moved
    /// since, and its notifications go.
    func followReads(_ marks: ReadMarks, in workspace: BotWorkspace) {
        shared.noteRead(marks, gateway: workspace.id)
        workspace.roster?.groupRooms.readElsewhere(marks.rooms)
        readMayHaveMoved(in: workspace)
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

    /// Sends the reads that are due, checking for the plugin first when this device hasn't yet (the
    /// Mac checks as it comes to the front, so one that never did hadn't). Each read goes once: a
    /// batch is cleared when the plugin has it, tried again later when it doesn't arrive, and dropped
    /// when there's no plugin to take it.
    private func flushReads(in workspace: BotWorkspace) async {
        let id = workspace.id
        guard readQueue(id).isDue() else { return rescheduleReads(workspace) }
        // Offline, or the list not fetched since Bot Mode came back: the next list sends them
        // (`chatListFetched`).
        guard let roster = workspace.roster, roster.state.isOnline, listedSinceConnect.contains(id) else { return }
        if !hasPushPlugin(id) {
            await check(workspace)
            switch gatewayStates[id] {
            case .on?, .notRegistered?:
                break
            case .notInstalled?:
                // Without the plugin no other device hears of reads; Hermes' own marks went anyway.
                var queue = readQueue(id)
                queue.clear()
                setReadQueue(queue, id)
                return
            default:
                var queue = readQueue(id)
                queue.failed()
                setReadQueue(queue, id)
                return rescheduleReads(workspace)
            }
        }
        var queue = readQueue(id)
        guard let batch = queue.take(lastActive: Self.activity(in: workspace)) else {
            setReadQueue(queue, id)
            return
        }
        setReadQueue(queue, id)
        let client = AppPushClient { try await roster.request($0, $1, timeout: .seconds(10)) }
        var landed = true
        do {
            let open = try await client.read(deviceID: shared.deviceID, chats: batch.chats.keys.sorted(), rooms: batch.rooms.keys.sorted())
            if let installation = installationID(for: id) { shared.recordOpen(open, gateway: installation) }
        } catch AppPushClient.Failure.refused(_), AppPushClient.Failure.notInstalled {
            // An older plugin doesn't know `read`: the other devices catch up when their app runs.
            ConnectionLog.logger.notice("push: the gateway didn't take a read")
        } catch {
            landed = false
            let failure = error as NSError
            ConnectionLog.logger.notice("push: a read didn't reach the gateway (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)); it waits")
        }
        var after = readQueue(id)
        if landed { after.sent(batch) } else { after.failed() }
        setReadQueue(after, id)
        rescheduleReads(workspace)
    }

    /// The next flush, at the waiting reads' next try.
    private func rescheduleReads(_ workspace: BotWorkspace) {
        let queue = readQueue(workspace.id)
        guard !queue.isEmpty, !queue.isSending else { return }
        scheduleReadFlush(workspace, at: queue.nextTry)
    }

    /// One flush per gateway, at the earliest time asked for.
    private func scheduleReadFlush(_ workspace: BotWorkspace, at date: Date) {
        let id = workspace.id
        if let pending = readFlushes[id], pending.at <= date { return }
        readFlushes[id]?.task.cancel()
        let task = Task { [weak self, weak workspace] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            self.readFlushes[id] = nil
            guard let workspace else { return }
            await self.flushReads(in: workspace)
        }
        readFlushes[id] = (date, task)
    }

    private static func readQueueKey(_ id: UUID) -> String { "pushReads.\(id.uuidString)" }

    /// A gateway's waiting reads, kept on the device so a quit doesn't lose them.
    private func readQueue(_ id: UUID) -> PushReadQueue {
        if let queue = readQueues[id] { return queue }
        let kept = UserDefaults.standard.data(forKey: Self.readQueueKey(id)).flatMap { try? JSONDecoder().decode(PushReadQueue.self, from: $0) }
        let queue = kept ?? PushReadQueue()
        readQueues[id] = queue
        return queue
    }

    private func setReadQueue(_ queue: PushReadQueue, _ id: UUID) {
        guard readQueues[id] != queue else { return }
        readQueues[id] = queue
        if queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.readQueueKey(id))
        } else if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.readQueueKey(id))
        }
    }

    /// When a chat (by session id, a Bot Chat's included) or a room last moved, as this device knows.
    private static func activity(in workspace: BotWorkspace) -> (String, Bool) -> Date? {
        { id, isRoom in
            if isRoom { return workspace.roster?.groupRooms.room(id)?.updatedAt }
            if let name = workspace.roster?.botChats[id] { return workspace.roster?.bot(named: name)?.chatActivity }
            return workspace.sessions.first { $0.id == id || $0.stableID == id }?.lastActive
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
