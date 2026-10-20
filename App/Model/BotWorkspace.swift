import Foundation
import HermesKit
import Observation

/// What the main area shows.
enum SidebarItem: Hashable {
    /// A conversation, keyed by its stable key (survives compression).
    case session(String)
    case tasks
    case skills
    /// A Bot's Bot Chat, keyed by profile name.
    case bot(String)
    /// A hosted group chat, keyed by room id.
    case group(String)
    /// A project's home, keyed by project id (`docs/projects.md`).
    case project(String)
    /// A project's Board, keyed by project id (`docs/board.md`).
    case board(String)
    /// All Projects.
    case allProjects

    /// As a string for `SceneStorage`: what a window showed, restored when it opens again.
    var storedValue: String {
        switch self {
        case .session(let key): "session:\(key)"
        case .tasks: "tasks"
        case .skills: "skills"
        case .bot(let name): "bot:\(name)"
        case .group(let id): "group:\(id)"
        case .project(let id): "project:\(id)"
        case .board(let id): "board:\(id)"
        case .allProjects: "allProjects"
        }
    }

    init?(storedValue: String) {
        let parts = storedValue.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("session", let key?): self = .session(key)
        case ("tasks", _): self = .tasks
        case ("skills", _): self = .skills
        case ("bot", let name?): self = .bot(name)
        case ("group", let id?): self = .group(id)
        case ("project", let id?): self = .project(id)
        case ("board", let id?): self = .board(id)
        case ("allProjects", _): self = .allProjects
        default: return nil
        }
    }
}

/// The sidebar's two halves, like Hermes Desktop's Sessions and Bots modes.
enum SidebarMode: String {
    case chats, bots
}

/// Everything the app knows about one Hermes gateway.
@MainActor
@Observable
final class BotWorkspace: Identifiable {
    enum Connection: Equatable {
        case idle
        case connecting
        case online(version: String?)
        case failed(HermesError)

