import Foundation
import HermesKit
import Network
import Observation

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
    }

    private(set) var link: BackendLink
    private(set) var state: State = .idle
    /// Every Bot as `profiles.list` reports it.
    private(set) var profiles: [BotProfile] = []
    /// Pinned first, then most recently active or created. Rebuilt only when the roster changes.
    private(set) var visibleBots: [BotProfile] = []
    private(set) var hiddenBots: [BotProfile] = []
    private(set) var hasLoaded = false
    /// Bots with activity the person hasn't seen (keyed by profile name).
    private(set) var unread: Set<String> = []
    /// Wrote in the last 90 s, or a worker beat in the last 150 s (refreshed every poll).
    private(set) var activeNames: Set<String> = []
    /// A background worker of theirs beat in the last 150 s.
    private(set) var workingNames: Set<String> = []
    /// Photo avatars, as `FaceImageCache` keys, by profile name.
    private(set) var photos: [String: String] = [:]
    /// The Bot Chat on screen, which never counts as unread.
    var openBot: String? {
        didSet {
            if let openBot { markRead(openBot) }
        }
    }

    /// Sheets, shared by the sidebar and the chat toolbar.
    var editingBot: String?
    var routinesBot: String?
    var isCreatingBot = false

    @ObservationIgnored let botID: UUID
    @ObservationIgnored private let store: BotStore
    @ObservationIgnored private var client: BackendClient
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

    /// Every chat this socket serves: the Bot Chats and the attached normal chats.
    private var allConversations: [ConversationModel] {
        Array(conversations.values) + gatewayChats.values.compactMap(\.value)
    }
    @ObservationIgnored private var photoRevisions: [String: Int] = [:]
    @ObservationIgnored private var photoTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var index: [String: BotProfile] = [:]
    @ObservationIgnored private var watermarks: [String: Double]
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var connectedAt: Date?
    /// When a working connection dropped: the first moments after that are "Reconnecting…", not "offline".
    @ObservationIgnored private var droppedAt: Date?
    @ObservationIgnored private var version: String?
    @ObservationIgnored private var isTornDown = false
    /// The app is in the background: no polling, no reconnect loop.
    @ObservationIgnored private var isInBackground = false
    /// Watches the device's network so a new or returning route reconnects at once.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
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
    }

    private static func makeClient(botID: UUID, link: BackendLink, store: BotStore) -> BackendClient {
        BackendClient(baseURL: link.url, credential: store.backendCredential(for: botID)) { credential in
            // The gate refreshes cookies on use; keep the newest pair.
            try? store.setBackendCredential(credential, for: botID)
        }
    }

    private static func watermarkKey(_ id: UUID) -> String { "botWatermarks.\(id.uuidString)" }

    // MARK: - Roster

    private static func rosterOrder(_ a: BotProfile, _ b: BotProfile) -> Bool {
        if a.meta.isPinned != b.meta.isPinned { return a.meta.isPinned }
        if a.recency != b.recency { return a.recency > b.recency }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    func bot(named name: String) -> BotProfile? {
        // `index` isn't observed: read `profiles`, which changes with it, so a view that looked a
        // Bot up before the roster arrived (the Bot Chat title) redraws when it does.
        access(keyPath: \.profiles)
        return index[name]
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
    func chatIsWorking(_ name: String) -> Bool {
        conversations[name]?.isWorking ?? false
    }

    /// What its running turn is doing ("Running a command…"), when one runs here.
    func workingStatus(_ name: String) -> String? {
        guard let conversation = conversations[name], conversation.isWorking else { return nil }
        return conversation.liveStatus
    }

    /// Thinking in its Bot Chat here, or a background worker of its is beating.
    func isBusy(_ name: String) -> Bool {
        conversations[name]?.isWorking == true || workingNames.contains(name)
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
        connectIfNeeded()
    }

    func connectIfNeeded() {
        guard !isTornDown, socket == nil, connectTask == nil else { return }
        watchNetwork()
        startConnect()
    }

    /// Connect now, skipping any backoff wait: the person asked (Retry, Reload), or the
    /// network just came back.
    func retryNow() {
        guard !isTornDown, !isInBackground, socket == nil else { return }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        if connectTask == nil { startConnect() }
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // Wi-Fi ↔ cellular, a VPN or Tailscale coming up: each is a different route.
            let signature = path.status == .satisfied
                ? "up:" + path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
                : "down"
            Task { @MainActor in self?.networkChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "hermes.roster.network", qos: .utility))
        pathMonitor = monitor
    }

    /// The route changed. Without a socket, connect at once; with one, prove it still works:
    /// a socket opened over the old route usually dies without a close and would otherwise
    /// look healthy until the heartbeat gives up on it.
    private func networkChanged(_ signature: String) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature, signature != "down" else { return }
        guard !isTornDown, !isInBackground else { return }
        if let socket {
            reconnectAttempts = 0
            Task { _ = await socket.probe(timeout: .seconds(3)) }
        } else {
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            // An attempt started on the dead route can hang until it times out; start over.
            startConnect()
        }
    }

    /// One tracked connect at a time; a superseded attempt discards what it opened.
    private func startConnect() {
        connectTask?.cancel()
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task { [weak self] in
            await self?.connect(generation: generation)
            if self?.connectGeneration == generation { self?.connectTask = nil }
        }
    }

    private func connect(generation: Int) async {
        reconnectTask?.cancel()
        if !state.isOnline { state = .connecting }
        func isCurrent() -> Bool { generation == connectGeneration && !Task.isCancelled && !isTornDown }
        do {
            let status = try await client.status()
            guard isCurrent() else { return }
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
            version = status.version
            connectedAt = .now
            droppedAt = nil
            state = .online(version: status.version)
            startPump(socket)
            await refresh()
            guard isCurrent() else { return }
            startPolling()
            for conversation in allConversations {
                conversation.botChatReconnected()
            }
        } catch is CancellationError {
        } catch {
            guard isCurrent() else { return }
            handleConnectFailure(error)
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
        // A blip (a tunnel, a Wi-Fi handover, a backend restart) usually heals in seconds: keep
        // saying "Reconnecting…" for a while before calling the Bots offline.
        if hasLoaded, let droppedAt, Date.now.timeIntervalSince(droppedAt) < Self.reconnectGrace {
            state = .connecting
        } else {
            state = .failed(Self.describe(error))
        }
        scheduleReconnect()
    }

    static let reconnectGrace: TimeInterval = 20

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
        guard !isTornDown, !isInBackground else { return }
        reconnectTask?.cancel()
        reconnectAttempts += 1
        // 0.5, 1, 2, 4, 8, then every 15 s, with jitter so devices don't reconnect in lockstep.
        let base = min(15, 0.5 * pow(2, Double(min(reconnectAttempts - 1, 5))))
        let delay = base * Double.random(in: 0.8...1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connectIfNeeded()
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
        pathMonitor?.cancel()
        pathMonitor = nil
        disconnect()
        conversations.values.forEach { $0.cancelAll() }
        for chat in gatewayChats.values.compactMap(\.value) { chat.botChatConnectionLost() }
        gatewayChats = [:]
    }

    /// The app went to the background: stop polling and reconnecting until it's back.
    func didEnterBackground() {
        isInBackground = true
        pollTask?.cancel()
        pollTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Back in the foreground but not on screen (another gateway is): just resume polling.
    func resume() {
        guard isInBackground, !isTornDown else { return }
        isInBackground = false
        if socket != nil { startPolling() } else { connectIfNeeded() }
    }

    /// Back in the foreground: suspended sockets are usually dead.
    func didBecomeActive() {
        guard !isTornDown else { return }
        isInBackground = false
        reconnectAttempts = 0
        if let socket {
            Task {
                // A ping, not the socket's own idea of being open: after a suspension it often isn't.
                if await socket.probe(timeout: .seconds(3)) {
                    await refresh()
                    if self.pollTask == nil, self.socket === socket { self.startPolling() }
                }
                // A failed probe closes the socket; the pump sees it and reconnects.
            }
        } else {
            retryNow()
        }
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
        } else {
            // terminal.read, preview.*, window.read, tour: desktop-only surfaces.
            await socket.decline(request.id)
        }
    }

    private func socketClosed(_ error: (any Error)?, socket closed: GatewaySocket) {
        guard socket === closed else { return }
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
        guard let socket else { throw GatewaySocket.Failure.notConnected }
        return try await socket.request(method, params, timeout: timeout)
    }

    func respond(to requestID: String, result: JSONValue) async {
        await socket?.respond(to: requestID, result: result)
    }

    func transcript(storedSessionID: String, profile: String) async throws -> SessionTranscript {
        try await client.transcript(storedSessionID: storedSessionID, profile: profile)
    }

    var isConnected: Bool { socket != nil && state.isOnline }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var quietPolls = 0
            while !Task.isCancelled {
                // Desktop's 5 s while things move, 10 s once the roster has sat still for
                // half a minute, 15 s in Low Power Mode.
                let interval: Double = PowerState.shared.isLowPower ? 15 : (quietPolls >= 6 ? 10 : 5)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                let before = self.profiles
                await self.refresh()
                quietPolls = self.profiles == before ? quietPolls + 1 : 0
            }
        }
    }

    /// Reads the roster (`profiles.list`), the way Desktop polls it every five seconds.
    func refresh() async {
        guard socket != nil else { return }
        do {
            let result = try await request("profiles.list", [:], timeout: .seconds(30))
            guard case .array(let rows)? = result["profiles"] else { return }
            apply(rows.map(BotProfile.init(json:)).filter { !$0.name.isEmpty })
            await groupRooms.refresh()
        } catch is CancellationError {
        } catch {
            if !hasLoaded { state = .failed(Self.describe(error)) }
        }
    }

    private func apply(_ fresh: [BotProfile]) {
        let previous = index
        if fresh != profiles {
            profiles = fresh
            index = Dictionary(fresh.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let visible = fresh.filter { !$0.meta.isHidden }.sorted(by: Self.rosterOrder)
            let hidden = fresh.filter(\.meta.isHidden).sorted(by: Self.rosterOrder)
            if visible != visibleBots { visibleBots = visible }
            if hidden != hiddenBots { hiddenBots = hidden }
        }
        if !hasLoaded { hasLoaded = true }
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
        updateUnread()
        loadPhotos()
        for bot in fresh {
            guard let conversation = conversations[bot.name] else { continue }
            conversation.botRosterChanged(bot, previous: previous[bot.name])
        }
    }

    // MARK: - Unread

    /// Client-side, like Desktop: a Bot's activity watermark is seeded on first sight;
    /// a later advance while its chat isn't open makes it unread.
    private func updateUnread() {
        var marks = watermarks
        var next = unread
        for bot in profiles {
            guard let active = bot.lastActive?.timeIntervalSince1970 else { continue }
            guard let seen = marks[bot.name] else {
                marks[bot.name] = active
                continue
            }
            if active > seen + 0.5 {
                if bot.name == openBot {
                    marks[bot.name] = active
                } else {
                    next.insert(bot.name)
                }
            }
        }
        next.formIntersection(profiles.map(\.name))
        if next != unread { unread = next }
        if marks != watermarks {
            watermarks = marks
            UserDefaults.standard.set(marks, forKey: Self.watermarkKey(botID))
        }
    }

    func markRead(_ name: String) {
        if unread.contains(name) { unread.remove(name) }
        guard let active = bot(named: name)?.lastActive?.timeIntervalSince1970 else { return }
        if (watermarks[name] ?? 0) < active {
            watermarks[name] = active
            UserDefaults.standard.set(watermarks, forKey: Self.watermarkKey(botID))
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
        Task {
            await refresh()
            if openBot == name { markRead(name) }
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
        try await saveMeta(for: name) { meta in
            var meta = meta
            meta["pinned"] = pinned ? .bool(true) : nil
            return meta
        }
    }

    func setHidden(_ name: String, _ hidden: Bool) async throws {
        try await saveMeta(for: name) { meta in
            var meta = meta
            meta["hidden"] = hidden ? .bool(true) : nil
            return meta
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
            meta["shape"] = .string(draft.shape.rawValue)
            meta["color"] = .string(draft.colorValue)
            meta["custom"] = .bool(true)
            if meta["imageKind"]?.stringValue != "photo" { meta["imageKind"] = .string("shape") }
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

    func addRoutine(for name: String, title: String, prompt: String, schedule: String, deliverToBotChat: Bool) async throws {
        let result = try await request("cron.manage", [
            "action": .string("add"),
            "profile": .string(name),
            "name": .string("[bot:\(name)] \(title.trimmingCharacters(in: .whitespacesAndNewlines))"),
            "schedule": .string(schedule),
            "prompt": .string(prompt),
            "deliver": .string(deliverToBotChat ? "bot-chat" : "local"),
        ])
        try Self.checkCron(result)
    }

    func setRoutine(_ routine: BotRoutine, paused: Bool, for name: String) async throws {
        let result = try await request("cron.manage", [
            "action": .string(paused ? "pause" : "resume"), "profile": .string(name), "name": .string(routine.id),
        ])
        try Self.checkCron(result)
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
        hue = Self.hue(of: bot.meta.color) ?? Int(BotAppearance.stringHash(bot.name) % 360) / 30 * 30
    }

    /// The hue of an `hsl(...)` value, snapped to a swatch.
    static func hue(of color: String?) -> Int? {
        guard let color, color.lowercased().hasPrefix("hsl("),
              let first = color.dropFirst(4).split(whereSeparator: { " ,".contains($0) }).first, let value = Double(first)
        else { return nil }
        return (Int(value.rounded()) % 360) / 30 * 30
    }
}
