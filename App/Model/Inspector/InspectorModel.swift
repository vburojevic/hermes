import Foundation
import HermesKit
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One tab of the Inspector (`inspectorTab`): one thing, identified by its kind and a key (a URL,
/// an artifact's slug, a path, a process, a team).
struct InspectorTab: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        case preview, artifact, file, files, changes, terminal, screen, team, plan, sources
        /// Hermes's browser in this app (`docs/web.md` §6).
        case browser
        /// What a turn did to files, from the chat itself (`docs/inspector.md` §2.7).
        case turnChanges

        var symbol: String {
            switch self {
            case .preview: "globe"
            case .browser: "safari"
            case .artifact: "sparkles"
            case .file: "doc"
            case .files: "folder"
            case .changes: "arrow.triangle.branch"
            case .turnChanges: "plus.forwardslash.minus"
            case .terminal: "apple.terminal"
            case .screen: "desktopcomputer"
            case .team: "person.2"
            case .plan: "checklist"
            case .sources: "link"
            }
        }

        var name: String {
            switch self {
            case .preview: String(localized: "Preview")
            case .browser: String(localized: "Browser")
            case .artifact: String(localized: "Artifact")
            case .file: String(localized: "File")
            case .files: String(localized: "Files")
            case .changes: String(localized: "Changes")
            case .turnChanges: String(localized: "Changed Files")
            case .terminal: String(localized: "Terminal")
            case .screen: String(localized: "Screen")
            case .team: String(localized: "Team")
            case .plan: String(localized: "Plan")
            case .sources: String(localized: "Sources")
            }
        }
    }

    var kind: Kind
    var key: String
    var title: String

    var id: String { "\(kind.rawValue):\(key)" }

    /// The one Changed Files tab: the turn it shows is the Inspector's `changesTurn`.
    static let turnChangesKey = "turn"

    /// The one Terminal tab: the chat's processes (`docs/background-processes.md` §6).
    static let terminalKey = "processes"
    static let terminal = InspectorTab(kind: .terminal, key: terminalKey, title: String(localized: "Terminal"))

    /// Tabs saved before the Terminal listed every process had one tab per process.
    static func current(_ tabs: [InspectorTab]) -> [InspectorTab] {
        var seen: Set<String> = []
        return tabs.compactMap { tab in
            let tab = tab.kind == .terminal ? terminal : tab
            return seen.insert(tab.id).inserted ? tab : nil
        }
    }
}

/// A turn's changes to show in the Changes sheet, and the file to open on.
struct TurnChangesTarget: Identifiable, Hashable {
    var turnKey: String
    var file: String?

    var id: String { turnKey }
}

/// Tabs pinned to stay across every chat on a gateway.
@MainActor
@Observable
final class InspectorPins {
    private(set) var tabs: [InspectorTab]
    @ObservationIgnored private let storageKey: String

    init(workspaceID: UUID) {
        storageKey = "inspector.pins.\(workspaceID.uuidString)"
        tabs = InspectorTab.current(UserDefaults.standard.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([InspectorTab].self, from: $0) } ?? [])
    }

    func contains(_ id: String) -> Bool { tabs.contains { $0.id == id } }

    func pin(_ tab: InspectorTab) {
        guard !contains(tab.id) else { return }
        tabs.append(tab)
        save()
    }

    func unpin(_ id: String) {
        tabs.removeAll { $0.id == id }
        save()
    }

    func retitle(_ id: String, _ title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].title != title else { return }
        tabs[index].title = title
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(tabs), forKey: storageKey)
    }
}

/// A chat's Inspector (`docs/inspector.md`): its tabs, which one shows, what Hermes opened or is
/// using, and the state behind each kind. Tabs come back with the chat; pinned ones stay across
/// chats. Hermes opens Previews (`preview.open`), reads and drives them (`preview.read`,
/// `preview.act`), and reads the Terminal (`terminal.read`). File contents and terminal output
/// are never logged.
@MainActor
@Observable
final class InspectorModel {
    enum SheetHeight: Hashable {
        case medium, large
    }

    @ObservationIgnored private(set) weak var conversation: ConversationModel?
    let pins: InspectorPins

    private(set) var ownTabs: [InspectorTab] = []
    private(set) var selectedID: String?
    /// The panel beside the chat (Mac, iPad landscape) or the sheet (iPhone, iPad portrait).
    var isPresented = false {
        didSet { if isPresented, let selectedID { unseenTabs.remove(selectedID) } }
    }
    var sheetHeight = SheetHeight.medium
    /// The + menu's sheet page on iPhone (`inspectorOpen`).
    var showsOpenGrid = false
    /// Open Address… (⌘L).
    var showsAddressPrompt = false
    /// Where this Inspector shows now; Hermes's requests are declined (4404) when it can't be seen.
    var placement = Placement.hidden
    /// Tabs dragged out into their own window (Mac).
    private(set) var detachedTabs: Set<String> = []
    /// Tabs Hermes opened: the ink dot while it works.
    private(set) var hermesTabs: Set<String> = []
    /// Tabs that changed while unseen (bold until opened).
    private(set) var unseenTabs: Set<String> = []
    /// The commit HEAD pointed at when the latest turn started (This Turn's base).
    private(set) var turnBase: String?
    /// The Terminal shows this process's own page (its whole output); nil: the list.
    var terminalPage: String?
    /// The list row whose output is open; nil: the newest running one's.
    var terminalOpenRow: String?
    /// ⌘. on the Mac: the process waiting for Stop's confirmation.
    var confirmingStop: String?
    /// The turn the Changed Files tab shows, by its `changesKey`; nil: the newest that changed files.
    var changesTurn: String?
    /// The file selected there.
    var changesFile: String?
    /// iPhone, and wherever the Inspector is a sheet: a turn's changes in their own sheet.
    var changesSheet: TurnChangesTarget?
    /// The Inspector sits beside the chat (the Mac, iPad landscape): the chat says so.
    var showsAsPanel = false
    /// A process wrote in the last moments: the Terminal tab's ink dot.
    private(set) var terminalWriting = false
    @ObservationIgnored private var terminalQuiet: Task<Void, Never>?

