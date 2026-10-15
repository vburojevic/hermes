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
    }

    let id: UUID
    private(set) var bot: BotConfiguration
    private(set) var client: HermesClient?
    let imageStore: SentImageStore

    private(set) var connection: Connection = .idle
    private(set) var capabilities: ServerCapabilities?
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
        return SessionGroup.grouped(sessions).flatMap { $0.1 }.map { .session($0.stableID) }
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

    /// Starts a fresh chat, reusing the current draft if it is still untouched.
    func startNewChat() {
        if !draft.isEmpty || draft.sessionID != nil {
            draft = ConversationModel(workspace: self)
        }
        selection = nil
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

    func connect() async {
        roster?.connectIfNeeded()
        guard let client else {
            connection = .failed(.missingAPIKey)
            return
        }
        if !connection.isOnline { connection = .connecting }
        do {
            async let health = client.health()
            async let capabilities = client.capabilities()
            let (status, features) = try await (health, capabilities)
            self.capabilities = features
            guard features.supportsNativeClient else {
                connection = .failed(.unsupportedServer)
                return
            }
            connection = .online(version: status.version)
            await refreshSessions()
            await loadModelOptions()
        } catch is CancellationError {
        } catch {
            connection = .failed(error as? HermesError ?? .invalidResponse(error.localizedDescription))
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let limit = min(200, max(50, nextSessionOffset))
            let page = try await client.sessions(limit: limit)
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
            prefetchRecent()
        } catch is CancellationError {
        } catch {
            if sessions.isEmpty {
                connection = .failed(error as? HermesError ?? .invalidResponse(error.localizedDescription))
            }
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
        row.source = parent?.source ?? "hermes_app"
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

    // MARK: - Foreground

    func didBecomeActive() {
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
