import HermesKit
import Observation
import OSLog

/// Settings → Setup for one gateway (`docs/setup.md` §3): every feature that needs something
/// configured, with its state, worked out from what the gateway and this device report. The
/// checks themselves are `GatewaySetup` (HermesKit); this gathers what they read and makes the
/// fixes the person taps.
@MainActor
@Observable
final class SetupCenter {
    /// What the last check read. Live state (the connection, Bot Mode, the Bots) is laid over it
    /// in `facts`, so the page follows a reconnect without checking again.
    private(set) var reads: Reads
    private(set) var isChecking = false
    /// A fix that didn't take: Hermes's words, for an alert.
    var fixError: String?
    /// An update of Hermes the person started here or with /update, while it runs and once
    /// it's done, with its lines (`docs/setup.md` §4.2a).
    private(set) var updateRun: HermesUpdateRun?
    private(set) var updateLog = ActionLog()
    /// A gateway restart started with /restart, the same way.
    private(set) var restartRun: ActionRunState?
    private(set) var restartLog = ActionLog()
    /// Each kind's current run, and the runs before it as they ended, for the chat cards that
    /// started them.
    private(set) var currentJobs: [GatewayJob.Kind: GatewayJob.Ref] = [:]
    private(set) var pastJobs: [GatewayJob.Ref: GatewayJob] = [:]
    @ObservationIgnored private var jobStarts: [GatewayJob.Kind: Date] = [:]
    /// Runs that restarted Hermes and have read the gateway's priority since (`docs/setup.md`
    /// §4.17): their result says when Hermes's rewritten plist put it at background priority.
    private var priorityReadAfter: Set<GatewayJob.Ref> = []
    /// Whether the last read before each run found the gateway at background priority already.
    @ObservationIgnored private var throttledBefore: [GatewayJob.Ref: Bool] = [:]
    @ObservationIgnored private var priorityRead: Task<Void, Never>?
    /// The Mac's priority notice was put away with Not Now (`docs/setup.md` §4.17).
    private(set) var priorityNoticeDismissed: Bool
    @ObservationIgnored private var priorityCheckedAt: Date?

