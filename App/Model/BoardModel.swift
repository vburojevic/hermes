import Foundation
import HermesKit
import Observation
import os

/// One project's Board (`docs/board.md`): its cards by column, kept current from the board's
/// event socket (or every 5 s while that can't connect), the detail of an open card, and every
/// action a person takes on cards. The gateway calls cards "tasks"; that word stays in HermesKit.
/// Card titles, bodies and comments are never logged.
@MainActor
@Observable
final class BoardModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// Bot Mode isn't working: the Board runs on it (`docs/setup.md` §4.1).
        case needsBotMode
        /// The kanban plugin is turned off, or this Hermes has none (`docs/setup.md` §4.8).
        case notSetUp(SetupStatus)
        case failed(String)
    }

    /// What New Card starts from: a column (+ on a column header) or the board's default.
    struct NewCardTarget: Identifiable, Hashable {
        var triage = false
        var id: String { triage ? "triage" : "ready" }
    }

    let projectID: String
    @ObservationIgnored private weak var workspace: BotWorkspace?
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "board")

    private(set) var phase: Phase = .loading
    private(set) var info: BoardInfo?
    private(set) var workflow: BoardWorkflow?
    private(set) var snapshot = BoardSnapshot(lanes: [])
    /// What the detail adds for cards that wait, were split or are in review.
    private(set) var extras: [String: BoardCardExtras] = [:]
    private(set) var assignees: [String] = []
    private(set) var defaultAssignee: String?
    /// How many cards the dispatcher runs at once (`kanban.max_in_progress`), when set.
    private(set) var maxRunning: Int?
    /// The event socket is open; otherwise the board polls.
    private(set) var isLive = false
    /// Open cards' details and worker output.
    private(set) var details: [String: BoardCardDetail] = [:]
    private(set) var logs: [String: BoardWorkerLog] = [:]
    /// Why Approve was refused, per card, until the card changes.
    private(set) var approvalRefusals: [String: String] = [:]
    /// The clock the run times read (ticks every 30 s while the board is on screen).
    private(set) var now = Date.now

    /// The card in the inspector (iPad landscape, Mac) or pushed (iPhone).
    var openCardID: String?
    /// ⌘-clicked cards on the Mac.
    var selection: Set<String> = []
    /// The iPhone's column.
    var visibleColumn: String?
    /// Only this Bot's cards (iPad and Mac filter); nil = everyone's.
    var assigneeFilter: String?
    /// A refusal or failure to show over the board.
    var notice: String?
    /// Typing in a card's reply or comment field: ⌘→ / ⌘← move the cursor, not the card.
    var isTyping = false
    /// The card being dragged (iPad, Mac): columns it can't go to dim.
    var draggingCardID: String?
    /// "Nothing will pick it up" from the gateway, under cards just added.
    private(set) var warnings: [String: String] = [:]

    // Sheets and confirmations.
    var newCard: NewCardTarget?
    var assigning: BoardCard?
    var editing: BoardCard?
    var reopening: BoardCard?
    var deleting: BoardCard?
    var watching: BoardCard?

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0
    /// Someone opened the Board itself (not just the project home's row): a missing board is
    /// made now.
    @ObservationIgnored private var mayCreate = false
    /// The project has no board yet.
    private(set) var boardMissing = false
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var extrasLoading: Set<String> = []

    init(workspace: BotWorkspace, projectID: String) {
        self.workspace = workspace
        self.projectID = projectID
    }

    /// A board with no gateway behind it (the welcome tour); `showDemo` fills it.
    init(demoProjectID: String) {
        projectID = demoProjectID
    }

    private var roster: BotRoster? { workspace?.roster }
    private var client: BackendClient? {
        guard let roster, roster.isConnected else { return nil }
        return roster.boardClient
    }

    var isOnline: Bool { roster?.isConnected == true }
    var gatewayName: String { workspace?.bot.name ?? "" }
    var projectName: String { workspace?.projects.project(projectID)?.name ?? info?.projectName ?? "" }

    private var rememberedSlugKey: String {
        "board.\(workspace?.id.uuidString ?? "").\(projectID)"
    }

    // MARK: Reading

    /// The columns to show: the workflow's, without Triage and Scheduled while they're empty
    /// (an inbox and a waiting room; cards still move there from menus).
    var columns: [BoardColumn] {
        (workflow?.columns ?? []).filter { column in
            !["triage", "scheduled"].contains(column.key) || !cards(in: column.key).isEmpty
        }
    }

    func cards(in column: String) -> [BoardCard] {
        let cards = snapshot.cards(in: column)
        guard let assigneeFilter else { return cards }
        return cards.filter { $0.assignee == assigneeFilter }
    }

    func card(_ id: String) -> BoardCard? { snapshot.card(id) }

    func state(of card: BoardCard) -> BoardCardState {
        card.state(now: now, extras: extras[card.id])
    }

    var allCards: [BoardCard] { snapshot.cards }

    var needsYouCount: Int {
        allCards.filter { if case .needsYou = state(of: $0) { true } else { false } }.count
    }

    var runningCount: Int { snapshot.cards(in: "running").count }
    var reviewCount: Int { snapshot.cards(in: "review").count }
    var doneCount: Int { snapshot.cards(in: "done").count }

    /// Who's working now, by profile, Hermes first.
    var workingAssignees: [String] {
        let names = Set(snapshot.cards(in: "running").compactMap(\.assignee))
        return names.sorted { a, b in
            if (a == "default") != (b == "default") { return a == "default" }
            return a < b
        }
    }

    /// The iPhone opens on the most urgent column: Blocked with a card that needs you, then
    /// Review, then Running.
    var urgentColumn: String? {
        let keys = columns.map(\.key)
        if needsYouCount > 0, keys.contains("blocked") { return "blocked" }
        for key in ["review", "running"] where keys.contains(key) && !cards(in: key).isEmpty { return key }
        return keys.first { !cards(in: $0).isEmpty } ?? keys.first
    }

    func moves(for card: BoardCard) -> [BoardColumn] {
        workflow?.moves(from: card.column) ?? []
    }

    func columnTitle(_ key: String) -> String {
        workflow?.column(key)?.title ?? BoardColumn(key: key, label: key).title
    }

    /// A profile's name as people know it ("Hermes", "Ada").
    func name(of profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return String(localized: "Nobody") }
        if let bot = roster?.bot(named: profile) { return bot.title }
        return profile == "default" ? "Hermes" : profile.capitalized
    }

    func appearance(of profile: String?) -> BotAppearance? {
        guard let profile else { return nil }
        guard let roster, let bot = roster.bot(named: profile) else { return demoFaces[profile] }
        return roster.appearance(for: bot)
    }

    // MARK: The welcome tour's board

    /// Faces for a board with no roster behind it (the welcome tour).
    @ObservationIgnored private var demoFaces: [String: BotAppearance] = [:]

    /// Shows fixed cards (the welcome tour's `welcomeWork`); `tickDemo` moves its clock.
    func showDemo(_ snapshot: BoardSnapshot, extras: [String: BoardCardExtras], faces: [String: BotAppearance], now: Date) {
        self.snapshot = snapshot
        self.extras = extras
        demoFaces = faces
        self.now = now
        phase = .ready
    }

    func tickDemo(to date: Date) {
        now = date
    }

    /// Who can work on cards: Hermes first, then the Bots in roster order.
    var assignableProfiles: [String] {
        let known = Set(assignees)
        var order = (roster?.visibleBots.map(\.name) ?? []).filter { known.isEmpty || known.contains($0) }
        for name in assignees where !order.contains(name) && roster?.bot(named: name)?.meta.isHidden != true {
            order.append(name)
        }
        if let primary = order.firstIndex(where: { roster?.bot(named: $0)?.isDefault == true || $0 == "default" }) {
            order.insert(order.remove(at: primary), at: 0)
        }
        return order
    }

    // MARK: Lifetime

    /// A view showing the board (or one of its cards) appeared: load it and keep it live.
    func appear(creating: Bool = true) {
        viewers += 1
        if creating, !mayCreate {
            mayCreate = true
            if boardMissing { Task { await load() } }
        }
        stopTask?.cancel()
        stopTask = nil
        if liveTask == nil { liveTask = Task { await run() } }
        if clockTask == nil {
            clockTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30), tolerance: .seconds(6))
                    // Ages ("5 min") redraw the board: not for a Mac app behind other apps.
                    if !AppPresence.isInBack { now = .now }
                }
            }
        }
    }

    /// The last view went away: stop listening shortly after (a push to a card disappears the
    /// board just before the card appears).
    func disappear() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        stopTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, viewers == 0 else { return }
            liveTask?.cancel()
            liveTask = nil
            clockTask?.cancel()
            clockTask = nil
            isLive = false
        }
    }

    /// Loads again (pull to refresh, back online).
    func reload() async {
        await load()
    }

    /// The workspace, for the Bot Mode setup message.
    var owner: BotWorkspace? { workspace }

    /// Turn On, for a Board turned off on the gateway: `kanban` out of `plugins.disabled`
    /// (`PUT /api/config`); its routes come back without a restart.
    func turnOn() async {
        guard let client else { return }
        do {
            try await client.enableBoard()
        } catch {
            notice = BoardCopy.message(for: error)
        }
        await load()
    }

    private func run() async {
        await load()
        while !Task.isCancelled {
            guard let slug = info?.slug, let client else {
                try? await Task.sleep(for: .seconds(2))
                if client != nil, phase != .ready { await load() }
                continue
            }
            do {
                let url = try await client.boardEventsURL(slug, since: cursor)
                isLive = true
                for try await batch in BoardEventStream.batches(url: url) {
                    await apply(batch)
                }
            } catch is CancellationError {
                break
            } catch {
                // Domain and code only: a URLError's description carries the URL, and its token.
                Self.log.notice("board socket: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            }
            isLive = false
            guard !Task.isCancelled else { break }
            // No socket (a proxy that drops it, an older gateway): poll every 5 s, then try again.
            for _ in 0..<6 where !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await loadSnapshot()
            }
        }
        isLive = false
    }

    private func load() async {
        guard let client else {
            if phase != .ready { phase = .needsBotMode }
            return
        }
        do {
            async let workflow = client.boardWorkflow()
            let resolved = try await resolveBoard(client)
            self.workflow = try await workflow
            boardMissing = resolved == nil
            guard let info = resolved else {
                phase = .ready
                return
            }
            self.info = info
            await loadSnapshot()
            phase = .ready
            async let assignees = try? client.boardAssignees(info.slug)
            async let defaultAssignee = try? client.boardDefaultAssignee()
            async let limit = try? client.boardRunLimit()
            self.assignees = await assignees ?? []
            self.defaultAssignee = await defaultAssignee ?? nil
            self.maxRunning = await limit ?? nil
        } catch BackendClient.Failure.http(404, let detail) {
            // "Plugin not found": `kanban` is in `plugins.disabled`; any other 404, a Hermes without it.
            var facts = workspace?.setup.facts ?? GatewaySetupFacts(gatewayName: gatewayName, gatewayOnline: true, botMode: .online)
            facts.botMode = .online
            facts.board = detail == "Plugin not found" ? .turnedOff : .missing
            phase = .notSetUp(GatewaySetup.board(facts))
        } catch is CancellationError {
        } catch {
            if phase != .ready { phase = .failed(BoardCopy.message(for: error)) }
        }
    }

    /// The project's board: the one remembered here, the one the project names, the one scoped
    /// to the project, or a new one (made the first time someone opens the project's Board).
    private func resolveBoard(_ client: BackendClient) async throws -> BoardInfo? {
        let boards = try await client.boards()
        let project = workspace?.projects.project(projectID)
        let remembered = UserDefaults.standard.string(forKey: rememberedSlugKey)
        if let found = boards.first(where: { $0.slug == remembered && ($0.projectID == nil || $0.projectID == projectID) })
            ?? boards.first(where: { $0.slug == project?.boardSlug })
            ?? boards.first(where: { $0.projectID == projectID }) {
            UserDefaults.standard.set(found.slug, forKey: rememberedSlugKey)
            return found
        }
        guard mayCreate else { return nil }
        let base = BoardCopy.slug(project?.slug.isEmpty == false ? project!.slug : (project?.name ?? projectID))
        var slug = base
        var suffix = 2
        while boards.contains(where: { $0.slug == slug }) {
            slug = "\(base)-\(suffix)"
            suffix += 1
        }
        let made = try await client.createBoard(slug: slug, name: project?.name ?? slug, projectID: projectID)
        UserDefaults.standard.set(made.slug, forKey: rememberedSlugKey)
        if let projects = workspace?.projects.client {
            _ = try? await projects.update(id: projectID, boardSlug: made.slug)
        }
        return made
    }

    private func loadSnapshot() async {
        guard let slug = info?.slug, let client else { return }
        do {
            let fresh = try await client.board(slug)
            snapshot = fresh
            cursor = max(cursor, fresh.latestEventID)
            now = .now
            loadExtras()
        } catch is CancellationError {
        } catch {
            // Domain and code only: a URLError's description carries the URL, and its token.
                Self.log.notice("board load: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        }
    }

    /// Details for the cards whose look depends on them: waiting or split cards, and reviews.
    private func loadExtras() {
        let wanted = snapshot.cards.filter { card in
            (card.column == "review" || (card.column == "todo" && card.parentCount > 0)) && extras[card.id] == nil
        }.map(\.id)
        refreshCards(wanted.filter { !extrasLoading.contains($0) })
    }

    // MARK: Live

    private func apply(_ batch: BoardEventBatch) async {
        cursor = max(cursor, batch.cursor)
        now = .now
        for event in batch.events where event.kind == "heartbeat" {
            guard let id = event.cardID, var card = snapshot.card(id) else { continue }
            card.lastHeartbeatAt = event.createdAt ?? .now
            snapshot.upsert(card)
        }
        refreshCards(batch.touchedCards)
    }

    /// Fetches cards' details and puts them on the board in place (an event, an action).
    private func refreshCards(_ ids: [String]) {
        guard !ids.isEmpty, let slug = info?.slug, let client else { return }
        extrasLoading.formUnion(ids)
        Task {
            await withTaskGroup(of: (String, Result<BoardCardDetail, any Error>).self) { group in
                for id in ids {
                    group.addTask {
                        do { return (id, .success(try await client.boardCard(id, board: slug))) } catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    extrasLoading.remove(id)
                    switch result {
                    case .success(let detail):
                        absorb(detail)
                    case .failure(BackendClient.Failure.http(404, _)):
                        snapshot.remove(id)
                        details[id] = nil
                        extras[id] = nil
                        if openCardID == id { openCardID = nil }
                    case .failure:
                        break
                    }
                }
            }
        }
    }

    private func absorb(_ detail: BoardCardDetail) {
        let id = detail.card.id
        let before = snapshot.card(id)
        snapshot.upsert(detail.boardCard)
        extras[id] = detail.extras
        if details[id] != nil || openCardID == id { details[id] = detail }
        if before?.column != detail.card.column { approvalRefusals[id] = nil }
    }

    // MARK: A card

    func loadDetail(_ id: String) async {
        guard let slug = info?.slug, let client else { return }
        do {
            let detail = try await client.boardCard(id, board: slug)
            details[id] = detail
            absorb(detail)
        } catch BackendClient.Failure.http(404, _) {
            snapshot.remove(id)
            details[id] = nil
        } catch {}
    }

    /// Keeps an open card's detail; its worker output refreshes every 3 s while it runs.
    func watchDetail(_ id: String) async {
        var slug = info?.slug
        if slug == nil { slug = await waitForBoard() }
        guard let slug else { return }
        if let client, let detail = try? await client.boardCard(id, board: slug) {
            details[id] = detail
            absorb(detail)
        }
        while !Task.isCancelled {
            guard let card = snapshot.card(id), card.column == "running", let client else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            if let log = try? await client.boardWorkerLog(card.id, board: slug, tail: 4096) {
                logs[id] = log
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func waitForBoard() async -> String? {
        for _ in 0..<40 where info == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return info?.slug
    }

    // MARK: Actions

    /// Runs an action against the board's slug; a refusal becomes the notice, in the app's words.
    @discardableResult
    private func perform(_ failurePrefix: String, _ body: (BackendClient, String) async throws -> Void) async -> Bool {
        guard let slug = info?.slug, let client else {
            notice = String(localized: "Connect to \(gatewayName) first.")
            return false
        }
        do {
            try await body(client, slug)
            return true
        } catch is CancellationError {
            return false
        } catch {
            notice = "\(failurePrefix) \(BoardCopy.message(for: error))"
            return false
        }
    }

    func move(_ card: BoardCard, to column: String) async {
        guard card.column != column else { return }
        let title = columnTitle(column)
        var moved = card
        moved.column = column
        let previous = snapshot
        snapshot.upsert(moved)
        let ok = await perform(String(localized: "Couldn't move it to \(title).")) { client, slug in
            try await client.updateBoardCard(card.id, board: slug, column: column)
        }
        if !ok { snapshot = previous }
        refreshCards([card.id])
    }

    func move(_ ids: [String], to column: String) async {
        guard !ids.isEmpty else { return }
        let title = columnTitle(column)
        await perform(String(localized: "Couldn't move them to \(title).")) { client, slug in
            let results = try await client.updateBoardCards(ids, board: slug, column: column)
            let refused = results.filter { !$0.ok }
            if !refused.isEmpty {
                notice = refused.count == 1
                    ? String(localized: "One card didn't move: \(BoardCopy.refusal(refused[0].error ?? ""))")
                    : String(localized: "\(refused.count) cards didn't move to \(title).")
            }
        }
        refreshCards(ids)
    }

    /// ⌘→ / ⌘←: the selected card to the next column it may go to.
    func moveOpenCard(forward: Bool) async {
        guard let id = openCardID, let card = snapshot.card(id), let target = workflow?.nextMove(from: card.column, forward: forward) else { return }
        await move(card, to: target.key)
    }

    /// Approve: Review → Done. Refused while the PR's required checks fail; the reason shows.
    func approve(_ card: BoardCard) async {
        approvalRefusals[card.id] = nil
        guard let slug = info?.slug, let client else { return }
        do {
            try await client.updateBoardCard(card.id, board: slug, column: "done")
            refreshCards([card.id])
        } catch {
            let detail = try? await client.boardCard(card.id, board: slug)
            if let detail { absorb(detail) }
            approvalRefusals[card.id] = BoardCopy.approvalRefusal(detail: detail, error: error)
        }
    }

    /// Reopen with Note: the note as a comment, then back to Ready.
    @discardableResult
    func reopen(_ card: BoardCard, note: String) async -> Bool {
        let ok = await perform(String(localized: "Couldn't reopen it.")) { client, slug in
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { try await client.commentOnBoardCard(card.id, board: slug, body: text) }
            try await client.updateBoardCard(card.id, board: slug, column: "ready")
        }
        refreshCards([card.id])
        return ok
    }

    /// Reply and Continue: the answer as a comment, then Ready for the dispatcher to pick up.
    @discardableResult
    func reply(_ card: BoardCard, text: String) async -> Bool {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return false }
        let ok = await perform(String(localized: "Couldn't send the reply.")) { client, slug in
            try await client.commentOnBoardCard(card.id, board: slug, body: answer)
            try await client.updateBoardCard(card.id, board: slug, column: "ready")
        }
        refreshCards([card.id])
        return ok
    }

    func comment(_ card: BoardCard, text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        let ok = await perform(String(localized: "Couldn't add the comment.")) { client, slug in
            try await client.commentOnBoardCard(card.id, board: slug, body: body)
        }
        refreshCards([card.id])
        return ok
    }

    /// Stop: the run ends and the card goes back to Ready.
    func stop(_ card: BoardCard) async {
        await perform(String(localized: "Couldn't stop it.")) { client, slug in
            try await client.stopBoardCard(card.id, board: slug, reason: "Stopped from the Hermes app")
        }
        refreshCards([card.id])
    }

    func assign(_ card: BoardCard, to profile: String) async {
        await perform(String(localized: "Couldn't give it to \(name(of: profile)).")) { client, slug in
            try await client.reassignBoardCard(card.id, board: slug, to: profile, stopRun: card.column == "running")
        }
        refreshCards([card.id])
    }

    func assign(_ ids: [String], to profile: String) async {
        await perform(String(localized: "Couldn't give them to \(name(of: profile)).")) { client, slug in
            _ = try await client.updateBoardCards(ids, board: slug, assignee: profile)
        }
        refreshCards(ids)
    }

    func raisePriority(_ card: BoardCard) async {
        await perform(String(localized: "Couldn't raise its priority.")) { client, slug in
            try await client.updateBoardCard(card.id, board: slug, priority: card.priority + 1)
        }
        refreshCards([card.id])
    }

    func edit(_ card: BoardCard, title: String, body: String) async -> Bool {
        let ok = await perform(String(localized: "Couldn't save the card.")) { client, slug in
            try await client.updateBoardCard(card.id, board: slug, title: title, body: body)
        }
        refreshCards([card.id])
        return ok
    }

    func archive(_ card: BoardCard) async {
        snapshot.remove(card.id)
        if openCardID == card.id { openCardID = nil }
        await perform(String(localized: "Couldn't archive it.")) { client, slug in
            try await client.updateBoardCard(card.id, board: slug, column: BoardWorkflow.archived)
        }
        refreshCards([card.id])
    }

    func archive(_ ids: [String]) async {
        for id in ids { snapshot.remove(id) }
        selection.subtract(ids)
        await perform(String(localized: "Couldn't archive them.")) { client, slug in
            _ = try await client.updateBoardCards(ids, board: slug, archive: true)
        }
        refreshCards(ids)
    }

    func delete(_ card: BoardCard) async {
        let ok = await perform(String(localized: "Couldn't delete it.")) { client, slug in
            try await client.deleteBoardCard(card.id, board: slug)
        }
        if ok {
            snapshot.remove(card.id)
            details[card.id] = nil
            if openCardID == card.id { openCardID = nil }
            selection.remove(card.id)
        }
    }

    /// Split into Cards (triage): Hermes fans it out; the reason shows when it can't.
    func split(_ card: BoardCard) async {
        await perform(String(localized: "Couldn't split it.")) { client, slug in
            let outcome = try await client.splitBoardCard(card.id, board: slug)
            if !outcome.ok { notice = String(localized: "Hermes couldn't split it: \(BoardCopy.refusal(outcome.reason ?? ""))") }
            refreshCards([card.id] + outcome.childIDs)
        }
    }

    /// Let Hermes Write It Up (triage): a fuller title and body, then To Do.
    func writeUp(_ card: BoardCard) async {
        await perform(String(localized: "Couldn't write it up.")) { client, slug in
            let outcome = try await client.writeUpBoardCard(card.id, board: slug)
            if !outcome.ok { notice = String(localized: "Hermes couldn't write it up: \(BoardCopy.refusal(outcome.reason ?? ""))") }
        }
        refreshCards([card.id])
    }

    /// Start Now: a Ready card needn't wait for the dispatcher's next tick.
    func startNow() async {
        await perform(String(localized: "Couldn't start it.")) { client, slug in
            try await client.dispatchBoard(slug)
        }
    }

    /// Adds a card; with Let Hermes Write It Up it lands in Triage and Hermes writes it up.
    /// Returns the gateway's warning when nothing will pick it up.
    func add(_ draft: NewBoardCard, writeUp: Bool) async -> (ok: Bool, warning: String?) {
        var draft = draft
        draft.triage = writeUp
        draft.projectID = projectID
        var created: BoardCreated?
        let ok = await perform(String(localized: "Couldn't add the card.")) { client, slug in
            created = try await client.addBoardCard(draft, board: slug)
        }
        guard ok, let card = created?.card else { return (false, nil) }
        snapshot.upsert(card)
        if let warning = created?.warning { warnings[card.id] = BoardCopy.refusal(warning) }
        refreshCards([card.id])
        if writeUp {
            Task { await self.writeUp(card) }
        }
        return (true, created?.warning.map(BoardCopy.refusal))
    }

    func estimate(title: String, body: String) async -> BoardEstimate? {
        guard let client, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? await client.estimateBoardCard(title: title, body: body)
    }

    // MARK: Chats

    /// Open Chat: the chat the card came from.
    func openChat(_ card: BoardCard) {
        guard let id = card.sessionID, let workspace else { return }
        workspace.sidebarMode = .chats
        workspace.open(workspace.session(forKey: id) ?? HermesSession(id: id))
    }

    /// The run's live chat (Watch): the worker's chat in the card's folder, in its profile.
    func workerChat(for card: BoardCard) async -> String? {
        guard let client, let folder = card.workspacePath else { return nil }
        return try? await client.boardWorkerChat(folder: folder, profile: card.assignee)
    }

    func transcript(of sessionID: String, profile: String?) async throws -> SessionTranscript? {
        guard let roster, roster.isConnected else { return nil }
        return try await roster.transcript(storedSessionID: sessionID, profile: profile ?? "default")
    }

    /// Opens a run's chat among the chats, for runs in this gateway's own profile.
    func openWorkerChat(_ sessionID: String, card: BoardCard) {
        guard let workspace else { return }
        var session = HermesSession(id: sessionID)
        session.title = card.title
        session.source = "kanban"
        workspace.sidebarMode = .chats
        workspace.open(session)
    }

    /// The Bot behind a card (its sheet).
    func openBot(_ profile: String) {
        roster?.editingBot = profile
    }

    /// "Default profile · Claude Sonnet 4.6": the profile, and the model the card runs on.
    func assigneeDetail(_ card: BoardCard) -> String {
        let bot = card.assignee.flatMap { roster?.bot(named: $0) }
        var parts: [String] = []
        if bot?.isDefault == true || card.assignee == "default" {
            parts.append(String(localized: "Default profile"))
        } else if let role = bot?.role, !role.isEmpty {
            parts.append(role)
        }
        if let name = card.modelOverride ?? bot?.model { parts.append(ModelNames.display(name)) }
        return parts.joined(separator: " · ")
    }

    /// A link that opens this card on this gateway (Copy Link).
    func link(to card: BoardCard) -> String {
        var components = URLComponents()
        // The scheme this build answers: Hermes Dev opens its own links, not the App Store app's.
        #if DEBUG
        components.scheme = "hermesapp-dev"
        #else
        components.scheme = "hermesapp"
        #endif
        components.host = "board"
        components.path = "/\(projectID)"
        components.queryItems = [URLQueryItem(name: "card", value: card.id)]
        if let id = workspace?.id { components.queryItems?.append(URLQueryItem(name: "gateway", value: id.uuidString)) }
        return components.string ?? ""
    }

    /// Runs in this gateway's own profile open among the chats; a Bot's run shows in Watch.
    func isOwnProfile(_ profile: String?) -> Bool {
        (profile ?? "default") == (workspace?.bot.profileName ?? "default")
    }
}
