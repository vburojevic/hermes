import HermesKit
import HermesPush
import Observation
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
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
    /// The permission sheet (`permissionPrime`), when a trigger asked for it.
    var prime: PrimeReason?
    /// The Set Up Push sheet's gateway (`pushSetup`).
    var setupGateway: UUID?
    /// Chats the app is showing, by gateway: no banner for these (their card docks instead).
    private(set) var isActive = false

    @ObservationIgnored let shared = PushShared.current
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var registeredAt: [UUID: Date] = [:]
    @ObservationIgnored private var registering: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var preferenceSync: Task<Void, Never>?
    @ObservationIgnored private var lastPresence: (chat: String?, at: Date)?
    @ObservationIgnored private var pendingResponses: [PushResponder.Response] = []
    @ObservationIgnored private(set) var activities: AnyObject?

    private init() {
        preferences = PushShared.current.preferences
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
            if authorization == .authorized || authorization == .provisional || authorization == .ephemeral {
                UIApplication.shared.registerForRemoteNotifications()
            }
            #endif
            for response in pendingResponses { await PushResponder.handle(response, center: self) }
            pendingResponses.removeAll()
        }
    }

    func sceneDidBecomeActive() {
        isActive = true
        shared.writeUnlockProbe()
        Task {
            await refreshAuthorization()
            await refreshBadge()
        }
        startLoop()
        #if os(iOS)
        (activities as? TurnActivityController)?.appDidBecomeActive()
        #endif
    }

    func sceneDidEnterBackground() {
        isActive = false
        loop?.cancel()
        loop = nil
        #if os(iOS)
        (activities as? TurnActivityController)?.appDidEnterBackground()
        reportAway()
        #endif
    }

    /// Every few seconds while the app is in front: register with gateways as they come online and
    /// keep each one's idea of what's on screen fresh (the plugin forgets it after 75 s).
    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func tick() async {
        guard let model else { return }
        for workspace in model.workspaces.values {
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

    /// A moment worth asking in: the first approval, or a turn that ran over 30 s. Never at launch;
    /// after Not Now, once more a week later, then only from Settings.
    func considerAsking(_ reason: PrimeReason) {
        guard authorization == .notDetermined, prime == nil, isActive else { return }
        let defaults = shared.defaults
        let declines = defaults.integer(forKey: "push.primeDeclines")
        guard declines < 2 else { return }
        if let snoozed = defaults.object(forKey: "push.primeSnoozedUntil") as? Date, snoozed > .now { return }
        prime = reason
    }

    func notNow() {
        let defaults = shared.defaults
        defaults.set(defaults.integer(forKey: "push.primeDeclines") + 1, forKey: "push.primeDeclines")
        defaults.set(Date.now.addingTimeInterval(7 * 86_400), forKey: "push.primeSnoozedUntil")
        prime = nil
    }

    var isDenied: Bool { authorization == .denied }

    var canNotify: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
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
            if let token = deviceToken, canNotify, let key = try shared.deviceKey(create: true) {
                let registration = try await client.register(device(token: token, key: key), preferences: preferences)
                shared.remember(installationID: registration.installationID, appID: id, name: workspace.bot.name)
                registerCategories()
                gatewayStates[id] = .on(relay: registration.relay == "ok" ? nil : registration.relay)
                renderFaces(for: workspace)
            } else {
                let status = try await client.status(deviceID: shared.deviceID)
                if let installation = status.installationID {
                    shared.remember(installationID: installation, appID: id, name: workspace.bot.name)
                }
                gatewayStates[id] = .on(relay: status.relayError)
            }
            #else
            let status = try await client.status(deviceID: shared.deviceID)
            gatewayStates[id] = .on(relay: status.relayError)
            #endif
            registeredAt[id] = .now
        } catch AppPushClient.Failure.notInstalled {
            gatewayStates[id] = .notInstalled
            registeredAt[id] = .now.addingTimeInterval(-3600 + 30)  // look again in 30 s
        } catch {
            gatewayStates[id] = .failed(error.localizedDescription)
            registeredAt[id] = .now.addingTimeInterval(-3600 + 30)
        }
    }

    /// Checks one gateway now (the Set Up Push sheet polls this).
    func recheck(_ id: UUID) async {
        guard let workspace = model?.workspaces[id] else { return }
        registeredAt[id] = nil
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

    /// Leaving the app: gateways push again, including for the chat that was on screen.
    private func reportAway() {
        guard let model, deviceToken != nil else { return }
        lastPresence = nil
        let deviceID = shared.deviceID
        let rosters = model.workspaces.values.compactMap { workspace -> BotRoster? in
            gatewayStates[workspace.id]?.isOn == true ? workspace.roster : nil
        }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Hermes presence")
        Task {
            for roster in rosters where roster.state.isOnline {
                _ = try? await AppPushClient { try await roster.request($0, $1, timeout: .seconds(5)) }.setPresence(.away, deviceID: deviceID)
            }
            UIApplication.shared.endBackgroundTask(task)
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
                  let status = try? await AppPushClient({ try await roster.request($0, $1) }).status(deviceID: deviceID),
                  let installation = status.installationID
            else { continue }
            shared.recordOpen(status.open, gateway: installation)
        }
        await applyBadge()
    }

    func applyBadge() async {
        #if os(iOS)
        try? await UNUserNotificationCenter.current().setBadgeCount(shared.badge)
        #endif
    }

    // MARK: - Notices

    /// A withdrawal (background push): the request was answered, timed out or was cancelled.
    func withdraw(_ notice: PushNotice) async {
        let center = UNUserNotificationCenter.current()
        let ids = Set(notice.ids)
        let delivered = await center.deliveredNotifications()
        let gone = delivered.filter { notification in
            let info = notification.request.content.userInfo
            return (info[PushUserInfo.request] as? String).map(ids.contains) ?? ids.contains(notification.request.identifier)
        }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: gone + Array(ids))
        if let gateway = notice.gateway?.id, let open = notice.open {
            shared.recordOpen(open, gateway: gateway, at: notice.sentAt ?? .now)
        }
        await applyBadge()
        #if os(iOS)
        (activities as? TurnActivityController)?.requestsResolved(ids)
        #endif
    }

    /// Foreground rule: nothing for the chat on screen (its card docks), banners for the rest.
    func presentation(for notice: PushNotice?) -> UNNotificationPresentationOptions {
        guard let notice else { return [.banner, .list, .sound] }
        if notice.kind == .withdraw { return [] }
        if isShowing(notice) { return [] }
        return notice.kind == .task || notice.kind == .background ? [.list] : [.banner, .list, .sound]
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
        if let room = notice.roomID {
            workspace.sidebarMode = .bots
            workspace.selection = .group(room)
        } else if notice.kind == .task || notice.kind == .taskFailed {
            workspace.selection = .tasks
        } else if let chat = notice.chatID {
            let key = workspace.sessions.first { $0.id == chat || $0.stableID == chat }?.stableID ?? chat
            workspace.sidebarMode = .chats
            workspace.selection = .session(key)
        }
    }

    // MARK: - Faces

    /// Saves each Bot's face where the service extension finds it (communication notifications).
    func renderFaces(for workspace: BotWorkspace) {
        #if os(iOS)
        guard let roster = workspace.roster else { return }
        for bot in roster.profiles {
            guard let url = shared.faceURL(gateway: workspace.id, bot: bot.name) else { continue }
            let appearance = roster.appearance(for: bot)
            if let fresh = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date.now.timeIntervalSince(fresh) < 86_400 { continue }
            let renderer = ImageRenderer(content: BotFace(appearance: appearance, size: 96).frame(width: 96, height: 96))
            renderer.scale = 2
            guard let data = renderer.uiImage?.pngData() else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        #endif
    }
}
