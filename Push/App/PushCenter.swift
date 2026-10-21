import HermesKit
import HermesPush
import Observation
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Push notifications in the app (`docs/notifications.md`): permission, the APNs token and this
/// device's key, registration with each gateway's `hermes-app-push` plugin, preferences, where the
/// person is (so the chat on screen never banners), the badge, and opening a notification.
///
/// iPhone and iPad get remote notices through the gateway plugin and the relay. The Mac posts its
/// own notifications from its live connections while the app runs (`MacNotifier`).
@MainActor
@Observable
final class PushCenter {
    static let shared = PushCenter()

    /// What push looks like for one gateway.
    enum GatewayState: Equatable {
        case unknown
        case checking
        /// The plugin answered (and, on iPhone, has this device). `relay` is a relay problem, if any.
        case on(relay: String?)
        /// The plugin answered, but this iPhone isn't on its list: no permission, or no push
        /// address from Apple yet (`docs/setup.md` §4.13). Why, in words.
        case notRegistered(String)
        /// The gateway has no `/app-push` command: Set Up Push.
        case notInstalled
        /// No Bot Mode link, so the app can't reach the gateway's commands.
        case needsBackend
        case offline
        case failed(String)

        var isOn: Bool { if case .on = self { true } else { false } }
    }

    /// Why the permission sheet is showing.
    enum PrimeReason: String, Identifiable {
        case approval, longTurn
        var id: String { rawValue }
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var showPreviews: UNShowPreviewsSetting = .always
    private(set) var timeSensitive: UNNotificationSetting = .notSupported
    private(set) var deviceToken: String?
    private(set) var tokenError: String?
    private(set) var gatewayStates: [UUID: GatewayState] = [:]
    var preferences: PushPreferences {
        didSet {
            guard preferences != oldValue else { return }
            shared.preferences = preferences
            schedulePreferenceSync()
        }
    }
    /// Settings → Notifications → App Icon Badge: what the badge counts (`docs/inbox.md` §5).
    var badgeMode: PushShared.BadgeMode {
        didSet {
            guard badgeMode != oldValue else { return }
            shared.badgeMode = badgeMode
            Task { await applyBadge() }
        }
    }
    /// The permission sheet (`permissionPrime`), when a trigger asked for it.
    var prime: PrimeReason?
    /// The Set Up Push sheet's gateway (`pushSetup`).
    var setupGateway: UUID?
    /// Settings → Notifications, from the system's "Hermes Notification Settings" link.
    var showSettings = false
    /// Why the last Live Activity couldn't start (Settings shows it).
    private(set) var activityError: String?
    /// Chats the app is showing, by gateway: no banner for these (their card docks instead).
    private(set) var isActive = false
    /// A moment to ask came while the app wasn't in front: on iPhone a long reply or an
    /// approval usually lands after the person has left, which is when notifications matter.
    /// Asked when they're back.
    @ObservationIgnored private var pendingPrime: PrimeReason?
    /// Chats running a turn now (`conversation(_:working:)`).
    @ObservationIgnored var workingChats: Set<ObjectIdentifier> = []

    @ObservationIgnored let shared = PushShared.current
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var registeredAt: [UUID: Date] = [:]
    /// Checks in a row that found no plugin or failed: the next one waits longer (30 s, then
    /// doubling up to an hour). A reconnect or the Set Up sheet asks again at once.
    @ObservationIgnored private var failedChecks: [UUID: Int] = [:]

    /// When a gateway whose check failed is looked at again: `registeredAt` set back so the
    /// hourly refresh comes due after the backoff.
    private func retryLater(_ id: UUID) {
        let failures = (failedChecks[id] ?? 0) + 1
        failedChecks[id] = failures
        let wait = min(3600, 30 * pow(2, Double(failures - 1)))
        registeredAt[id] = .now.addingTimeInterval(-3600 + wait)
    }
    @ObservationIgnored private var registering: Set<UUID> = []
    @ObservationIgnored private var wasOnline: [UUID: Bool] = [:]
    @ObservationIgnored private var facesRenderedAt: [UUID: Date] = [:]
    /// What `shareBotChats` last wrote, per gateway.
    @ObservationIgnored private var sharedBotChats: [UUID: [String: String]] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var preferenceSync: Task<Void, Never>?
    @ObservationIgnored private var lastPresence: (chat: String?, at: Date)?
    @ObservationIgnored private var pendingResponses: [PushResponder.Response] = []
    @ObservationIgnored private(set) var activities: AnyObject?
    /// Per gateway: the pending sweep of read chats' notifications, and reads on their way to the
    /// plugin (`PushCenter+Reading`).
    @ObservationIgnored var readSweeps: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var readReports: [UUID: ReadReport] = [:]