    @ObservationIgnored private weak var workspace: BotWorkspace?
    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "setup")

    struct Reads: Equatable {
        var version: String?
        var update: GatewaySetupFacts.UpdateCheck?
        var config: JSONValue?
        var gatewayRunning: Bool?
        var searchIndexRebuilding = false
        var providerConfigured: Bool?
        var memory: MemoryStatus?
        var curator: CuratorStatus?
        var groupDriver: Bool?
        var board: GatewaySetupFacts.Board?
        var taskProblems: [CronJob] = []
        var hostPriority: GatewaySetupFacts.HostPriority?
        var hostIsThisMac = false
        var vaultSources: [VaultSource]?
        var vaultMissing = false
    }

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        reads = Reads()
        priorityNoticeDismissed = UserDefaults.standard.bool(forKey: Self.noticeKey(workspace.bot.id))
    }

    // MARK: State

    var facts: GatewaySetupFacts {
        guard let workspace else { return GatewaySetupFacts(gatewayName: "", gatewayOnline: false, botMode: .notLinked) }
        var facts = GatewaySetupFacts(gatewayName: workspace.bot.name, gatewayOnline: workspace.connection.isOnline, botMode: botMode)
        if case .failed(.unsupportedServer) = workspace.connection { facts.gatewayTooOld = true }
        var connectionVersion: String?
        if case .online(let version) = workspace.connection { connectionVersion = version }
        facts.version = reads.version ?? connectionVersion
        facts.update = reads.update
        facts.hostPriority = reads.hostPriority
        facts.hostIsThisMac = reads.hostIsThisMac
        facts.deliveryProtection = workspace.deliveryProtection
        facts.updateRun = updateRun
        facts.config = reads.config
        facts.gatewayRunning = reads.gatewayRunning
        facts.searchIndexRebuilding = reads.searchIndexRebuilding
        facts.providerConfigured = reads.providerConfigured
        facts.defaultModel = workspace.defaultModelName
        facts.usableProviders = workspace.modelOptions.map { $0.usableProviders.count }
        facts.memory = reads.memory
        facts.curator = reads.curator
        facts.groupDriver = reads.groupDriver ?? workspace.roster.map { $0.groupRooms.isLoaded ? $0.groupRooms.isAvailable : nil } ?? nil
        facts.botCount = workspace.roster?.profiles.count ?? 0
        facts.board = reads.board
        facts.taskProblems = reads.taskProblems
        facts.vaultSources = reads.vaultSources
        facts.vaultMissing = reads.vaultMissing
        if let projects = workspace.projects, projects.hasLoaded, !projects.isAvailable { facts.projectsMissing = true }
        return facts
    }

    private var botMode: GatewaySetupFacts.BotMode {
        guard let workspace, workspace.bot.backend != nil, let roster = workspace.roster else { return .notLinked }
        switch roster.state {
        case .online: return .online
        case .idle, .connecting: return .connecting
        case .signInRequired: return .signInNeeded
        case .failed(let message): return .unreachable(message)
        }
    }

    /// Hermes on the gateway, in the order the page lists them.
    var hermesStatuses: [SetupStatus] {
        let facts = facts
        return [
            GatewaySetup.botMode(facts),
            GatewaySetup.hermes(facts),
            GatewaySetup.priority(facts),
            GatewaySetup.models(facts),
        ].map(shown)
    }

    /// What Hermes does for you, each needing something on the gateway.
    var featureStatuses: [SetupStatus] {
        let facts = facts
        return [
            GatewaySetup.memory(facts),
            GatewaySetup.passwords(facts),
            GatewaySetup.browser(facts),
            GatewaySetup.search(facts),
            GatewaySetup.checkpoints(facts),
            GatewaySetup.tasks(facts),
            GatewaySetup.projects(facts),
            GatewaySetup.board(facts),
            GatewaySetup.groupChats(facts),
            GatewaySetup.botReplies(facts),
            GatewaySetup.learned(facts),
        ].compactMap { $0 }.map(shown)
    }

    /// The app's plugins and push: what reaches this device.
    var deviceReachStatuses: [SetupStatus] {
        [notificationsStatus, widgetsStatus].map(shown)
    }

    /// Everything on the page, for the Settings row's count.
    var allStatuses: [SetupStatus] {
        hermesStatuses + featureStatuses + deviceReachStatuses + (workspace?.voiceSetup.setupStatuses ?? []) + DeviceSetup.shared.statuses
    }

    /// "2 to set up", or what's in use when everything is.
    var summary: String {
        let count = allStatuses.needingAttention
        switch count {
        case 0: return String(localized: "Everything is set up")
        case 1: return String(localized: "1 thing to set up")
        default: return String(localized: "\(count) things to set up")
        }
    }

    // MARK: Notifications and widgets

    static let notificationsID = "notifications"
    static let widgetsID = "widgets"

    var notificationsStatus: SetupStatus {
        let title = String(localized: "Notifications")
        #if HERMES_PUSH
        let push = PushCenter.shared
        let docs = HermesDocs.page("user-guide/features/plugins")
        if push.isDenied {
            return SetupStatus(
                id: Self.notificationsID, state: .notSetUp, title: title,
                detail: String(localized: "Notifications are off for Hermes, so it can't reach you when it needs an answer."),
                fix: .openSettings
            )
        }
        if !push.canNotify {
            return SetupStatus(
                id: Self.notificationsID, state: .notSetUp, title: title,
                detail: String(localized: "Hermes can't notify you yet."),
                fix: SetupFix(title: String(localized: "Turn On Notifications"))
            )
        }
        #if os(iOS)
        let gateway = workspace?.bot.name ?? ""
        switch workspace.flatMap({ push.gatewayStates[$0.id] }) {
        case .on(let relay?)?:
            return SetupStatus(
                id: Self.notificationsID, state: .limited, title: title,
                detail: String(localized: "The relay isn't answering: \(relay)"),
                fallback: String(localized: "Hermes reaches you while the app is open.")
            )
        case .on(nil)?:
            if let partial = pluginGap(.push, title: title, id: Self.notificationsID) { return partial }
            return SetupStatus(id: Self.notificationsID, state: .ready, title: title, detail: String(localized: "On for \(gateway)"))
        case .notInstalled?:
            return SetupStatus(
                id: Self.notificationsID, state: .notSetUp, title: title,
                detail: String(localized: "\(gateway) needs the Hermes app plugin to reach this iPhone when the app is closed."),
                fallback: String(localized: "Hermes reaches you while the app is open."),
                fix: SetupFix(title: String(localized: "Set Up…")),
                steps: [
                    SetupStep(String(localized: "Or on \(gateway):"), command: "hermes plugins install vburojevic/hermes-app-push --enable"),
                    .restartGateway,
                ],
                docs: docs
            )
        case .needsBackend?:
            return SetupStatus(
                id: Self.notificationsID, state: .notSetUp, title: title,
                detail: String(localized: "Needs Bot Mode, so Hermes can reach the app's plugin."),
                fallback: String(localized: "Hermes reaches you while the app is open."),
                fix: .linkBotMode,
                docs: GatewaySetup.Docs.botMode
            )
        case .notRegistered(let reason)?:
            return SetupStatus(
                id: Self.notificationsID, state: .notSetUp, title: title,
                detail: reason,
                fallback: String(localized: "Hermes reaches you while the app is open.")
            )
        case .failed(let message)?:
            return .unknown(id: Self.notificationsID, title: title, reason: message)
        case .offline?:
            return .unknown(id: Self.notificationsID, title: title, reason: String(localized: "Can't reach \(gateway) to ask."))
        case .checking?, .unknown?, nil:
            return .checking(id: Self.notificationsID, title: title)
        }
        #else
        return SetupStatus(id: Self.notificationsID, state: .ready, title: title, detail: String(localized: "This Mac notifies you while Hermes is open."))
        #endif
        #else
        return SetupStatus(id: Self.notificationsID, state: .unknown, title: title, detail: String(localized: "This build has no notifications."))
        #endif
    }

    var widgetsStatus: SetupStatus {
        let title = String(localized: "Widgets")
        guard let workspace else { return .checking(id: Self.widgetsID, title: title) }
        if workspace.widgets.isAvailable {
            if let partial = pluginGap(.widgets, title: title, id: Self.widgetsID) { return partial }
            return SetupStatus(id: Self.widgetsID, state: .ready, title: title, detail: String(localized: "Hermes can send cards the app draws."))
        }
        guard workspace.connection.isOnline else {
            return .unknown(id: Self.widgetsID, title: title, reason: String(localized: "Can't reach \(workspace.bot.name) to ask."))
        }
        return SetupStatus(
            id: Self.widgetsID, state: .limited, title: title,
            detail: String(localized: "\(workspace.bot.name) doesn't have the Hermes app's widgets plugin."),
            fallback: String(localized: "Hermes sends lists, numbers and choices as text."),
            fix: workspace.roster?.isConnected == true ? SetupFix(title: String(localized: "Install…")) : nil,
            steps: [SetupStep(String(localized: "Or on \(workspace.bot.name):"), command: "hermes plugins install vburojevic/hermes-app-widgets --enable")],
            docs: HermesDocs.page("user-guide/features/plugins")
        )
    }

    /// What's left when a plugin works for the gateway itself but not everywhere: missing or older
    /// in some Bots, turned off, or a restart to finish (`AppPluginStatus`, the plugins page's
    /// words). Nil when it's current everywhere or Bot Mode can't tell.
    private func pluginGap(_ plugin: AppPlugin, title: String, id: String) -> SetupStatus? {
        guard let model = workspace?.plugins else { return nil }
        let status = model.status(for: plugin)
        switch status {
        case .restartPending:
            return SetupStatus(
                id: id, state: .limited, title: title,
                detail: AppPluginsModel.line(for: status, title: model.title(of:)),
                steps: [SetupStep(String(localized: "Restart it from Apps and Tools → Plugins → \(plugin.words.title), or on \(model.gatewayName):"), command: "hermes gateway restart")],
                docs: HermesDocs.page("user-guide/features/plugins")
            )
        case .missing, .outdated, .off:
            // An update that adds access waits for the person's yes (`docs/plugins.md` §7).
            let held = model.heldUpdates[plugin] != nil
            return SetupStatus(
                id: id, state: .limited, title: title,
                detail: held ? String(localized: "An update asks for more access. It waits until you allow it.")
                    : AppPluginsModel.line(for: status, title: model.title(of:)),
                fallback: plugin == .push
                    ? String(localized: "Where it's on, Hermes still reaches you.")
                    : String(localized: "Where it's missing, Hermes sends lists and choices as text."),
                docs: HermesDocs.page("user-guide/features/plugins")
            )
        case .needsBotMode, .offline, .checking, .current, .failed:
            return nil
        }
    }

    // MARK: Checking

    @ObservationIgnored private var checking: Task<Void, Never>?
    /// Reads not back yet: a status that depends on one says Checking… rather than Can't check.
    private(set) var pending: Set<Read> = []

    enum Read: Hashable {
        case status, config, update, board, memory, curator, setup, groups, widgets, models, jobs, plugins, host, vault
    }

    /// Statuses that wait on each read while it's out.
    private static let waiting: [Read: Set<String>] = [
        .status: [GatewaySetup.ID.hermes, GatewaySetup.ID.tasks, GatewaySetup.ID.search, GatewaySetup.ID.board],
        .config: [GatewaySetup.ID.checkpoints, GatewaySetup.ID.groupChats, GatewaySetup.ID.browser],
        .update: [GatewaySetup.ID.hermes],
        .host: [GatewaySetup.ID.priority],
        .board: [GatewaySetup.ID.board],
        .memory: [GatewaySetup.ID.memory],
        .vault: [GatewaySetup.ID.passwords],
        .curator: [GatewaySetup.ID.learned],
        .setup: [GatewaySetup.ID.models],
        .groups: [GatewaySetup.ID.groupChats],
        .widgets: [SetupCenter.widgetsID],
        .models: [GatewaySetup.ID.models],
        .jobs: [GatewaySetup.ID.tasks],
        .plugins: [SetupCenter.notificationsID, SetupCenter.widgetsID],
    ]

    /// The first check is done: from then on a check keeps showing what the last one found.
    private(set) var hasChecked = false

    /// A status as the page shows it: Checking… while a read it needs is out, the first time
    /// round, or when the last check couldn't tell.
    func shown(_ status: SetupStatus) -> SetupStatus {
        guard !hasChecked || status.state == .unknown,
              pending.contains(where: { Self.waiting[$0]?.contains(status.id) == true }) else { return status }
        return .checking(id: status.id, title: status.title)
    }

    /// Reads everything the page shows. Free to run: no model calls, and Hermes caches its update
    /// check for a day. One check at a time, and it carries on if the view that started it goes
    /// (Settings' row starts it, the page joins it).
    func check() async {
        let connected = workspace?.roster?.isConnected == true
        if let checking {
            await checking.value
            // Joined: unless Bot Mode connected or dropped meanwhile, that check read what this
            // one would.
            if checkedConnected == connected { return }
        }
        checkedConnected = connected
        let task = Task { await runCheck() }
        checking = task
        await task.value
        if checking == task { checking = nil }
    }

    /// Whether Bot Mode was connected when the last check started.
    @ObservationIgnored private var checkedConnected = false

    /// Each read lands as it comes back, so one slow answer (a busy dashboard) holds up only the
    /// statuses that need it; none waits more than 20 s.
    private func runCheck() async {
        guard let workspace else { return }
        isChecking = true
        defer { isChecking = false }
        // Notification permission comes from PushCenter, which reads it whenever the app comes to
        // the front; awaiting the system for it here could hang the check (it did on a simulator).
        DeviceSetup.shared.refresh()
        let profile = workspace.bot.profileName
        let roster = workspace.roster?.isConnected == true ? workspace.roster : nil
        pending = roster == nil ? [.models, .jobs] : Set(Self.waiting.keys)
        let gateway = workspace.client
        var reads: [Task<Void, Never>] = [
            Task { await self.read(.models) { await workspace.loadModelOptions() } },
            Task {
                // Active tasks whose last run didn't work or whose results didn't arrive.
                let jobs = await self.read(.jobs) { try? await gateway?.jobs() } ?? []
                self.reads.taskProblems = jobs.filter { !$0.isPaused && ($0.hasFailed || $0.deliveryFailed || $0.missedRun) }
            },
        ]
        if let roster {
            let client = roster.backendClient
            reads += [
                Task {
                    let status = await self.read(.status) { try? await client.status() }
                    self.reads.version = status?.version
                    self.reads.gatewayRunning = status?.gatewayRunning
                    self.reads.searchIndexRebuilding = status?.searchIndexRebuilding ?? false
                },
                Task { self.reads.config = await self.read(.config) { try? await client.config(profile: profile) } },
                Task { self.reads.update = await self.read(.update) { try? await client.hermesUpdateCheck() } },
                Task { self.reads.board = await self.read(.board) { try? await client.boardAvailability() } },
                Task { self.reads.memory = await self.read(.memory) { try? await client.memoryStatus(profile: profile) } },
                Task { self.reads.curator = await self.read(.curator) { try? await client.curatorStatus(profile: profile) } },
                Task {
                    // Passwords (`docs/web.md` §3): an older Hermes answers "unknown method".
                    let sources: Result<[VaultSource], any Error>? = await self.read(.vault) {
                        do {
                            return .success(try await VaultClient(profile: profile) { method, params in
                                try await roster.request(method, params, timeout: .seconds(20))
                            }.sources())
                        } catch {
                            return .failure(error)
                        }
                    }
                    switch sources {
                    case .success(let sources)?:
                        self.reads.vaultSources = sources
                        self.reads.vaultMissing = false
                    case .failure(let error)?:
                        self.reads.vaultSources = nil
                        self.reads.vaultMissing = HermesVersionGap.isMissing(error)
                    case nil:
                        self.reads.vaultSources = nil
                    }
                },
                Task {
                    let setup = await self.read(.setup) {
                        try? await roster.request("setup.status", profile.map { ["profile": .string($0)] } ?? [:], timeout: .seconds(20))
                    }
                    self.reads.providerConfigured = setup?["provider_configured"]?.boolValue
                },
                Task {
                    let groups = await self.read(.groups) { try? await roster.request("groups.capabilities", timeout: .seconds(20)) }
                    self.reads.groupDriver = groups.map { $0["driver"]?.boolValue ?? false }
                },
                Task { await self.read(.widgets) { await workspace.widgets.checkSupport(client: workspace.client, roster: roster) } },
                // The app's plugins in every profile (`docs/plugins.md` §2).
                Task { await self.read(.plugins) { await workspace.plugins.check() } },
                Task { self.land(await self.read(.host) { await self.readHostPriority(roster: roster) }) },
            ]
        }
        // Voice keeps its own statuses (`docs/voice.md` §6.1), Can't check without Bot Mode.
        reads.append(Task { await workspace.voiceSetup.checkSetup() })
        for read in reads { await read.value }
        pending = []
        hasChecked = true
    }

    /// One read, cancelled after 20 s (its `try?` answers nil then), and taken off `pending`
    /// when it's back.
    private func read<Value: Sendable>(_ which: Read, _ work: @escaping @MainActor () async -> Value) async -> Value {
        let started = ContinuousClock.now
        let task = Task { await work() }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            task.cancel()
        }
        let value = await task.value
        timeout.cancel()
        pending.remove(which)
        Self.logger.debug("setup read \(String(describing: which), privacy: .public) took \(String(describing: ContinuousClock.now - started), privacy: .public)")
        return value
    }

    /// A host read is back. Seeing the gateway at full priority again puts the Mac's notice back
    /// in play for the next time something resets it.
    private func land(_ host: (priority: GatewaySetupFacts.HostPriority, isThisMac: Bool)) {
        reads.hostPriority = host.priority
        reads.hostIsThisMac = host.isThisMac
        priorityCheckedAt = .now
        if case .report(let report) = host.priority, report.throttledGateway == nil, priorityNoticeDismissed {
            priorityNoticeDismissed = false
            UserDefaults.standard.removeObject(forKey: Self.noticeKey(workspace?.bot.id))
        }
    }

    /// How the gateway's Mac schedules Hermes (`docs/setup.md` §4.17): the push plugin's
    /// `/app-push host`. On the Mac, a gateway on this Mac is read here when the plugin is older.
    private func readHostPriority(roster: BotRoster) async -> (priority: GatewaySetupFacts.HostPriority, isThisMac: Bool) {
        let push = AppPushClient(transport: { try await roster.request($0, $1, timeout: .seconds(20)) })
        var priority: GatewaySetupFacts.HostPriority
        do {
            priority = .report(try await push.host())
        } catch AppPushClient.Failure.notInstalled {
            priority = .noPlugin
        } catch AppPushClient.Failure.refused(let reason) where reason.contains("unknown command") {
            priority = .pluginTooOld
        } catch {
            priority = .failed
        }
        #if os(macOS)
        if case .report(let report) = priority, let id = report.machineID {
            return (priority, id == LocalLaunchJobs.machineID)
        }
        guard let host = workspace?.bot.baseURL.host(),
              await Task.detached(operation: { LocalLaunchJobs.isThisMac(host: host) }).value
        else { return (priority, false) }
        if case .report = priority { return (priority, true) }
        return (.report(await Task.detached(operation: { LocalLaunchJobs.report() }).value), true)
        #else
        return (priority, false)
        #endif
    }

    // MARK: Priority beyond Setup (`docs/setup.md` §4.17)

    /// The Mac's notice beside Settings: the gateway runs at background priority, until it's set
    /// back or the person says Not Now. Nil on other devices.
    var priorityNotice: PriorityNotice? {
        #if os(macOS)
        priorityNoticeDismissed ? nil : GatewaySetup.priorityNotice(facts)
        #else
        nil
        #endif
    }

    /// Not Now: the notice stays away until the gateway is seen at full priority again.
    func dismissPriorityNotice() {
        priorityNoticeDismissed = true
        UserDefaults.standard.set(true, forKey: Self.noticeKey(workspace?.bot.id))
    }

    private static func noticeKey(_ gatewayID: UUID?) -> String {
        "setup.priorityNoticeDismissed.\(gatewayID?.uuidString ?? "")"
    }

    /// Bot Mode came online: on the Mac, read how the gateway's Mac runs Hermes, at most hourly,
    /// so the notice doesn't wait for Settings. One plugin command, no model calls.
    func connected() {
        #if os(macOS)
        guard priorityRead == nil, priorityCheckedAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true,
              let roster = workspace?.roster, roster.isConnected else { return }
        priorityRead = Task { [weak self] in
            guard let self else { return }
            land(await read(.host) { await self.readHostPriority(roster: roster) })
            priorityRead = nil
        }
        #endif
    }

    /// After an update or restart the app ran: Hermes wrote the gateway's plist again on the way,
    /// so read how its Mac runs it once Bot Mode is back, for up to two minutes while the dashboard
    /// restarts. The run's result then says what came of it.
    private func readPriority(after ref: GatewayJob.Ref) {
        priorityRead?.cancel()
        priorityRead = Task { [weak self] in
            for attempt in 0..<12 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(10)) }
                guard let self, !Task.isCancelled else { return }
                guard let roster = workspace?.roster, roster.isConnected else { continue }
                let host = await read(.host) { await self.readHostPriority(roster: roster) }
                guard !Task.isCancelled else { return }
                guard case .report = host.priority else { continue }
                land(host)
                priorityReadAfter.insert(ref)
                break
            }
            self?.priorityRead = nil
        }
    }

    private static func gatewayThrottled(_ priority: GatewaySetupFacts.HostPriority?) -> Bool {
        if case .report(let report)? = priority { return report.throttledGateway != nil }
        return false
    }

    // MARK: Fixes (each only on the person's tap)

    var client: BackendClient? { workspace?.roster?.backendClient }
    private var profile: String? { workspace?.bot.profileName }

    /// Undo for Files: `checkpoints.enabled` (`docs/checkpoints.md`).
    func turnOnCheckpoints() async {
        await fix { try await $0.setCheckpointsEnabled(true, profile: self.profile) }
    }

    /// The Board: `kanban` out of `plugins.disabled`.
    func turnOnBoard() async {
        await fix { try await $0.enableBoard() }
    }

    /// Tidying: `curator.enabled`, or out of pause.
    func turnOnTidying() async {
        let paused = reads.curator?.enabled == true && reads.curator?.paused == true
        await fix { client in
            if paused {
                try await client.setCuratorPaused(false, profile: self.profile)
            } else {
                try await client.updateConfig(.object(["curator": .object(["enabled": .bool(true)])]), profile: self.profile)
            }
        }
    }

    /// Group chats: `dashboard.turn_isolation` off. The person confirms first: isolation keeps
    /// a busy dashboard answering.
    func turnOffTurnIsolation() async {
        await fix { try await $0.updateConfig(.object(["dashboard": .object(["turn_isolation": .bool(false)])]), profile: self.profile) }
    }

    #if os(macOS)
    /// Run at Full Priority is restarting Hermes's services on this Mac.
    private(set) var isRaisingPriority = false

    /// Run at Full Priority (`docs/setup.md` §4.17): Hermes's throttled jobs on this Mac get
    /// `ProcessType Interactive` and are reloaded. The person confirms first: replies in progress
    /// stop, and Bot Mode reconnects by itself.
    func runAtFullPriority() {
        guard !isRaisingPriority, reads.hostIsThisMac, case .report(let report)? = reads.hostPriority else { return }
        let jobs = report.throttled
        isRaisingPriority = true
        Task {
            let failed = await Task.detached { LocalLaunchJobs.runAtFullPriority(jobs) }.value
            isRaisingPriority = false
            if !failed.isEmpty {
                fixError = String(localized: "launchd didn't start \(failed.joined(separator: ", ")) again. Check Again in a minute, or use the steps on this page in Terminal.")
            }
            await check()
        }
    }
    #endif

    // MARK: Long jobs: updating Hermes, restarting the gateway

    @ObservationIgnored private var updating: Task<Void, Never>?
    @ObservationIgnored private var restarting: Task<Void, Never>?

    static let needsBotModeToUpdate = String(localized: "Bot Mode isn't connected, so the app can't update Hermes.")
    static let needsBotModeToRestart = String(localized: "Bot Mode isn't connected, so the app can't restart the gateway.")

    var isUpdatingHermes: Bool {
        switch updateRun {
        case .starting?, .running?: true
        default: false
        }
    }

    /// A run as the page and the chat card show it: the current one live, earlier ones as they
    /// ended.
    func job(_ ref: GatewayJob.Ref) -> GatewayJob? {
        guard currentJobs[ref.kind] == ref else { return pastJobs[ref] }
        return currentJob(ref.kind)
    }

    func currentJob(_ kind: GatewayJob.Kind) -> GatewayJob? {
        let name = workspace?.bot.name ?? ""
        let started = jobStarts[kind] ?? .now
        var job = switch kind {
        case .update: updateRun.map { GatewayJob.update($0, log: updateLog, started: started, gatewayName: name) }
        case .restart: restartRun.map { GatewayJob.restart($0, log: restartLog, started: started, gatewayName: name) }
        }
        // Live: Run at Full Priority, or the same fix in Terminal, takes it away again.
        if let ref = currentJobs[kind], priorityReadAfter.contains(ref) {
            job?.priorityReset = GatewaySetup.priorityReset(facts, after: kind, wasThrottled: throttledBefore[ref] ?? false)
        }
        return job
    }

    /// Numbers a new run of `kind`, keeping the one before as it ended.
    private func beginJob(_ kind: GatewayJob.Kind) -> GatewayJob.Ref {
        if let previous = currentJobs[kind], let ended = currentJob(kind) {
            pastJobs[previous] = ended
        }
        let ref = GatewayJob.Ref(kind: kind, number: (currentJobs[kind]?.number ?? 0) + 1)
        currentJobs[kind] = ref
        jobStarts[kind] = .now
        throttledBefore[ref] = Self.gatewayThrottled(reads.hostPriority)
        return ref
    }

    /// The dashboard restarts during an update, so polls fail for a while; this long without an
    /// answer, the app stops following it.
    private static let lostTouchAfter = Duration.seconds(600)
    /// Not running and no exit code: right after a restart Hermes's record of the run can lag.
    private static let unknownAfter = Duration.seconds(90)
    /// The dashboard reads the log on each poll, as Hermes's own dashboard does every 1.5 s;
    /// Telegram gets new lines every 4 s.
    private static let pollEvery = Duration.seconds(2)

    /// Updates Hermes Agent on the gateway (`docs/setup.md` §4.2), then follows it and its lines
    /// until it's done. From Settings the person confirms first; /update is the confirmation in a
    /// chat. An update already running is the one returned. Nil without Bot Mode.
    @discardableResult
    func updateHermes() -> GatewayJob.Ref? {
        if updating != nil { return currentJobs[.update] }
        guard let client else { return nil }
        let ref = beginJob(.update)
        updateRun = .starting
        updateLog = ActionLog()
        updating = Task { [weak self] in
            await self?.runUpdate(client, ref: ref)
            self?.updating = nil
        }
        return ref
    }

    private func runUpdate(_ client: BackendClient, ref: GatewayJob.Ref) async {
        let actionID: String?
        do {
            switch try await client.startHermesUpdate() {
            case .refused(let message, let command):
                updateRun = .refused(message: message, command: command)
                return
            case .started(let id):
                actionID = id
            }
        } catch {
            Self.logger.error("hermes update failed to start: \(String(describing: type(of: error)), privacy: .public)")
            updateRun = .couldNotStart(message: error.localizedDescription)
            return
        }
        updateRun = .running
        var lastAnswer = ContinuousClock.now
        var unknownSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollEvery)
            if Task.isCancelled { return }
            // Bot Mode signs in again after the restart, with a new client.
            guard let current = self.client, let status = try? await current.hermesUpdateStatus() else {
                if lastAnswer.duration(to: .now) > Self.lostTouchAfter {
                    updateRun = .lostTouch
                    return
                }
                continue
            }
            lastAnswer = .now
            updateLog.merge(tail: status.lines, name: "hermes-update", actionID: actionID)
            switch status.outcome(actionID: actionID) {
            case nil:
                unknownSince = nil
            case .unknown?:
                let since = unknownSince ?? .now
                unknownSince = since
                if since.duration(to: .now) > Self.unknownAfter {
                    updateRun = .finished(.unknown)
                    readPriority(after: ref)
                    return
                }
            case let outcome?:
                updateRun = .finished(outcome)
                await check()
                // Hermes restarted on the way unless the update stopped before it.
                if case .failed = outcome {} else { readPriority(after: ref) }
                return
            }
        }
    }

    /// Restarts the gateway (`hermes gateway restart`, which lets running chats and tasks
    /// finish first), then follows its lines until it's back. A restart already running is the
    /// one returned. Nil without Bot Mode.
    @discardableResult
    func restartGateway() -> GatewayJob.Ref? {
        if restarting != nil { return currentJobs[.restart] }
        guard let client else { return nil }
        let ref = beginJob(.restart)
        restartRun = .starting
        restartLog = ActionLog()
        restarting = Task { [weak self] in
            await self?.runRestart(client, ref: ref)
            self?.restarting = nil
        }
        return ref
    }

    private func runRestart(_ client: BackendClient, ref: GatewayJob.Ref) async {
        do {
            try await client.restartGateway()
        } catch {
            Self.logger.error("gateway restart failed to start: \(String(describing: type(of: error)), privacy: .public)")
            restartRun = .couldNotStart(message: error.localizedDescription)
            return
        }
        restartRun = .running
        var lastAnswer = ContinuousClock.now
        var unknownSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollEvery)
            if Task.isCancelled { return }
            guard let current = self.client, let status = try? await current.actionStatus("gateway-restart", lines: 300) else {
                if lastAnswer.duration(to: .now) > Self.lostTouchAfter {
                    restartRun = .lostTouch
                    return
                }
                continue
            }
            lastAnswer = .now
            restartLog.merge(tail: status.lines, name: "gateway-restart")
            guard !status.running else { continue }
            switch status.exitCode {
            case 0?:
                restartRun = .succeeded
                await check()
                readPriority(after: ref)
                return
            case let code?:
                restartRun = .failed(exitCode: code)
                return
            case nil:
                // Not running and no exit code: the dashboard restarted and forgot the run.
                let since = unknownSince ?? .now
                unknownSince = since
                if since.duration(to: .now) > Self.unknownAfter {
                    restartRun = .lostTouch
                    return
                }
            }
        }
    }

    func tearDown() {
        updating?.cancel()
        updating = nil
        restarting?.cancel()
        restarting = nil
        priorityRead?.cancel()
        priorityRead = nil
        checking?.cancel()
    }

    private func fix(_ change: @escaping (BackendClient) async throws -> Void) async {
        guard let client else {
            fixError = String(localized: "Bot Mode isn't connected, so the app can't change this setting.")
            return
        }
        do {
            try await change(client)
        } catch {
            Self.logger.error("setup fix failed: \(String(describing: type(of: error)), privacy: .public)")
            fixError = error.localizedDescription
        }
        await check()
    }
}
