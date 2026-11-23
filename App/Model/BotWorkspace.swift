import Foundation
import HermesKit
import Observation

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
    /// What the access gateway in front said when it turned the app away (a sign-in that expired,
    /// a token it refused), `docs/connecting-and-voice.md` §11.5. It turns Bot Mode away too, so
    /// chats of every kind offer its fix rather than a retry (`chatAccessExpired`, §11.10).
    var accessRefusal: AccessRefusal? {
        if case .failed(let error) = connection { return error.accessRefusal }
        return nil
    }
    /// Decides `isBusy` from the signs and answers this workspace sees
    /// (`docs/connecting-and-voice.md` §3): the person's own turns are no sign, and busy clears by
    /// itself once answers are quick.
    @ObservationIgnored private var busySignal = BusySignal()
    /// Wakes at `BusySignal.clearsAt`, so busy clears with nothing else going on.
    @ObservationIgnored private var busyClearing: Task<Void, Never>?
    @ObservationIgnored private var busyRetry: Task<Void, Never>?
    /// Every session the list keeps: the chats and the scheduled runs with output, which only
    /// Show → Scheduled Tasks lists (`ScheduledRuns`, `docs/inbox.md` §5). Empty runs never come in.
    private(set) var allSessions: [HermesSession] = [] {
        didSet {
            // Unchanged chats redraw nothing that reads only them (a run's row changing, say).
            let chats = ScheduledRuns.chats(allSessions)
            if chats != sessions { sessions = chats }
            sessionsByKey = Dictionary(allSessions.map { ($0.stableID, $0) }, uniquingKeysWith: { first, _ in first })
            unread.update()
            keepSessions()
        }
    }
    /// The chats: everything that lists or counts chats reads these (the list's counts, unread
    /// badges, Quick Open, search by title, the push plugin's lists), never a scheduled run.
    private(set) var sessions: [HermesSession] = []
    @ObservationIgnored private var sessionsSave: Task<Void, Never>?

    /// The list as it stands goes on the device a moment after it changes (a deleted, archived or
    /// renamed chat as well as a fresh read), so a cold launch never brings back what's gone.
    private func keepSessions() {
        guard hasFetchedSessions else { return }
        sessionsSave?.cancel()
        sessionsSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            if self.allSessions.isEmpty {
                SessionsCache.remove(self.id)
            } else {
                SessionsCache.save(self.id, sessions: self.allSessions)
            }
        }
    }
    /// `allSessions` by stable key: rows ask for theirs as they draw, and a walk through a few
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
    /// The chat list's filter (`docs/inbox.md` §5): which chats it holds (Show), then which of
    /// those (Only).
    var inboxShow = InboxShow.atLaunch
    var inboxFilter = InboxFilter.all
    /// A chat just archived, for Undo.
    var recentlyArchived: HermesSession?
    /// Where it was archived from: Undo shows there, once per window.
    private(set) var recentlyArchivedPlace = ArchivePlace.chatList
    enum ArchivePlace { case chatList, project }
    /// Archive calls on their way, by chat: Undo goes after its archive, never alongside it.
    @ObservationIgnored private var archiving: [String: Task<Void, any Error>] = [:]
    private(set) var isLoadingSessions = false
    private(set) var hasMoreSessions = false
    /// Server-side paging position. Pinned rows are back-filled outside the page, so
    /// `allSessions.count` can't be used as the next offset. Observed: the loading rows at the end of
    /// the list load again each time it moves (`docs/inbox.md` §5).
    private(set) var nextSessionOffset = 0
    /// The gateway's chat list arrived this launch: the device's copy never goes over it, and a
    /// tap on a notice that launched the app waits for it (`PushCenter.show`).
    @ObservationIgnored private(set) var hasFetchedSessions = false
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
            if case .session(let key) = selection { lastChatKey = key }
            if selection == nil { lastChatKey = nil }
            navigation.selectionChanged(to: selection, keepsPlace: keepsPlace, fromProject: openingFromProject)
            openSelection()
        }
    }
    /// Whether the selected screen is on screen and when a compact window pushes it
    /// (`docs/design-to-swiftui.md` §6).
    private(set) var navigation = CompactNavigation()
    /// The next selection change keeps a compact window where it is (`CompactNavigation`).
    @ObservationIgnored private var keepsPlace = false
    /// The next selection is a chat opened from this project's home (`CompactNavigation.parentProject`).
    @ObservationIgnored private var openingFromProject: String?

    /// Selects without pushing: the other mode's selection coming back under its list, or the
    /// screen on show getting a new name.
    private func reselect(_ item: SidebarItem?) {
        keepsPlace = true
        selection = item
        keepsPlace = false
    }

    /// The window shows the selected screen, or went back to the list over it (iPhone). A chat
    /// that was backed out of stays selected but isn't open: replies to it count as unread.
    func setShowsDetail(_ shows: Bool) {
        guard navigation.showsDetail != shows else { return }
        navigation.showsDetail = shows
        if shows, let key = selectionUnreadKey { unread.noteOpening(key) }
        openSelection()
    }

    /// Asks a compact window to push the selected screen, which may be the one already selected.
    func showSelection() {
        navigation.show()
    }

    private var selectionUnreadKey: String? {
        switch selection {
        case .session(let key): key
        case .bot(let name): UnreadStore.botKey(name)
        default: nil
        }
    }

    /// The selected chat, Bot Chat or group chat, as far as it is on screen, is open: it never
    /// counts as unread and opening it clears a dot.
    private func openSelection() {
        let bot: String? = if navigation.showsDetail, case .bot(let name) = selection { name } else { nil }
        if roster?.openBot != bot { roster?.openBot = bot }
        if let key = unread.openKey {
            activity.opened(key)
            // Marked unread by hand: opening it clears the dot (`docs/inbox.md` §4).
            if unread.badge(for: key) == .dot || unread.readMark(for: key) == .markedUnread { unread.markRead(key) }
        }
        unread.update()
    }
    /// The chat open last (Skills' Use adds to its tray; `nil`: the new-chat draft).
    @ObservationIgnored private(set) var lastChatKey: String?
    /// The detail reads it, so it resolves its screen again when the selection stays the same
    /// (`DetailPass`, `docs/bots-groups-skills.md` §1.2).
    private(set) var detailPass = DetailPass()

    /// The screen the main area shows for the selection. On a compact width a chat opened from a
    /// project's home pushes over that home (`docs/projects.md` §2).
    func detailRoute(compact: Bool) -> DetailRoute {
        DetailRoute(selection: selection, mode: sidebarMode, hasBotMode: roster != nil,
                    parentProject: compact ? navigation.parentProject : nil)
    }

    /// Selects a chat (or, `nil`, the new-chat draft) opened from a project's home, so a compact
    /// window's Back returns to the project.
    private func select(_ item: SidebarItem?, fromProject projectID: String, keepingPlace: Bool = false) {
        openingFromProject = projectID
        if keepingPlace { reselect(item) } else { selection = item }
        openingFromProject = nil
    }

    /// Back from a chat or a Board pushed over its project's home (a compact window): the window
    /// is already on the project, so selecting it pushes nothing more (a push there stacked a
    /// second copy of the home).
    func returnToProject(_ projectID: String) {
        reselect(.project(projectID))
        navigation.poppedToProject(projectID)
    }

    /// A row picked in the sidebar: the row that is already selected shows its screen again.
    func pick(_ item: SidebarItem?) {
        if detailPass.pick(item, current: selection) { selection = item }
        navigation.show()
    }

    /// What the window opens on: restored from when it last closed, before the gateway answers.
    /// An iPhone that was back on the list keeps the item selected under it, unpushed.
    func openAtLaunch(_ item: SidebarItem, pushed: Bool = true) {
        detailPass.open(item)
        if pushed {
            selection = item
            navigation.show()
        } else {
            reselect(item)
        }
    }

    /// The gateway answered (or gave up): the detail resolves what the window opened on again,
    /// in case its first frame was built before the selection arrived.
    func settleLaunchSelection() {
        detailPass.settle(current: selection)
    }

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
            reselect(selectionByMode[sidebarMode] ?? nil)
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

    /// The Skills page's list, kept while the app runs so Skills opens on it at once.
    private(set) var skillCatalog = SkillCatalog()
    private(set) var isLoadingSkills = false
    /// Counts the turns that wrote a skill, so a Skills page on screen reads its list again.
    private(set) var skillsGeneration = 0

    /// Reads the skills when this gateway's list hasn't been read yet (or the last read failed),
    /// or always with `force` (pull to refresh).
    func loadSkills(force: Bool = false) async {
        let address = bot.baseURL
        guard let client, !isLoadingSkills,
              force || skillCatalog.needsLoad(from: address, isOnline: connection.isOnline) else { return }
        isLoadingSkills = true
        defer { isLoadingSkills = false }
        do {
            skillCatalog.received(try await client.skills(), from: address)
        } catch {
            // Skills closed before the answer: the next open asks again.
            guard !Task.isCancelled else { return }
            skillCatalog.failed(error as? HermesError ?? .invalidResponse(error.localizedDescription), from: address)
        }
    }

    /// The line under What Hermes Learned on Skills ("2 new skills this week · tidied today"),
    /// read once per gateway like the list: it takes six Bot Mode calls.
    private(set) var learnedSkillsSubtitle: String?
    @ObservationIgnored private var hasLearnedSkillsSubtitle = false
    @ObservationIgnored private var isLoadingLearnedSkillsSubtitle = false

    /// Reads the line when Bot Mode is up and it hasn't been read yet, or always with `force`.
    /// The model notes the line itself once the learning graph arrives, so a failed read leaves
    /// it unread and the next open tries again.
    func loadLearnedSkillsSubtitle(force: Bool = false) async {
        guard roster?.isConnected == true, !isLoadingLearnedSkillsSubtitle,
              force || !hasLearnedSkillsSubtitle else { return }
        isLoadingLearnedSkillsSubtitle = true
        defer { isLoadingLearnedSkillsSubtitle = false }
        await LearnedModel(workspace: self).load()
    }

    /// A turn wrote a skill: the list and the line are read again the next time Skills opens,
    /// or now when it shows. The Mac has no pull to refresh, so this is how a new skill shows
    /// there without a relaunch.
    func skillsChanged() {
        skillCatalog.markStale()
        hasLearnedSkillsSubtitle = false
        skillsGeneration += 1
    }

    /// What Hermes Learned read its page: the row shows the same, with no read of its own.
    func noteLearnedSkillsSubtitle(_ subtitle: String?) {
        learnedSkillsSubtitle = subtitle
        hasLearnedSkillsSubtitle = true
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
    @ObservationIgnored private var inAppBrowserModel: InAppBrowser?
    /// Whether this app is Hermes's browser here (`docs/web.md` §6).
    var inAppBrowser: InAppBrowser {
        if let inAppBrowserModel { return inAppBrowserModel }
        let model = InAppBrowser(workspace: self)
        inAppBrowserModel = model
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
    /// Chats with the person's own turn running (`ownTurnChanged`, `ownTurnCutOff`).
    @ObservationIgnored private var ownTurns = BusySignal.OwnTurns<ConversationModel>()
    @ObservationIgnored private var titleRefreshTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private let store: BotStore
    /// Reads this gateway's key and Bot Mode sign-in later, for the addresses they were saved for.
    @ObservationIgnored weak var app: AppModel?

    init(bot: BotConfiguration, apiKey: String?, backendCredential: BackendCredential? = nil, store: BotStore) {
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
            roster = BotRoster(botID: bot.id, link: link, credential: backendCredential, store: store)
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
        restoreWaitingChats()
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
    /// minutes over it, and a cold launch meanwhile showed an empty sidebar (`SessionsCache`). It's
    /// read here, before the first frame, so the rows are in the window when it shows rather than
    /// sliding in after it as one animated insert.
    private func restoreCachedSessions() {
        guard let cached = SessionsCache.load(id) else { return }
        allSessions = ScheduledRuns.kept(cached)
        nextSessionOffset = cached.count
        LaunchTrace.mark("cached chats shown (\(cached.count))", id: "cached chats")
    }

    /// Applies edited settings; reconnects when the address or key changed. New access settings
    /// reconnect too, but keep the chats: the gateway is the same one (`docs/connecting-and-voice.md`
    /// §11.1).
    func update(
        bot: BotConfiguration, apiKey: String?, keyChanged: Bool, backendSignInChanged: Bool = false,
        accessChanged: Bool = false, botModeStop: BotModeStop? = nil
    ) {
        let endpointChanged = bot.baseURL != self.bot.baseURL || keyChanged
        // First, so Bot Mode reads its sign-in for the addresses it's now saved for.
        self.bot = bot
        updateBackend(bot.backend, signInChanged: backendSignInChanged || accessChanged, stopped: botModeStop)
        guard endpointChanged else {
            // Same gateway: a sign-in or a token fixed in Edit Gateway wakes the replies that
            // waited for it, the same as the chat's Sign In… (§11.10).
            if accessChanged { signedIn() }
            return
        }
        client = (apiKey?.isEmpty ?? true) ? nil : HermesClient(baseURL: bot.baseURL, apiKey: apiKey ?? "")
        conversations.values.forEach { $0.cancelAll() }
        conversations = [:]
        closeSelection()
        draft = ConversationModel(workspace: self)
        hasFetchedSessions = false
        allSessions = []
        SessionsCache.remove(id)
        ModelOptionsCache.remove(id)
        LastLinesCache.remove(id)
        nextSessionOffset = 0
        modelOptions = nil
        connection = .idle
        Task { await connect() }
    }

    /// `stopped` when Edit Gateway saved a Bot Mode address or sign-in that can't work: the
    /// roster starts stopped, rather than asking again (`docs/setup.md` §4.1).
    private func updateBackend(_ link: BackendLink?, signInChanged: Bool, stopped: BotModeStop? = nil) {
        switch (roster, link) {
        case (nil, let link?):
            let roster = BotRoster(botID: id, link: link, credential: app?.backendCredential(for: bot), store: store)
            roster.workspace = self
            self.roster = roster
            sidebarMode = .bots
            if let stopped {
                roster.stayStopped(stopped)
            } else {
                roster.connectIfNeeded()
            }
        case (let roster?, nil):
            roster.tearDown()
            self.roster = nil
            sidebarMode = .chats
            if case .bot = selection { closeSelection() }
        case (let roster?, let link?):
            if link != roster.link || stopped != nil {
                roster.update(link: link, stopped: stopped)
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
        // A waiting chat that's gone (sent, or deleted) has no chat to load under its key.
        if WaitingChat.isKey(key) { return draft }
        let session = allSessions.first { $0.stableID == key } ?? HermesSession(id: key)
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
        let listed = !allSessions.isEmpty
        if !listed { await refreshSessions() }
        var seen: Set<ObjectIdentifier> = []
        let models = chats.compactMap(conversationToKeepCurrent).filter { seen.insert(ObjectIdentifier($0)).inserted }
        await withTaskGroup(of: Void.self) { group in
            for model in models {
                group.addTask { await model.readForSync() }
            }
            if listed { group.addTask { await self.refreshSessions() } }
            // The badge is counted again from the list: with Hermes' read marks as they are now.
            group.addTask { await self.unread.catchUpMarks() }
        }
    }

    /// A Bot's own chat, a chat open here, or one in the list; never a new one for an id it can't place.
    private func conversationToKeepCurrent(_ chat: String) -> ConversationModel? {
        if let roster, let bot = roster.botChats[chat] { return roster.conversation(for: bot) }
        if let open = conversations.values.first(where: { $0.sessionID == chat }) { return open }
        guard let session = allSessions.first(where: { $0.id == chat || $0.stableID == chat }) else { return nil }
        return conversation(forKey: session.stableID)
    }

    func session(forKey key: String) -> HermesSession? {
        _ = allSessions // whoever asks follows the list, as before
        return sessionsByKey[key] ?? waitingChats.first { $0.rowKey == key }?.row
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
        return allSessions.first { $0.id == id || $0.stableID == id }?.stableID ?? id
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

    /// - Parameter fromHome: started on that project's home (Talk), so Back returns to it.
    func startNewChat(inProject projectID: String? = nil, fromHome: Bool = false) {
        if !draft.isEmpty || draft.sessionID != nil || (projectID != nil && draft.placement?.projectID != projectID) {
            draft = ConversationModel(workspace: self)
        }
        if let projectID {
            draft.placement = projects.placement(in: projectID)
        }
        if fromHome, let projectID {
            select(nil, fromProject: projectID)
        } else {
            selection = nil
        }
        navigation.show()
    }

    /// The open screen went away under the person (deleted, archived, its Bot or gateway gone):
    /// nothing is selected, and on iPhone the chat list comes back rather than an empty screen.
    private func closeSelection() {
        selection = nil
        navigation.dismiss()
    }

    /// Opens a chat that may not be in the loaded history page (a project's chats come from the
    /// tree, which reaches further back).
    /// - Parameter projectID: the project home it was opened from, so Back returns to it.
    func open(_ session: HermesSession, fromProject projectID: String? = nil) {
        list(session)
        if let projectID {
            select(.session(session.stableID), fromProject: projectID)
        } else {
            selection = .session(session.stableID)
        }
    }

    /// Puts a chat opened from elsewhere in the list, in its place by time, unless it's there.
    private func list(_ session: HermesSession) {
        guard !allSessions.contains(where: { $0.stableID == session.stableID }) else { return }
        let index = allSessions.firstIndex { ($0.lastActive ?? .distantPast) < (session.lastActive ?? .distantPast) && !$0.pinned }
        allSessions.insert(session, at: index ?? allSessions.endIndex)
    }

    /// Opens a search result at the message that matched (`docs/search.md`). A Bot's result opens
    /// that Bot's chat. It picks like a sidebar row, so the result already selected shows its
    /// screen again.
    func open(_ hit: ChatSearch.Hit) {
        let result = hit.result
        LoadTrace.mark(result.lineageRoot ?? result.sessionID, "search result opened")
        let focus = SearchFocus(result: result)
        if let botName = hit.botName, let roster, roster.bot(named: botName) != nil {
            sidebarMode = .bots
            pick(.bot(botName))
            roster.conversation(for: botName).searchFocus = focus
            return
        }
        sidebarMode = .chats
        let known = allSessions.first { $0.id == result.sessionID || (result.lineageRoot != nil && $0.stableID == result.lineageRoot) }
        var session = known ?? HermesSession(id: result.sessionID)
        if known == nil {
            session.title = result.title
            session.lineageRootID = result.lineageRoot
            session.source = result.source
            session.startedAt = result.sessionStarted
            session.lastActive = result.lastActive ?? result.sessionStarted
        }
        list(session)
        pick(.session(session.stableID))
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
        // Listed as a waiting chat until now (`keepWaiting`): its row becomes the chat's.
        if case .session(let key)? = selection, key != session.stableID, WaitingChat.isKey(key), conversations[key] === conversation {
            reselect(.session(session.stableID))
        }
        conversations = conversations.filter { !WaitingChat.isKey($0.key) || $0.value !== conversation }
        conversations[session.stableID] = conversation
        // Filed under its session now: the background list no longer needs to hold it.
        backgroundChats.removeAll { $0 === conversation }
        if !allSessions.contains(where: { $0.stableID == session.stableID }) {
            var row = session
            row.lastActive = .now
            allSessions.insert(row, at: 0)
        }
        if conversation === draft {
            draft = ConversationModel(workspace: self)
            if selection == nil {
                reselect(.session(session.stableID))
            }
        } else if let projectID = projectDrafts.first(where: { $0.value === conversation })?.key {
            // Sent from a project home: the chat opens.
            projectDrafts[projectID] = nil
            if selection == .project(projectID) {
                select(.session(session.stableID), fromProject: projectID, keepingPlace: true)
            }
        }
    }

    // MARK: Waiting chats (`docs/chat.md` §4)

    /// Brand-new chats whose first message waits for the gateway, kept on the device
    /// (`WaitingChat`): listed above the chats until Hermes makes them, and sent again after a
    /// relaunch.
    private(set) var waitingChats: [WaitingChat] = []

    /// A new chat's first message waits: it's kept and listed under its own row from now on, and
    /// the new-chat draft gives way to a fresh one, as when Hermes makes the chat (`adopt`).
    func keepWaiting(_ chat: WaitingChat, in conversation: ConversationModel) {
        if let index = waitingChats.firstIndex(where: { $0.key == chat.key }) {
            guard waitingChats[index] != chat else { return }
            waitingChats[index] = chat
        } else {
            waitingChats.append(chat)
        }
        WaitingChatStore.save(waitingChats, gateway: id)
        if conversations[chat.rowKey] !== conversation { conversations[chat.rowKey] = conversation }
        backgroundChats.removeAll { $0 === conversation }
        if conversation === draft {
            draft = ConversationModel(workspace: self)
            if selection == nil { reselect(.session(chat.rowKey)) }
        } else if let projectID = projectDrafts.first(where: { $0.value === conversation })?.key {
            projectDrafts[projectID] = nil
            // Opened from the project, as when Hermes makes the chat (`adopt`), so Back returns to it.
            if selection == .project(projectID) { select(.session(chat.rowKey), fromProject: projectID, keepingPlace: true) }
        }
    }

    /// Hermes has the message, or it went back to the person.
    func forgetWaiting(_ chat: WaitingChat) {
        guard waitingChats.contains(where: { $0.key == chat.key }) else { return }
        waitingChats.removeAll { $0.key == chat.key }
        WaitingChatStore.save(waitingChats, gateway: id)
    }

    func waitingChat(forKey key: String) -> WaitingChat? {
        waitingChats.first { $0.rowKey == key }
    }

    /// What a waiting chat's row says: "Waiting for <Mac>…" while its message is on its way.
    func waitingNote(forKey key: String) -> String? {
        guard waitingChat(forKey: key) != nil else { return nil }
        guard conversations[key]?.isWorking == true else { return nil }
        return String(localized: "Waiting for \(bot.name)…")
    }

    /// The chats a previous run of the app kept waiting. One whose message never left goes again
    /// by itself; one whose message went out is looked for in the chat Hermes made, and a message
    /// that isn't there waits in Up Next for a Send.
    private func restoreWaitingChats() {
        let kept = WaitingChatStore.load(gateway: id)
        guard !kept.isEmpty else { return }
        var restored: [WaitingChat] = []
        var sends: [(ConversationModel, QueuedFollowUp)] = []
        for chat in kept {
            switch chat.resume {
            case .send:
                guard let message = FollowUpQueueStore.loadOutbox(key: chat.outboxKey).first?.message else { continue }
                let queue = FollowUpQueueStore.load(key: chat.outboxKey)
                let resent = chat.resent
                if chat.outboxKey != resent.key {
                    // Kept under its own key again: the chat Hermes made over the socket was never
                    // stored, and one made over the API server is asked for under the same id.
                    FollowUpQueueStore.saveOutbox([OutboxItem(message: message, sentAt: chat.sentAt)], key: resent.key)
                    FollowUpQueueStore.save(queue, key: resent.key)
                    FollowUpQueueStore.saveOutbox([], key: chat.outboxKey)
                    FollowUpQueueStore.save([], key: chat.outboxKey)
                }
                let conversation = ConversationModel(workspace: self, waiting: resent, queue: queue)
                conversations[resent.rowKey] = conversation
                restored.append(resent)
                sends.append((conversation, message))
            case .lookFor(let sessionID):
                let conversation = conversations[sessionID] ?? ConversationModel(workspace: self, session: HermesSession(id: sessionID))
                conversation.restoreWaiting(chat)
                conversations[sessionID] = conversation
                restored.append(chat)
                conversation.loadIfNeeded()
            }
        }
        waitingChats = restored
        WaitingChatStore.save(restored, gateway: id)
        ConnectionLog.logger.notice("chat: \(restored.count) new chat(s) kept from before a relaunch, \(sends.count) sent again")
        // Once the workspace is set up: the sends wait for the gateway like any other.
        Task { @MainActor in
            for (conversation, message) in sends { conversation.sendWaiting(message) }
        }
    }

    /// Deletes a chat that waits: nothing more of it goes. One whose message may have reached Hermes
    /// is deleted there too, if Hermes made it.
    private func discardWaiting(_ chat: WaitingChat) async {
        conversations[chat.rowKey]?.discardWaiting()
        conversations[chat.rowKey] = nil
        forgetWaiting(chat)
        if selection == .session(chat.rowKey) { closeSelection() }
        if let sessionID = chat.sessionID, let client {
            try? await client.deleteSession(id: sessionID)
            allSessions.removeAll { $0.stableID == sessionID }
        }
    }

    func turnFinished(in conversation: ConversationModel) {
        guard let key = conversation.stableKey else { return }
        if let index = allSessions.firstIndex(where: { $0.stableID == key }) {
            allSessions[index].lastActive = .now
            if let id = conversation.sessionID, id != allSessions[index].id {
                // Compression moved the conversation to a new session id; keep the row's identity.
                if allSessions[index].lineageRootID == nil { allSessions[index].lineageRootID = key }
                allSessions[index].id = id
            }
            let session = allSessions.remove(at: index)
            allSessions.insert(session, at: allSessions.firstIndex { !$0.pinned || session.pinned } ?? 0)
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
        guard let index = allSessions.firstIndex(where: { $0.stableID == key }) else { return }
        var merged = allSessions[index]
        merged.title = fresh.title
        merged.model = fresh.model
        merged.messageCount = fresh.messageCount
        merged.toolCallCount = fresh.toolCallCount
        merged.estimatedCostUSD = fresh.estimatedCostUSD
        if merged.preview?.isEmpty ?? true, let text = conversations[key]?.items.firstUserText {
            merged.preview = String(text.prefix(60))
        }
        allSessions[index] = merged
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
        if client == nil, let key = app?.apiKey(for: bot) {
            // Unreadable as the app started (a locked Keychain), and readable now.
            client = HermesClient(baseURL: bot.baseURL, apiKey: key)
        }
        let endpoint = bot.baseURL
        roster?.connectIfNeeded(quietly: quietly)
        guard let client else {
            connection = .failed(store.missingKey(for: bot))
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
            LaunchTrace.mark("gateway answered")
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
        } catch is TooSlow {
            // Alive but too slow to finish connecting: keep at it (the keeper connects again in a
            // few seconds), rather than calling it offline.
            connection = .connecting
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            let explained = await explained(failure, endpoint: endpoint)
            // The gateway's address changed meanwhile (`update(bot:)`): this failure is the old one's.
            guard bot.baseURL == endpoint else { return }
            updateBusy { $0.reset() }
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
            let localOnly = allSessions.filter { local in
                // Keep rows this device just created if the list hasn't caught up yet.
                conversations[local.stableID]?.isWorking == true && !page.sessions.contains { $0.stableID == local.stableID }
            }
            // Most refreshes bring nothing new: an unchanged list redraws nothing and recounts
            // nothing (the sidebar, the open chat's title and the unread counts all read it).
            let fresh = localOnly + ScheduledRuns.kept(page.sessions.filter { !$0.isInternalChild })
            // A waiting chat Hermes lists now got its message (Hermes stores a chat with its first).
            let stillWaiting = WaitingChat.remaining(waitingChats, gatewayListed: Set(page.sessions.map(\.stableID)))
            if stillWaiting != waitingChats {
                for chat in waitingChats where !stillWaiting.contains(chat) {
                    conversations[chat.rowKey]?.restoreWaiting(nil)
                }
                waitingChats = stillWaiting
                WaitingChatStore.save(stillWaiting, gateway: id)
            }
            if !hasFetchedSessions {
                hasFetchedSessions = true
                if fresh == allSessions { keepSessions() }
            }
            if fresh != allSessions {
                allSessions = fresh
                widgets.markKnownChats()
            }
            LaunchTrace.mark("chat list fetched (\(fresh.count))", id: "chat list fetched")
            #if HERMES_PUSH
            // Reads waiting for the push plugin are judged against this list (`PushReadQueue`).
            PushCenter.shared.chatListFetched(self)
            #endif
            hasMoreSessions = page.hasMore
            nextSessionOffset = limit
            for session in allSessions {
                conversations[session.stableID]?.adoptSessionID(session.id)
                // A model picked on another device follows into the open chat (`docs/sessions-and-models.md` §4).
                conversations[session.stableID]?.sessionRowReported(model: session.model)
            }
            if case .failed = connection { connection = .online(version: nil) }
            prefetchRecent()
        } catch is CancellationError {
        } catch is TooSlow {
            // Too slow, but alive: a busy Mac, not an offline one. Try again shortly.
            if !connection.isOnline { connection = .online(version: nil) }
            retrySessionsWhileBusy()
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            // It answered (an error, not a timeout or a proxy giving up): not busy. Kept rows don't
            // hide a first read that failed.
            if !BackendClient.isSlowAnswer(error) { updateBusy { $0.reset() } }
            if !hasFetchedSessions { connection = .failed(failure) }
        }
    }

    /// A request that timed out while the gateway was there (`GatewayLiveness`): its Mac is slow,
    /// not gone.
    private struct TooSlow: Error {}

    /// Runs `work`, timed by `busySignal`: still going after 8 s while the gateway is there, back
    /// slowly, or timed out while it's there, the Mac is busy (unless the person's own turn
    /// explains it); back quickly, it may not be any more. A timeout with the gateway there
    /// throws `TooSlow`.
    private func watchingForBusy<T>(_ work: () async throws -> T) async throws -> T {
        let ticket = busySignal.began()
        let watcher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let client = self?.client else { return }
            if (try? await client.liveness())?.isThere == true, !Task.isCancelled {
                self?.updateBusy { $0.stillRunning(ticket) }
            }
        }
        defer { watcher.cancel() }
        do {
            let result = try await work()
            updateBusy { $0.answered(ticket) }
            return result
        } catch {
            if (error as? HermesError)?.isTimeout == true, let client,
               (try? await client.liveness())?.isThere == true {
                updateBusy { $0.timedOut(ticket) }
                throw TooSlow()
            }
            updateBusy { $0.ended(ticket) }
            throw error
        }
    }

    /// Changes `busySignal`, shows what it decides, and wakes when busy would clear by itself.
    private func updateBusy(_ change: (inout BusySignal) -> Void) {
        change(&busySignal)
        busySignal.settle()
        if busySignal.isBusy != isBusy { isBusy = busySignal.isBusy }
        busyClearing?.cancel()
        busyClearing = nil
        guard let clearsAt = busySignal.clearsAt else { return }
        busyClearing = Task { [weak self] in
            try? await Task.sleep(until: clearsAt, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.updateBusy { _ in }
        }
    }

    /// One of the person's own turns, here or in a Bot Chat, started or ended. What a turn holds
    /// up on the gateway (a chat list waits for its token counts) says nothing about the Mac. Each
    /// chat says so itself: a new chat's first turn runs before it's filed under its session.
    func ownTurnChanged(_ conversation: ConversationModel) {
        ownTurns.set(conversation, running: conversation.isWorking)
        ownTurnsCounted()
    }

    /// The chat stopped all its work (deleted, discarded, disconnected). Its `isWorking` never
    /// comes back down, so a turn it was running stops excusing slow answers here.
    func ownTurnCutOff(_ conversation: ConversationModel) {
        ownTurns.forget(conversation)
        ownTurnsCounted()
    }

    private func ownTurnsCounted() {
        let running = ownTurns.anyRunning
        updateBusy { $0.ownTurn(running: running) }
        roster?.ownTurn(running: running)
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
            let known = Set(allSessions.map(\.stableID))
            allSessions += ScheduledRuns.kept(page.sessions.filter { !known.contains($0.stableID) && !$0.isInternalChild })
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
        // A project chat older than the loaded pages joins the list as it's pinned: Hermes lists
        // every pinned chat, so the next read would bring it anyway.
        let joined = pinned && !allSessions.contains { $0.stableID == session.stableID }
        if joined {
            var row = session
            row.pinned = true
            allSessions.append(row)
        } else if let index = allSessions.firstIndex(where: { $0.stableID == session.stableID }) {
            allSessions[index].pinned = pinned
        }
        do {
            let updated = try await client.setSessionFlags(id: session.id, pinned: pinned)
            replace(session, with: updated)
        } catch {
            if joined {
                allSessions.removeAll { $0.stableID == session.stableID }
            } else if let index = allSessions.firstIndex(where: { $0.stableID == session.stableID }) {
                allSessions[index].pinned = !pinned
            }
            throw error
        }
    }

    /// Archive (`docs/inbox.md` §5): Hermes keeps the chat and leaves it out of the list and its
    /// project's lanes (`docs/projects.md` §2). `place` is where it was archived from, which shows
    /// the Undo.
    func archive(_ session: HermesSession, from place: ArchivePlace = .chatList) async throws {
        guard let client else { return }
        let index = allSessions.firstIndex { $0.stableID == session.stableID }
        allSessions.removeAll { $0.stableID == session.stableID }
        projects?.archiving(session)
        if selection == .session(session.stableID) { closeSelection() }
        // Undo is offered at once, not once a busy Mac has answered.
        recentlyArchivedPlace = place
        recentlyArchived = session
        let call = Task { _ = try await client.setSessionFlags(id: session.id, archived: true) }
        archiving[session.stableID] = call
        defer { if archiving[session.stableID] == call { archiving[session.stableID] = nil } }
        do {
            try await call.value
            projects?.chatChangeLanded(session, .archived)
        } catch {
            // Undone meanwhile: the row is back and the chat was never archived; nothing to say.
            let undone = recentlyArchived?.stableID != session.stableID && allSessions.contains { $0.stableID == session.stableID }
            if recentlyArchived?.stableID == session.stableID { recentlyArchived = nil }
            projects?.chatChangeFailed(session)
            if !allSessions.contains(where: { $0.stableID == session.stableID }) {
                allSessions.insert(session, at: min(index ?? 0, allSessions.count))
            }
            if !undone { throw error }
        }
    }

    func unarchive(_ session: HermesSession) async throws {
        guard let client else { return }
        if recentlyArchived?.stableID == session.stableID { recentlyArchived = nil }
        // Back in the list and its lane at once; the gateway's row replaces it when it answers.
        if !allSessions.contains(where: { $0.stableID == session.stableID }) {
            allSessions.append(session)
        }
        projects?.restoring(session)
        // After the archive still on its way: two calls in flight could land in either order.
        if case .failure? = await archiving[session.stableID]?.result {
            return // it never was archived
        }
        do {
            let updated = try await client.setSessionFlags(id: session.id, archived: false)
            projects?.chatChangeLanded(session, .restored)
            // A list read between Undo and here (the gateway still had it archived) took the row.
            if let index = allSessions.firstIndex(where: { $0.stableID == session.stableID }) {
                allSessions[index] = updated
            } else {
                allSessions.append(updated)
            }
        } catch {
            allSessions.removeAll { $0.stableID == session.stableID }
            projects?.unarchiveFailed(session)
            throw error
        }
    }

    func delete(_ session: HermesSession) async throws {
        if let waiting = waitingChat(forKey: session.stableID) {
            await discardWaiting(waiting)
            return
        }
        guard let client else { return }
        try await client.deleteSession(id: session.id)
        allSessions.removeAll { $0.stableID == session.stableID }
        // Its widgets' sort, filter and step go with the chat (`docs/widgets.md` §4).
        if let shown = conversations[session.stableID]?.widgetFacts.shown { widgets.forgetViews(shown) }
        conversations[session.stableID]?.cancelAll()
        conversations[session.stableID] = nil
        TranscriptCache.remove("\(bot.id.uuidString)-\(session.stableID)")
        KeptTurns().set(KeptTurn(), for: "\(bot.id.uuidString)-\(session.stableID)")
        // What waited to go in it goes with it.
        FollowUpQueueStore.save([], key: session.stableID)
        FollowUpQueueStore.saveOutbox([], key: session.stableID)
        if selection == .session(session.stableID) {
            closeSelection()
        }
    }

    /// Opens a branch the gateway made (`session.branch`); `text` is sent in it once it loads
    /// (Edit and Resend).
    func openBranch(storedID: String, title: String?, from parent: HermesSession?, thenSend text: String?) {
        // Made now, holding the parent's messages: its row's time is its newest message's
        // (`RowTime`), the parent's until something is sent in it.
        var row = HermesSession(id: storedID, lastActive: parent?.lastActive ?? .now)
        row.title = title
        row.source = parent?.source ?? PreviewBridge.sessionSource
        row.preview = parent?.preview
        if !allSessions.contains(where: { $0.stableID == row.stableID }) {
            allSessions.insert(row, at: 0)
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
        // Hermes' answer has the copied messages' activity; the row's time is theirs (`RowTime`).
        row.lastActive = row.lastActive ?? session.lastActive
        row.preview = row.preview ?? session.preview
        allSessions.insert(row, at: 0)
        if let index = allSessions.firstIndex(where: { $0.stableID == session.stableID }) {
            allSessions[index].endReason = "branched"
        }
        selection = .session(branch.stableID)
    }

    private func replace(_ session: HermesSession, with updated: HermesSession) {
        guard let index = allSessions.firstIndex(where: { $0.stableID == session.stableID }) else { return }
        var merged = updated
        merged.lastActive = allSessions[index].lastActive
        merged.preview = allSessions[index].preview
        merged.lineageRootID = allSessions[index].lineageRootID
        allSessions[index] = merged
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
                case .failed(let error) where !error.keepsChecking:
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
        case .failed(let error) where !error.keepsChecking:
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
        case .failed(let error) where !error.keepsChecking: Self.healthInterval
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
            let ticket = busySignal.began()
            // Every way out ends the ticket; once answered, ending it again does nothing.
            defer { updateBusy { $0.ended(ticket) } }
            guard !Task.isCancelled, let liveness = try? await client.liveness() else { return true }
            switch liveness {
            case .answering:
                updateBusy { $0.answered(ticket) }
                return true
            case .busy:
                // A health check left unanswered: no turn of the person's holds that up.
                updateBusy {
                    $0.ended(ticket)
                    $0.sign()
                }
                return true
            case .unreachable(let error) where error.accessRefusal?.isSignIn == true:
                // The access gateway turned the app away (a sign-in that ran out or was revoked):
                // nothing gets through until the person signs in again, so the gateway shows it
                // now and the checks wait for them (`docs/connecting-and-voice.md` §11.10).
                guard connection.isOnline else { return false }
                connection = .failed(error)
                return false
            case .unreachable(let error):
                guard error.keepsChecking else { return true } // not a connection problem
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

    /// The person signed in to the access gateway again: connect, then the replies that lost
    /// their stream when it turned the app away pick up where they stopped.
    func signedIn() {
        keepConnected()
        Task {
            await connect()
            guard connection.isOnline else { return }
            for conversation in conversations.values {
                conversation.resumeIfNeeded()
            }
        }
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
        waitingChats = []
        WaitingChatStore.save([], gateway: id)
        draft.forgetLocalData()
        projectDrafts.values.forEach { $0.forgetLocalData() }
    }

    /// The gateway is being removed: every page its chats show closes, the Preview's and the
    /// browser's, before its web data is touched (`docs/connecting-and-voice.md` §7).
    func closeWebViews() {
        let chats = Array(conversations.values) + Array(projectDrafts.values) + backgroundChats + [draft].compactMap { $0 }
        for chat in chats { chat.inspectorIfLoaded?.closeWebViews() }
        roster?.closeWebViews()
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
        // Last, after the chats' `cancelAll` recounts that may have started it again.
        busyClearing?.cancel()
        busyClearing = nil
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