    enum Placement {
        /// Not on screen (a closed sheet, another chat showing).
        case hidden
        /// Beside the chat or in a sheet.
        case visible
    }

    @ObservationIgnored private var storageKey: String?
    @ObservationIgnored private var previewControllers: [String: PreviewController] = [:]
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    /// The chat left the screen. Two minutes later its previews let their web views go (a
    /// WebContent process each); the tabs stay, and a page loads again when it's next shown.
    /// Tabs in their own window (Mac) keep theirs.
    func chatLeftScreen() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self else { return }
            for (id, controller) in self.previewControllers where !self.detachedTabs.contains(id) {
                controller.tearDown()
            }
        }
    }

    /// Back on screen before the release: nothing goes.
    func chatOnScreen() {
        releaseTask?.cancel()
        releaseTask = nil
    }
    @ObservationIgnored private var editors: [String: FileEditorModel] = [:]
    @ObservationIgnored private var trees: [String: FileTreeModel] = [:]
    @ObservationIgnored private var reviews: [String: ChangesModel] = [:]
    @ObservationIgnored private var screen: ScreenController?
    @ObservationIgnored private var artifactCache: (key: Int, artifacts: [Artifact])?

    init(conversation: ConversationModel, pins: InspectorPins) {
        self.conversation = conversation
        self.pins = pins
    }

    var workspace: BotWorkspace? { conversation?.workspace }

    // MARK: Tabs

    /// Pinned tabs first, then this chat's own; tabs in their own window aren't in the strip.
    var tabs: [InspectorTab] {
        (pins.tabs + ownTabs.filter { !pins.contains($0.id) }).filter { !detachedTabs.contains($0.id) }
    }

    var selected: InspectorTab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    func tab(_ id: String) -> InspectorTab? {
        (pins.tabs + ownTabs).first { $0.id == id }
    }

    func isPinned(_ id: String) -> Bool { pins.contains(id) }

    /// The ink dot: Hermes opened the tab and is still working, or is driving it.
    func isUsedByHermes(_ tab: InspectorTab) -> Bool {
        if driving?.tabID == tab.id { return true }
        if tab.kind == .terminal { return terminalWriting }
        guard hermesTabs.contains(tab.id) else { return false }
        if tab.kind == .screen { return screen?.status?.holder == "agent" && conversation?.isWorking == true }
        return conversation?.isWorking ?? false
    }

    func isUnseen(_ tab: InspectorTab) -> Bool {
        unseenTabs.contains(tab.id) && !(isPresented && selected?.id == tab.id)
    }

    /// Opens (or focuses) a tab and shows the Inspector.
    @discardableResult
    func open(_ kind: InspectorTab.Kind, key: String, title: String, byHermes: Bool = false, present: Bool = true) -> InspectorTab {
        let tab = InspectorTab(kind: kind, key: key, title: title)
        Task { await InspectorTip.opened.donate() }
        if let index = ownTabs.firstIndex(where: { $0.id == tab.id }) {
            if ownTabs[index].title != title, !title.isEmpty { ownTabs[index].title = title }
        } else if pins.contains(tab.id) {
            if !title.isEmpty { pins.retitle(tab.id, title) }
        } else {
            ownTabs.append(tab)
        }
        if byHermes { hermesTabs.insert(tab.id) }
        detachedTabs.remove(tab.id)
        showsOpenGrid = false
        select(tab.id)
        if present { withAnimation(Theme.snappy) { isPresented = true } }
        save()
        return tab
    }

    func select(_ id: String) {
        selectedID = id
        showsOpenGrid = false
        unseenTabs.remove(id)
        save()
    }

    /// ⌘⌥1–9.
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    func close(_ id: String) {
        let wasSelected = selected?.id == id
        let position = tabs.firstIndex { $0.id == id } ?? 0
        if pins.contains(id) { pins.unpin(id) }
        ownTabs.removeAll { $0.id == id }
        hermesTabs.remove(id)
        unseenTabs.remove(id)
        detachedTabs.remove(id)
        previewControllers.removeValue(forKey: id)?.tearDown()
        editors[id] = nil
        trees[id] = nil
        reviews[id] = nil
        // The controller stays: its status is what the Bot's ··· menu reads for Open Screen.
        if id.hasPrefix("screen:") { screen?.disconnect() }
        if id.hasPrefix("team:") { conversation?.helpers.shownTeam = nil; conversation?.helpers.shownHelper = nil }
        if id.hasPrefix("terminal:") { terminalPage = nil }
        if wasSelected {
            let remaining = tabs
            selectedID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)].id
        }
        if tabs.isEmpty { withAnimation(Theme.snappy) { isPresented = false } }
        save()
    }

    /// ⌘W while the panel has focus.
    func closeSelected() {
        if let selected { close(selected.id) }
    }

    func togglePin(_ id: String) {
        guard let tab = tab(id) else { return }
        if pins.contains(id) {
            pins.unpin(id)
            if !ownTabs.contains(where: { $0.id == id }) { ownTabs.append(tab) }
        } else {
            pins.pin(tab)
            ownTabs.removeAll { $0.id == id }
        }
        save()
    }

    func toggle() {
        if isPresented {
            withAnimation(Theme.snappy) { isPresented = false }
        } else {
            if tabs.isEmpty { showsOpenGrid = true }
            withAnimation(Theme.snappy) { isPresented = true }
        }
    }

    /// A tab dragged out into its own window (Mac); closing that window brings it back.
    func detach(_ id: String) {
        detachedTabs.insert(id)
        if selectedID == id { selectedID = tabs.first?.id }
        if tabs.isEmpty { isPresented = false }
    }

    func reattach(_ id: String) {
        guard detachedTabs.remove(id) != nil else { return }
        if tab(id) != nil { select(id) }
    }

    func markChanged(_ id: String) {
        guard !(isPresented && selected?.id == id) else { return }
        unseenTabs.insert(id)
    }

    // MARK: Persistence

    /// This chat's tabs, kept under its stored session once it has one.
    func restore(chatKey: String?, workspaceID: UUID) {
        guard let chatKey else { return }
        let key = "inspector.tabs.\(workspaceID.uuidString).\(chatKey)"
        guard key != storageKey else { return }
        storageKey = key
        guard ownTabs.isEmpty, let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) else {
            save()
            return
        }
        ownTabs = InspectorTab.current(saved.tabs)
        selectedID = saved.selected.map { $0.hasPrefix("terminal:") ? InspectorTab.terminal.id : $0 }
        turnBase = saved.turnBase
    }

    private struct SavedTabs: Codable {
        var tabs: [InspectorTab]
        var selected: String?
        var turnBase: String?
    }

    private func save() {
        guard let storageKey else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(SavedTabs(tabs: ownTabs, selected: selectedID, turnBase: turnBase)), forKey: storageKey)
    }

    // MARK: State behind tabs

    func preview(for tab: InspectorTab) -> PreviewController {
        if let existing = previewControllers[tab.id] { return existing }
        let controller = PreviewController(inspector: self, tabID: tab.id, target: PreviewTarget(tab.key))
        previewControllers[tab.id] = controller
        return controller
    }

    func editor(for tab: InspectorTab) -> FileEditorModel {
        if let existing = editors[tab.id] { return existing }
        let editor = FileEditorModel(inspector: self, path: tab.key)
        editors[tab.id] = editor
        return editor
    }

    func tree(root: String) -> FileTreeModel {
        if let existing = trees[root] { return existing }
        let tree = FileTreeModel(inspector: self, root: root)
        trees[root] = tree
        return tree
    }

    func changes(for tab: InspectorTab) -> ChangesModel {
        if let existing = reviews[tab.id] { return existing }
        let model = ChangesModel(inspector: self, root: tab.key)
        reviews[tab.id] = model
        return model
    }

    /// "Changes · 4": the files a Changes tab lists, once it has looked.
    func changesCount(_ tab: InspectorTab) -> Int? {
        guard let count = reviews[tab.id]?.list?.files.count, count > 0 else { return nil }
        return count
    }

    /// `display.lease`: who controls the Bot Screen now.
    func screenLeaseChanged(_ payload: JSONValue) {
        screen?.leaseChanged(payload)
    }

    func screenController() -> ScreenController {
        if let screen { return screen }
        let controller = ScreenController(inspector: self)
        screen = controller
        return controller
    }

    /// `display.status`, broadcast when a screen starts or stops on the gateway: the status is
    /// read again (it's per Bot, and the broadcast names a Hermes home, not a Bot).
    func screenStatusChanged() {
        guard let screen else { return }
        Task { await screen.refreshStatus() }
    }

    /// Open Screen in the Bot's ··· menu (`docs/inspector.md` §2.6): wherever the gateway can give
    /// the Bot a screen, whether or not this chat has Inspector tabs, so the iPhone, whose
    /// Inspector otherwise opens only from the pill, can reach it.
    var offersOpenScreen: Bool { BotScreenStatus.offersOpenScreen(screen?.status) }

    // MARK: The chat's folder and gateway

    /// Where Files and Changes look: the chat's working folder on the gateway.
    var workingFolder: String? {
        if let cwd = conversation?.liveWorkspace?.cwd, !cwd.isEmpty { return cwd }
        if let placement = conversation?.placement {
            if let cwd = placement.cwd { return cwd }
            if let projectID = placement.projectID, let path = workspace?.projects.project(projectID)?.primaryPath { return path }
        }
        return workspace?.projects.defaultFolder
    }

    /// The REST backend (`/api/fs`, `/api/git`, `/api/display`).
    var backend: BackendClient? { workspace?.roster?.boardClient }

    /// A Bot's files are read through its profile.
    var profile: String? { conversation?.gatewayProfileForCheckpoints }

    /// The gateway machine's host name, for reaching its localhost from another device.
    var gatewayHost: String? { backend?.baseURL.host() }

    /// The gateway this chat is on: its Preview pages keep their own cookies and storage.
    var gatewayID: UUID? { workspace?.bot.id }

    /// "Studio Mac": what the person calls the gateway.
    var gatewayMachineName: String { workspace?.bot.name ?? String(localized: "the gateway") }

    // MARK: What the + menu offers (only kinds with something behind them)

    struct Offer: Identifiable {
        var kind: InspectorTab.Kind
        var detail: String
        var id: InspectorTab.Kind { kind }
    }

    var offers: [Offer] {
        var offers: [Offer] = []
        guard let conversation else { return offers }
        if let folder = workingFolder {
            offers.append(Offer(kind: .files, detail: ProjectPath.lastComponent(folder)))
            let changed = changesSummary
            offers.append(Offer(kind: .changes, detail: changed ?? String(localized: "Git review")))
        }
        if let key = conversation.latestChangesKey, let changes = conversation.changes(forTurn: key) {
            offers.append(Offer(kind: .turnChanges, detail: String(localized: "\(changes.title) · latest turn")))
        }
        let processes = conversation.processes
        if !processes.isEmpty {
            let running = processes.filter(\.isRunning)
            let detail = switch running.count {
            case 0: String(localized: "\(processes.count) finished")
            case 1: String(localized: "\(running[0].name) · running")
            default: String(localized: "\(running.count) running")
            }
            offers.append(Offer(kind: .terminal, detail: detail))
        }
        if let screen, screen.isAvailable {
            let detail = screen.personInControl ? String(localized: "You're in control")
                : screen.someoneElseInControl ? String(localized: "Someone else is in control") : String(localized: "Hermes is using it")
            offers.append(Offer(kind: .screen, detail: detail))
        }
        if let plan = latestPlan, !plan.isEmpty {
            offers.append(Offer(kind: .plan, detail: String(localized: "\(plan.filter { $0.status == .completed }.count) of \(plan.count) done")))
        }
        if let team = conversation.helpers.teams.last {
            let working = team.topLevel.filter { $0.status == .running }.count
            offers.append(Offer(kind: .team, detail: working > 0 ? String(localized: "\(working) helpers working") : String(localized: "\(team.everyone) helpers")))
        }
        let sources = latestSources
        if !sources.isEmpty {
            offers.append(Offer(kind: .sources, detail: String(localized: "\(sources.count) from this turn")))
        }
        return offers
    }

    /// "4 files · +169 −12", once Changes has looked.
    private var changesSummary: String? {
        reviews.values.first?.summary ?? offerSummary
    }

    /// What the + menu learned when it opened (Changes' count, whether the Bot Screen runs).
    private var offerSummary: String?

    /// Looks up what the + menu offers that only the gateway knows: the changes waiting, and
    /// whether Hermes's screen is running (Linux gateways only).
    func refreshOffers() async {
        if let folder = workingFolder, let backend, reviews.isEmpty,
           let list = try? await backend.reviewList(folder, scope: .uncommitted), !list.files.isEmpty {
            offerSummary = list.files.count == 1 ? String(localized: "1 file") : String(localized: "\(list.files.count) files")
        }
        await screenController().refreshStatus()
    }

    /// Opens a kind from the + menu.
    func open(_ kind: InspectorTab.Kind) {
        switch kind {
        case .files:
            guard let folder = workingFolder else { return }
            open(.files, key: folder, title: ProjectPath.lastComponent(folder))
        case .changes:
            guard let folder = workingFolder else { return }
            open(.changes, key: folder, title: String(localized: "Changes"))
        case .terminal:
            openTerminal()
        case .screen:
            open(.screen, key: "bot", title: String(localized: "Screen"))
        case .plan:
            open(.plan, key: "plan", title: String(localized: "Plan"))
        case .team:
            guard let team = conversation?.helpers.teams.last else { return }
            openTeam(team.id)
        case .sources:
            open(.sources, key: "sources", title: String(localized: "Sources"))
        case .preview:
            showsAddressPrompt = true
        case .browser:
            showBrowser(byHermes: false)
        case .turnChanges:
            guard let key = conversation?.latestChangesKey else { return }
            showChanges(turn: key)
        case .artifact, .file:
            break
        }
    }

    // MARK: Hermes's browser (`docs/web.md` §6)

    @ObservationIgnored private var browserStore: BrowserController?
    /// The app as Hermes's browser for this chat, made when it's first needed.
    var browser: BrowserController {
        if let browserStore { return browserStore }
        let controller = BrowserController(inspector: self)
        browserStore = controller
        return controller
    }

    var browserIfLoaded: BrowserController? { browserStore }

    static let browserTabKey = "hermes-browser"

    /// Brings Hermes's browser to the front: a web view off screen stops running the page's
    /// scripts, and the person watches what Hermes does. iPhone shows it in the sheet at medium.
    func showBrowser(byHermes: Bool = true) {
        if !isPresented { sheetHeight = .medium }
        let title = browser.siteTitle ?? String(localized: "Browser")
        open(.browser, key: Self.browserTabKey, title: title, byHermes: byHermes)
    }

    /// The Terminal tab (`docs/background-processes.md` §6): the list, or one process's page.
    /// iPhone shows it in the sheet at medium height.
    func openTerminal(_ processID: String? = nil, byHermes: Bool = false) {
        terminalPage = processID
        if !isPresented { sheetHeight = .medium }
        open(.terminal, key: InspectorTab.terminalKey, title: InspectorTab.terminal.title, byHermes: byHermes)
        Task { await conversation?.refreshProcesses() }
    }

    /// The process the Terminal shows: its page, else the running row whose output is open.
    var selectedProcessID: String? {
        guard isPresented, selected?.kind == .terminal else { return nil }
        let running = (conversation?.processes ?? []).filter(\.isRunning)
        if let terminalPage { return running.contains { $0.id == terminalPage } ? terminalPage : nil }
        if let row = terminalOpenRow, running.contains(where: { $0.id == row }) { return row }
        return running.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }?.id
    }

    /// "Terminal · 2" while two run.
    var terminalRunningCount: Int {
        conversation?.processes.filter(\.isRunning).count ?? 0
    }

    /// Hermes closed a Terminal tab (`terminal.close`): its page goes back to the list; the
    /// process keeps running (§1).
    func terminalClosed(_ processID: String) {
        if terminalPage == processID { terminalPage = nil }
    }

    func openTeam(_ teamID: String) {
        conversation?.helpers.shownTeam = teamID
        open(.team, key: teamID, title: String(localized: "Team"))
    }

    func openFile(_ path: String) {
        let full = path.hasPrefix("/") || path.hasPrefix("~") ? path : ((workingFolder ?? "") as NSString).appendingPathComponent(path)
        open(.file, key: full, title: ProjectPath.lastComponent(full))
    }

    /// A turn's Changes row (`docs/chat.md` §1): its files and diffs in the Changed Files tab
    /// beside the chat, else in a sheet of their own.
    func showChanges(turn key: String, file: String? = nil) {
        if showsAsPanel {
            changesTurn = key
            changesFile = file
            open(.turnChanges, key: InspectorTab.turnChangesKey, title: InspectorTab.Kind.turnChanges.name)
        } else {
            changesSheet = TurnChangesTarget(turnKey: key, file: file)
        }
    }

    func openChanges(scope: ReviewScope = .lastTurn, file: String? = nil) {
        guard let folder = workingFolder else { return }
        let tab = open(.changes, key: folder, title: String(localized: "Changes"))
        let model = changes(for: tab)
        model.scope = scope
        if let file { model.selectedFile = file }
    }

    /// A page card's Open: the tab showing it, or a new one with its label.
    func openPage(url: String, label: String?) {
        let target = PreviewTarget(url)
        if let existing = (pins.tabs + ownTabs).first(where: { $0.kind == .preview && target.matches($0.key) }) {
            detachedTabs.remove(existing.id)
            select(existing.id)
            withAnimation(Theme.snappy) { isPresented = true }
        } else {
            open(.preview, key: url, title: label ?? target.displayURL)
        }
    }

    /// The URL bar or Open Address…: a page, localhost, or a gateway path.
    func openAddress(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = PreviewTarget(trimmed)
        if let existing = tabs.first(where: { $0.kind == .preview && PreviewTarget($0.key).matches(trimmed) }) {
            select(existing.id)
            withAnimation(Theme.snappy) { isPresented = true }
            return
        }
        open(.preview, key: trimmed, title: target.displayURL)
    }

    // MARK: Turn data

    /// The plan of the latest turn that has one (`todo.updated`), the running turn's first.
    var latestPlan: [PlanItem]? {
        // The mirror, not the live turn: this is read in views, which would redraw for every word.
        if let plan = conversation?.livePlan, !plan.isEmpty { return plan }
        return conversation?.items.reversed().lazy.compactMap { item -> [PlanItem]? in
            if case .assistant(let turn) = item, !turn.plan.isEmpty { return turn.plan }
            return nil
        }.first
    }

    /// The latest turn's search results.
    var latestSources: [SearchResult] {
        guard let items = conversation?.items else { return [] }
        for item in items.reversed() {
            guard case .assistant(let turn) = item else { continue }
            let results = turn.steps.flatMap { step -> [SearchResult] in
                if case .tool(let tool) = step { return tool.searchResults }
                return []
            }
            if !results.isEmpty { return results }
        }
        return []
    }

    /// Artifacts found in the chat's replies (`artifact-detect.ts`), each with its versions.
    var artifacts: [Artifact] {
        guard let items = conversation?.items else { return [] }
        let replies: [(turnID: String, text: String, at: Date?)] = items.compactMap { item in
            guard case .assistant(let turn) = item, !turn.isWorking, !turn.answer.isEmpty else { return nil }
            return (turn.id, turn.answer, turn.finishedAt ?? turn.startedAt)
        }
        // Every reply row asks, on every pass: the key has to be cheap. `utf8.count` is O(1);
        // `count` walked every character of every reply, per row.
        var hasher = Hasher()
        for reply in replies {
            hasher.combine(reply.turnID)
            hasher.combine(reply.text.utf8.count)
        }
        let key = hasher.finalize()
        if let cache = artifactCache, cache.key == key { return cache.artifacts }
        let found = Artifact.collect(from: replies)
        artifactCache = (key, found)
        return found
    }

    func artifact(_ slug: String) -> Artifact? {
        artifacts.first { $0.slug == slug }
    }

    func openArtifact(_ artifact: Artifact, version: Int? = nil) {
        let tab = open(.artifact, key: artifact.slug, title: artifact.detection.title)
        if let version { artifactVersions[tab.id] = version }
    }

    /// The version each Artifact tab shows (1-based; nil: the newest).
    var artifactVersions: [String: Int] = [:]
    /// Artifacts the person let reach the network.
    var networkArtifacts: Set<String> = []

    // MARK: Events from the chat

    /// `preview.open {url, label}`: open or focus a Preview tab, with the ink dot.
    func previewOpen(url: String, label: String?) {
        let target = PreviewTarget(url)
        if let existing = tabs.first(where: { $0.kind == .preview && target.matches($0.key) }) ?? ownTabs.first(where: { $0.kind == .preview && target.matches($0.key) }) {
            hermesTabs.insert(existing.id)
            previewControllers[existing.id]?.open(url)
            select(existing.id)
            present(byHermes: true)
            return
        }
        let title = label.flatMap { $0.isEmpty ? nil : $0 } ?? target.displayURL
        open(.preview, key: url, title: title, byHermes: true, present: false)
        present(byHermes: true)
    }

    /// `preview.close {url}`: '' closes every Preview tab.
    func previewClose(url: String) {
        let previews = (pins.tabs + ownTabs).filter { $0.kind == .preview }
        for tab in previews where url.isEmpty || PreviewTarget(tab.key).matches(url) {
            close(tab.id)
        }
    }

    /// `pane.reveal {pane}`: Hermes asks to show a part of the panel.
    func paneReveal(_ pane: String) {
        switch pane {
        case "files": open(.files)
        case "terminal": open(.terminal)
        case "review": openChanges(scope: .lastTurn)
        case "screen": open(.screen)
        default: break
        }
    }

    /// Hermes opened something: on iPhone and iPad it waits behind the pill instead of covering
    /// the chat, unless the sheet is already up.
    private func present(byHermes: Bool) {
        #if os(macOS)
        withAnimation(Theme.snappy) { isPresented = true }
        #else
        if prefersPanel { withAnimation(Theme.snappy) { isPresented = true } }
        #endif
    }

    /// Mac and iPad landscape show the panel beside the chat (set by the chat screen).
    var prefersPanel = false

    /// A turn started: remember HEAD for This Turn.
    func turnStarted() {
        guard let folder = workingFolder, let backend else { return }
        Task {
            if let sha = try? await backend.revParse(folder, ref: "HEAD") {
                turnBase = sha
                save()
            }
        }
    }

    /// A tool wrote a file (`tool.complete` with a diff): localhost Previews reload, open files
    /// that aren't being edited re-read, and Changes refreshes.
    func filesChanged(paths: [String]) {
        for controller in previewControllers.values { controller.reloadIfLocal() }
        for (id, editor) in editors where paths.isEmpty || paths.contains(where: { editor.path.hasSuffix($0) || $0.hasSuffix(editor.path) }) {
            Task { await editor.gatewayChanged() }
            markChanged(id)
        }
        for (id, review) in reviews {
            Task { await review.refresh() }
            markChanged(id)
        }
        for tree in trees.values { Task { await tree.refresh() } }
    }

    /// A turn finished: Hermes's ink dots go out (tabs it opened stay).
    func turnFinished() {
        driving = nil
        personInControl = false
    }

    /// New output in a process: the Terminal tab bolds while unseen, and shows its ink dot while
    /// output keeps coming.
    func processOutput(_ processID: String) {
        markChanged(InspectorTab.terminal.id)
        if !terminalWriting { terminalWriting = true }
        terminalQuiet?.cancel()
        terminalQuiet = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.terminalWriting = false
        }
    }

    /// The person saved a file: the tree's git letters and Changes catch up.
    func fileSaved(_ path: String) {
        for tree in trees.values { Task { await tree.refresh() } }
        for review in reviews.values { Task { await review.refresh() } }
    }

    func previewChanged(tabID: String, title: String) {
        guard !title.isEmpty, let tab = tab(tabID), tab.kind == .preview else { return }
        // A label from Hermes stays; a page's own title names tabs the person opened.
        if !hermesTabs.contains(tabID), tab.title == PreviewTarget(tab.key).displayURL {
            if let index = ownTabs.firstIndex(where: { $0.id == tabID }) { ownTabs[index].title = title }
        }
    }

    // MARK: Reaching localhost (`reachNote`)

    /// Ask Hermes to Share It on the Tailnet: Hermes restarts the dev server listening on the
    /// network (`preview.restart`, a helper the gateway runs), then the page loads again. Older
    /// gateways get the same request as a message.
    func shareOnTailnet(_ controller: PreviewController) {
        guard let conversation else { return }
        let url = controller.target.url?.absoluteString ?? controller.target.displayURL
        let device = Self.deviceName
        let host = gatewayHost ?? gatewayMachineName
        let context = "The Hermes app on \(device) opens this page through \(host) over the tailnet, but the server only listens on localhost. Restart it on the same port bound to all interfaces (0.0.0.0, e.g. --host) so \(host) reaches it. Don't open tunnels or other ports."
        Task {
            if let roster = workspace?.roster, let runtime = conversation.runtimeSessionID {
                var params: [String: JSONValue] = ["session_id": .string(runtime), "url": .string(url), "context": .string(context)]
                if let cwd = workingFolder { params["cwd"] = .string(cwd) }
                if (try? await roster.request("preview.restart", params, timeout: .seconds(20))) != nil { return }
            }
            conversation.sendMessage(String(localized: "\(controller.target.displayURL) doesn't load on \(device): the dev server only listens on localhost. Restart it on the same port listening on the network (0.0.0.0) so I can open it through \(host) over the tailnet. Don't open a tunnel."))
        }
    }

    /// Show a Screenshot Instead: Hermes takes one with its browser tool.
    func askForScreenshot(_ controller: PreviewController) {
        conversation?.sendMessage(String(localized: "Take a screenshot of \(controller.target.displayURL) with your browser tool and show it to me here."))
    }

    /// The restart helper finished: unreachable localhost pages try again.
    func previewServerRestarted() {
        for controller in previewControllers.values where controller.target.isLocalhost {
            controller.reload()
        }
    }

    private static var deviceName: String {
        #if os(macOS)
        String(localized: "a Mac")
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "an iPad") : String(localized: "an iPhone")
        #endif
    }

    // MARK: Hermes driving (`preview.act`)

    /// The Preview Hermes is acting in, while it is (`agentDrivingBar`).
    struct Driving: Equatable {
        var tabID: String
        var action: String
        var step: Int
    }

    private(set) var driving: Driving?
    /// The person took over: Hermes's actions are refused until they hand back.
    private(set) var personInControl = false
    @ObservationIgnored private var drivingEnds: Task<Void, Never>?

    /// What the bar's first line says: the plan's current item, or what Hermes is doing.
    var drivingTitle: String {
        if let item = latestPlan?.first(where: { $0.status == .inProgress }) { return item.content }
        return String(localized: "Hermes is using this page")
    }

    /// "Clicking “Join the beta” · step 3 of 5".
    var drivingDetail: String {
        guard let driving else { return "" }
        if let plan = latestPlan, let index = plan.firstIndex(where: { $0.status == .inProgress }) {
            return String(localized: "\(driving.action) · step \(index + 1) of \(plan.count)")
        }
        return String(localized: "\(driving.action) · step \(driving.step)")
    }

    func takeOver() {
        personInControl = true
        driving = nil
    }

    func handBack() {
        personInControl = false
    }

    /// The person touched the page Hermes was using: Hermes waits.
    func personTouchedPreview(tabID: String) {
        guard driving?.tabID == tabID || (hermesTabs.contains(tabID) && conversation?.isWorking == true) else { return }
        takeOver()
    }

    /// Whether Hermes's requests can be answered here: the Inspector is on screen (iPhone: the
    /// sheet is open), and this chat is the one showing.
    var canAnswerHermes: Bool {
        placement == .visible
    }

    /// Answers a bridge request (`preview.read`, `preview.act`, `terminal.read`, `window.read`);
    /// nil declines it with 4404 (not shown here).
    func answer(_ request: GatewayServerRequest) async -> JSONValue? {
        switch request.method {
        case "window.read":
            // Like the others: only while this chat's Inspector is on screen.
            guard canAnswerHermes else { return nil }
            return Self.windowBelow()
        case "terminal.read":
            guard canAnswerHermes else { return nil }
            return terminalRead(start: request.params["start"]?.truncatedIntValue, count: request.params["count"]?.truncatedIntValue)
        case "preview.read":
            guard canAnswerHermes else { return nil }
            // Nothing open reads as empty: the tool tells Hermes to open a page first.
            guard let tab = activePreviewTab else { return .object(["value": .string("")]) }
            await bringForward(tab)
            return await preview(for: tab).read(start: request.params["start"]?.truncatedIntValue, count: request.params["count"]?.truncatedIntValue)
        case "preview.act":
            guard canAnswerHermes else { return nil }
            guard let action = PreviewAction(params: request.params) else {
                return PreviewBridge.answer(["success": .bool(false), "error": .string("Unknown action.")])
            }
            guard let tab = activePreviewTab else {
                return PreviewBridge.answer(["success": .bool(false), "error": .string("No live page is open in the preview. Open one with desktop_preview first.")])
            }
            if personInControl {
                return PreviewBridge.answer(["success": .bool(false), "error": .string("The person took over the preview, so nothing was done. Wait for them to hand it back, or ask them in the chat.")])
            }
            return await drive(action, in: tab)
        default:
            return nil
        }
    }

    /// The Preview Hermes means: the selected one, else the newest it opened, else any.
    private var activePreviewTab: InspectorTab? {
        let all = pins.tabs + ownTabs
        if let selected, selected.kind == .preview { return selected }
        return all.last { $0.kind == .preview && hermesTabs.contains($0.id) } ?? all.last { $0.kind == .preview }
    }

    /// Hermes reads and acts where the person can see it: its page comes to the front (a web
    /// view that isn't on screen stops running the page's scripts).
    private func bringForward(_ tab: InspectorTab) async {
        guard selected?.id != tab.id, !detachedTabs.contains(tab.id) else { return }
        select(tab.id)
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func drive(_ action: PreviewAction, in tab: InspectorTab) async -> JSONValue {
        let controller = preview(for: tab)
        hermesTabs.insert(tab.id)
        await bringForward(tab)
        if action.verb != .elements {
            let step = (driving?.tabID == tab.id ? driving?.step ?? 0 : 0) + 1
            driving = Driving(tabID: tab.id, action: describe(action), step: step)
        }
        drivingEnds?.cancel()
        if action.actsOnElement {
            let colors = inkColors
            await controller.ring(action, ink: colors.ink, onInk: colors.onInk)
            try? await Task.sleep(for: .milliseconds(600))
        }
        let answer = await controller.act(action)
        await controller.unring()
        // The bar stays while Hermes keeps acting; a quiet moment ends it.
        drivingEnds = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.driving = nil
        }
        return answer
    }

    private func describe(_ action: PreviewAction) -> String {
        let target = action.ref.map { Self.readable(ref: $0) } ?? action.selector ?? ""
        switch action.verb {
        case .click: return target.isEmpty ? String(localized: "Clicking") : String(localized: "Clicking “\(target)”")
        case .type: return target.isEmpty ? String(localized: "Typing") : String(localized: "Typing into “\(target)”")
        case .hover: return String(localized: "Pointing at “\(target)”")
        case .press: return String(localized: "Pressing \(action.key ?? "")")
        case .scroll: return String(localized: "Scrolling")
        case .back: return String(localized: "Going back")
        case .forward: return String(localized: "Going forward")
        case .reload: return String(localized: "Reloading")
        case .elements, .strobe: return String(localized: "Looking at the page")
        }
    }

    /// `btn-join-the-beta` reads as "Join the beta".
    private static func readable(ref: String) -> String {
        var parts = ref.split(separator: "-").map(String.init)
        if parts.count > 1 { parts.removeFirst() }
        if let last = parts.last, Int(last) != nil, parts.count > 1 { parts.removeLast() }
        let words = parts.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The panel's appearance (the app can differ from the system's), for the ring's ink.
    var isDark = false

    /// Ink and its foreground as CSS, for the ring drawn in the page.
    private var inkColors: (ink: String, onInk: String) {
        isDark ? ("#F5F5F7", "#111113") : ("#111113", "#FFFFFF")
    }

    // MARK: terminal.read and window.read

    private func terminalRead(start: Int?, count: Int?) -> JSONValue {
        let processes = conversation?.processTracker.processes ?? []
        let process = terminalPage.flatMap { id in processes.first { $0.id == id } }
            ?? processes.last(where: \.isRunning) ?? processes.last
        guard let process else { return .object(["value": .string("")]) }
        let lines = process.output.text.components(separatedBy: "\n")
        let rows = 40
        let total = lines.count
        let from = max(0, min(start ?? max(0, total - rows), total))
        // A count near Int.max would overflow the addition and stop the app (security scan F26).
        let to = max(from, min(from + min(max(1, count ?? rows), 20_000), total))
        var text = Array(lines[from..<to])
        while let last = text.last, last.trimmingCharacters(in: .whitespaces).isEmpty { text.removeLast() }
        return PreviewBridge.answer([
            "total_lines": .number(Double(total)), "start": .number(Double(from)), "end": .number(Double(to)),
            "viewport_rows": .number(Double(rows)), "cursor_row": .number(Double(max(0, total - 1))),
            "text": .string(text.joined(separator: "\n")),
        ])
    }

    /// The window behind this app's (Mac): app, title and bounds, never pixels.
    private static func windowBelow() -> JSONValue {
        #if os(macOS)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return PreviewBridge.answer(["error": .string("Window enumeration is unavailable."), "platform": .string("darwin")])
        }
        let mine = ProcessInfo.processInfo.processIdentifier
        let windows = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let myIndex = windows.firstIndex(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == mine }) else {
            return PreviewBridge.answer(["error": .string("Hermes has no window on screen."), "platform": .string("darwin")])
        }
        guard let below = windows[(myIndex + 1)...].first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) != mine }) else {
            return PreviewBridge.answer(["window": .null, "frontmost": .bool(NSApp.isActive), "platform": .string("darwin"), "note": .string("No other window is behind Hermes.")])
        }
        let bounds = below[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let title = below[kCGWindowName as String] as? String ?? ""
        var answer: [String: JSONValue] = [
            "window": .object([
                "app": .string(below[kCGWindowOwnerName as String] as? String ?? ""),
                "title": .string(title),
                "bounds": .object(["x": .number(bounds["X"] ?? 0), "y": .number(bounds["Y"] ?? 0), "width": .number(bounds["Width"] ?? 0), "height": .number(bounds["Height"] ?? 0)]),
                "id": .number(Double(below[kCGWindowNumber as String] as? Int ?? 0)),
            ]),
            "frontmost": .bool(NSApp.isActive),
            "platform": .string("darwin"),
        ]
        if title.isEmpty { answer["note"] = .string("macOS withholds window titles until Hermes has Screen Recording permission.") }
        return PreviewBridge.answer(answer)
        #else
        return PreviewBridge.answer(["error": .string("iPhone and iPad show one app at a time, so there's no window behind Hermes to read."), "platform": .string("ios")])
        #endif
    }
}