    private init() {
        preferences = PushShared.current.preferences
        badgeMode = PushShared.current.badgeMode
    }

    // MARK: - Lifecycle

    /// Called once the app model exists: categories, current permission, and the APNs token.
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        registerCategories()
        #if os(iOS)
        activities = TurnActivityController(center: self)
        #endif
        Task {
            await refreshAuthorization()
            #if os(iOS)
            if canNotify {
                UIApplication.shared.registerForRemoteNotifications()
            }
            #endif
            for response in pendingResponses { await PushResponder.handle(response, center: self) }
            pendingResponses.removeAll()
        }
    }

    func sceneDidBecomeActive() {
        isActive = true
        Task {
            await refreshAuthorization()
            await refreshBadge()
            askIfPending()
        }
        // Chats read elsewhere while the app was away leave nothing on the Lock Screen.
        catchUpOnReads()
        startLoop()
        #if os(iOS)
        (activities as? TurnActivityController)?.appDidBecomeActive()
        #endif
    }

    func sceneWillResignActive() {
        #if os(iOS)
        (activities as? TurnActivityController)?.appWillResignActive()
        #endif
    }

    func sceneDidEnterBackground() {
        isActive = false
        // Leaving while Hermes works is the moment a notification helps: ask on the way back.
        if !workingChats.isEmpty { considerAsking(.longTurn) }
        loop?.cancel()
        loop = nil
        #if os(iOS)
        (activities as? TurnActivityController)?.appDidEnterBackground()
        reportAway()
        #endif
    }