        var isOnline: Bool {
            if case .online = self { true } else { false }
        }

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }
    }

    let id: UUID
    private(set) var bot: BotConfiguration
    private(set) var client: HermesClient?
    let imageStore: SentImageStore

    private(set) var connection: Connection = .idle {
        didSet {
            guard connection != oldValue else { return }
            ConnectionLog.logger.notice("gateway \(self.bot.name, privacy: .public): \(String(describing: self.connection), privacy: .public)")
            // What another version's deliveries showed doesn't hold for this one.
            if case .online(let version?) = connection, let record = deliveryProtection, record.version != version {
                noteDeliveries([])
            }
        }
    }
    private(set) var capabilities: ServerCapabilities?
    /// The gateway answers its health check but takes ages over everything else (its Mac is
    /// overloaded): still connected, and the status line says why things are slow.
    private(set) var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            ConnectionLog.logger.notice("gateway \(self.bot.name, privacy: .public): \(self.isBusy ? "busy" : "no longer busy", privacy: .public)")
        }
    }
    /// The last sign the Mac was busy. "Busy" clears only after half a minute without one: a starved
    /// Mac answers quickly for the moment it runs, then goes quiet again.
    @ObservationIgnored private var lastSlowAt = Date.distantPast
    private static let busyLingers: TimeInterval = 30
    /// Requests running under `watchingForBusy`: a quick health check doesn't clear "busy" while
    /// one of them is still slow.
    @ObservationIgnored private var watchedRequests = 0
    /// Only an answer this quick clears "busy": a starved Mac answers in bursts, and an answer that
    /// took longer is the busy Mac itself.
    private static let quickAnswer: Duration = .seconds(5)
    @ObservationIgnored private var busyRetry: Task<Void, Never>?
    private(set) var sessions: [HermesSession] = [] {
        didSet {
            sessionsByKey = Dictionary(sessions.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
            unread.update()
            keepSessions()
        }
    }
    @ObservationIgnored private var sessionsSave: Task<Void, Never>?

    /// The list as it stands goes on the device a moment after it changes (a deleted, archived or
    /// renamed chat as well as a fresh read), so a cold launch never brings back what's gone.
    private func keepSessions() {
        guard hasFetchedSessions else { return }
        sessionsSave?.cancel()
        sessionsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            if self.sessions.isEmpty {
                SessionsCache.remove(self.id)
            } else {
                SessionsCache.save(self.id, sessions: self.sessions)
            }
        }
    }
    /// `sessions` by stable key: rows ask for theirs as they draw, and a walk through a few
    /// hundred chats per row added up.
    @ObservationIgnored private var sessionsByKey: [String: HermesSession] = [:]
    /// What's new in this gateway's chats and Bots (`docs/inbox.md` §1).
    let unread: UnreadStore
    /// What they're doing right now (`docs/inbox.md` §2).
    let activity = LiveActivity()
    /// Agent widgets in this gateway's chats (`docs/widgets.md` §4).
    let widgets: WidgetStore
    /// Whether this Hermes keeps a Bot's message to another Bot going when the sender's chat
    /// closes, as its deliveries showed (`DeliveryProtection`, Settings → Setup): nil until a
    /// delivery has been seen on the current version. Kept per gateway on the device.
    private(set) var deliveryProtection: DeliveryProtection?
    /// The chat list's filter (`docs/inbox.md` §5).
    var inboxFilter = InboxFilter.all
    /// A chat just archived from the list, for Undo.
    var recentlyArchived: HermesSession?
    /// Archive calls on their way, by chat: Undo goes after its archive, never alongside it.
    @ObservationIgnored private var archiving: [String: Task<Void, any Error>] = [:]
    private(set) var isLoadingSessions = false
    private(set) var hasMoreSessions = false
    /// Server-side paging position. Pinned rows are back-filled outside the page, so
    /// `sessions.count` can't be used as the next offset.
    @ObservationIgnored private var nextSessionOffset = 0
    /// The gateway's chat list arrived this launch: the device's copy never goes over it.
    @ObservationIgnored private var hasFetchedSessions = false
    private(set) var modelOptions: ModelOptions?
    /// The "/" menu's skills and commands, per profile.
    @ObservationIgnored private var slashCatalogs: [String: SlashCatalog] = [:]

    /// A chat's processes were listed: a delivery to another Bot among them says whether this
    /// Hermes's deliveries outlive the sender's chat. A new Hermes version starts over.
    func noteDeliveries(_ processes: [BackgroundProcess]) {
        guard case .online(let version?) = connection else { return }
        let next = DeliveryProtection.updated(deliveryProtection, seen: DeliveryProtection.seen(in: processes, version: version), version: version)
        guard next != deliveryProtection else { return }
        deliveryProtection = next
        let defaults = UserDefaults.standard
        if let next, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.deliveryProtectionKey(id))
        } else {
            defaults.removeObject(forKey: Self.deliveryProtectionKey(id))
        }
    }

    private static func deliveryProtectionKey(_ id: UUID) -> String { "deliveryProtection.\(id.uuidString)" }

    func slashCatalog(profile: String?) -> SlashCatalog {
        let key = profile ?? "default"
        if let catalog = slashCatalogs[key] { return catalog }
        let catalog = SlashCatalog()
        slashCatalogs[key] = catalog
        return catalog
    }
    private(set) var isRefreshingModels = false

    /// `nil` shows the new-chat draft.
    var selection: SidebarItem? {
        willSet {
            // How far the chat was read, before opening it marks anything read (`docs/inbox.md` §4).
            let key: String? = switch newValue {
            case .session(let key): key
            case .bot(let name): UnreadStore.botKey(name)
            default: nil
            }
            if let key, newValue != selection { unread.noteOpening(key) }
        }
        didSet {
            if case .bot(let name) = selection {
                roster?.openBot = name
            } else if roster?.openBot != nil {
                roster?.openBot = nil
            }
            if case .session(let key) = selection { lastChatKey = key }
            if selection == nil { lastChatKey = nil }
            if let key = unread.openKey {
                activity.opened(key)
                // Marked unread by hand: opening it clears the dot (`docs/inbox.md` §4).
                if unread.badge(for: key) == .dot || unread.readMark(for: key) == .markedUnread { unread.markRead(key) }
            }
            unread.update()
        }
    }
    /// The chat open last (Skills' Use adds to its tray; `nil`: the new-chat draft).
    @ObservationIgnored private(set) var lastChatKey: String?

    /// Use on a skill (`docs/bots-groups-skills.md`): the skill goes in the tray of the chat that
    /// was open, or of a new chat.
    func use(_ skill: Skill) {
        sidebarMode = .chats
        let target: ConversationModel
        if let key = lastChatKey, conversations[key] != nil {
            selection = .session(key)
            target = conversation(forKey: key)
        } else {
            startNewChat()
            target = draft
        }
        if target.usesGateway {
            if !target.skills.contains(skill.name), target.skills.count < MessageParts.maxSkills {
                target.skills.append(skill.name)
            }
        } else if target.draft.isEmpty {
            target.draft = "Use the \(skill.name) skill to "
        }
    }
    var searchText = ""
    /// What Hermes Learned is open over Skills (iPhone, iPad), or chosen in Skills → Library |
    /// Learned (Mac).
    var showsLearned = false {
        didSet {
            guard !showsLearned else { return }
            learnedScope = .hermes
            pendingLearnedRoute = nil
        }
    }
    /// Whose learning it shows: Hermes's, or a Bot's when a notification was about one.
    var learnedScope = MemoryModel.Scope.hermes
    /// The page What Hermes Learned opens on once it has loaded (a tidy's notification → Tidying).
    var pendingLearnedRoute: LearnedRoute?
    /// Skills opens filtered to this skill (Show Skill on a skill chip).
    var pendingSkillQuery: String?
    /// A gateway file opened from its pill.
    var openedFile: GatewayFile?
    /// Bot Mode, when this gateway has a Hermes backend linked.
    private(set) var roster: BotRoster?
    var sidebarMode: SidebarMode {
        didSet {
            guard sidebarMode != oldValue else { return }
            UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarMode.\(id.uuidString)")
            // Each mode remembers what it last showed.
            selectionByMode[oldValue] = selection
            selection = selectionByMode[sidebarMode] ?? nil
            searchText = ""
        }
    }
    @ObservationIgnored private var selectionByMode: [SidebarMode: SidebarItem?] = [:]
    /// A conversation waiting for its first message.
    private(set) var draft: ConversationModel!
    /// Talk was asked for before its chat was on screen (a project home's composer).
    @ObservationIgnored var voiceModeRequested = false
    /// Bumped by Chat → Talk (⌥⌘V): the open chat starts or ends a call.
    var voiceToggleRequests = 0
    /// This gateway's projects (Bot Mode backends only).
    private(set) var projects: ProjectsModel!
    @ObservationIgnored private var pinStore: InspectorPins?
    /// Inspector tabs pinned across this gateway's chats (`docs/inspector.md` §1).
    var inspectorPins: InspectorPins {
        if let pinStore { return pinStore }
        let pins = InspectorPins(workspaceID: id)
        pinStore = pins
        return pins
    }
    @ObservationIgnored private var boardModels: [String: BoardModel] = [:]
    /// A project's Board (`docs/board.md`), one per project for as long as the gateway is open.
    func board(for projectID: String) -> BoardModel {
        if let model = boardModels[projectID] { return model }
        let model = BoardModel(workspace: self, projectID: projectID)
        boardModels[projectID] = model
        return model
    }

    /// The project on screen: its home, its Board, or a chat in it (⇧⌘B opens its Board).
    var currentProjectID: String? {
        switch selection {
        case .project(let id), .board(let id): id
        case .session(let key): projects?.projectID(forSessionID: key)
        default: nil
        }
    }

    /// Opens a card (a notification, a link): its project's board with the card open. Without the
    /// project, the gateway's boards say which project the board belongs to.
    func openCard(_ cardID: String, board slug: String?, projectID: String?) {
        sidebarMode = .chats
        if let projectID {
            selection = .board(projectID)
            board(for: projectID).openCardID = cardID
            return
        }
        guard let slug, let client = roster?.boardClient else { return }
        Task {
            guard let info = try? await client.boards().first(where: { $0.slug == slug }), let projectID = info.projectID else { return }
            selection = .board(projectID)
            board(for: projectID).openCardID = cardID
        }
    }

    /// Opens What Hermes Learned (a notification after a tidy): Skills → Learned, on `route`, for
    /// a Bot's skills when it names one.
    func openLearned(_ route: LearnedRoute?, bot: String?) {
        sidebarMode = .chats
        selection = .skills
        showsLearned = true
        learnedScope = bot.map { .bot($0) } ?? .hermes
        pendingLearnedRoute = route
    }

    /// The Board on screen, if one is.
    var shownBoard: BoardModel? {
        if case .board(let id) = selection { board(for: id) } else { nil }
    }

    @ObservationIgnored private var appsAndToolsModel: AppsAndToolsModel?
    /// What Hermes on this gateway can reach: Settings → Apps and Tools.
    var appsAndTools: AppsAndToolsModel {
        if let appsAndToolsModel { return appsAndToolsModel }
        let model = AppsAndToolsModel(workspace: self)
        appsAndToolsModel = model
        return model
    }
    @ObservationIgnored private var appPluginsModel: AppPluginsModel?
    /// The app's own Hermes plugins on this gateway (`docs/plugins.md` §2).
    var plugins: AppPluginsModel {
        if let appPluginsModel { return appPluginsModel }
        let model = AppPluginsModel(workspace: self)
        appPluginsModel = model
        return model
    }
    @ObservationIgnored private var pluginHubModel: PluginHubModel?
    /// Apps and Tools → Plugins: offers, the catalog and catalog installs (`docs/plugins.md` §4).
    var pluginHub: PluginHubModel {
        if let pluginHubModel { return pluginHubModel }
        let model = PluginHubModel(workspace: self)
        pluginHubModel = model
        return model
    }
    @ObservationIgnored private var setupCenter: SetupCenter?
    /// What on this gateway needs setting up: Settings → Setup (`docs/setup.md` §3).
    var setup: SetupCenter {
        if let setupCenter { return setupCenter }
        let model = SetupCenter(workspace: self)
        setupCenter = model
        return model
    }
    @ObservationIgnored private var chatSearchModel: ChatSearch?
    /// Searching this gateway's chats by what was said (`docs/search.md`).
    var search: ChatSearch {
        if let chatSearchModel { return chatSearchModel }
        let model = ChatSearch(workspace: self)
        chatSearchModel = model
        return model
    }
    /// A project home's composer: the next chat in that project, by project id.
    @ObservationIgnored private var projectDrafts: [String: ConversationModel] = [:]

    private(set) var preferredModel: ModelSelection?
    private(set) var preferredEffort: ReasoningEffort?

    @ObservationIgnored private var conversations: [String: ConversationModel] = [:]
    @ObservationIgnored private var titleRefreshTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private let store: BotStore

    init(bot: BotConfiguration, apiKey: String?, store: BotStore) {
        self.id = bot.id
        self.bot = bot
        self.store = store
        self.imageStore = SentImageStore(botID: bot.id)
        self.unread = UnreadStore(gatewayID: bot.id)
        self.widgets = WidgetStore(gatewayID: bot.id)
        if let apiKey, !apiKey.isEmpty {
            client = HermesClient(baseURL: bot.baseURL, apiKey: apiKey)
        }
        deliveryProtection = UserDefaults.standard.data(forKey: Self.deliveryProtectionKey(bot.id))
            .flatMap { try? JSONDecoder().decode(DeliveryProtection.self, from: $0) }
        let savedMode = UserDefaults.standard.string(forKey: "sidebarMode.\(bot.id.uuidString)").flatMap(SidebarMode.init(rawValue:))
        sidebarMode = bot.backend == nil ? .chats : (savedMode ?? .bots)
        if let link = bot.backend {
            roster = BotRoster(botID: bot.id, link: link, store: store)
        }
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "model.\(bot.id.uuidString)") {
            preferredModel = try? JSONDecoder().decode(ModelSelection.self, from: data)
        }
        preferredEffort = defaults.string(forKey: "effort.\(bot.id.uuidString)").flatMap(ReasoningEffort.init(rawValue:))
        draft = ConversationModel(workspace: self)
        projects = ProjectsModel(workspace: self)
        roster?.workspace = self
        unread.workspace = self
        activity.workspace = self
        widgets.workspace = self
        restoreCachedSessions()
        restoreCachedModels()
    }

    /// The model list this device saw last: the model picker opens on it instead of "Loading
    /// models…" while a busy Mac reads its providers (`ModelOptionsCache`).
    private func restoreCachedModels() {
        let endpoint = bot.baseURL
        Task { [weak self, id] in
            guard let data = await ModelOptionsCache.load(id), let options = try? ModelOptions.read(data), let self,
                  self.modelOptions == nil, self.bot.baseURL == endpoint else { return }
            self.modelOptions = options
        }
    }

    /// The chat list this device saw last, shown until the gateway's arrives: a busy Mac can take
    /// minutes over it, and a cold launch meanwhile showed an empty sidebar (`SessionsCache`).
    private func restoreCachedSessions() {
        let endpoint = bot.baseURL
        Task { [weak self, id] in
            guard let cached = await SessionsCache.load(id), let self,
                  !self.hasFetchedSessions, self.sessions.isEmpty, self.bot.baseURL == endpoint else { return }
            self.sessions = cached
            self.nextSessionOffset = cached.count
        }
    }

    /// Applies edited settings; reconnects when the address or key changed.
    func update(bot: BotConfiguration, apiKey: String?, keyChanged: Bool, backendSignInChanged: Bool = false) {
        let endpointChanged = bot.baseURL != self.bot.baseURL || keyChanged
        updateBackend(bot.backend, signInChanged: backendSignInChanged)
        self.bot = bot
        guard endpointChanged else { return }
        client = (apiKey?.isEmpty ?? true) ? nil : HermesClient(baseURL: bot.baseURL, apiKey: apiKey ?? "")
        conversations.values.forEach { $0.cancelAll() }
        conversations = [:]
        selection = nil
        draft = ConversationModel(workspace: self)
        hasFetchedSessions = false
        sessions = []
        SessionsCache.remove(id)
        ModelOptionsCache.remove(id)
        nextSessionOffset = 0
        modelOptions = nil
        connection = .idle
        Task { await connect() }
    }

    private func updateBackend(_ link: BackendLink?, signInChanged: Bool) {
        switch (roster, link) {
        case (nil, let link?):
            let roster = BotRoster(botID: id, link: link, store: store)
            roster.workspace = self
            self.roster = roster
            sidebarMode = .bots
            roster.connectIfNeeded()
        case (let roster?, nil):
            roster.tearDown()
            self.roster = nil
            sidebarMode = .chats
            if case .bot = selection { selection = nil }
        case (let roster?, let link?):
            if link != roster.link {
                roster.update(link: link)
            } else if signInChanged {
                Task { await roster.reconnectNow() }
            }
        case (nil, nil):
            break
        }
    }

    // MARK: - Conversations

    /// The conversation the main area shows.
    var currentConversation: ConversationModel {
        switch selection {
        case .session(let key):
            return conversation(forKey: key)
        case .bot(let name):
            if let roster { return roster.conversation(for: name) }
            return draft
        default:
            return draft
        }
    }

    /// A chat this window already has open, by its id (an Inspector tab's own window).
    /// A chat's conversation if this launch opened it (never creates one).
    func loadedConversation(forKey key: String) -> ConversationModel? {
        conversations[key]
    }

    func loadedConversation(id: UUID) -> ConversationModel? {
        if draft?.id == id { return draft }
        if let found = conversations.values.first(where: { $0.id == id }) { return found }
        return roster?.loadedConversation(id: id)
    }

    /// The gateway is there, answering its health check or too busy to (`GatewayLiveness`): its
    /// machine is up and reachable (`BotRoster` keeps a quiet Bot Mode socket open meanwhile,
    /// since the dashboard on it is only frozen).
    func gatewayAnswers() async -> Bool {
        guard let client else { return false }
        return (try? await client.liveness())?.isThere ?? false
    }

    func conversation(forKey key: String) -> ConversationModel {
        if let existing = conversations[key] { return existing }
        let session = sessions.first { $0.stableID == key } ?? HermesSession(id: key)
        let conversation = ConversationModel(workspace: self, session: session)
        conversations[key] = conversation
        return conversation
    }

    /// The chats to keep current while the app is away: the one on screen, the Bots' own chats and
    /// the most recent chats in the list, at most 20 (`docs/notifications.md` §2).
    func chatsToKeepCurrent(showing: Bool) -> [String] {
        var chats: [String] = []
        if showing, let chat = currentConversation.sessionID { chats.append(chat) }
        for bot in roster?.visibleBots ?? [] {
            if let chat = bot.canonicalSession?.resolvedID { chats.append(chat) }
        }
        chats += sessions.prefix(5).map(\.id)
        var seen: Set<String> = []
        return Array(chats.filter { seen.insert($0).inserted }.prefix(20))
    }

    /// Chats a background push said changed (`sync`): each is read over HTTP and kept on the device,
    /// with the chat list, so the app shows them as they are when the person comes back. Gives up
    /// after `limit`, inside the time iOS allows (`docs/notifications.md` §2).
    func keepCurrent(chats: [String], within limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.read(chats: chats) }
            group.addTask { try? await Task.sleep(for: limit) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func read(chats: [String]) async {
        await roster?.readyForHTTP()
        // Woken from scratch: the Bots come from the device's copy, the chat list from the gateway.
        for _ in 0..<10 where roster?.profiles.isEmpty == true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let listed = !sessions.isEmpty
        if !listed { await refreshSessions() }
        var seen: Set<ObjectIdentifier> = []
        let models = chats.compactMap(conversationToKeepCurrent).filter { seen.insert(ObjectIdentifier($0)).inserted }
        await withTaskGroup(of: Void.self) { group in
            for model in models {
                group.addTask { await model.readForSync() }
            }
            if listed { group.addTask { await self.refreshSessions() } }
        }
    }

    /// A Bot's own chat, a chat open here, or one in the list; never a new one for an id it can't place.
    private func conversationToKeepCurrent(_ chat: String) -> ConversationModel? {
        if let roster, let bot = roster.botChats[chat] { return roster.conversation(for: bot) }
        if let open = conversations.values.first(where: { $0.sessionID == chat }) { return open }
        guard let session = sessions.first(where: { $0.id == chat || $0.stableID == chat }) else { return nil }
        return conversation(forKey: session.stableID)
    }

    func session(forKey key: String) -> HermesSession? {
        _ = sessions // whoever asks follows the list, as before
        return sessionsByKey[key]
    }

    func isWorking(sessionKey key: String) -> Bool {
        conversations[key]?.isWorking ?? false
    }

    /// Chats the app follows live, by inbox key (`UnreadStore`): opened chats and Bot Chats.
    var attachedConversations: [(String, ConversationModel)] {
        var all = conversations.map { ($0.key, $0.value) }
        if let roster {
            all += roster.botConversations.map { (UnreadStore.botKey($0.key), $0.value) }
        }
        return all
    }

    /// The inbox key of a stored session Hermes names (`session.active_list`): a Bot's chat, or
    /// one of this gateway's chats (by its stable key, which survives compression).
    func unreadKey(forStoredSession id: String) -> String {
        if let roster, let bot = roster.profiles.first(where: { $0.canonicalSession?.id == id || $0.canonicalSession?.resolvedID == id }) {
            return UnreadStore.botKey(bot.name)
        }
        return sessions.first { $0.id == id || $0.stableID == id }?.stableID ?? id
    }

    /// The sidebar's rows in order: the group chats and Bots in Bots mode, else the chats.
    var sidebarOrder: [SidebarItem] {
        if sidebarMode == .bots, let roster {
            return roster.groupRooms.rooms.map { .group($0.id) } + roster.visibleBots.map { .bot($0.name) }
        }
        return inboxSessions.map { .session($0.stableID) }
    }

    /// Next / Previous Conversation: moves the selection along the sidebar.
    func selectAdjacent(_ step: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        if let selection, let index = order.firstIndex(of: selection) {
            self.selection = order[min(max(index + step, 0), order.count - 1)]
        } else {
            self.selection = step > 0 ? order.first : order.last
        }
    }

    /// Starts a fresh chat, reusing the current draft if it is still untouched. It runs where
    /// Run In last pointed (the active project), unless a project is given.
    /// Tell Hermes Something to Remember… (`docs/memory.md` §1): a new chat, or the Bot's chat,
    /// with "Remember that " typed. Hermes saves it with its memory tool.
    func startRememberChat(bot name: String?) {
        let prompt = String(localized: "Remember that ")
        if let name, let roster, roster.bot(named: name)?.isDefault != true {
            sidebarMode = .bots
            selection = .bot(name)
            let chat = roster.conversation(for: name)
            if chat.draft.isEmpty { chat.draft = prompt }
        } else {
            sidebarMode = .chats
            startNewChat()
            draft.draft = prompt
        }
    }

    /// A new chat with `prompt` typed, not sent (setup's "Ask about Studio Mac", the checklist).
    func startChat(typing prompt: String) {
        sidebarMode = .chats
        startNewChat()
        draft.draft = prompt
    }

    /// Chats sent from elsewhere that nobody is looking at (setup's About You). Held until the
    /// gateway files them under their session (`adopt`).
    @ObservationIgnored private var backgroundChats: [ConversationModel] = []

    /// Sends `text` as the first message of a new chat, without opening it.
    func sendInBackground(_ text: String) {
        let chat = ConversationModel(workspace: self)
        chat.sentInBackground = true
        chat.savesOneMemory = true
        backgroundChats.append(chat)
        chat.sendMessage(text)
    }

    /// New Task opens with these filled in (setup's morning briefing).
    var pendingNewTask: TaskPrefill?

    func startNewChat(inProject projectID: String? = nil) {
        if !draft.isEmpty || draft.sessionID != nil || (projectID != nil && draft.placement?.projectID != projectID) {
            draft = ConversationModel(workspace: self)
        }
        if let projectID {
            draft.placement = projects.placement(in: projectID)
        }
        selection = nil
    }

    /// Opens a chat that may not be in the loaded history page (a project's chats come from the
    /// tree, which reaches further back).
    func open(_ session: HermesSession) {
        if !sessions.contains(where: { $0.stableID == session.stableID }) {
            let index = sessions.firstIndex { ($0.lastActive ?? .distantPast) < (session.lastActive ?? .distantPast) && !$0.pinned }
            sessions.insert(session, at: index ?? sessions.endIndex)
        }
        selection = .session(session.stableID)
    }

    /// Opens a search result at the message that matched (`docs/search.md`). A Bot's result opens
    /// that Bot's chat.
    func open(_ hit: ChatSearch.Hit) {
        let result = hit.result
        let focus = SearchFocus(result: result)
        if let botName = hit.botName, let roster, roster.bot(named: botName) != nil {
            sidebarMode = .bots
            selection = .bot(botName)
            roster.conversation(for: botName).searchFocus = focus
            return
        }
        sidebarMode = .chats
        let known = sessions.first { $0.id == result.sessionID || (result.lineageRoot != nil && $0.stableID == result.lineageRoot) }
        var session = known ?? HermesSession(id: result.sessionID)
        if known == nil {
            session.title = result.title
            session.lineageRootID = result.lineageRoot
            session.source = result.source
            session.startedAt = result.sessionStarted
            session.lastActive = result.lastActive ?? result.sessionStarted
        }
        open(session)
        let conversation = conversation(forKey: session.stableID)
        conversation.loadIfNeeded()
        conversation.searchFocus = focus
    }

    /// Checkpoints… from a chat's menu: opens the chat with its checkpoints on top.
    func showCheckpoints(for session: HermesSession) {
        open(session)
        let conversation = conversation(forKey: session.stableID)
        conversation.loadIfNeeded()
        conversation.checkpoints.showTimeline()
    }

    /// The composer at the bottom of a project home: its next chat in that project.
    func projectDraft(for projectID: String) -> ConversationModel {
        if let existing = projectDrafts[projectID], existing.sessionID == nil { return existing }
        let conversation = ConversationModel(workspace: self)
        conversation.placement = projects.placement(in: projectID)
        projectDrafts[projectID] = conversation
        return conversation
    }

    /// The draft got its server session on first send: file it under that session.
    func adopt(_ conversation: ConversationModel, session: HermesSession) {
        conversations[session.stableID] = conversation
        // Filed under its session now: the background list no longer needs to hold it.
        backgroundChats.removeAll { $0 === conversation }
        if !sessions.contains(where: { $0.stableID == session.stableID }) {
            var row = session
            row.lastActive = .now
            sessions.insert(row, at: 0)
        }
        if conversation === draft {
            draft = ConversationModel(workspace: self)
            if selection == nil {
                selection = .session(session.stableID)
            }
        } else if let projectID = projectDrafts.first(where: { $0.value === conversation })?.key {
            // Sent from a project home: the chat opens.
            projectDrafts[projectID] = nil
            if selection == .project(projectID) {
                selection = .session(session.stableID)
            }
        }
    }

    func turnFinished(in conversation: ConversationModel) {
        guard let key = conversation.stableKey else { return }
        if let index = sessions.firstIndex(where: { $0.stableID == key }) {
            sessions[index].lastActive = .now
            if let id = conversation.sessionID, id != sessions[index].id {
                // Compression moved the conversation to a new session id; keep the row's identity.
                if sessions[index].lineageRootID == nil { sessions[index].lineageRootID = key }
                sessions[index].id = id
            }
            let session = sessions.remove(at: index)
            sessions.insert(session, at: sessions.firstIndex { !$0.pinned || session.pinned } ?? 0)
        }
        scheduleTitleRefresh(forKey: key)
    }

    /// The gateway announced a new title for this chat (`session.title`).
    func titleChanged(in conversation: ConversationModel) {
        guard let key = conversation.stableKey else { return }
        Task { await refreshSession(forKey: key) }
    }

    /// Hermes writes a quick title at turn start and a better one a few seconds later,
    /// without announcing either; fetch it twice.
    private func scheduleTitleRefresh(forKey key: String) {
        titleRefreshTasks[key]?.cancel()
        titleRefreshTasks[key] = Task { [weak self] in
            for delay in [0.3, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.refreshSession(forKey: key)
            }
        }
    }

    private func refreshSession(forKey key: String) async {
        guard let client, let current = session(forKey: key) else { return }
        guard let fresh = try? await client.session(id: current.id) else { return }
        guard let index = sessions.firstIndex(where: { $0.stableID == key }) else { return }
        var merged = sessions[index]
        merged.title = fresh.title
        merged.model = fresh.model
        merged.messageCount = fresh.messageCount
        merged.toolCallCount = fresh.toolCallCount
        merged.estimatedCostUSD = fresh.estimatedCostUSD
        if merged.preview?.isEmpty ?? true, let text = conversations[key]?.items.firstUserText {
            merged.preview = String(text.prefix(60))
        }
        sessions[index] = merged
    }

    func rememberModelChoice(_ model: ModelSelection?, effort: ReasoningEffort?) {
        preferredModel = model
        preferredEffort = effort
        let defaults = UserDefaults.standard
        if let model, let data = try? JSONEncoder().encode(model) {
            defaults.set(data, forKey: "model.\(bot.id.uuidString)")
        } else {
            defaults.removeObject(forKey: "model.\(bot.id.uuidString)")
        }
        defaults.set(effort?.rawValue, forKey: "effort.\(bot.id.uuidString)")
    }

    // MARK: - Connection

    /// One connect at a time: the keeper, a Retry and the app coming to the front can all ask.
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    /// - Parameter quietly: a retry in the background (`keepConnected`): an offline gateway
    ///   stays "Offline" until it's back, rather than flickering to "Connecting…" every few seconds.
    func connect(quietly: Bool = false) async {
        if let connectTask {
            await connectTask.value
            return
        }
        let task = Task { await performConnect(quietly: quietly) }
        connectTask = task
        await task.value
        connectTask = nil
    }

    private func performConnect(quietly: Bool) async {
        let endpoint = bot.baseURL
        roster?.connectIfNeeded(quietly: quietly)
        guard let client else {
            connection = .failed(.missingAPIKey)
            return
        }
        if !connection.isOnline, !(quietly && connection.isFailed) { connection = .connecting }
        do {
            let (status, features) = try await watchingForBusy {
                async let health = client.health()
                async let capabilities = client.capabilities()
                return try await (health, capabilities)
            }
            self.capabilities = features
            guard features.supportsNativeClient else {
                connection = .failed(.unsupportedServer)
                return
            }
            connection = .online(version: status.version)
            // Side by side: the model list and widget answers don't wait behind a chat list that a
            // busy Mac takes minutes over.
            async let sessions: Void = refreshSessions()
            async let models: Void = loadModelOptions()
            // Widgets are on when the gateway has the plugin's tool (`docs/widgets.md` §11); batches
            // that waited for the gateway go now.
            await widgets.checkSupport(client: client, roster: roster)
            widgets.flushWaiting()
            _ = await (sessions, models)
        } catch is CancellationError {
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            // Alive but too slow to finish connecting: keep at it (the keeper connects again in a
            // few seconds) and say the Mac is busy, rather than calling it offline.
            if failure.isTimeout, (try? await client.liveness())?.isThere == true {
                noteSlow()
                connection = .connecting
                return
            }
            let explained = await explained(failure, endpoint: endpoint)
            // The gateway's address changed meanwhile (`update(bot:)`): this failure is the old one's.
            guard bot.baseURL == endpoint else { return }
            clearBusy()
            connection = .failed(explained)
        }
    }

    /// What this device says about a failure to reach the gateway: Mobile Data or Wi-Fi off for
    /// the app, or no local network access for a gateway on the local network (TN3179). Each
    /// looks like an unreachable host otherwise.
    private func explained(_ failure: HermesError, endpoint: URL) async -> HermesError {
        guard case .unreachable(let host, let reason) = failure else { return failure }
        switch reason {
        case .offline, .cannotConnect, .timedOut, .other:
            if let blocked = route?.blocked { return .unreachable(host: host, reason: blocked.reason) }
            if await LocalNetworkAccess.isDenied(for: endpoint) { return .unreachable(host: host, reason: .localNetworkDenied) }
            return failure
        default:
            return failure
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let limit = min(200, max(50, nextSessionOffset))
            let page = try await watchingForBusy { try await client.sessions(limit: limit) }
            let localOnly = sessions.filter { local in
                // Keep rows this device just created if the list hasn't caught up yet.
                conversations[local.stableID]?.isWorking == true && !page.sessions.contains { $0.stableID == local.stableID }
            }
            // Most refreshes bring nothing new: an unchanged list redraws nothing and recounts
            // nothing (the sidebar, the open chat's title and the unread counts all read it).
            let fresh = localOnly + page.sessions.filter { !$0.isInternalChild }
            if !hasFetchedSessions {
                hasFetchedSessions = true
                if fresh == sessions { keepSessions() }
            }
            if fresh != sessions {
                sessions = fresh
                widgets.markKnownChats()
            }
            hasMoreSessions = page.hasMore
            nextSessionOffset = limit
            for session in sessions {
                conversations[session.stableID]?.adoptSessionID(session.id)
            }
            if case .failed = connection { connection = .online(version: nil) }
            prefetchRecent()
        } catch is CancellationError {
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            // Too slow, but alive: a busy Mac, not an offline one. Say so and try again shortly.
            if failure.isTimeout, (try? await client.liveness())?.isThere == true {
                noteSlow()
                if !connection.isOnline { connection = .online(version: nil) }
                retrySessionsWhileBusy()
                return
            }
            // It answered (an error, not a timeout or a proxy giving up): not busy. Kept rows don't
            // hide a first read that failed.
            if !BackendClient.isSlowAnswer(error) { clearBusy() }
            if !hasFetchedSessions { connection = .failed(failure) }
        }
    }

    /// Runs `work`; still going after 8 s while the gateway is there (`GatewayLiveness`), its Mac is
    /// busy, and the status line says so while the work carries on. Back quickly with nothing else
    /// slow under way, it isn't.
    private func watchingForBusy<T>(_ work: () async throws -> T) async throws -> T {
        let began = ContinuousClock.now
        watchedRequests += 1
        let watcher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let client = self?.client else { return }
            if (try? await client.liveness())?.isThere == true, !Task.isCancelled { self?.noteSlow() }
        }
        let result: T
        do {
            result = try await work()
        } catch {
            watcher.cancel()
            watchedRequests -= 1
            throw error
        }
        watcher.cancel()
        watchedRequests -= 1
        answered(within: ContinuousClock.now - began)
        return result
    }

    /// An answer came. A slow one is a sign the Mac is busy; a quick one, with nothing else slow
    /// under way and no sign for half a minute, means it isn't any more.
    private func answered(within elapsed: Duration) {
        guard elapsed < Self.quickAnswer else {
            noteSlow()
            return
        }
        guard watchedRequests == 0, Date.now.timeIntervalSince(lastSlowAt) > Self.busyLingers else { return }
        clearBusy()
    }

    /// A sign the Mac is busy: "busy" from now on, for at least half a minute.
    private func noteSlow() {
        lastSlowAt = .now
        if !isBusy { isBusy = true }
    }

    private func clearBusy() {
        if isBusy { isBusy = false }
    }

    /// Another go at the chat list once a busy Mac has had a moment.
    private func retrySessionsWhileBusy() {
        guard busyRetry == nil else { return }
        busyRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.busyRetry = nil
            await self.refreshSessions()
        }
    }

    /// Chats whose transcript this launch fetched ahead.
    @ObservationIgnored private var prefetched: Set<String> = []

    /// The few most recent chats are fetched ahead into the transcript cache, so opening one
    /// shows it at once. Once per chat per launch, after a pause (never competing with the chat
    /// being opened), and not in Low Power Mode.
    private func prefetchRecent() {
        guard let client, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let recent = sessions.sorted { $0.activityDate > $1.activityDate }.prefix(3)
            .filter { !prefetched.contains($0.stableID) && conversations[$0.stableID]?.isEmpty != false }
        guard !recent.isEmpty else { return }
        prefetched.formUnion(recent.map(\.stableID))
        let botID = bot.id.uuidString
        let gateway = bot.id
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            for session in recent {
                guard let transcript = try? await client.transcript(sessionID: session.id) else { continue }
                TranscriptCache.save("\(botID)-\(session.stableID)", gateway: gateway, sessionID: transcript.sessionID,
                                     messages: transcript.messages, hasEarlier: transcript.hasEarlier)
            }
        }
    }

    func loadMoreSessions() async {
        guard let client, hasMoreSessions, !isLoadingSessions else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        if let page = try? await client.sessions(limit: 50, offset: nextSessionOffset) {
            let known = Set(sessions.map(\.stableID))
            sessions += page.sessions.filter { !known.contains($0.stableID) && !$0.isInternalChild }
            hasMoreSessions = page.hasMore
            nextSessionOffset += 50
        }
    }

    func loadModelOptions(refresh: Bool = false) async {
        guard let client, capabilities?.features.modelOptions != false else { return }
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let data = try await client.modelOptionsJSON(refresh: refresh)
            modelOptions = try ModelOptions.read(data)
            modelOptionsError = nil
            ModelOptionsCache.save(id, data: data)
        } catch is CancellationError {
        } catch {
            // The picker says so with Try Again, instead of "Loading models…" for ever.
            modelOptionsError = error.localizedDescription
        }
    }

    /// Why the last model list didn't load, while there's none to show.
    private(set) var modelOptionsError: String?

    /// Add Key… for a provider without one (`model.save_key`, over Bot Mode), then the models again.
    func saveProviderKey(_ key: String, slug: String) async throws {
        guard let roster, roster.isConnected else {
            throw HermesError.invalidResponse(String(localized: "Bot Mode isn't connected, so the key can't go to \(bot.name) from here."))
        }
        var params: [String: JSONValue] = ["slug": .string(slug), "api_key": .string(key)]
        if let profile = bot.profileName { params["profile"] = .string(profile) }
        _ = try await roster.request("model.save_key", params, timeout: .seconds(30))
        await loadModelOptions(refresh: true)
    }

    /// The model new turns will use when the user hasn't picked one.
    var defaultModelName: String? {
        modelOptions?.model.map(Formatting.modelShortName)
    }

    // MARK: - Session actions

    func rename(_ session: HermesSession, to title: String) async throws {
        guard let client else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = try await client.renameSession(id: session.id, title: trimmed.isEmpty ? nil : String(trimmed.prefix(100)))
        replace(session, with: updated)
    }

    func setPinned(_ session: HermesSession, _ pinned: Bool) async throws {
        guard let client else { return }
        if let index = sessions.firstIndex(where: { $0.stableID == session.stableID }) {
            sessions[index].pinned = pinned
        }
        do {
            let updated = try await client.setSessionFlags(id: session.id, pinned: pinned)
            replace(session, with: updated)
        } catch {
            if let index = sessions.firstIndex(where: { $0.stableID == session.stableID }) {
                sessions[index].pinned = !pinned
            }
            throw error
        }
    }

    /// Archive (`docs/inbox.md` §5): Hermes keeps the chat and leaves it out of the list.
    func archive(_ session: HermesSession) async throws {
        guard let client else { return }
        let index = sessions.firstIndex { $0.stableID == session.stableID }
        sessions.removeAll { $0.stableID == session.stableID }
        if selection == .session(session.stableID) { selection = nil }
        // Undo is offered at once, not once a busy Mac has answered.
        recentlyArchived = session
        let call = Task { _ = try await client.setSessionFlags(id: session.id, archived: true) }
        archiving[session.stableID] = call
        defer { if archiving[session.stableID] == call { archiving[session.stableID] = nil } }
        do {
            try await call.value
        } catch {
            // Undone meanwhile: the row is back and the chat was never archived; nothing to say.
            let undone = recentlyArchived?.stableID != session.stableID && sessions.contains { $0.stableID == session.stableID }
            if recentlyArchived?.stableID == session.stableID { recentlyArchived = nil }
            if !sessions.contains(where: { $0.stableID == session.stableID }) {
                sessions.insert(session, at: min(index ?? 0, sessions.count))
            }
            if !undone { throw error }
        }
    }

    func unarchive(_ session: HermesSession) async throws {
        guard let client else { return }
        if recentlyArchived?.stableID == session.stableID { recentlyArchived = nil }
        // Back in the list at once; the gateway's row replaces it when it answers.
        if !sessions.contains(where: { $0.stableID == session.stableID }) {
            sessions.append(session)
        }
        // After the archive still on its way: two calls in flight could land in either order.
        if case .failure? = await archiving[session.stableID]?.result {
            return // it never was archived
        }
        do {
            let updated = try await client.setSessionFlags(id: session.id, archived: false)
            // A list read between Undo and here (the gateway still had it archived) took the row.
            if let index = sessions.firstIndex(where: { $0.stableID == session.stableID }) {
                sessions[index] = updated
            } else {
                sessions.append(updated)
            }
        } catch {
            sessions.removeAll { $0.stableID == session.stableID }
            throw error
        }
    }

    func delete(_ session: HermesSession) async throws {
        guard let client else { return }
        try await client.deleteSession(id: session.id)
        sessions.removeAll { $0.stableID == session.stableID }
        // Its widgets' sort, filter and step go with the chat (`docs/widgets.md` §4).
        if let shown = conversations[session.stableID]?.widgetFacts.shown { widgets.forgetViews(shown) }
        conversations[session.stableID]?.cancelAll()
        conversations[session.stableID] = nil
        TranscriptCache.remove("\(bot.id.uuidString)-\(session.stableID)")
        // What waited to go in it goes with it.
        FollowUpQueueStore.save([], key: session.stableID)
        FollowUpQueueStore.saveOutbox([], key: session.stableID)
        if selection == .session(session.stableID) {
            selection = nil
        }
    }

    /// Opens a branch the gateway made (`session.branch`); `text` is sent in it once it loads
    /// (Edit and Resend).
    func openBranch(storedID: String, title: String?, from parent: HermesSession?, thenSend text: String?) {
        var row = HermesSession(id: storedID)
        row.title = title
        row.lastActive = .now
        row.source = parent?.source ?? PreviewBridge.sessionSource
        row.preview = parent?.preview
        if !sessions.contains(where: { $0.stableID == row.stableID }) {
            sessions.insert(row, at: 0)
        }
        let branch = conversation(forKey: row.stableID)
        if let text { branch.sendWhenLoaded(text) }
        selection = .session(row.stableID)
    }

    /// Branches a conversation and opens the branch.
    func fork(_ session: HermesSession) async throws {
        guard let client else { return }
        let branch = try await client.forkSession(id: session.id)
        var row = branch
        row.lastActive = .now
        row.preview = row.preview ?? session.preview
        sessions.insert(row, at: 0)
        if let index = sessions.firstIndex(where: { $0.stableID == session.stableID }) {
            sessions[index].endReason = "branched"
        }
        selection = .session(branch.stableID)
    }

    private func replace(_ session: HermesSession, with updated: HermesSession) {
        guard let index = sessions.firstIndex(where: { $0.stableID == session.stableID }) else { return }
        var merged = updated
        merged.lastActive = sessions[index].lastActive
        merged.preview = sessions[index].preview
        merged.lineageRootID = sessions[index].lineageRootID
        sessions[index] = merged
    }

    // MARK: - Staying connected

    /// While the app is in front the connection looks after itself, so a gateway that restarts
    /// (or a Mac that slept, or Tailscale coming back) needs no Retry: offline, it tries again
    /// after 2, 4, 8, 16, then every 30 s; online, a health check every 30 s notices a gateway
    /// that went away, so the app says so and comes back by itself. A Mac app behind other apps
    /// checks every 2 minutes, and again as it comes to the front (`cameToFront`).
    @ObservationIgnored private var keeper: Task<Void, Never>?
    private static let healthInterval: Double = 30
    private static let healthIntervalInBack: Double = 120
    @ObservationIgnored private var lastHealthCheck = Date.distantPast
    /// The device's route: coming back reconnects at once, changing proves the connection.
    @ObservationIgnored private var route: RouteWatcher?

    func keepConnected() {
        if route == nil {
            route = RouteWatcher(label: "hermes.gateway.network") { [weak self] cameBack in
                self?.routeChanged(cameBack: cameBack)
            }
        }
        guard keeper == nil else { return }
        keeper = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let delay = self?.nextCheck(after: misses) else { return }
                try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay * 0.1))
                guard !Task.isCancelled, let self else { return }
                switch self.connection {
                case .online:
                    misses = await self.isStillOnline() ? 0 : 1
                case .failed(let error) where !error.isTransient:
                    continue // a missing or rejected key, a gateway too old: the person fixes it
                case .connecting where self.connectTask != nil:
                    continue
                case .idle, .failed, .connecting:
                    // `.connecting` with no connect under way: the last one found the gateway too
                    // busy to finish (`performConnect`), so it goes again.
                    await self.connect(quietly: true)
                    guard self.connection.isOnline else {
                        misses += 1
                        continue
                    }
                    misses = 0
                    // Replies that lost their stream while the gateway was away pick up again.
                    for conversation in self.conversations.values {
                        conversation.resumeIfNeeded()
                    }
                }
            }
        }
    }

    /// The network came back, or now goes another way (Wi-Fi ↔ cellular, a VPN): offline, connect
    /// now instead of after the backoff; online, look now (an address that only the old route
    /// reached is offline as of this moment). Only while the connection is being kept.
    private func routeChanged(cameBack: Bool) {
        guard keeper != nil else { return }
        switch connection {
        case .online:
            checkConnectionNow()
        case .failed(let error) where !error.isTransient:
            break // a missing or rejected key, a gateway too old: the person fixes it
        case .connecting:
            break
        case .idle, .failed:
            // The keeper's backoff (built up while there was no route) starts over, and a connect
            // goes now. One already under way began before the route was back; if it fails, the
            // fresh keeper tries again in 2 s.
            stopKeepingConnected()
            keepConnected()
            Task { await connect(quietly: true) }
        }
    }

    /// Something else on the gateway's machine just went quiet (Bot Mode's socket): look now,
    /// rather than at the next health check, so the app says "Offline" before a send fails.
    func checkConnectionNow() {
        guard keeper != nil, connection.isOnline else { return }
        Task { _ = await isStillOnline() }
    }

    func stopKeepingConnected() {
        keeper?.cancel()
        keeper = nil
    }

    /// Seconds until the next look: online or waiting on the person, the health interval; a
    /// connect under way, a moment; offline, backing off from 2 s.
    private func nextCheck(after misses: Int) -> Double {
        switch connection {
        case .online: AppPresence.isInBack ? Self.healthIntervalInBack : Self.healthInterval
        case .failed(let error) where !error.isTransient: Self.healthInterval
        case .connecting: 5
        // No route at all: nothing to try until there is one (`routeChanged` connects then).
        case .idle, .failed:
            route?.isUp == false ? Self.healthInterval : misses == 0 ? 2 : min(Self.healthInterval, 2 * pow(2, Double(min(misses, 4))))
        }
    }

    /// The Mac app came to the front: a health check that's due (put off while it was behind)
    /// goes now, so "Connected" is current when it's read.
    func cameToFront() {
        guard Date.now.timeIntervalSince(lastHealthCheck) >= Self.healthInterval else { return }
        checkConnectionNow()
    }

    /// Two misses a few seconds apart count, so one slow answer from a busy machine doesn't
    /// flash "Offline". A health check that the gateway took and didn't answer in time is no miss:
    /// the gateway is there and busy (`GatewayLiveness`), and the status line says so.
    private func isStillOnline() async -> Bool {
        guard let client else { return true }
        lastHealthCheck = .now
        var failure: HermesError?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            let began = ContinuousClock.now
            guard !Task.isCancelled, let liveness = try? await client.liveness() else { return true }
            switch liveness {
            case .answering:
                answered(within: ContinuousClock.now - began)
                return true
            case .busy:
                noteSlow()
                return true
            case .unreachable(let error):
                guard error.isTransient else { return true } // not a connection problem
                failure = error
            }
        }
        guard !Task.isCancelled, connection.isOnline, let failure else { return true }
        let endpoint = bot.baseURL
        let explained = await explained(failure, endpoint: endpoint)
        guard connection.isOnline, bot.baseURL == endpoint else { return false }
        connection = .failed(explained)
        return false
    }

    // MARK: - Foreground

    #if os(macOS)
    /// The Mac woke: the connection looks after itself again, the Bots' socket comes back, and
    /// replies that lost their stream while it slept pick up. Not "active": nothing counts as read.
    func didWake() {
        keepConnected()
        roster?.didWake()
        for conversation in conversations.values {
            conversation.resumeIfNeeded()
        }
        Task {
            if connection.isOnline {
                await refreshSessions()
            } else {
                await connect(quietly: true)
            }
        }
    }
    #endif

    func didBecomeActive() {
        keepConnected()
        roster?.didBecomeActive()
        for conversation in conversations.values {
            conversation.resumeIfNeeded()
        }
        Task {
            if connection.isOnline {
                await refreshSessions()
            } else {
                await connect()
            }
        }
    }

    /// The gateway was removed: its chats' drafts, goals and waiting messages on this device.
    func forgetLocalData() {
        widgets.forgetDevice()
        WidgetCache.removeAll(gateway: id)
        for conversation in conversations.values { conversation.forgetLocalData() }
        draft.forgetLocalData()
        projectDrafts.values.forEach { $0.forgetLocalData() }
    }

    func tearDown() {
        stopKeepingConnected()
        appPluginsModel?.tearDown()
        route?.cancel()
        route = nil
        roster?.tearDown()
        for conversation in conversations.values {
            conversation.cancelAll()
        }
        // Chats not filed under a session yet: the draft, project drafts, background sends.
        draft.cancelAll()
        projectDrafts.values.forEach { $0.cancelAll() }
        backgroundChats.forEach { $0.cancelAll() }
        backgroundChats.removeAll()
        projects.disconnected()
        unread.tearDown()
        activity.tearDown()
        widgets.tearDown()
        setupCenter?.tearDown()
        titleRefreshTasks.values.forEach { $0.cancel() }
    }
}

extension Array where Element == TranscriptItem {
    var firstUserText: String? {
        for item in self {
            if case .user(let entry) = item, !entry.text.isEmpty { return entry.text }
        }
        return nil
    }
}
