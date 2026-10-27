import Foundation
import HermesKit
import Network
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Bot Mode for one gateway: the roster of Bots on its Hermes backend (`hermes serve`),
/// their Bot Chats, looks and routines — Hermes Desktop's Bots pane, natively.
///
/// One gateway socket (`/api/ws`) serves every Bot; requests pick the Bot with `profile`.
@MainActor
@Observable
final class BotRoster {
    enum State: Equatable {
        case idle
        case connecting
        case online(version: String?)
        /// The backend needs a (fresh) token or password sign-in.
        case signInRequired(String?)
        case failed(String)

        var isOnline: Bool {
            if case .online = self { true } else { false }
        }

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }
    }

    private(set) var link: BackendLink
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            ConnectionLog.logger.notice("bots: \(String(describing: self.state), privacy: .public)")
            if state.isOnline { resumeConnectedWaiters() }
        }
    }
    /// Every Bot as `profiles.list` reports it.
    private(set) var profiles: [BotProfile] = []
    /// Pinned first, then most recently active or created. Rebuilt only when the roster changes.
    private(set) var visibleBots: [BotProfile] = []
    private(set) var hiddenBots: [BotProfile] = [] {
        // Hidden or shown again: a hidden Bot's news leaves the badge, a shown one's comes back.
        didSet { if hiddenBots.map(\.name) != oldValue.map(\.name) { workspace?.unread.update() } }
    }
    private(set) var hasLoaded = false
    /// Bots with activity the person hasn't seen (keyed by profile name).
    private(set) var unread: Set<String> = [] {
        didSet { if unread != oldValue { workspace?.unread.update() } }
    }
    /// Bots marked unread by hand (here or on another device): a dot, not a count, until opened.
    private(set) var markedUnread: Set<String> = [] {
        didSet { if markedUnread != oldValue { workspace?.unread.update() } }
    }
    /// Wrote in the last 90 s, or a worker beat in the last 150 s (refreshed every poll).
    private(set) var activeNames: Set<String> = []
    /// A background worker of theirs beat in the last 150 s.
    private(set) var workingNames: Set<String> = []
    /// Bots answering another Bot where no events reach the app (`ElsewhereTurn`, `docs/chat.md`
    /// a turn going on elsewhere): Hermes runs that turn in a one-shot `hermes -p <bot> chat`, which
    /// `session.active_list` doesn't list. Read from the Bot Chat's last rows when it moves.
    private(set) var runningElsewhere: [String: ElsewhereTurn] = [:] {
        didSet { if runningElsewhere != oldValue { workspace?.activity.elsewhereChanged() } }
    }
    /// Each Bot Chat as last read for `runningElsewhere` (id, count, last activity).
    @ObservationIgnored private var elsewhereTips: [String: String] = [:]
    @ObservationIgnored private var elsewhereReads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var elsewhereRecheck: Task<Void, Never>?
    /// Where the roster lost track of a Bot Chat's last turn (`BotTurnBook`, in memory). Where one
    /// settled is the chat's own record on the device (`KeptTurn.stoppedAt`), which the roster reads
    /// for every Bot and writes when it settles a turn no chat followed (`recoverOwnTurn`). The row,
    /// its tile, its face and every working line follow both (`docs/bots-groups-skills.md` §1.2).
    @ObservationIgnored private var turnBook = BotTurnBook()
    @ObservationIgnored private let keptTurns = KeptTurns()
    @ObservationIgnored private var ownTurnRecoveries: [String: Task<Void, Never>] = [:]
    /// Bots shown working for their own turn stopping mid-work (`recoverOwnTurn`): each roster read
    /// looks at them again, so a turn that died while the socket was down settles as soon as it's back,
    /// not at the next 30 s re-read.
    @ObservationIgnored private var ownTurns: Set<String> = []
    /// Photo avatars, as `FaceImageCache` keys, by profile name.
    private(set) var photos: [String: String] = [:]
    /// The Bot Chat on screen, which never counts as unread.
    /// The Bot Chat on screen. Opening it isn't reading it: the chat marks it read once its newest
    /// message has been on screen (`TranscriptView`, `docs/inbox.md` §4).
    var openBot: String?

    /// Sheets, shared by the sidebar and the chat toolbar.
    var editingBot: String?
    var routinesBot: String?
    /// The routine Routines opens on (a delivery's name tapped in a chat), by its title.
    var routinesFocus: String?
    var isCreatingBot = false

    @ObservationIgnored let botID: UUID
    @ObservationIgnored private let store: BotStore
    @ObservationIgnored private var client: BackendClient
    /// The backend's REST client, for the audio routes (`docs/voice.md` §10).
    var backendClient: BackendClient { client }
    // Observed: `isConnected` reads it.
    private var socket: GatewaySocket?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var conversations: [String: ConversationModel] = [:]
    /// Normal chats running over this socket (every chat does while it's connected), held
    /// weakly by the workspace that owns them; routed like Bot Chats.
    @ObservationIgnored private var gatewayChats: [ObjectIdentifier: WeakConversation] = [:]

    private struct WeakConversation {
        weak var value: ConversationModel?
    }

    /// Lets a normal chat receive its events and requests from this socket.
    func attach(_ conversation: ConversationModel) {
        gatewayChats = gatewayChats.filter { $0.value.value != nil }
        gatewayChats[ObjectIdentifier(conversation)] = WeakConversation(value: conversation)
    }

    /// A Bot Chat or attached chat by its id.
    func loadedConversation(id: UUID) -> ConversationModel? {
        allConversations.first { $0.id == id }
    }

    /// Every chat this socket serves: the Bot Chats and the attached normal chats.
    private var allConversations: [ConversationModel] {
        Array(conversations.values) + gatewayChats.values.compactMap(\.value)
    }
    @ObservationIgnored private var photoRevisions: [String: Int] = [:]
    @ObservationIgnored private var photoTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var index: [String: BotProfile] = [:]
    @ObservationIgnored private var watermarks: [String: Double]
    /// The Bot Chat's read mark on the server (`last_read_at`, shared by every device), by profile
    /// name: as last fetched, or as far as this device's own mark is known to reach.
    @ObservationIgnored private var serverRead: [String: Double] = [:]
    /// When to ask again about the Bots' read marks (shared with the chats, `UnreadStore`).
    @ObservationIgnored private lazy var readRecheck = ReadRecheck { [weak self] now in self?.checkReadElsewhere(now: now) }
    /// Read Bots whose mark was last asked about, for Mark as Unread on another device.
    @ObservationIgnored private var readBotsCheckedAt = Date.distantPast
    /// The roster read again soon after Hermes' sessions moved (`rosterMayHaveMoved`).
    @ObservationIgnored private var rosterRecheck: Task<Void, Never>?
    @ObservationIgnored private var sessionsTick: Task<Void, Never>?
    @ObservationIgnored private var sessionsTickedAt = Date.distantPast
    @ObservationIgnored private var rosterRecheckedAt = Date.distantPast
    @ObservationIgnored private var sharingRead: Set<String> = []
    @ObservationIgnored private var readThrottle = ReadThrottle()
    @ObservationIgnored private var trailingRead: [String: Task<Void, Never>] = [:]
    #if os(macOS)
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    #endif
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var connectedAt: Date?
    /// When a working connection dropped: the first moments after that are "Reconnecting…", not "offline".
    @ObservationIgnored private var droppedAt: Date?
    @ObservationIgnored private var version: String?
    /// Reads the version alongside a connect, never in its way (`readVersion`).
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    /// The backend run (`gateway.ready`'s `replay_epoch`) the version was read from.
    @ObservationIgnored private var versionEpoch: String?
    /// The `profiles.list` rows last kept on the device (`RosterCache`).
    @ObservationIgnored private var cachedRows: [JSONValue] = []
    /// The backend is there but slow (`BackendClient.isSlowAnswer`) while its machine's gateway
    /// answers: the Bots stay as they were and the status says the Mac is busy, not offline.
    private(set) var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            ConnectionLog.logger.notice("bots: \(self.isBusy ? "busy" : "no longer busy", privacy: .public)")
        }
    }
    /// The last sign the backend was busy: a quick roster read clears "busy" only half a minute
    /// after it (a starved Mac answers quickly for the moment it runs, then goes quiet again).
    @ObservationIgnored private var lastSlowAt = Date.distantPast
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var isTornDown = false
    /// The app is in the background: no polling, no reconnect loop.
    @ObservationIgnored private var isInBackground = false
    /// In the background on iOS, where nothing reconnects until the app is back (or a request
    /// needs the socket). A Mac with its windows closed keeps reconnecting: its socket carries
    /// the notifications.
    private var isAwayOnPhone: Bool {
        #if os(iOS)
        isInBackground
        #else
        false
        #endif
    }
    /// Watches the device's network so a new or returning route reconnects at once.
    @ObservationIgnored private var route: RouteWatcher?
    #if os(iOS)
    /// The app's time in the background, spent keeping the socket open (`didEnterBackground`).
    @ObservationIgnored private let backgroundHold = BackgroundActivity()
    #endif
    @ObservationIgnored private var connectStartedAt: Date?
    /// The socket is gone for a moment and coming back: it died while the app was away, failed
    /// its proof on coming back (`verify`), or closed as the Mac went to sleep. Meanwhile the Bots
    /// still count as connected: nothing on screen says otherwise for a few seconds after coming
    /// back, and what's asked of them waits for the new socket instead of failing (`request`).
    private(set) var isPaused = false
    @ObservationIgnored private var resumeDeadline: Task<Void, Never>?
    /// Requests waiting for the socket to come back from a pause.
    @ObservationIgnored private var socketWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Pins and hides shown before the gateway has them (`saveFlag`), by Bot then key; `.null`
    /// means the flag goes. The token is the call's: a later Pin or Unpin of the same Bot owns it.
    @ObservationIgnored private var pendingFlags: [String: [String: (value: JSONValue, token: UUID)]] = [:]
    /// Messages waiting for the Bots to be connected at all (`untilConnected`).
    @ObservationIgnored private var connectedWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The socket is being proven after the app came back or the route changed (`verify`):
    /// requests wait for the outcome rather than go out on a link that may be dead.
    @ObservationIgnored private var verification: Task<Void, Never>?
    @ObservationIgnored private var verificationGeneration = 0
    /// A replacement socket is connecting alongside one being proven: its failure decides nothing
    /// on its own (`verify` does).
    @ObservationIgnored private var isReplacingSocket = false
    /// After coming back, how long the new socket may take before the app says "Reconnecting…".
    static let resumeWindow: Duration = .seconds(6)
    @ObservationIgnored weak var workspace: BotWorkspace?

    /// The gateway's hosted group chats.
    @ObservationIgnored private(set) lazy var groupRooms = GroupRooms(roster: self)
    /// New Group Chat is showing.
    var isCreatingGroup = false

    init(botID: UUID, link: BackendLink, store: BotStore) {
        self.botID = botID
        self.link = link
        self.store = store
        self.client = Self.makeClient(botID: botID, link: link, store: store)
        watermarks = UserDefaults.standard.dictionary(forKey: Self.watermarkKey(botID)) as? [String: Double] ?? [:]
        #if os(macOS)
        // Coming to the front with a Bot Chat open is reading it (`isInFront`).
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readMayHaveMoved() // read on the phone in the meantime
                // A reconnect waiting out the slower backoff behind other apps goes now.
                if self.reconnectTask != nil { self.retryNow() }
            }
        }
        #endif
        restoreCachedRoster()
    }

    /// The roster this device saw last, shown until the live one arrives: an app iOS ended in the
    /// background opens on its Bots while the socket connects.
    private func restoreCachedRoster() {
        let link = link
        Task { [weak self, botID] in
            guard let rows = await RosterCache.load(botID), let self,
                  !self.hasLoaded, !self.isTornDown, self.link == link else { return }
            self.cachedRows = rows
            self.apply(rows.map(BotProfile.init(json:)).filter { !$0.name.isEmpty })
            LaunchTrace.mark("cached Bots shown (\(rows.count))", id: "cached Bots")
            // Connected when the app last ran: its first moments read "Reconnecting…", like a drop's
            // (`reconnectGrace`), not offline at the first failed try.
            if self.socket == nil, self.droppedAt == nil {
                self.droppedAt = .now
                if self.state.isFailed { self.state = .connecting }
            }
        }
    }

    private static func makeClient(botID: UUID, link: BackendLink, store: BotStore) -> BackendClient {
        BackendClient(baseURL: link.url, credential: store.backendCredential(for: botID)) { credential in
            // The gate refreshes cookies on use; keep the newest pair.
            try? store.setBackendCredential(credential, for: botID)
        }
    }

    private static func watermarkKey(_ id: UUID) -> String { "botWatermarks.\(id.uuidString)" }

    // MARK: - Roster

    /// Pinned first, then by each row's time, then by title (`docs/bots-groups-skills.md` §1.2).
    private func rosterOrder(_ bots: [BotProfile]) -> [BotProfile] {
        let byTitle = bots.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return RowTime.ordered(byTitle, pinned: \.meta.isPinned) { self.rowTime(for: $0) }
    }

    /// A Bot's time on its row, its tile and in the order (`RowTime`): its last line's message,
    /// standing at the Bot Chat's activity only while a turn runs there. A routine's run in a
    /// session of its own, or opening the chat, moves nothing.
    func rowTime(for bot: BotProfile) -> Date? {
        let key = UnreadStore.botKey(bot.name)
        return bot.rowTime(line: workspace?.unread.lastLines[key], live: workspace?.activity.line(for: key)?.isLive == true)
    }

    /// Rows' times moved (a last line was read, a turn started or ended): the roster in order again.
    func reorder() {
        let visible = rosterOrder(profiles.filter { !$0.meta.isHidden })
        let hidden = rosterOrder(profiles.filter(\.meta.isHidden))
        if visible != visibleBots { visibleBots = visible }
        if hidden != hiddenBots { hiddenBots = hidden }
    }

    func bot(named name: String) -> BotProfile? {
        // `index` isn't observed: read `profiles`, which changes with it, so a view that looked a
        // Bot up before the roster arrived (the Bot Chat title) redraws when it does.
        access(keyPath: \.profiles)
        return index[name]
    }

    /// Each Bot's own chat by session id (its first and its newest, and the one open here) to the
    /// Bot: what a notification about it opens (`PushShared.botChats`).
    var botChats: [String: String] {
        var chats: [String: String] = [:]
        for bot in profiles {
            guard let chat = bot.canonicalSession else { continue }
            chats[chat.id] = bot.name
            chats[chat.resolvedID] = bot.name
        }
        for (name, conversation) in conversations {
            if let open = conversation.sessionID { chats[open] = name }
        }
        return chats
    }

    /// The Bot behind a handle (`hermes` is the primary profile).
    func bot(handle: String) -> BotProfile? {
        index[handle] ?? profiles.first { $0.handle == handle }
    }

    func isActive(_ name: String) -> Bool {
        activeNames.contains(name)
    }

    func appearance(for bot: BotProfile) -> BotAppearance {
        BotAppearance(
            profile: bot.name,
            shape: bot.meta.shape,
            color: bot.meta.color,
            image: photos[bot.name],
            customized: bot.meta.isCustom
        )
    }

    /// A turn is streaming in this Bot's chat here.
    /// Bot Chats opened this launch, by profile name.
    var botConversations: [String: ConversationModel] { conversations }

    func chatIsWorking(_ name: String) -> Bool {
        conversations[name]?.isWorking ?? false
    }

    /// What its running turn is doing ("Running a command…"), when one runs here, or the one it
    /// runs answering another Bot ("Answering CORE") or following up on a routine.
    func workingStatus(_ name: String) -> String? {
        if let conversation = conversations[name], conversation.isWorking { return conversation.liveStatus }
        guard let turn = runningElsewhere[name] else { return nil }
        if let tool = turn.runningTool { return ToolDescriptor.describe(tool).activeTitle }
        if let sender = turn.answering { return String(localized: "Answering \(sender)") }
        return turn.routine.map { String(localized: "Following up on \($0)") }
    }

    /// Thinking in its Bot Chat here, answering another Bot elsewhere, or a background worker of
    /// its is beating.
    func isBusy(_ name: String) -> Bool {
        conversations[name]?.isWorking == true || runningElsewhere[name] != nil || workingNames.contains(name)
    }

    /// The face a Bot shows on the grid and in rosters (`docs/bot-faces.md` §3): its chat's turn
    /// (thinking, working), working while a background worker runs, asleep when Bot Mode is
    /// offline or the Bot is hidden.
    func faceMood(for name: String) -> BotMood {
        guard isConnected else { return .sleeping }
        if let mood = conversations[name]?.turnMood, mood != .idle { return mood }
        if runningElsewhere[name] != nil || workingNames.contains(name) { return .working }
        if bot(named: name)?.meta.isHidden == true { return .sleeping }
        return .idle
    }

    // MARK: - Connection

    /// Swaps in a new address or sign-in method.
    func update(link: BackendLink) {
        guard link != self.link else { return }
        self.link = link
        disconnect()
        client = Self.makeClient(botID: botID, link: link, store: store)
        profiles = []
        visibleBots = []
        hiddenBots = []
        index = [:]
        photos = [:]
        photoRevisions = [:]
        hasLoaded = false
        version = nil
        versionEpoch = nil
        cachedRows = []
        turnBook = BotTurnBook()
        RosterCache.remove(botID)
        connectIfNeeded()
    }

    /// - Parameter quietly: a retry in the background: Bots that are offline stay "offline" until
    ///   they're back, rather than flickering to "Connecting…" on every attempt.
    func connectIfNeeded(quietly: Bool = false) {
        guard !isTornDown, socket == nil, connectTask == nil else { return }
        watchNetwork()
        startConnect(quietly: quietly)
    }

    /// Connect now, skipping any backoff wait: the person asked (Retry, Reload), or the
    /// network just came back.
    func retryNow() {
        guard !isTornDown, !isAwayOnPhone, socket == nil else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        if connectTask == nil { startConnect() }
    }

    private func watchNetwork() {
        guard route == nil else { return }
        route = RouteWatcher(label: "hermes.roster.network") { [weak self] cameBack in
            self?.routeChanged(cameBack: cameBack)
        }
    }

    /// Without a socket, connect now rather than after the backoff; with one, prove it still
    /// works: a socket opened over the old route usually dies without a close and would look
    /// healthy until the heartbeat gives up on it.
    private func routeChanged(cameBack: Bool) {
        guard !isTornDown, !isAwayOnPhone else { return }
        reconnectAttempts = 0
        if let socket {
            verify(socket, heardWithin: 0)
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        if let connectStartedAt, connectTask != nil {
            // An attempt in flight keeps going. Only one that started while the network was gone
            // and is still hanging gets replaced.
            guard cameBack, Date.now.timeIntervalSince(connectStartedAt) > 5 else { return }
        }
        startConnect()
    }

    /// One tracked connect at a time; a superseded attempt discards what it opened.
    private func startConnect(quietly: Bool = false) {
        connectTask?.cancel()
        connectStartedAt = .now
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task { [weak self] in
            await self?.connect(generation: generation, quietly: quietly)
            if self?.connectGeneration == generation { self?.connectTask = nil }
        }
    }

    private func connect(generation: Int, quietly: Bool) async {
        reconnectTask?.cancel()
        if !state.isOnline, !(quietly && state.isFailed) { state = .connecting }
        func isCurrent() -> Bool { generation == connectGeneration && !Task.isCancelled && !isTornDown }
        do {
            if await client.credential == nil {
                guard link.signIn == .automatic else {
                    state = .signInRequired(nil)
                    return
                }
                _ = try await client.discoverSessionToken()
            }
            let socket = try await openSocket()
            guard isCurrent() else {
                await socket.close()
                return
            }
            if let previous = self.socket, previous !== socket {
                Task { await previous.close() }
            }
            self.socket = socket
            // Quiet for minutes while the gateway on the same machine answers: the dashboard is
            // frozen, not gone. A new socket would wait on the same loop, so this one is kept, and
            // the status says the Mac is busy rather than a plain "Connected" (the next roster read
            // that comes back clears it).
            await socket.keepOpenWhile { [weak self, weak workspace] in
                let there = await workspace?.gatewayAnswers() ?? false
                if there { await self?.socketStalled(socket) }
                return there
            }
            if let connectStartedAt {
                ConnectionLog.logger.notice("bots: socket open in \(Int(Date.now.timeIntervalSince(connectStartedAt) * 1000))ms\(self.isPaused ? " (after a pause)" : "", privacy: .public)")
            }
            connectedAt = .now
            droppedAt = nil
            state = .online(version: version)
            LaunchTrace.mark("Bot Mode socket open")
            // Even when `state` didn't change (a reconnect from online): what waits goes now.
            resumeConnectedWaiters()
            // Once per backend run: a restart (a new replay epoch) may be a new version.
            let epoch = await socket.replayEpoch
            if version == nil || epoch != versionEpoch { readVersion(generation: generation, epoch: epoch) }
            endPause()
            startPump(socket)
            // The chats first: a reply running in the open one streams again now, not after the
            // roster and the group rooms, which a busy Mac can take minutes over.
            let onScreen = workspace?.currentConversation
            for conversation in allConversations {
                if conversation === onScreen {
                    conversation.botChatReconnected()
                } else {
                    conversation.reconnectedOutOfSight()
                }
            }
            await refresh()
            guard isCurrent() else { return }
            // Away (a request brought the socket back for a notification): no polling until the
            // app is back (`resume`, `didBecomeActive`).
            if !isInBackground {
                startPolling()
                workspace?.projects.connected()
                workspace?.unread.connected()
                workspace?.plugins.connected()
                workspace?.setup.connected()
                groupRooms.connected()
                workspace?.widgets.socketConnected()
            }
            // Bot Mode runs on the gateway's machine: back for one, likely back for the other.
            if let workspace, workspace.connection.isFailed {
                Task { await workspace.connect(quietly: true) }
            }
        } catch is CancellationError {
        } catch {
            guard isCurrent() else { return }
            // Linked to sign in by itself, but the backend has a password: that's a sign-in to
            // choose, not an offline backend (`docs/setup.md` §4.1).
            if link.signIn == .automatic, Self.mayNeedPassword(error), await backendAsksForSignIn() {
                guard isCurrent() else { return }
                endPause()
                state = .signInRequired(String(localized: "Bot Mode on \(workspace?.bot.name ?? "this gateway") asks for a sign-in. Choose Username & password in Edit Gateway."))
                return
            }
            handleConnectFailure(error)
        }
    }

    /// A refusal that a backend with a password gives a client signing in by itself.
    private static func mayNeedPassword(_ error: any Error) -> Bool {
        if let failure = error as? BackendClient.Failure {
            return failure == .tokenNotFound || failure == .signInRequired || failure == .invalidCredentials
        }
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure { return reason.contains("sign-in") }
        return false
    }

    /// `/api/status.auth_required`, which answers before any sign-in.
    private func backendAsksForSignIn() async -> Bool {
        (try? await client.status())?.authRequired == true
    }

    /// Hermes's version, for "Connected · Hermes 0.21.6". `/api/status` is the dashboard's slowest
    /// call on a busy Mac (it asks the gateway, every profile, memory and disk), and a proxy in
    /// front of it gives up after 30 s with a 502: a connect that waited for it came back from the
    /// background to "Reconnecting…" and a Bots screen that never filled. The socket doesn't need
    /// it, so it's read once the socket is open, and shows when it lands.
    private func readVersion(generation: Int, epoch: String?) {
        versionTask?.cancel()
        let client = client
        versionTask = Task { [weak self] in
            guard let status = try? await client.status(), let self, !Task.isCancelled,
                  generation == self.connectGeneration else { return }
            self.version = status.version
            self.versionEpoch = epoch
            if self.state.isOnline { self.state = .online(version: status.version) }
        }
    }

    /// Opens `/api/ws`. A local backend's token changes on restart, so on a refusal the
    /// token is read again once.
    private func openSocket() async throws -> GatewaySocket {
        do {
            let socket = GatewaySocket(url: try await client.gatewaySocketURL())
            try await socket.connect()
            return socket
        } catch {
            guard link.signIn == .automatic, Self.isAuthFailure(error) else { throw error }
            _ = try await client.discoverSessionToken()
            let socket = GatewaySocket(url: try await client.gatewaySocketURL())
            try await socket.connect()
            return socket
        }
    }

    private static func isAuthFailure(_ error: any Error) -> Bool {
        if let failure = error as? BackendClient.Failure, failure == .signInRequired { return true }
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure { return reason.contains("sign-in") }
        if let urlError = error as? URLError, urlError.code == .badServerResponse { return true } // handshake refused
        return false
    }

    private func handleConnectFailure(_ error: any Error) {
        if isReplacingSocket, !Self.needsThePerson(error, link: link) {
            return // the socket being proven may still answer (`verify`)
        }
        if isPaused, !Self.needsThePerson(error, link: link) {
            // Coming back from a pause (or still away): try again soon, still "connected" until the
            // resume window is up (`resumeTookTooLong`).
            scheduleReconnect()
            return
        }
        endPause()
        if let failure = error as? BackendClient.Failure {
            switch failure {
            case .signInRequired, .invalidCredentials:
                if link.signIn != .automatic {
                    state = .signInRequired(failure.errorDescription)
                    return
                }
            case .tokenNotFound, .notHermes:
                state = .failed(failure.errorDescription ?? "")
                return
            default:
                break
            }
        }
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure, reason.contains("sign-in"), link.signIn != .automatic {
            state = .signInRequired(reason)
            return
        }
        // Slow, not gone: a proxy's 502 or a timeout while the gateway on the same machine still
        // answers. The Bots stay listed and the status says the Mac is busy; only after
        // `busyGiveUp` without one answer does it call them offline.
        if BackendClient.isSlowAnswer(error), workspace?.connection.isFailed != true {
            markBusy()
            // A gateway known to be busy too (`BotWorkspace.isBusy`) explains it: the whole Mac is
            // loaded, and the Bots stay "busy" for as long as it is.
            if let busySince, Date.now.timeIntervalSince(busySince) < Self.busyGiveUp || workspace?.isBusy == true {
                if !state.isOnline { state = .connecting }
                scheduleReconnect()
                return
            }
            state = .failed(String(localized: "Your Bots haven't answered for 5 minutes. \(workspace?.bot.name ?? "The Mac") may be overloaded, or hermes serve stopped there."))
            scheduleReconnect()
            return
        }
        // A blip (a tunnel, a Wi-Fi handover, a backend restart) usually heals in seconds: keep
        // saying "Reconnecting…" for a while before calling the Bots offline.
        if hasLoaded, let droppedAt, Date.now.timeIntervalSince(droppedAt) < Self.reconnectGrace {
            state = .connecting
        } else if let blocked = route?.blocked {
            // A setting, not the network: say which.
            state = .failed(HermesError.unreachable(host: link.url.host() ?? "", reason: blocked.reason).errorDescription ?? "")
        } else {
            state = .failed(Self.describe(error))
        }
        scheduleReconnect()
    }

    static let reconnectGrace: TimeInterval = 20
    /// How long a slow backend is called busy before the Bots are called offline.
    static let busyGiveUp: TimeInterval = 300
    /// How long a send waits for its answer on an open socket: as long as the socket waits out a
    /// frozen backend (`GatewaySocket.longestStall`). A socket that dies fails it at once.
    static let patientTimeout: Duration = .seconds(600)

    private func markBusy() {
        if busySince == nil { busySince = .now }
        noteSlow()
    }

    /// The socket has heard nothing for over a minute while the gateway's machine is there.
    private func socketStalled(_ stalled: GatewaySocket) {
        // Busy, without starting `busyGiveUp`'s clock: only a failed connect starts that, and the
        // next roster read that comes back clears both.
        guard socket === stalled else { return }
        noteSlow()
    }

    /// A sign the backend is busy: "busy" from now on, for at least half a minute.
    private func noteSlow() {
        lastSlowAt = .now
        if !isBusy { isBusy = true }
    }

    private func clearBusy() {
        busySince = nil
        if isBusy { isBusy = false }
    }

    /// A refusal no retry fixes: a sign-in, a missing token, not a Hermes backend.
    private static func needsThePerson(_ error: any Error, link: BackendLink) -> Bool {
        if let failure = error as? BackendClient.Failure {
            switch failure {
            case .signInRequired, .invalidCredentials: return link.signIn != .automatic
            case .tokenNotFound, .notHermes: return true
            default: return false
            }
        }
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure {
            return reason.contains("sign-in") && link.signIn != .automatic
        }
        return false
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? HermesError { return error.errorDescription ?? "" }
        if let error = error as? any LocalizedError, let description = error.errorDescription { return description }
        if let error = error as? URLError {
            return HermesError.from(urlError: error, host: "the Hermes backend").errorDescription ?? error.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain || nsError.domain == "kNWErrorDomainPOSIX" {
            // "Socket is not connected", "Connection reset by peer": the network, not Hermes.
            return String(localized: "Can't reach the Hermes backend right now.")
        }
        return error.localizedDescription
    }

    private func scheduleReconnect() {
        guard !isTornDown, !isAwayOnPhone else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        // No route at all: nothing to try until there is one (`routeChanged` connects then).
        guard route?.isUp != false else {
            ConnectionLog.logger.notice("bots: no network, reconnecting when it's back")
            return
        }
        reconnectAttempts += 1
        // 0.5, 1, 2, 4, 8, then every 15 s (60 s while the Mac app is behind other apps; coming to
        // the front reconnects at once), with jitter so devices don't reconnect in lockstep.
        // Coming back from a pause, at most a second apart: the resume window is short.
        let cap: Double = isPaused ? 1 : AppPresence.isInBack ? 60 : 15
        let base = min(cap, 0.5 * pow(2, Double(min(reconnectAttempts - 1, 7))))
        let delay = base * Double.random(in: 0.8...1.2)
        ConnectionLog.logger.notice("bots: reconnect \(self.reconnectAttempts) in \(delay, format: .fixed(precision: 1))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connectIfNeeded(quietly: true)
        }
    }

    /// Pasted token sign-in.
    func signIn(token: String) async throws {
        await client.useSessionToken(token)
        try store.setBackendCredential(.sessionToken(token), for: botID)
        await reconnectNow()
    }

    /// Username and password sign-in (the dashboard's `basic` provider).
    func signIn(username: String, password: String) async throws {
        try await client.signIn(username: username, password: password)
        await reconnectNow()
    }

    func reconnectNow() async {
        disconnect()
        reconnectAttempts = 0
        startConnect()
        await connectTask?.value
    }

    func disconnect() {
        connectGeneration += 1 // any connect in flight is now stale
        #if os(iOS)
        backgroundHold.end()
        #endif
        workspace?.projects.disconnected()
        workspace?.unread.disconnected()
        verificationGeneration += 1
        verification?.cancel()
        verification = nil
        isReplacingSocket = false
        endPause()
        versionTask?.cancel()
        versionTask = nil
        pumpTask?.cancel()
        pollTask?.cancel()
        reconnectTask?.cancel()
        connectTask?.cancel()
        connectTask = nil
        pumpTask = nil
        pollTask = nil
        photoTasks.values.forEach { $0.cancel() }
        photoTasks = [:]
        photoRevisions = [:] // refetch on reconnect
        elsewhereReads.values.forEach { $0.cancel() }
        elsewhereReads = [:]
        elsewhereRecheck?.cancel()
        elsewhereRecheck = nil
        ownTurnRecoveries.values.forEach { $0.cancel() }
        ownTurnRecoveries = [:]
        ownTurns = []
        elsewhereTips = [:] // read again on reconnect
        runningElsewhere = [:]
        if let socket {
            Task { await socket.close() }
            for conversation in allConversations {
                conversation.botChatConnectionLost()
            }
        }
        socket = nil
    }

    func tearDown() {
        isTornDown = true
        #if os(macOS)
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        #endif
        route?.cancel()
        route = nil
        readRecheck.cancel()
        rosterRecheck?.cancel()
        rosterRecheck = nil
        sessionsTick?.cancel()
        sessionsTick = nil
        disconnect()
        resumeConnectedWaiters()
        conversations.values.forEach { $0.cancelAll() }
        for chat in gatewayChats.values.compactMap(\.value) { chat.botChatConnectionLost() }
        gatewayChats = [:]
    }

    /// The gateway is being removed: its Bot Chats' pages close (`AppModel.removeBot`).
    func closeWebViews() {
        for chat in Array(conversations.values) + gatewayChats.values.compactMap(\.value) {
            chat.inspectorIfLoaded?.closeWebViews()
        }
    }

    /// The app went to the background: stop polling and reconnecting until it's back. On iPhone
    /// and iPad the socket stays open for as long as iOS lets the app run, about 30 s: a quick
    /// trip to another app comes back to it as it was, and what arrives meanwhile (a reply still
    /// streaming, a Bot's message) still comes in. When the time is up it closes cleanly (a pause)
    /// and coming back opens a new one at once; either way coming back proves it
    /// (`didBecomeActive`). The time is always given back a few seconds before iOS would take it
    /// (`BackgroundActivity`): held to its end, a busy phone ran the timers late and got the app
    /// ended.
    func didEnterBackground() {
        isInBackground = true
        workspace?.projects.disconnected()
        workspace?.unread.disconnected()
        pollTask?.cancel()
        pollTask = nil
        // A Mac with its windows closed keeps reconnecting (`isAwayOnPhone`).
        if isAwayOnPhone {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        #if os(iOS)
        if socket != nil, state.isOnline, !isTornDown {
            backgroundHold.begin("Hermes connection") { [weak self] in self?.backgroundTimeRanOut() }
            let left = UIApplication.shared.backgroundTimeRemaining
            ConnectionLog.logger.notice("bots: keeping the socket open in the background (\(left < 3600 ? "\(Int(left)) s" : "time not known yet", privacy: .public))")
        }
        #endif
    }

    #if os(iOS)
    /// The background time is nearly up: the socket closes while it still can, cleanly, rather
    /// than dying with the app suspended.
    private func backgroundTimeRanOut() {
        guard isInBackground, !isTornDown, socket != nil else { return }
        ConnectionLog.logger.notice("bots: background time is up")
        pause()
    }
    #endif

    /// Back in the foreground but not on screen (another gateway is): the socket comes back, or
    /// is proven, and polling resumes.
    func resume() {
        guard isInBackground, !isTornDown else { return }
        isInBackground = false
        #if os(iOS)
        backgroundHold.end()
        #endif
        if isPaused {
            resumeFromPause()
        } else if let socket {
            verify(socket, heardWithin: 3) // kept through a short absence: proven, then polled
        } else {
            connectIfNeeded()
        }
    }

    /// Back in the foreground: a paused socket comes back at once; one kept through a short
    /// absence is proven before it's trusted.
    func didBecomeActive() {
        guard !isTornDown else { return }
        let wasAway = isInBackground
        isInBackground = false
        #if os(iOS)
        backgroundHold.end()
        #endif
        reconnectAttempts = 0
        if let openBot { markRead(openBot) } // seen now, on every device
        readMayHaveMoved() // and what was read elsewhere meanwhile is read here
        if isPaused {
            resumeFromPause()
            return
        }
        if let socket {
            // Back from the background: heard from just now, or proven (a suspended app's socket can
            // look open and answer nothing). Only coming to the front on the Mac, which happens
            // all the time: heard within the heartbeat's reach is enough, and probing anyway only
            // risked a false "dead" from a busy backend.
            verify(socket, heardWithin: wasAway ? 3 : 12)
        } else {
            retryNow()
        }
    }

    /// Proves the socket before it's trusted again: heard from within `seconds`, or a ping that
    /// comes back. A healthy link answers in a moment; one that hasn't by `replaceAfter` gets a
    /// new socket connecting alongside, and whichever proves itself first is kept, so a dead link
    /// costs about as long as a connect, not the ping's whole timeout. The Bots read as connected
    /// throughout, and requests made meanwhile wait for the outcome (`request`).
    private func verify(_ socket: GatewaySocket, heardWithin seconds: Double) {
        guard verification == nil else { return }
        verificationGeneration += 1
        let generation = verificationGeneration
        verification = Task { [weak self] in
            guard let self else { return }
            let kept = await self.prove(socket, heardWithin: seconds)
            // Over before anything is asked of the socket: `refresh` waits for no verification,
            // least of all this one. A newer verification (or a disconnect) owns the state now.
            guard self.verificationGeneration == generation else { return }
            self.verification = nil
            self.isReplacingSocket = false
            // Proven: what waited goes now, while the roster catches up.
            if kept, self.socket === socket, !self.isTornDown {
                Task { await self.verified(socket) }
            }
        }
    }

    /// The race behind `verify`. True: the socket answered and stays. False: it was replaced (a
    /// new one won, or it's being replaced quietly) or is gone.
    private func prove(_ socket: GatewaySocket, heardWithin seconds: Double) async -> Bool {
        if await socket.heard(within: seconds) { return true }
        enum Outcome { case ping(Bool), slow, replacementEnded }
        let (outcomes, sink) = AsyncStream<Outcome>.makeStream()
        let ping = Task { sink.yield(.ping(await socket.probe(timeout: Self.verifyTimeout, closesOnFailure: false))) }
        let timer = Task {
            try? await Task.sleep(for: Self.replaceAfter)
            if !Task.isCancelled { sink.yield(.slow) }
        }
        defer {
            ping.cancel()
            timer.cancel()
            sink.finish()
        }
        for await outcome in outcomes {
            // Replaced (the new socket won) or gone: nothing left to prove.
            guard self.socket === socket, !isTornDown else { return false }
            switch outcome {
            case .ping(true):
                if isReplacingSocket {
                    // The old link answered after all: the replacement is dropped.
                    connectGeneration += 1
                    connectTask?.cancel()
                    connectTask = nil
                    isReplacingSocket = false
                }
                return true
            case .slow:
                guard !isReplacingSocket else { continue }
                ConnectionLog.logger.notice("bots: no answer yet; connecting a replacement alongside")
                isReplacingSocket = true
                startConnect(quietly: true)
                let attempt = connectTask
                Task {
                    await attempt?.value
                    sink.yield(.replacementEnded)
                }
            case .ping(false):
                // Dead. A replacement already connecting carries on as the new socket's connect.
                ConnectionLog.logger.notice("bots: the socket didn't answer; replacing it")
                isReplacingSocket = false
                replaceSocket()
                return false
            case .replacementEnded:
                // It failed (one that connected took the old socket's place: caught above). The
                // ping still decides, within `verifyTimeout`.
                isReplacingSocket = false
            }
        }
        return false
    }

    /// A socket that won't do: closed quietly and a new one connected, still reading as connected
    /// when the Bots were online (`pause`, `resumeFromPause`), as any reconnect otherwise.
    private func replaceSocket() {
        pause()
        if isPaused {
            resumeFromPause()
        } else if connectTask == nil {
            startConnect()
        }
    }

    /// The socket answered: trusted again, and caught up.
    private func verified(_ socket: GatewaySocket) async {
        await refresh()
        if pollTask == nil, self.socket === socket, !isInBackground {
            startPolling()
            workspace?.projects.connected()
            workspace?.unread.connected()
        }
    }

    /// How long a ping may take before the socket counts as dead: a sleeping cellular radio or a
    /// busy Mac answers in a second or two; a socket the suspension killed never does.
    static let verifyTimeout: Duration = .seconds(5)
    /// No answer by then: a replacement starts connecting alongside.
    static let replaceAfter: Duration = .milliseconds(700)

    #if os(macOS)
    /// The Mac is going to sleep: close the socket cleanly. A sleeping Mac's connections die
    /// without a word, and the socket would look open for the minute it takes to notice.
    func willSleep() {
        guard !isTornDown else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        pause()
    }

    /// Awake again: the socket comes back at once, windows open or not (a Mac in the background
    /// keeps its socket, for notifications).
    func didWake() {
        guard !isTornDown else { return }
        reconnectAttempts = 0
        if isPaused {
            resumeFromPause()
        } else if let socket {
            verify(socket, heardWithin: 0) // opened around the sleep: proven, not assumed
        } else {
            retryNow()
        }
    }
    #endif

    /// New connections for the Bot Mode backend's next requests (`AppModel.recycleConnections`).
    func recycleConnections() async {
        await client.recycleConnections()
    }

    // MARK: - Pausing

    /// Lets the socket go quietly (`isPaused`). The gateway carries on with a running reply; the
    /// new socket picks the chats up where they were (`botChatReconnected`).
    private func pause() {
        guard let socket, !isTornDown else { return }
        ConnectionLog.logger.notice("bots: pausing the socket")
        self.socket = nil // first: its close is no drop (`socketClosed` ignores a socket it doesn't hold)
        // A replacement connecting alongside it is now simply the connect; its failure retries.
        isReplacingSocket = false
        workspace?.projects.disconnected()
        workspace?.unread.disconnected()
        pumpTask?.cancel()
        pumpTask = nil
        pollTask?.cancel()
        pollTask = nil
        photoTasks.values.forEach { $0.cancel() }
        photoTasks = [:]
        if state.isOnline { isPaused = true }
        Task { await socket.close() }
    }

    /// Connects again after a pause, straight away and retrying quickly; the Bots read as connected
    /// meanwhile. Not back within `resumeWindow`: the app says so (`resumeTookTooLong`).
    private func resumeFromPause() {
        guard isPaused, !isTornDown else { return }
        ConnectionLog.logger.notice("bots: resuming after a pause")
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        if connectTask == nil { startConnect(quietly: true) }
        resumeDeadline?.cancel()
        resumeDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.resumeWindow)
            guard !Task.isCancelled else { return }
            self?.resumeTookTooLong()
        }
    }

    /// Still no socket a few seconds after coming back: say so. The connect keeps trying.
    private func resumeTookTooLong() {
        guard isPaused, socket == nil, !isTornDown else { return }
        ConnectionLog.logger.notice("bots: no socket yet after coming back")
        endPause()
        droppedAt = .now // "Reconnecting…" for a while yet, not "offline" (`reconnectGrace`)
        if state.isOnline { state = .connecting }
        for conversation in allConversations {
            conversation.botChatConnectionLost()
        }
    }

    /// The pause is over, with a socket or without: what waited for it goes on.
    private func endPause() {
        resumeDeadline?.cancel()
        resumeDeadline = nil
        if isPaused { isPaused = false }
        // Waiters loop on `isConnected`: a spare wake costs nothing.
        resumeConnectedWaiters()
        let waiters = socketWaiters.values
        socketWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    /// Waits (at most `timeout`) for the socket a pause took away, connecting if nothing is: a
    /// request made while the app is still away (a notification's reply) brings it back too.
    private func waitForSocket(timeout: Duration = .seconds(10)) async {
        guard socket == nil, isPaused, !isTornDown else { return }
        if connectTask == nil { startConnect(quietly: true) }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.socketWaiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { continuation in
            socketWaiters[id] = continuation
        }
        timer.cancel()
    }

    /// Waits for as long as it takes the Bots to be connected: a message sent while they're away
    /// waits for them rather than failing. True once connected; false when the roster is torn down
    /// or the caller is cancelled (Stop, Don't Send).
    func untilConnected() async -> Bool {
        while !isConnected {
            guard !isTornDown, !Task.isCancelled else { return false }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    connectedWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.connectedWaiters.removeValue(forKey: id)?.resume() }
            }
        }
        return true
    }

    private func resumeConnectedWaiters() {
        let waiters = connectedWaiters.values
        connectedWaiters = [:]
        waiters.forEach { $0.resume() }
    }

    // MARK: - Socket

    private func startPump(_ socket: GatewaySocket) {
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            let messages = await socket.messages()
            for await message in messages {
                guard let self, !Task.isCancelled else { return }
                switch message {
                case .frame(.event(let event)):
                    self.route(event)
                case .frame(.request(let request)):
                    await self.handle(request, on: socket)
                case .frame(.response):
                    break
                case .closed(let error):
                    self.socketClosed(error, socket: socket)
                }
            }
        }
    }

    private func route(_ event: GatewayEvent) {
        // The gateway's change watcher: broadcast to every client, not tagged with a profile.
        if event.type == "projects.changed" {
            workspace?.projects.changeEvent(event.type)
            return
        }
        if event.type == "sessions.changed" {
            sessionsChanged()
            return
        }
        // The Bot Screen's control moved (`display.lease`, to every client).
        if event.type == "display.lease" {
            for conversation in allConversations {
                conversation.inspectorIfLoaded?.screenLeaseChanged(event.payload)
            }
            return
        }
        // A Bot Screen started or stopped outside this app (`display.status`, to every client).
        if event.type == "display.status" {
            for conversation in allConversations {
                conversation.inspectorIfLoaded?.screenStatusChanged()
            }
            return
        }
        // Hey Hermes (`docs/voice.md` §4.6): the gateway heard its wake word.
        if event.type == "wake.detected" {
            if let detection = WakeDetection(payload: event.payload) { HeyHermes.shared.detected(detection) }
            return
        }
        if event.sessionID.isEmpty {
            // Broadcasts (`approval.cancelled`, `session.reclaimed`) name their chat in the payload.
            let runtime = event.payload["session_id"]?.stringValue
            let stored = event.payload["stored_session_id"]?.stringValue
            guard runtime != nil || stored != nil else { return }
            for conversation in allConversations
            where (runtime != nil && conversation.runtimeSessionID == runtime) || (stored != nil && conversation.sessionID == stored) {
                conversation.receive(event)
            }
            return
        }
        for conversation in allConversations where conversation.runtimeSessionID == event.sessionID {
            conversation.receive(event)
        }
    }

    private func handle(_ request: GatewayServerRequest, on socket: GatewaySocket) async {
        let target = allConversations.first { $0.runtimeSessionID == request.sessionID }
        guard let target else {
            // No chat here shows that session; let a window that does answer it.
            await socket.decline(request.id, code: 4404, message: "This chat isn't open in the Hermes app.")
            return
        }
        if let approval = GatewayTurnDecoder.approval(from: request) {
            target.receive(approval)
        } else if let card = HermesRequest.parse(request) {
            target.receive(card)
        } else if PreviewBridge.requestMethods.contains(request.method) {
            // Hermes reading and using the Inspector (`docs/inspector.md` §2). A chat whose
            // Inspector isn't on screen declines, so the gateway stops waiting at once.
            if let answer = await target.inspector.answer(request) {
                await socket.respond(to: request.id, result: answer)
            } else {
                await socket.decline(request.id, code: PreviewBridge.notShownCode, message: "This chat's Inspector isn't on screen in the Hermes app.")
            }
        } else {
            // tour: a desktop-only surface.
            await socket.decline(request.id)
        }
    }

    private func socketClosed(_ error: (any Error)?, socket closed: GatewaySocket) {
        guard socket === closed else { return }
        ConnectionLog.logger.notice("bots: socket closed after \(Int(Date.now.timeIntervalSince(self.connectedAt ?? .now)))s\(self.isInBackground ? " in the background" : "", privacy: .public): \(error.map { Self.describe($0) } ?? "no error", privacy: .public)")
        #if os(iOS)
        if isInBackground, state.isOnline, !isTornDown, !Self.needsThePerson(error ?? GatewaySocket.Failure.notConnected, link: link) {
            // Lost while the app was away: the same as pausing it, and coming back reconnects.
            // Nothing is left to keep the app running for.
            pause()
            backgroundHold.end()
            return
        }
        #endif
        if verification != nil, state.isOnline, !isTornDown, !Self.needsThePerson(error ?? GatewaySocket.Failure.notConnected, link: link) {
            // Closed while being proven: replaced quietly, as a failed proof would be. A replacement
            // already connecting becomes the new socket's connect, and its failure retries like one.
            isReplacingSocket = false
            replaceSocket()
            return
        }
        socket = nil
        droppedAt = .now
        pumpTask?.cancel()
        pollTask?.cancel()
        photoTasks.values.forEach { $0.cancel() }
        photoTasks = [:]
        photoRevisions = [:]
        for conversation in allConversations {
            conversation.botChatConnectionLost()
        }
        guard !isTornDown else { return }
        workspace?.checkConnectionNow()
        // A rejected sign-in needs the person, not a retry loop.
        if case GatewaySocket.Failure.closed(let reason)? = error as? GatewaySocket.Failure,
           reason.contains("sign-in"), link.signIn != .automatic {
            state = .signInRequired(reason)
            return
        }
        state = .connecting
        // Back off unless the connection had been healthy for a while.
        if let connectedAt, Date.now.timeIntervalSince(connectedAt) > 30 { reconnectAttempts = 0 }
        scheduleReconnect()
    }

    /// One JSON-RPC call on the shared socket.
    func request(_ method: String, _ params: [String: JSONValue] = [:], timeout: Duration = .seconds(60)) async throws -> JSONValue {
        #if os(iOS)
        // Asked while the app is away (a notification's action): the socket may have died with
        // the app suspended. Proven first, rather than waiting out a request on a dead one.
        if isInBackground, verification == nil, let socket, !(await socket.heard(within: 10)), self.socket === socket {
            verify(socket, heardWithin: 0)
        }
        #endif
        if let verification { await verification.value }
        if socket == nil, isPaused { await waitForSocket() }
        guard let socket else { throw GatewaySocket.Failure.notConnected }
        return try await socket.request(method, params, timeout: timeout)
    }

    /// Answers Hermes's request `requestID` on the socket, waiting for one coming back from a
    /// pause as `request` does. False when there's none to send it on: the chat keeps the answer
    /// for the next attach (`AnswerLedger`).
    @discardableResult
    func respond(to requestID: String, result: JSONValue) async -> Bool {
        if let verification { await verification.value }
        if socket == nil, isPaused { await waitForSocket() }
        guard let socket else { return false }
        return await socket.respond(to: requestID, result: result)
    }

    /// A repo's checkouts on the gateway (the dashboard's git REST; the protocol has no git calls).
    func gitWorktrees(repo: String) async throws -> [GitWorktree] {
        try await client.gitWorktrees(repo: repo)
    }

    /// A new worktree on a new branch, for a chat that keeps its edits off the main checkout.
    func startProviderSignIn(provider: String, profile: String?) async throws -> (sessionID: String, url: URL, userCode: String, interval: Int) {
        try await client.startProviderSignIn(provider: provider, profile: profile)
    }

    func pollProviderSignIn(provider: String, sessionID: String, profile: String?) async throws -> String {
        try await client.pollProviderSignIn(provider: provider, sessionID: sessionID, profile: profile)
    }

    /// `hermes gateway restart` (the app's plugins, `docs/plugins.md` §2).
    func restartGateway() async throws {
        try await client.restartGateway()
    }

    /// A secret for the gateway's `.env` (plugin settings of `type: secret`). Write-only.
    func setEnv(key: String, value: String, profile: String?) async throws {
        try await client.setEnv(key: key, value: value, profile: profile)
    }

    /// A task's runs (`GET /api/cron/jobs/{id}/runs`).
    func cronRuns(jobID: String, profile: String?, limit: Int = 20) async throws -> [CronRun] {
        try await client.cronRuns(jobID: jobID, profile: profile, limit: limit)
    }

    /// Full-text chat search (`GET /api/sessions/search`).
    func searchSessions(_ query: String, limit: Int, profile: String?, sources: [String], excludeSources: [String]) async throws -> [SessionSearchResult] {
        try await client.searchSessions(query, limit: limit, profile: profile, sources: sources, excludeSources: excludeSources)
    }

    /// `checkpoints.enabled` in the profile's config (Turn On Checkpoints).
    func setCheckpointsEnabled(_ enabled: Bool, profile: String?) async throws {
        try await client.setCheckpointsEnabled(enabled, profile: profile)
    }

    // MARK: Board (`docs/board.md`; card text is never logged)

    /// The backend the Board calls (`/api/plugins/kanban/…`). It changes when the link does, so
    /// read it for each call.
    var boardClient: BackendClient { client }

    // MARK: Memory (`docs/memory.md`; entries are never kept here)

    func memoryEntries(profile: String?) async throws -> MemoryList {
        try await client.memoryEntries(profile: profile)
    }

    func memoryEntryText(id: String, profile: String?) async throws -> String {
        try await client.memoryEntryText(id: id, profile: profile)
    }

    func editMemoryEntry(id: String, content: String, profile: String?) async throws {
        try await client.editMemoryEntry(id: id, content: content, profile: profile)
    }

    func forgetMemoryEntry(id: String, profile: String?) async throws {
        try await client.forgetMemoryEntry(id: id, profile: profile)
    }

    func memoryStatus(profile: String?) async throws -> MemoryStatus {
        try await client.memoryStatus(profile: profile)
    }

    func memorySettings(profile: String?) async throws -> MemorySettings {
        try await client.memorySettings(profile: profile)
    }

    func setMemorySetting(_ key: String, to value: Bool, profile: String?) async throws {
        try await client.setMemorySetting(key, to: value, profile: profile)
    }

    func setMemoryProvider(_ provider: String, profile: String?) async throws {
        try await client.setMemoryProvider(provider, profile: profile)
    }

    func resetMemory(target: String, profile: String?) async throws {
        try await client.resetMemory(target: target, profile: profile)
    }

    func addGitWorktree(repo: String) async throws -> GitWorktree {
        try await client.addGitWorktree(repo: repo)
    }

    func transcript(storedSessionID: String, profile: String, limit: Int = SessionTranscript.firstPage, offset: Int = 0) async throws -> SessionTranscript {
        try await client.transcript(storedSessionID: storedSessionID, profile: profile, limit: limit, offset: offset)
    }

    /// HTTP reads need the dashboard's session token, which connecting fetches: an app woken in the
    /// background before it ever connected fetches it now (automatic sign-in only).
    func readyForHTTP() async {
        guard link.signIn == .automatic, await client.credential == nil else { return }
        _ = try? await client.discoverSessionToken()
    }

    /// Connected, or paused and coming back with the app (`isPaused`).
    var isConnected: Bool { (socket != nil || isPaused) && state.isOnline }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var quietPolls = 0
            while !Task.isCancelled {
                // Desktop's 5 s while things move, 10 s once the roster has sat still for
                // half a minute, 30 s after five quiet minutes, 15 s in Low Power Mode.
                #if os(macOS)
                // A Mac app behind other windows: coming to the front refreshes at once anyway.
                let inBack = !NSApp.isActive
                #else
                let inBack = false
                #endif
                let interval: Double = PowerState.shared.isLowPower ? 15 : (inBack || quietPolls >= 30 ? 30 : quietPolls >= 6 ? 10 : 5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                let before = self.profiles
                await self.refresh()
                quietPolls = self.profiles == before ? quietPolls + 1 : 0
            }
        }
    }

    /// `sessions.changed` comes up to every 2 s while anything runs anywhere (a streaming turn moves
    /// its session row), and five things here follow it, each with its own request to a dashboard
    /// that is often the busy process on its machine. One tick serves them all: a quarter second
    /// after the first change, then at most every 3 s while changes keep coming (every 30 s while
    /// the Mac app is behind other apps).
    private func sessionsChanged() {
        guard sessionsTick == nil else { return }
        let spacing: Double = AppPresence.isInBack ? 30 : 3
        let wait = max(0.25, spacing - Date.now.timeIntervalSince(sessionsTickedAt))
        sessionsTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.sessionsTick = nil
            self.sessionsTickedAt = .now
            // Project lanes and running chats, read marks (another device may have just read a Bot
            // or a chat), the roster (a Bot may have written where nothing streamed here), and the
            // chat list's live lines.
            self.workspace?.projects.changeEvent("sessions.changed")
            self.readMayHaveMoved()
            self.rosterMayHaveMoved()
            self.workspace?.unread.sessionsMayHaveMoved()
            self.workspace?.activity.sessionsChanged()
            // A chat that appeared anywhere is the app's too (`docs/widgets.md` §11).
            self.workspace?.widgets.markKnownChats()
        }
    }

    /// Hermes' sessions moved (`sessions.changed`): a Bot may have written where no turn streamed
    /// here (a routine's result, another Bot's message, a turn on another device). The roster is
    /// read again at once, then at most every 3 s while changes keep coming (Desktop's pace while
    /// things move), so an open Bot Chat shows it in seconds, not at the next poll (up to 30 s).
    private func rosterMayHaveMoved() {
        guard rosterRecheck == nil, socket != nil, !isInBackground else { return }
        let wait = max(0, 3 - Date.now.timeIntervalSince(rosterRecheckedAt))
        rosterRecheck = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.rosterRecheck = nil
            self.rosterRecheckedAt = .now
            await self.refresh()
        }
    }

    /// Reads the roster (`profiles.list`), the way Desktop polls it every five seconds.
    func refresh() async {
        guard socket != nil else { return }
        do {
            let began = ContinuousClock.now
            let result = try await request("profiles.list", [:], timeout: .seconds(30))
            guard case .array(let rows)? = result["profiles"] else { return }
            apply(rows.map(BotProfile.init(json:)).filter { !$0.name.isEmpty }, quickly: ContinuousClock.now - began < .seconds(5))
            LaunchTrace.mark("Bots fetched (\(rows.count))", id: "Bots fetched")
            if rows != cachedRows {
                cachedRows = rows
                RosterCache.save(botID, rows: rows)
            }
            await groupRooms.refresh()
        } catch is CancellationError {
        } catch {
            // A roster read that timed out on an open socket is a busy backend: the polls ask
            // again, and nothing on screen calls the Bots offline meanwhile.
            if BackendClient.isSlowAnswer(error), socket != nil {
                markBusy()
            } else if !hasLoaded {
                state = .failed(Self.describe(error))
            }
        }
    }

    /// Bot Chats that moved since they were last read, among those active in the last 20 minutes,
    /// have their last rows read for a turn running elsewhere (`ElsewhereTurn`); the Bots found
    /// running are read again every 30 s, so a turn that went quiet stops showing.
    private func readElsewhere(_ bots: [BotProfile], now: Date) {
        var names: Set<String> = []
        for bot in bots {
            names.insert(bot.name)
            guard let chat = bot.canonicalSession,
                  let active = chat.lastActive ?? bot.lastActive,
                  now.timeIntervalSince(active) < TranscriptBuilder.midTurnStaleAfter else {
                elsewhereTips[bot.name] = nil
                if runningElsewhere[bot.name] != nil { runningElsewhere[bot.name] = nil }
                continue
            }
            let tip = "\(chat.resolvedID)|\(chat.messageCount ?? -1)|\(active.timeIntervalSince1970)"
            guard elsewhereTips[bot.name] != tip else { continue }
            elsewhereTips[bot.name] = tip
            readElsewhere(bot.name, chat: chat.resolvedID)
        }
        for name in runningElsewhere.keys where !names.contains(name) { runningElsewhere[name] = nil }
        for name in ownTurns where ownTurnRecoveries[name] == nil && elsewhereReads[name] == nil {
            guard let chat = bot(named: name)?.canonicalSession?.resolvedID else {
                ownTurns.remove(name)
                continue
            }
            readElsewhere(name, chat: chat)
        }
    }

    private func readElsewhere(_ name: String, chat: String) {
        elsewhereReads[name]?.cancel()
        elsewhereReads[name] = Task { [weak self, client] in
            let tail = try? await client.transcript(storedSessionID: chat, profile: name, limit: 12)
            guard let self, !Task.isCancelled, let tail else { return }
            self.elsewhereReads[name] = nil
            // A turn this app streams is live, not elsewhere.
            let working = self.conversations[name]?.isWorking == true
            let settledAt = self.keptStop(name)
            let turn = working ? nil : self.turnBook.shown(name, rows: tail.messages, settledAt: settledAt)
            if self.runningElsewhere[name] != turn { self.runningElsewhere[name] = turn }
            // The person's own turn stopping mid-work runs on the gateway, which says whether it still
            // does: it isn't left showing as working for 20 minutes once it died (a gateway restart).
            // One the app lost track of is looked at again on every read, though nothing shows it.
            if !working, BotTurnBook.needsLook(tail.messages, settledAt: settledAt) {
                self.ownTurns.insert(name)
                self.recoverOwnTurn(name, chat: chat, from: tail.messages)
            } else {
                self.ownTurns.remove(name)
                self.turnBook.found(name)
            }
            self.recheckElsewhere()
        }
    }

    /// A Bot's own turn whose stored rows stop mid-work, with no chat here following it live: the
    /// roster finds out how it ended the way the chat does (`TurnRecovery`, `docs/chat.md` §2). It
    /// asks whether Hermes runs the chat and reads its last rows again, and keeps showing the Bot
    /// working meanwhile. Still running, it shows working (the next roster read looks again); stored
    /// whole, the rows take over; two looks a second apart finding nothing running and the rows
    /// partway (`TurnRecovery.forBotsList`), it ended there and stops showing as working. With no
    /// answer within the minute it stops showing as working too, but isn't "Stopped": the app lost
    /// track of it (`BotTurnBook.lose`), and the next roster read looks again.
    private func recoverOwnTurn(_ name: String, chat: String, from tail: [SessionMessage]) {
        guard ownTurnRecoveries[name] == nil else { return }
        ownTurnRecoveries[name] = Task { [weak self] in
            let began = Date.now
            var recovery = TurnRecovery.forBotsList()
            var step = TurnRecovery.Step.wait(0)
            // The rows last read: where the turn ended, should no look read them again.
            var stored = tail
            while case .wait(let seconds) = step {
                if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
                guard let self, !Task.isCancelled else { return }
                // The chat runs the turn here now, or already settled it: it's the one to follow.
                guard self.conversations[name]?.isWorking != true else { break }
                let look = await self.lookAtOwnTurn(name, chat: chat, within: TurnRecovery.timeout(elapsed: Date.now.timeIntervalSince(began)))
                guard !Task.isCancelled else { return }
                if let rows = look.stored { stored = rows }
                if self.keptStop(name) == TranscriptBuilder.lastTurnRowID(stored) { break }
                step = recovery.next(after: look.look, elapsed: Date.now.timeIntervalSince(began))
            }
            guard let self, !Task.isCancelled else { return }
            self.ownTurnRecoveries[name] = nil
            switch step {
            case .settle:
                self.settleOwnTurn(name, rows: stored)
            case .lost:
                self.loseOwnTurn(name, rows: stored)
            case .follow, .handOver:
                // It runs, or its rows say what it is now.
                self.turnBook.found(name)
                guard self.conversations[name]?.isWorking != true else { return }
                let turn = self.turnBook.shown(name, rows: stored, settledAt: self.keptStop(name))
                if self.runningElsewhere[name] != turn { self.runningElsewhere[name] = turn }
            case .wait:
                break
            }
        }
    }

    /// What one of `lookAtOwnTurn`'s reads answered.
    nonisolated private enum OwnTurnRead: Sendable {
        case running(Bool?)
        case stored([SessionMessage]?)
        case timedOut
    }

    /// One look for `recoverOwnTurn`: whether Hermes runs the chat now (a turn waiting on the person
    /// runs too) and its last rows, both given up after `limit` seconds.
    private func lookAtOwnTurn(_ name: String, chat: String, within limit: TimeInterval) async -> (look: TurnRecovery.Look, stored: [SessionMessage]?) {
        let client = client
        var running: Bool?
        var stored: [SessionMessage]?
        await withTaskGroup(of: OwnTurnRead.self) { group in
            group.addTask { .stored(try? await client.transcript(storedSessionID: chat, profile: name, limit: 12).messages) }
            group.addTask { .running(await self.gatewayHoldsTurn(in: chat, within: limit)) }
            group.addTask {
                try? await Task.sleep(for: .seconds(limit))
                return .timedOut
            }
            var answered = 0
            for await read in group {
                switch read {
                case .running(let value): running = value
                case .stored(let value): stored = value
                case .timedOut: break
                }
                answered += 1
                if case .timedOut = read { break }
                if answered == 2 { break }
            }
            group.cancelAll()
        }
        return (TurnRecovery.look(running: running, stored: stored), stored)
    }

    /// Whether Hermes has a turn under way in the stored chat `chat` (`session.active_list`), nil when
    /// it couldn't be asked within `limit` seconds. Asked afresh on the socket, not through the lists'
    /// shared answer: that one waits as long as a frozen backend holds it, and is up to 2 s old.
    /// Hermes lists the sessions of its own process (`tui_gateway`, where Bot Chats run): a turn in
    /// another Hermes process, a terminal's `--resume`, reads as not running, as it does for the
    /// chat's attach (`session.resume`'s `running`).
    private func gatewayHoldsTurn(in chat: String, within limit: TimeInterval) async -> Bool? {
        guard isConnected else { return nil }
        let client = ProjectsClient(profile: nil) { [weak self] method, params in
            guard let self else { throw CancellationError() }
            return try await self.request(method, params, timeout: .seconds(limit))
        }
        guard let rows = try? await client.activeSessions() else { return nil }
        return rows.contains { $0.sessionKey == chat && $0.holdsTurn }
    }

    /// The roster settled a Bot's own turn where its rows stop: the Bot stops showing as working, and
    /// its chat, when it's open, shows the turn ended there.
    private func settleOwnTurn(_ name: String, rows: [SessionMessage]) {
        guard let row = BotTurnBook.stoppedRow(rows) else { return }
        // The chat's own record, through the chat when it's loaded so its copy stays the same.
        if let conversation = conversations[name] {
            conversation.turnSettledByRoster(at: row)
        } else {
            var kept = keptTurns.turn(for: keptKey(name))
            kept.stoppedAt = row
            keptTurns.set(kept, for: keptKey(name))
        }
        turnBook.found(name)
        ownTurns.remove(name)
        if runningElsewhere[name] != nil { runningElsewhere[name] = nil }
        workspace?.activity.botTurnSettled(name)
    }

    /// The Bot Chat's key in `KeptTurns`, as the chat's own (`ConversationModel.cacheKey`).
    private func keptKey(_ name: String) -> String {
        "bot-\(botID.uuidString)-\(name)"
    }

    /// The row the Bot Chat's last turn settled at, kept on the device (`KeptTurn.stoppedAt`).
    private func keptStop(_ name: String) -> Int? {
        keptTurns.turn(for: keptKey(name)).stoppedAt
    }

    /// The roster couldn't find out how a Bot's own turn ended: it stops showing as working, its chat
    /// doesn't say "Stopped", and the next roster read looks again (`ownTurns` keeps it).
    private func loseOwnTurn(_ name: String, rows: [SessionMessage]) {
        guard turnBook.lose(name, rows: rows) else { return }
        if runningElsewhere[name] != nil { runningElsewhere[name] = nil }
        workspace?.activity.botTurnSettled(name)
    }

    /// The Bot's chat settled its last turn (finished, or stopped where Hermes stored it, which it
    /// keeps in its `KeptTurn`): the row, tile, face and working lines stop showing it as working at
    /// once, and the roster's own look at it ends.
    func chatSettledTurn(_ name: String) {
        turnBook.found(name)
        ownTurnRecoveries.removeValue(forKey: name)?.cancel()
        workspace?.activity.botTurnSettled(name)
        guard runningElsewhere[name] != nil else { return }
        runningElsewhere[name] = nil
        // A turn going on after the row the chat settled at shows again from the rows themselves.
        if let chat = bot(named: name)?.canonicalSession?.resolvedID { readElsewhere(name, chat: chat) }
    }

    /// The Bot's chat lost track of its last turn (no answer within the recovery's minute): the Bot
    /// stops showing it as working, but it isn't settled there, so the roster's reads keep asking.
    func chatLostTurn(_ name: String, rows: [SessionMessage]) {
        turnBook.lose(name, rows: rows)
        workspace?.activity.botTurnSettled(name)
        if runningElsewhere[name] != nil { runningElsewhere[name] = nil }
    }


    private func recheckElsewhere() {
        guard elsewhereRecheck == nil, !runningElsewhere.isEmpty else { return }
        elsewhereRecheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled else { return }
            self.elsewhereRecheck = nil
            for name in self.runningElsewhere.keys {
                guard let chat = self.bot(named: name)?.canonicalSession?.resolvedID else { continue }
                self.readElsewhere(name, chat: chat)
            }
        }
    }

    /// - Parameter fromGateway: false for a change made here (`saveFlag`): the list is rebuilt, but
    ///   nothing that only a read the gateway answered can say (it's not busy, it's online) moves.
    /// - Parameter quickly: the read came back quickly; a slow one is the busy Mac itself, so the
    ///   Bots stay (or turn) busy.
    private func apply(_ fresh: [BotProfile], fromGateway: Bool = true, quickly: Bool = true) {
        var fresh = fresh
        // Pins and hides still on their way (`saveFlag`): a roster read from before them doesn't
        // move the Bot back.
        if !pendingFlags.isEmpty {
            for index in fresh.indices {
                for (key, pending) in pendingFlags[fresh[index].name] ?? [:] {
                    fresh[index].meta.raw[key] = pending.value == .null ? nil : pending.value
                }
            }
        }
        let previous = index
        if fresh != profiles {
            profiles = fresh
            index = Dictionary(fresh.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            reorder()
        }
        guard fromGateway else { return }
        if !hasLoaded { hasLoaded = true }
        if socket != nil {
            if !quickly {
                noteSlow() // not `markBusy`: it answered, so no clock toward "offline"
            } else if Date.now.timeIntervalSince(lastSlowAt) > 30 {
                clearBusy()
            }
        }
        // A failed first read must not leave a working socket looking offline.
        if socket != nil, !state.isOnline { state = .online(version: version) }
        // Time windows move even when the roster doesn't.
        let now = Date.now
        let active = Set(fresh.filter { $0.isActive(now: now) }.map(\.name))
        let working = Set(fresh.filter { bot in
            bot.workerSession?.lastActive.map { now.timeIntervalSince($0) < 150 } ?? false
        }.map(\.name))
        if active != activeNames { activeNames = active }
        if working != workingNames { workingNames = working }
        readElsewhere(fresh, now: now)
        updateUnread()
        // A Bot whose chat moved on has its row's last line read again (`LastLineBook`).
        workspace?.unread.readStaleLines()
        loadPhotos()
        for bot in fresh {
            guard let conversation = conversations[bot.name] else { continue }
            conversation.botRosterChanged(bot, previous: previous[bot.name])
        }
    }

    // MARK: - Unread

    /// A Bot's activity watermark is seeded on first sight; a later advance of its Bot Chat makes it
    /// unread, unless the Bot Chat was read since on another device (`serverRead`). A routine's run
    /// in a session of its own isn't news in the chat, and it's the Bot Chat Hermes' read mark is on.
    private func updateUnread() {
        var marks = watermarks
        var next = unread
        for bot in profiles {
            guard let active = bot.chatActivity?.timeIntervalSince1970 else { continue }
            guard let seen = marks[bot.name] else {
                marks[bot.name] = active
                continue
            }
            // Open or not: what's been on screen decides (the chat marks it read, `markRead`), so
            // news below where the person stopped reading stays unread.
            if active > max(seen, serverRead[bot.name] ?? 0) + 0.5 {
                next.insert(bot.name)
            }
        }
        next.formIntersection(profiles.map(\.name))
        if next != unread { unread = next }
        if marks != watermarks {
            watermarks = marks
            UserDefaults.standard.set(marks, forKey: Self.watermarkKey(botID))
        }
        checkReadElsewhere()
    }

    /// - Parameter share: tell Hermes and the other devices. A Bot writing in a chat left open on a
    ///   Mac behind other apps is read here, but nobody saw it (`isInFront`).
    func markRead(_ name: String, share: Bool = true) {
        if unread.contains(name) { unread.remove(name) }
        if markedUnread.contains(name) {
            markedUnread.remove(name)
            // Shared below once the watermark moves; a mark of 0 needs clearing even when it hasn't.
            serverRead[name] = 0
        }
        guard let bot = bot(named: name), let active = bot.chatActivity?.timeIntervalSince1970 else { return }
        if (watermarks[name] ?? 0) < active {
            watermarks[name] = active
            UserDefaults.standard.set(watermarks, forKey: Self.watermarkKey(botID))
        }
        if share { shareRead(bot) }
    }

    /// Tells Hermes the Bot Chat was read (the mark Hermes Desktop keeps), so the person's other
    /// devices stop showing the Bot unread. While the Bot keeps writing on screen, at most every
    /// 10 s (the last one carries what came meanwhile); a mark that doesn't land waits in the read
    /// outbox and goes when the gateway answers (`docs/inbox.md` §4).
    private func shareRead(_ bot: BotProfile) {
        let name = bot.name
        guard let chat = bot.canonicalSession, let active = bot.chatActivity?.timeIntervalSince1970,
              (serverRead[name] ?? 0) + 0.5 < active, !sharingRead.contains(name) else { return }
        let wait = readThrottle.wait(for: name)
        guard wait == 0 else {
            guard trailingRead[name] == nil else { return }
            trailingRead[name] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.trailingRead[name] = nil
                // What came since, behind other apps, wasn't seen: only the read already made goes then.
                guard let bot = self.bot(named: name),
                      Self.isInFront || (bot.chatActivity?.timeIntervalSince1970 ?? 0) <= active + 0.5 else { return }
                self.shareRead(bot)
            }
            return
        }
        readThrottle.sent(name)
        sharingRead.insert(name)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sharingRead.remove(name) }
            let key = UnreadStore.botKey(name)
            do {
                try await self.client.markRead(storedSessionID: chat.resolvedID, profile: name)
                // Stamped by the server after this activity; its clock, not ours, so no later.
                self.serverRead[name] = max(self.serverRead[name] ?? 0, active)
                self.workspace?.unread.readSent(key, through: Date(timeIntervalSince1970: active))
                self.workspace?.unread.didRead(chats: self.botChats.filter { $0.value == name }.keys.sorted())
            } catch is CancellationError {
            } catch {
                let failure = error as NSError
                ConnectionLog.logger.notice("bots: couldn't mark \(name, privacy: .public) read (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)); it waits")
                self.workspace?.unread.readFailed(key, through: Date(timeIntervalSince1970: active))
            }
        }
    }

    /// A read waiting in the outbox: sent now unless the Bot wrote since (`ReadOutbox.isCurrent`).
    func resendRead(_ name: String, through: Date) -> Bool {
        guard let bot = bot(named: name), let active = bot.chatActivity else { return false }
        guard active.timeIntervalSince(through) <= 0.5 else { return false }
        shareRead(bot)
        return true
    }

    /// Mark as Unread (`docs/inbox.md` §5): a dot on every device until the Bot Chat is opened.
    func markUnread(_ name: String) async throws {
        guard let chat = bot(named: name)?.canonicalSession else { return }
        markedUnread.insert(name)
        unread.insert(name)
        do {
            try await client.markUnread(storedSessionID: chat.resolvedID, profile: name)
        } catch {
            markedUnread.remove(name)
            unread.remove(name)
            throw error
        }
    }

    /// How far a Bot Chat was read, here or on another device: what its count starts after.
    func readPoint(_ name: String) -> Date? {
        let seconds = max(serverRead[name] ?? 0, watermarks[name] ?? 0)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// The person is looking at the app. A Mac often keeps a Bot Chat open all day: that counts as
    /// read here, but only what was on screen while Hermes was in front is read on other devices.
    /// Reading is possible: the app in front, and on the Mac a screen that isn't locked or asleep.
    static var isInFront: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        NSApp.isActive && !ScreenLock.isLocked
        #endif
    }

    /// Hermes' sessions moved (`sessions.changed`, which covers read marks), or the app came to the
    /// front: another device may have just read a Bot that's unread here, or marked one unread.
    private func readMayHaveMoved() {
        readRecheck.mayHaveMoved()
    }

    /// Bots unread here that another device may have read since: ask Hermes for the Bot Chat's
    /// read mark, every 15 s at first, backing off to every 2 minutes while it stays unread, or
    /// `now` when Hermes says something moved. Then (at most every 30 s) the read Bots, which
    /// another device may have marked unread.
    private func checkReadElsewhere(now: Bool = false) {
        readRecheck.keep(unread)
        var names = Array(unread)
        if now, Date.now.timeIntervalSince(readBotsCheckedAt) > 30 {
            readBotsCheckedAt = .now
            names += profiles.map(\.name).filter { !unread.contains($0) && $0 != openBot }
        }
        for name in names {
            guard let chat = index[name]?.canonicalSession, readRecheck.isDue(name, now: now) else { continue }
            Task { [weak self] in
                guard let self else { return }
                defer { self.readRecheck.answered(name) }
                guard let mark = try? await self.client.readMark(storedSessionID: chat.resolvedID, profile: name) else { return }
                self.adopt(mark, for: name)
            }
        }
    }

    /// What Hermes says about a Bot Chat's read mark.
    private func adopt(_ mark: ReadMark, for name: String) {
        switch mark {
        case .markedUnread:
            guard name != openBot, !markedUnread.contains(name) else { return }
            markedUnread.insert(name)
            unread.insert(name)
        case .readUntil(let read):
            let seconds = read.timeIntervalSince1970
            serverRead[name] = max(serverRead[name] ?? 0, seconds)
            if markedUnread.contains(name) { markedUnread.remove(name) }
            guard let active = index[name]?.chatActivity?.timeIntervalSince1970, seconds + 0.5 >= active,
                  unread.contains(name) else { return }
            ConnectionLog.logger.notice("bots: \(name, privacy: .public) was read on another device")
            unread.remove(name)
            if (watermarks[name] ?? 0) < active {
                watermarks[name] = active
                UserDefaults.standard.set(watermarks, forKey: Self.watermarkKey(botID))
            }
        case .untracked:
            break
        }
    }

    // MARK: - Avatars

    /// Fetches picture avatars. Desktop also stores a 160 px raster of every drawn face;
    /// those are skipped (unless marked as a photo) so the native face can animate.
    private func loadPhotos() {
        for bot in profiles {
            let revision = bot.metaRevision ?? 0
            guard bot.hasAvatar else {
                if photos[bot.name] != nil { photos[bot.name] = nil }
                photoRevisions[bot.name] = nil
                continue
            }
            guard photoRevisions[bot.name] != revision, photoTasks[bot.name] == nil else { continue }
            let name = bot.name
            let isPhoto = bot.meta.imageKind == "photo"
            photoTasks[name] = Task { [weak self] in
                defer { self?.photoTasks[name] = nil }
                guard let self,
                      let result = try? await self.request("profiles.get_asset", ["name": .string(name), "asset": .string("avatar")]),
                      !Task.isCancelled
                else { return }
                guard let data = result["data"]?.stringValue, data.hasPrefix("data:image/") else {
                    self.photoRevisions[name] = revision // the backend has none; don't ask again
                    return
                }
                if !isPhoto, Self.isBackfilledFace(data) {
                    self.photos[name] = nil
                } else {
                    // Decode and downsample off the main thread; faces never draw above ~100 pt.
                    let key = "face://\(name)#\(revision)"
                    guard let image = await FaceImageCache.prepare(dataURL: data, key: key), !Task.isCancelled else { return }
                    _ = image
                    self.photos[name] = key
                }
                self.photoRevisions[name] = revision
            }
        }
    }

    /// A 160×160 PNG is Desktop's raster of a drawn face.
    nonisolated static func isBackfilledFace(_ dataURL: String) -> Bool {
        guard dataURL.hasPrefix("data:image/png"), let comma = dataURL.firstIndex(of: ",") else { return false }
        let header = String(dataURL[dataURL.index(after: comma)...].prefix(44))
        guard let bytes = Data(base64Encoded: header, options: .ignoreUnknownCharacters), bytes.count >= 24 else { return false }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return width == 160 && height == 160
    }

    // MARK: - Bot Chats

    func conversation(for name: String) -> ConversationModel {
        if let existing = conversations[name] { return existing }
        let conversation = ConversationModel(roster: self, botName: name, workspace: workspace)
        conversations[name] = conversation
        return conversation
    }

    /// Finds the Bot's canonical "Bot Chat" (by exact title, the identity Desktop uses).
    ///
    /// Fails closed: a lookup error never reads as "no chat", or the app would mint a
    /// second forever-chat.
    func resolveBotChat(_ name: String) async throws -> String? {
        if let canonical = bot(named: name)?.canonicalSession { return canonical.resolvedID }
        let result = try await request("session.list", [
            "profile": .string(name), "title": .string(botChatTitle), "include_hidden": .bool(true), "limit": .number(200),
        ])
        guard case .array(let sessions)? = result["sessions"] else {
            throw HermesError.invalidResponse("session.list")
        }
        if let row = sessions.first, let id = row["resolved_id"]?.stringValue ?? row["id"]?.stringValue {
            return id
        }
        return nil
    }

    func turnFinished(in name: String) {
        workspace?.activity.botReplied(name)
        Task {
            await refresh()
            if openBot == name { markRead(name, share: Self.isInFront) }
        }
    }

    // MARK: - Editing Bots

    /// Read → merge → compare-and-swap write of `ui_meta['hermes-bots']`, retried on conflict.
    func saveMeta(for name: String, _ change: @escaping ([String: JSONValue]) -> [String: JSONValue]) async throws {
        for _ in 0..<3 {
            let listed = try await request("profiles.list", ["include_sessions": .bool(false)])
            guard case .array(let rows)? = listed["profiles"], let row = rows.first(where: { $0["name"]?.stringValue == name }) else {
                throw HermesError.notFound(message: String(localized: "That Bot no longer exists."))
            }
            var base: [String: JSONValue] = [:]
            if case .object(let namespace)? = row["ui_meta"]?["hermes-bots"] { base = namespace }
            base["chat"] = nil
            var params: [String: JSONValue] = [
                "name": .string(name),
                "ui_meta": .object(["hermes-bots": .object(change(base))]),
            ]
            if let revision = row["ui_meta_revisions"]?["hermes-bots"] {
                params["ui_meta_expected_revisions"] = .object(["hermes-bots": revision])
            }
            let result = try await request("profiles.configure", params)
            if result["ok"]?.boolValue == true {
                await refresh()
                return
            }
            guard result["applied"]?["ui_meta_conflicts"] != nil else {
                throw HermesError.unsupportedServer
            }
        }
        throw HermesError.server(status: 409, code: nil, message: String(localized: "Someone else changed this Bot at the same time. Try again."))
    }

    func setPinned(_ name: String, _ pinned: Bool) async throws {
        try await saveFlag("pinned", pinned, for: name)
    }

    func setHidden(_ name: String, _ hidden: Bool) async throws {
        try await saveFlag("hidden", hidden, for: name)
    }

    /// Pin and Hide show at once: the roster moves now, and roster reads keep the change while
    /// `saveMeta` takes it to the gateway (three calls, a minute or more on a busy Mac). A failure
    /// moves it back and throws.
    private func saveFlag(_ key: String, _ on: Bool, for name: String) async throws {
        let value: JSONValue = on ? .bool(true) : .null
        let previous = bot(named: name)?.meta.raw[key]
        let token = UUID()
        pendingFlags[name, default: [:]][key] = (value, token)
        apply(profiles, fromGateway: false)
        // Only the newest call for this flag clears it, or puts it back.
        func isOwn() -> Bool { pendingFlags[name]?[key]?.token == token }
        func release() {
            pendingFlags[name]?[key] = nil
            if pendingFlags[name]?.isEmpty == true { pendingFlags[name] = nil }
        }
        do {
            try await saveMeta(for: name) { meta in
                var meta = meta
                meta[key] = on ? .bool(true) : nil
                return meta
            }
            if isOwn() { release() }
        } catch {
            guard isOwn() else { throw error }
            release()
            var restored = profiles
            if let index = restored.firstIndex(where: { $0.name == name }) {
                restored[index].meta.raw[key] = previous
                apply(restored, fromGateway: false)
            }
            throw error
        }
    }

    /// Desktop's "New Agent": a profile, its look, then its Bot Chat with a hello.
    func createBot(_ draft: BotDraft, copySetupFromPrimary: Bool) async throws -> String {
        let slug = uniqueSlug(for: draft.title)
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: JSONValue] = [
            "name": .string(slug),
            "description": .string(role.isEmpty ? title : "\(title) — \(role)"),
            "no_skills": .bool(false),
            "share_auth": .bool(true),
            "soul": .string(Self.soul(title: title, role: role, slug: slug)),
        ]
        if copySetupFromPrimary { params["clone_from"] = .string("default") }
        _ = try await request("profiles.create", params, timeout: .seconds(120))
        let created = Date.now.timeIntervalSince1970 * 1000
        try await saveMeta(for: slug) { meta in
            var meta = meta
            meta["title"] = .string(title)
            meta["shape"] = .string(draft.shape.rawValue)
            meta["color"] = .string(draft.colorValue)
            meta["imageKind"] = .string("shape")
            meta["custom"] = .bool(true)
            meta["created"] = .number(created.rounded())
            return meta
        }
        // A fresh profile has none of the root's plugins (a copied setup has them already).
        workspace?.plugins.botCreated()
        // A Bot without a usable model would only fail its hello; skip it then.
        let check = try? await request("setup.runtime_check", ["profile": .string(slug)], timeout: .seconds(30))
        if check?["ok"]?.boolValue != false {
            conversation(for: slug).sendKickoff()
        }
        return slug
    }

    func updateBot(_ name: String, draft: BotDraft, originalRole: String?) async throws {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        try await saveMeta(for: name) { meta in
            var meta = meta
            meta["title"] = title.isEmpty ? nil : .string(title)
            // Only what the person changed: saving a new role mustn't repaint the face.
            if draft.changesShape { meta["shape"] = .string(draft.shape.rawValue) }
            if draft.changesColor { meta["color"] = .string(draft.colorValue) }
            if draft.changesShape || draft.changesColor {
                meta["custom"] = .bool(true)
                if meta["imageKind"]?.stringValue != "photo" { meta["imageKind"] = .string("shape") }
            }
            return meta
        }
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if role != (originalRole ?? "") {
            let label = title.isEmpty ? (bot(named: name)?.title ?? name) : title
            _ = try await request("profiles.configure", [
                "name": .string(name), "description": .string(role.isEmpty ? "" : "\(label) — \(role)"),
            ])
            await refresh()
        }
    }

    /// `Research Buddy` → `research-buddy`, unique on this backend.
    func uniqueSlug(for title: String) -> String {
        var base = BotMentions.slug(title)
        if base.isEmpty || !(base.first?.isLetter == true || base.first?.isNumber == true) { base = "bot" }
        base = String(base.prefix(60))
        let taken = Set(profiles.map(\.name) + profiles.flatMap(\.previousNames))
        var candidate = base
        var counter = 2
        while taken.contains(candidate) || candidate == "default" {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func soul(title: String, role: String, slug: String) -> String {
        var text = "# \(title)\n\n"
        if !role.isEmpty { text += "**Role:** \(role)\n\n" }
        text += "You are \(title), a persistent named agent (profile `\(slug)`) on this machine.\n"
        text += "You keep your own memory, skills, and conversation history across sessions."
        return text
    }

    // MARK: - Routines

    /// The Bot's routines: its cron jobs. Older backends ignore `profile`, so their
    /// lists are narrowed to jobs tagged `[bot:<name>]`.
    func routines(for name: String) async throws -> [BotRoutine] {
        let result = try await request("cron.manage", [
            "action": .string("list"), "profile": .string(name), "include_disabled": .bool(true),
        ], timeout: .seconds(90))
        try Self.checkCron(result)
        guard case .array(let jobs)? = result["jobs"] else { return [] }
        let routines = jobs.compactMap(BotRoutine.init(json:))
        return result["scoped"] == nil ? routines.filter { $0.taggedBot == name } : routines
    }

    /// The routine the gateway made (`job` in the answer), when it says.
    func addRoutine(for name: String, title: String, prompt: String, schedule: String, deliverToBotChat: Bool) async throws -> BotRoutine? {
        let result = try await request("cron.manage", [
            "action": .string("add"),
            "profile": .string(name),
            "name": .string("[bot:\(name)] \(title.trimmingCharacters(in: .whitespacesAndNewlines))"),
            "schedule": .string(schedule),
            "prompt": .string(prompt),
            "deliver": .string(deliverToBotChat ? "bot-chat" : "local"),
        ])
        try Self.checkCron(result)
        return result["job"].flatMap(BotRoutine.init(json:))
    }

    /// The routine as the gateway has it now (`job` in the answer), when it says.
    func setRoutine(_ routine: BotRoutine, paused: Bool, for name: String) async throws -> BotRoutine? {
        let result = try await request("cron.manage", [
            "action": .string(paused ? "pause" : "resume"), "profile": .string(name), "name": .string(routine.id),
        ])
        try Self.checkCron(result)
        return result["job"].flatMap(BotRoutine.init(json:))
    }

    func removeRoutine(_ routine: BotRoutine, for name: String) async throws {
        let result = try await request("cron.manage", [
            "action": .string("remove"), "profile": .string(name), "name": .string(routine.id),
        ])
        try Self.checkCron(result)
    }

    func runRoutineNow(_ routine: BotRoutine, for name: String) async throws {
        try await client.triggerRoutine(id: routine.id, profile: name)
    }

    private static func checkCron(_ result: JSONValue) throws {
        if result["success"]?.boolValue == false {
            throw HermesError.server(status: 400, code: nil, message: result["error"]?.stringValue)
        }
    }
}

/// What the New Bot and Edit Bot sheets collect.
struct BotDraft: Equatable {
    var title = ""
    var role = ""
    var shape: BotAppearance.Shape = .squircle
    var hue = 210
    /// The look the Bot had when Edit Bot opened (nil for a new Bot). Saving writes the colour or
    /// shape only when the person picked another one, so a colour between swatches, a hex colour
    /// or the one Hermes derives from the name stays as it was.
    private(set) var startHue: Int?
    private(set) var startShape: BotAppearance.Shape?

    var changesColor: Bool { hue != startHue }
    var changesShape: Bool { shape != startShape }

    /// Desktop's swatches: `hsl(H 68% 58%)` in 30° steps.
    var colorValue: String { "hsl(\(hue) 68% 58%)" }

    static let hues = Array(stride(from: 0, to: 360, by: 30))

    /// Spoken names for the swatches.
    static func colorName(_ hue: Int) -> String {
        switch hue {
        case 0: String(localized: "Red")
        case 30: String(localized: "Orange")
        case 60: String(localized: "Yellow")
        case 90: String(localized: "Lime")
        case 120: String(localized: "Green")
        case 150: String(localized: "Mint")
        case 180: String(localized: "Cyan")
        case 210: String(localized: "Sky blue")
        case 240: String(localized: "Blue")
        case 270: String(localized: "Violet")
        case 300: String(localized: "Magenta")
        default: String(localized: "Pink")
        }
    }

    init() {}

    init(bot: BotProfile, appearance: BotAppearance) {
        title = bot.title
        role = bot.role ?? ""
        shape = appearance.shape
        hue = Self.hue(of: bot.meta.color) ?? Self.nearestSwatch(Double(BotAppearance.stringHash(bot.name) % 360))
        startHue = hue
        startShape = shape
    }

    /// The hue of an `hsl(...)` value, at its nearest swatch.
    static func hue(of color: String?) -> Int? {
        guard let color, color.lowercased().hasPrefix("hsl("),
              let first = color.dropFirst(4).split(whereSeparator: { " ,".contains($0) }).first, let value = Double(first)
        else { return nil }
        return nearestSwatch(value)
    }

    /// 345° is red (0°), not pink (330°): the nearest swatch, not the one below.
    static func nearestSwatch(_ hue: Double) -> Int {
        let degrees = (Int(hue.rounded()) % 360 + 360) % 360
        return (degrees + 15) / 30 * 30 % 360
    }
}