    /// Every few seconds while the app is in front: register with gateways as they come online and
    /// keep each one's idea of what's on screen fresh (the plugin forgets it after 75 s). A Mac app
    /// behind other apps stays "active" here, so it ticks every 30 s then.
    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let interval: Double = AppPresence.isInBack ? 30 : 3
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
            }
        }
    }

    private func tick() async {
        guard let model else { return }
        for workspace in model.workspaces.values {
            // A gateway that just came back (restarted, or the network returned) hears from us again.
            let online = workspace.roster?.state.isOnline ?? false
            if online, wasOnline[workspace.id] == false {
                registeredAt[workspace.id] = nil
                failedChecks[workspace.id] = nil
            }
            wasOnline[workspace.id] = online
            if online, gatewayStates[workspace.id]?.isOn == true,
               facesRenderedAt[workspace.id].map({ Date.now.timeIntervalSince($0) > 600 }) ?? true {
                renderFaces(for: workspace)
            }
            if online { shareBotChats(of: workspace) }
            let stale = registeredAt[workspace.id].map { Date.now.timeIntervalSince($0) > 3600 } ?? true
            if stale, !registering.contains(workspace.id) {
                await check(workspace)
            }
        }
        #if os(iOS)
        let chat = visibleChatIDs.first
        if lastPresence == nil || lastPresence?.chat != chat || Date.now.timeIntervalSince(lastPresence?.at ?? .distantPast) > 50 {
            lastPresence = (chat, .now)
            await reportPresence(chat: chat)
        }
        #endif
    }

    // MARK: - Permission

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        timeSensitive = settings.timeSensitiveSetting
        #if os(iOS)
        showPreviews = settings.showPreviewsSetting
        #endif
    }

    /// Turn On Notifications. Time Sensitive comes from the entitlement, not an option here
    /// (`UNAuthorizationOptionTimeSensitive` only ever worked in iOS 15.0).
    func requestAuthorization() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge, .providesAppNotificationSettings]
        )) ?? false
        await refreshAuthorization()
        #if os(iOS)
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        #endif
        prime = nil
    }

    /// A moment worth asking in: the first approval, a turn that ran over 30 s, or leaving while
    /// one runs. Never at launch; away from the app, on the way back. After Not Now, once more a
    /// week later, then only from Settings.
    func considerAsking(_ reason: PrimeReason) {
        guard authorization == .notDetermined, prime == nil else { return }
        // Never during onboarding: setup after pairing is on screen.
        guard model?.setupGatewayID == nil else { return }
        let defaults = shared.defaults
        let declines = defaults.integer(forKey: "push.primeDeclines")
        guard declines < 2 else { return }
        if let snoozed = defaults.object(forKey: "push.primeSnoozedUntil") as? Date, snoozed > .now { return }
        // Not during a call either: the sheet would push the call's screen away (`docs/voice.md` §4).
        guard isInFront, !TalkCenter.shared.isActive else {
            pendingPrime = pendingPrime ?? reason
            return
        }
        prime = reason
    }

    /// Back in front with a moment saved: ask, once the app has settled.
    private func askIfPending() {
        guard let reason = pendingPrime else { return }
        pendingPrime = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            considerAsking(reason)
        }
    }

    /// The scene's phase, or on iPhone the app's own state: a launch straight into the
    /// foreground may not report a phase change.
    private var isInFront: Bool {
        #if os(iOS)
        isActive || UIApplication.shared.applicationState == .active
        #else
        isActive
        #endif
    }

    func notNow() {
        let defaults = shared.defaults
        defaults.set(defaults.integer(forKey: "push.primeDeclines") + 1, forKey: "push.primeDeclines")
        defaults.set(Date.now.addingTimeInterval(7 * 86_400), forKey: "push.primeSnoozedUntil")
        prime = nil
    }

    var isDenied: Bool { authorization == .denied }

    var canNotify: Bool {
        #if os(iOS)
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
        #else
        authorization == .authorized || authorization == .provisional
        #endif
    }

    /// Settings → Hermes → Notifications.
    func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Device

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        tokenError = nil
        guard token != deviceToken else { return }
        deviceToken = token
        registeredAt.removeAll()  // a new token: every gateway needs it
        Task { await tick() }
    }

    func didFailToRegister(_ error: any Error) {
        tokenError = error.localizedDescription
    }

    /// Why this device isn't on a gateway's list, for its row.
    private var notRegisteredReason: String {
        if authorization == .notDetermined { return String(localized: "Notifications aren't on for Hermes yet: turn them on above.") }
        if !canNotify { return String(localized: "Notifications are off for Hermes on this device.") }
        if let tokenError { return String(localized: "Apple didn't give this device a push address: \(tokenError)") }
        return String(localized: "Waiting for Apple to give this device a push address.")
    }

    /// `development` (the sandbox) or `production`, from the provisioning profile's APNs entitlement.
    static var apnsEnvironment: String {
        #if targetEnvironment(simulator)
        return "development"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .isoLatin1),
           let start = text.range(of: "<plist"), let end = text.range(of: "</plist>"),
           let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let environment = entitlements["aps-environment"] as? String {
            return environment
        }
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
        #endif
    }

    // MARK: - Gateways

    /// Registers this device with a gateway's plugin (iPhone), or checks the plugin is there (Mac).
    func check(_ workspace: BotWorkspace) async {
        let id = workspace.id
        guard let roster = workspace.roster else {
            gatewayStates[id] = .needsBackend
            return
        }
        guard roster.state.isOnline else {
            if gatewayStates[id] == nil || gatewayStates[id] == .checking { gatewayStates[id] = .offline }
            return
        }
        registering.insert(id)
        defer { registering.remove(id) }
        if gatewayStates[id] != .on(relay: nil) { gatewayStates[id] = .checking }
        let client = AppPushClient { method, params in try await roster.request(method, params, timeout: .seconds(20)) }
        do {
            #if os(iOS)
            if let token = deviceToken, canNotify {
                // Sealed to a key of this installation's own (`PushShared` device keys): asked for
                // first when this device doesn't know which installation the gateway is.
                var installation = installationID(for: id)
                if installation == nil { installation = try await client.status(deviceID: shared.deviceID).installationID }
                let own = try installation.flatMap { $0.isEmpty ? nil : try shared.deviceKey(installation: $0, create: true) }
                let key: PushDeviceKey
                if let own { key = own } else if let legacy = try shared.legacyKey(create: true) { key = legacy } else { return }
                var registration = try await client.register(device(token: token, key: key), preferences: preferences)
                if !registration.installationID.isEmpty, registration.installationID != installation,
                   let right = try shared.deviceKey(installation: registration.installationID, create: true) {
                    // Another installation than this device thought: once more with its own key.
                    registration = try await client.register(device(token: token, key: right), preferences: preferences)
                }
                shared.remember(installationID: registration.installationID, appID: id, name: workspace.bot.name)
                if !registration.installationID.isEmpty { shared.registeredOwnKey(installation: registration.installationID) }
                registerCategories()
                gatewayStates[id] = .on(relay: registration.relay == "ok" ? nil : registration.relay)
                renderFaces(for: workspace)
            } else {
                let status = try await client.status(deviceID: shared.deviceID)
                if let installation = status.installationID {
                    shared.remember(installationID: installation, appID: id, name: workspace.bot.name)
                }
                // The plugin is there, but without permission or a push address this iPhone can't
                // register: that isn't "Push on" (`docs/setup.md` §4.13).
                if status.registered, canNotify {
                    gatewayStates[id] = .on(relay: status.relayError)
                } else {
                    gatewayStates[id] = .notRegistered(notRegisteredReason)
                }
            }
            #else
            let status = try await client.status(deviceID: shared.deviceID)
            gatewayStates[id] = .on(relay: status.relayError)
            #endif
            registeredAt[id] = .now
            failedChecks[id] = nil
        } catch AppPushClient.Failure.notInstalled {
            gatewayStates[id] = .notInstalled
            retryLater(id)
        } catch {
            gatewayStates[id] = .failed(error.localizedDescription)
            retryLater(id)
        }
    }

    /// Checks one gateway now (the Set Up Push sheet polls this).
    func recheck(_ id: UUID) async {
        guard let workspace = model?.workspaces[id] else { return }
        registeredAt[id] = nil
        failedChecks[id] = nil
        await check(workspace)
    }

    #if os(iOS)
    private func device(token: String, key: PushDeviceKey) -> AppPushClient.Device {
        var simulator: String?
        #if targetEnvironment(simulator)
        simulator = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        #endif
        let info = Bundle.main.infoDictionary
        return AppPushClient.Device(
            id: shared.deviceID, token: token, topic: Bundle.main.bundleIdentifier ?? "",
            environment: Self.apnsEnvironment, publicKey: key.publicKeyBase64,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            name: UIDevice.current.name,
            appVersion: "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))",
            simulator: simulator
        )
    }
    #endif

    /// The gateway was removed from the app: forget this device there too.
    func forget(_ workspace: BotWorkspace) {
        let deviceID = shared.deviceID
        if let roster = workspace.roster, roster.state.isOnline {
            Task { _ = try? await AppPushClient { try await roster.request($0, $1) }.unregister(deviceID: deviceID) }
        }
        shared.forget(appID: workspace.id)
        gatewayStates[workspace.id] = nil
        registerCategories()
    }

    /// Push on, out of the gateways the app knows.
    var enabledGatewayCount: Int { gatewayStates.values.filter(\.isOn).count }

    private func schedulePreferenceSync() {
        preferenceSync?.cancel()
        preferenceSync = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let model else { return }
            let deviceID = shared.deviceID
            for workspace in model.workspaces.values where gatewayStates[workspace.id]?.isOn == true {
                guard let roster = workspace.roster, roster.state.isOnline else { continue }
                _ = try? await AppPushClient { try await roster.request($0, $1) }.setPreferences(preferences, deviceID: deviceID)
            }
        }
    }

    // MARK: - Categories

    /// The base categories plus one set per gateway slot, whose hidden-preview text names it.
    func registerCategories(questionChoices: [String: [String]] = [:]) {
        var slots: [Int: String] = [:]
        for gateway in shared.gateways.values {
            if let slot = gateway.slot { slots[slot] = gateway.name }
        }
        UNUserNotificationCenter.current().setNotificationCategories(
            NotificationCatalog.categories(slots: slots, questionChoices: questionChoices)
        )
    }

    // MARK: - Where the person is

    /// The chat on screen, as every id a notice might name it by.
    var visibleChatIDs: [String] {
        guard isActive, let workspace = model?.currentWorkspace else { return [] }
        if case .group(let room)? = workspace.selection { return [room] }
        let conversation = workspace.currentConversation
        return [conversation.sessionID, conversation.stableKey].compactMap { $0 }
    }

    func isShowing(_ notice: PushNotice) -> Bool {
        guard isActive, let model, let workspace = model.currentWorkspace else { return false }
        if let gateway = shared.gateway(notice.gateway?.id), gateway.appID != workspace.id { return false }
        let ids = Set(visibleChatIDs)
        return [notice.chatID, notice.roomID, notice.thread].contains { $0.map(ids.contains) ?? false }
    }

    #if os(iOS)
    private func reportPresence(chat: String?) async {
        guard let model, deviceToken != nil else { return }
        let deviceID = shared.deviceID
        for workspace in model.workspaces.values where gatewayStates[workspace.id]?.isOn == true {
            guard let roster = workspace.roster, roster.state.isOnline else { continue }
            let open = try? await AppPushClient { try await roster.request($0, $1) }.setPresence(
                .foreground, deviceID: deviceID, visibleChat: workspace.id == model.currentWorkspace?.id ? chat : nil
            )
            if let open, let installation = installationID(for: workspace.id) {
                shared.recordOpen(open, gateway: installation)
            }
        }
        await applyBadge()
    }

    /// Leaving the app: gateways push again, including for the chat that was on screen, and keep
    /// the chats the person is likely to come back to current while the app is away (`sync`).
    private func reportAway() {
        guard let model, deviceToken != nil else { return }
        lastPresence = nil
        let deviceID = shared.deviceID
        let countsUnread = shared.badgeMode == .unreadChats
        let targets = model.workspaces.values.compactMap { workspace -> (BotRoster, [String], AwayBadge?, Int)? in
            guard gatewayStates[workspace.id]?.isOn == true, let roster = workspace.roster else { return nil }
            // What the badge counts, so the plugin keeps it right while the app is away.
            var badge: AwayBadge?
            if countsUnread {
                let lists = workspace.unread.badgeLists()
                badge = (lists.unread, lists.muted, workspace.unread.listedChats())
            }
            return (roster, workspace.chatsToKeepCurrent(showing: workspace.id == model.currentWorkspace?.id), badge,
                    shared.badge(besides: workspace.id))
        }
        // Background time for it, given back before it runs out even if a gateway is slow to answer.
        let activity = BackgroundActivity()
        activity.begin("Hermes presence")
        Task {
            for (roster, chats, badge, others) in targets where roster.state.isOnline {
                _ = try? await AppPushClient { try await roster.request($0, $1, timeout: .seconds(5)) }
                    .setPresence(.away, deviceID: deviceID, sync: chats, unread: badge?.unread, muted: badge?.muted,
                                 listed: badge?.listed, badgeOthers: badge == nil ? nil : others)
            }
            activity.end()
        }
    }
    #endif

    func installationID(for appID: UUID) -> String? {
        shared.gateways.first { $0.value.appID == appID }?.key
    }

    // MARK: - Badge

    /// Badge = open "needs you" requests across gateways, nothing else.
    func refreshBadge() async {
        guard let model else { return }
        let deviceID = shared.deviceID
        for workspace in model.workspaces.values where gatewayStates[workspace.id]?.isOn == true {
            guard let roster = workspace.roster, roster.state.isOnline,
                  let status = try? await AppPushClient(transport: { try await roster.request($0, $1) }).status(deviceID: deviceID),
                  let installation = status.installationID
            else { continue }
            shared.recordOpen(status.open, gateway: installation)
        }
        await applyBadge()
    }

    func applyBadge() async {
        // Lists for gateways the app no longer has would count for ever.
        if let gateways = model?.workspaces.keys, !gateways.isEmpty { shared.keepUnread(gateways: Set(gateways)) }
        #if os(iOS)
        try? await UNUserNotificationCenter.current().setBadgeCount(shared.badge)
        #else
        let badge = shared.badge
        NSApp.dockTile.badgeLabel = badge > 0 ? "\(badge)" : nil
        #endif
    }

    /// A gateway's unread, unmuted chats changed (`UnreadStore`): the badge follows when it
    /// counts them.
    func unreadChanged(_ chats: [UnreadChat], countable: CountableChats?, gateway: UUID) {
        // Before its list has loaded, a gateway keeps what the badge knew.
        guard let countable else { return }
        let listed = shared.recordCountable(countable, gateway: gateway)
        guard shared.recordUnread(chats, gateway: gateway) || listed else { return }
        Task { await applyBadge() }
    }

    // MARK: - Notices

    /// Removes every delivered notice about these requests (answered here, or anywhere).
    func removeDelivered(requests ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let gone = delivered.filter { notification in
            let info = notification.request.content.userInfo
            return (info[PushUserInfo.request] as? String).map(ids.contains) ?? ids.contains(notification.request.identifier)
        }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: gone + Array(ids))
    }

    /// Chats changed while the app was away (`sync`, a background push): they're read now and kept
    /// on the device, so they show as they are when the person comes back (`docs/notifications.md` §2).
    func sync(_ notice: PushNotice) async {
        if let gateway = notice.gateway?.id, let open = notice.open {
            shared.recordOpen(open, gateway: gateway, at: notice.sentAt ?? .now)
        }
        // Woken from scratch, the app may still be setting up.
        for _ in 0..<20 where model == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let model, let appID = shared.gateway(notice.gateway?.id)?.appID,
              let workspace = model.workspaces[appID], !notice.sessions.isEmpty else { return }
        let began = Date.now
        ConnectionLog.logger.notice("push: keeping \(notice.sessions.count, privacy: .public) chats current")
        await workspace.keepCurrent(chats: notice.sessions, within: .seconds(20))
        ConnectionLog.logger.notice("push: chats read in \(Int(Date.now.timeIntervalSince(began) * 1000), privacy: .public)ms")
    }

    /// A withdrawal (background push): the request was answered, timed out or was cancelled.
    func withdraw(_ notice: PushNotice) async {
        let ids = Set(notice.ids)
        await removeDelivered(requests: ids)
        if let gateway = notice.gateway?.id, let open = notice.open {
            shared.recordOpen(open, gateway: gateway, at: notice.sentAt ?? .now)
        }
        await applyBadge()
        #if os(iOS)
        (activities as? TurnActivityController)?.requestsResolved(ids)
        #endif
    }

    /// Foreground rule: no banner for the chat on screen (its card docks), banners for the rest. A
    /// request the chat on screen is waiting on still goes quietly into Notification Center, so it's
    /// on the Lock Screen if the person walks away without answering (answering withdraws it).
    func presentation(for notice: PushNotice?) -> UNNotificationPresentationOptions {
        guard let notice else { return [.banner, .list, .sound] }
        if notice.kind == .withdraw || notice.kind == .sync || notice.kind == .read { return [] }
        if isShowing(notice) {
            if let workspace = model?.currentWorkspace { catchUp(notice, in: workspace) }
            return notice.kind.needsYou ? [.list] : []
        }
        return notice.kind == .task || notice.kind == .background || notice.kind == .tidied ? [.list] : [.banner, .list, .sound]
    }

    func handle(_ response: PushResponder.Response) async {
        guard model != nil else {
            pendingResponses.append(response)
            return
        }
        await PushResponder.handle(response, center: self)
    }

    // MARK: - Opening

    /// Shows the chat (or room, or Tasks) a notice is about.
    func open(_ notice: PushNotice) {
        guard let model else { return }
        let appID = shared.gateway(notice.gateway?.id)?.appID ?? model.selectedBotID
        guard let appID, let workspace = model.workspaces[appID] else { return }
        model.select(appID)
        if notice.kind.isCard, let card = notice.cardID {
            workspace.openCard(card, board: notice.board, projectID: notice.projectID)
        } else if notice.kind == .tidied {
            workspace.openLearned(.tidying, bot: notice.profile)
        } else if let room = notice.roomID {
            workspace.sidebarMode = .bots
            workspace.selection = .group(room)
        } else if let profile = notice.profile ?? botProfile(forChat: notice.chatID, in: workspace) {
            workspace.sidebarMode = .bots
            workspace.selection = .bot(profile)
            catchUp(notice, in: workspace)
        } else if notice.kind == .task || notice.kind == .taskFailed {
            workspace.selection = .tasks
        } else if let chat = notice.chatID {
            if let roster = workspace.roster, !roster.hasLoaded {
                // A tap that launched the app can come before the Bots have loaded: a moment for
                // them, since a Bot's own chat opens the Bot.
                Task { [weak self] in
                    for _ in 0..<20 where !roster.hasLoaded {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    self?.showChat(chat, in: workspace)
                    self?.catchUp(notice, in: workspace)
                }
            } else {
                showChat(chat, in: workspace)
                catchUp(notice, in: workspace)
            }
        }
    }

    private func showChat(_ chat: String, in workspace: BotWorkspace) {
        if let profile = botProfile(forChat: chat, in: workspace) {
            workspace.sidebarMode = .bots
            workspace.selection = .bot(profile)
        } else {
            let key = workspace.sessions.first { $0.id == chat || $0.stableID == chat }?.stableID ?? chat
            workspace.sidebarMode = .chats
            workspace.selection = .session(key)
        }
    }

    /// What a reply or a message announced is fetched at once in the chat it opened, or the one on
    /// screen it arrived for (`ConversationModel.notificationOpened`): on a busy Mac, waiting for
    /// the roster to notice took most of a minute.
    func catchUp(_ notice: PushNotice, in workspace: BotWorkspace) {
        guard [.reply, .message, .background].contains(notice.kind) else { return }
        switch workspace.selection {
        case .bot?, .session?: workspace.currentConversation.notificationOpened(sentAt: notice.sentAt)
        default: break
        }
    }

    /// The Bot whose own chat this is (the primary Bot's notices carry no profile): the roster
    /// knows, or what was shared with the extension does when a tap launched the app before the
    /// roster loaded.
    private func botProfile(forChat chat: String?, in workspace: BotWorkspace) -> String? {
        guard let chat else { return nil }
        return workspace.roster?.botChats[chat] ?? shared.botChats(gateway: workspace.id)[chat]
    }

    /// Shares each Bot's own chats with the service extension when they change, so their notices
    /// say who they're from and open the Bot (`PushNotice.nameBot`).
    private func shareBotChats(of workspace: BotWorkspace) {
        guard let roster = workspace.roster, !roster.profiles.isEmpty else { return }
        let chats = roster.botChats
        guard chats != sharedBotChats[workspace.id] else { return }
        sharedBotChats[workspace.id] = chats
        shared.setBotChats(chats, gateway: workspace.id)
    }

    // MARK: - Chats

    /// A chat's title as the sidebar shows it.
    func chatTitle(of conversation: ConversationModel, in workspace: BotWorkspace) -> String {
        if conversation.isBotChat { return conversation.askerName }
        if let key = conversation.stableKey, let title = workspace.session(forKey: key)?.title, !title.isEmpty {
            return title
        }
        return String(localized: "New Chat")
    }

    func recordActivityError(_ error: any Error) {
        activityError = error.localizedDescription
    }

    // MARK: - Faces

    /// Saves each Bot's face where the service extension finds it (communication notifications).
    func renderFaces(for workspace: BotWorkspace) {
        #if os(iOS)
        guard let roster = workspace.roster, !roster.profiles.isEmpty else { return }
        facesRenderedAt[workspace.id] = .now
        shared.setBotNames(Dictionary(roster.profiles.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first }),
                           gateway: workspace.id)
        // Faces drawn before the current style (`docs/bot-faces.md`) are drawn again once.
        let styleKey = "faces.style", style = 3
        let restyle = shared.defaults.integer(forKey: styleKey) != style
        for bot in roster.profiles {
            guard let url = shared.faceURL(gateway: workspace.id, bot: bot.name) else { continue }
            let appearance = roster.appearance(for: bot)
            if !restyle, let fresh = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date.now.timeIntervalSince(fresh) < 86_400 { continue }
            // The notification avatar (36 pt): the body's 40 × 40 box, at 3×.
            let size: CGFloat = 36
            let renderer = ImageRenderer(content: Group {
                if let photo = appearance.imageURL.flatMap(FaceImageCache.image(for:)) {
                    Image(platformImage: photo).resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                } else {
                    StillFace(look: appearance.look, size: size)
                }
            }
            .frame(width: size, height: size, alignment: .top))
            renderer.scale = 3
            guard let data = renderer.uiImage?.pngData() else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if restyle { shared.defaults.set(style, forKey: styleKey) }
        #endif
    }
}
