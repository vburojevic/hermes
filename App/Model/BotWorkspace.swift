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
        }
    }
    private(set) var capabilities: ServerCapabilities?
    /// The gateway answers its health check but takes ages over everything else (its Mac is
    /// overloaded): still connected, and the status line says why things are slow.
    private(set) var isBusy = false
    @ObservationIgnored private var busyRetry: Task<Void, Never>?
    private(set) var sessions: [HermesSession] = []
    private(set) var isLoadingSessions = false
    private(set) var hasMoreSessions = false
    /// Server-side paging position. Pinned rows are back-filled outside the page, so
    /// `sessions.count` can't be used as the next offset.
    @ObservationIgnored private var nextSessionOffset = 0
    private(set) var modelOptions: ModelOptions?
    /// The "/" menu's skills and commands, per profile.
    @ObservationIgnored private var slashCatalogs: [String: SlashCatalog] = [:]

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
        didSet {
            if case .bot(let name) = selection {
                roster?.openBot = name
            } else if roster?.openBot != nil {
                roster?.openBot = nil
            }
            if case .session(let key) = selection { lastChatKey = key }
            if selection == nil { lastChatKey = nil }
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
    /// Voice mode was asked for before its chat was on screen (a project home's composer).
    @ObservationIgnored var voiceModeRequested = false
    /// Bumped by Chat → Voice Mode (⌥⌘V): the open chat starts or ends Voice.
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
        if let apiKey, !apiKey.isEmpty {
            client = HermesClient(baseURL: bot.baseURL, apiKey: apiKey)
        }
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
        sessions = []
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
    func loadedConversation(id: UUID) -> ConversationModel? {
        if draft?.id == id { return draft }
        if let found = conversations.values.first(where: { $0.id == id }) { return found }
        return roster?.loadedConversation(id: id)
    }

    func conversation(forKey key: String) -> ConversationModel {
        if let existing = conversations[key] { return existing }
        let session = sessions.first { $0.stableID == key } ?? HermesSession(id: key)
        let conversation = ConversationModel(workspace: self, session: session)
        conversations[key] = conversation
        return conversation
    }

    func session(forKey key: String) -> HermesSession? {
        sessions.first { $0.stableID == key }
    }

    func isWorking(sessionKey key: String) -> Bool {
        conversations[key]?.isWorking ?? false
    }

    /// The sidebar's rows in order: the Bots in Bots mode, else the chats by date.
    var sidebarOrder: [SidebarItem] {
        if sidebarMode == .bots, let roster {
            return roster.visibleBots.map { .bot($0.name) }
        }
        let history = sessions.filter { $0.pinned || !projects.isScoped($0) }
        return SessionGroup.grouped(history).flatMap { $0.1 }.map { .session($0.stableID) }
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
            if isBusy { isBusy = false }
            await refreshSessions()
            await loadModelOptions()
        } catch is CancellationError {
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            // Alive but too slow to finish connecting: keep at it (the keeper looks again in a
            // few seconds) and say the Mac is busy, rather than calling it offline.
            if failure.isTimeout, (try? await client.health()) != nil {
                isBusy = true
                connection = .connecting
                return
            }
            connection = .failed(failure)
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
            sessions = localOnly + page.sessions.filter { !$0.isInternalChild }
            hasMoreSessions = page.hasMore
            nextSessionOffset = limit
            for session in sessions {
                conversations[session.stableID]?.adoptSessionID(session.id)
            }
            if case .failed = connection { connection = .online(version: nil) }
            if isBusy { isBusy = false }
            prefetchRecent()
        } catch is CancellationError {
        } catch {
            let failure = error as? HermesError ?? .invalidResponse(error.localizedDescription)
            // Too slow, but alive: a busy Mac, not an offline one. Say so and try again shortly.
            if failure.isTimeout, (try? await client.health()) != nil {
                isBusy = true
                if !connection.isOnline { connection = .online(version: nil) }
                retrySessionsWhileBusy()
                return
            }
            if sessions.isEmpty { connection = .failed(failure) }
        }
    }

    /// Runs `work`; still going after 8 s while the health check answers at once, the gateway's Mac
    /// is busy, and the status line says so while the work carries on.
    private func watchingForBusy<T>(_ work: () async throws -> T) async throws -> T {
        let watcher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let client = self?.client else { return }
            if (try? await client.health()) != nil, !Task.isCancelled { self?.isBusy = true }
        }
        defer { watcher.cancel() }
        return try await work()
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
        Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            for session in recent {
                guard let transcript = try? await client.transcript(sessionID: session.id) else { continue }
                TranscriptCache.save("\(botID)-\(session.stableID)", sessionID: transcript.sessionID,
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
        if let options = try? await client.modelOptions(refresh: refresh) {
            modelOptions = options
        }
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

    func delete(_ session: HermesSession) async throws {
        guard let client else { return }
        try await client.deleteSession(id: session.id)
        sessions.removeAll { $0.stableID == session.stableID }
        conversations[session.stableID]?.cancelAll()
        conversations[session.stableID] = nil
        TranscriptCache.remove("\(bot.id.uuidString)-\(session.stableID)")
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
    /// that went away, so the app says so and comes back by itself.
    @ObservationIgnored private var keeper: Task<Void, Never>?
    private static let healthInterval: Double = 30

    func keepConnected() {
        guard keeper == nil else { return }
        keeper = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let delay = self?.nextCheck(after: misses) else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                switch self.connection {
                case .online:
                    misses = await self.isStillOnline() ? 0 : 1
                case .failed(let error) where !error.isTransient:
                    continue // a missing or rejected key, a gateway too old: the person fixes it
                case .connecting:
                    continue
                case .idle, .failed:
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
        case .online: Self.healthInterval
        case .failed(let error) where !error.isTransient: Self.healthInterval
        case .connecting: 5
        case .idle, .failed: misses == 0 ? 2 : min(Self.healthInterval, 2 * pow(2, Double(min(misses, 4))))
        }
    }

    /// Two misses a few seconds apart count, so one slow answer from a busy machine doesn't
    /// flash "Offline".
    private func isStillOnline() async -> Bool {
        guard let client else { return true }
        var failure: HermesError?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            guard !Task.isCancelled else { return true }
            do {
                _ = try await client.health()
                return true
            } catch is CancellationError {
                return true
            } catch {
                let error = error as? HermesError ?? .invalidResponse(error.localizedDescription)
                guard error.isTransient else { return true } // not a connection problem
                failure = error
            }
        }
        guard !Task.isCancelled, connection.isOnline, let failure else { return true }
        connection = .failed(failure)
        return false
    }

    // MARK: - Foreground

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

    func tearDown() {
        stopKeepingConnected()
        roster?.tearDown()
        for conversation in conversations.values {
            conversation.cancelAll()
        }
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
