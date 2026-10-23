import Foundation
import HermesKit
import Observation

/// What Hermes, or one Bot, learned on a gateway (`docs/learned.md`): the skills it wrote or was
/// taught and the memories it keeps, how they connect, and the curator's tidying. Each Bot learns
/// on its own, so every call names the Bot's profile.
@MainActor
@Observable
final class LearnedModel {
    let workspace: BotWorkspace
    let scope: MemoryModel.Scope

    private(set) var graph: LearningGraph? {
        didSet {
            guard graph != oldValue else { return }
            graphRevision &+= 1
            layouts = [:]
            pendingLayouts = []
        }
    }
    /// Bumped whenever the graph changes: what the map's layouts are keyed on.
    @ObservationIgnored private var graphRevision = 0
    private(set) var curator: CuratorStatus?
    private(set) var report: CuratorReport?
    /// Archived skills (`/curator list-archived`); nil until Tidying asked.
    private(set) var archived: [String]?
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// A tidy started from here is running.
    private(set) var isTidying = false
    /// Skills with a /curator call in flight.
    private(set) var busy: Set<String> = []
    /// A gateway message to show (an action that failed).
    var message: String?
    /// A passing note ("Restored docker-cleanup").
    var toast: String?

    /// The map: the selected node, the filter, and the layout (kept for the graph it was made from).
    var selectedID: String?
    var filter = MapFilter.all
    /// The map's layouts by aspect (rounded to 0.1), for the current graph. Computed off the main
    /// thread: the force layout is O(n²) per step.
    private var layouts: [Double: [String: LearningLayout.Point]] = [:]
    @ObservationIgnored private var pendingLayouts: Set<Double> = []
    @ObservationIgnored private var skillTexts: [String: String] = [:]
    @ObservationIgnored private var creationDates: [String: Date]?

    enum MapFilter: Hashable {
        case all, skills, memories
        case category(String)
    }

    /// Shows a fixed graph with no gateway behind it (the welcome tour's `welcomeLearns`).
    func showDemo(_ graph: LearningGraph) {
        self.graph = graph
    }

    init(workspace: BotWorkspace, scope: MemoryModel.Scope = .hermes) {
        self.workspace = workspace
        self.scope = scope
    }

    // MARK: Gateway

    private var roster: BotRoster? { workspace.roster }
    private var backend: BackendClient? { roster?.boardClient }

    var isOnline: Bool { roster?.isConnected ?? false }
    var needsBotMode: Bool { roster == nil }
    /// "Studio Mac".
    var gatewayName: String { workspace.bot.name }

    var profile: String? {
        switch scope {
        case .hermes: workspace.bot.profileName
        case .bot(let name): name
        }
    }

    var bot: BotProfile? {
        if case .bot(let name) = scope { return roster?.bot(named: name) }
        return nil
    }

    /// "Hermes" or the Bot's name.
    var learnerName: String { bot?.title ?? "Hermes" }

    // MARK: Loading

    func load() async {
        guard let backend else {
            loadError = String(localized: "What Hermes learned is part of Bot Mode.")
            return
        }
        // Bot Mode still connecting: the page loads when it's up (`task(id: isOnline)`).
        guard isOnline else { return }
        isLoading = graph == nil
        defer { isLoading = false }
        do {
            var fresh = try await backend.learningGraph(profile: profile)
            // When each skill was written: the graph's dates are the latest use.
            if creationDates == nil, let text = try? await curatorCommand("usage --json") {
                creationDates = CuratorReply.creationDates(text)
            }
            if let creationDates { fresh = fresh.applyingCreationDates(creationDates) }
            if fresh != graph { graph = fresh }
            loadError = nil
        } catch {
            if graph == nil { loadError = (error as? HermesError)?.errorDescription ?? error.localizedDescription }
        }
        async let status = try? backend.curatorStatus(profile: profile)
        async let latest = try? backend.latestCuratorReport(profile: profile)
        curator = await status ?? curator
        report = await latest ?? report
    }

    func loadArchived() async {
        guard let text = try? await curatorCommand("list-archived") else { return }
        archived = CuratorReply.archivedNames(text)
    }

    // MARK: The story

    var skills: [LearningNode] { graph?.learnedSkills ?? [] }
    var memories: [LearningNode] { graph?.memories ?? [] }
    var newThisWeek: [LearningNode] { graph?.newThisWeek() ?? [] }
    var mostUsed: [LearningNode] { Array((graph?.mostUsed ?? []).prefix(5)) }
    var weeks: [LearningWeek] { graph?.weeks(limit: 12) ?? [] }

    /// "Since August, Hermes wrote 11 skills and learned 20 things about you and your setup."
    var story: String {
        let skillCount = skills.count, memoryCount = memories.count
        let wrote = skillCount == 1 ? String(localized: "wrote 1 skill") : String(localized: "wrote \(skillCount) skills")
        let learned = memoryCount == 1 ? String(localized: "learned 1 thing about you and your setup")
            : String(localized: "learned \(memoryCount) things about you and your setup")
        guard let since = graph?.since else { return String(localized: "\(learnerName) hasn't learned anything here yet.") }
        return String(localized: "Since \(Self.month(since)), \(learnerName) \(wrote) and \(learned).")
    }

    /// Above the map on iPad and the Mac: "Since August: 11 skills Hermes wrote, 20 things it
    /// remembers. Tap a skill to see its connections."
    var mapIntro: String {
        guard let since = graph?.since else { return String(localized: "Tap a skill to see its connections.") }
        let wrote = skills.count == 1 ? String(localized: "1 skill \(learnerName) wrote") : String(localized: "\(skills.count) skills \(learnerName) wrote")
        let remembers = memories.count == 1 ? String(localized: "1 thing it remembers") : String(localized: "\(memories.count) things it remembers")
        return String(localized: "Since \(Self.month(since)): \(wrote), \(remembers). Tap a skill to see its connections.")
    }

    /// "11 skills and 20 memories since August." (iPad, Mac).
    var shortStory: String {
        guard let since = graph?.since else { return String(localized: "Nothing learned yet.") }
        return String(localized: "\(skills.count) skills and \(memories.count) memories since \(Self.month(since)).")
    }

    /// "Most active week: Oct 6, 5 skills and 3 memories" (VoiceOver).
    var chartSummary: String {
        guard let busiest = weeks.max(by: { $0.total < $1.total }), busiest.total > 0 else { return String(localized: "Nothing learned yet.") }
        return String(localized: "Most active week: \(busiest.start.formatted(.dateTime.month(.abbreviated).day())), \(busiest.skills) skills and \(busiest.memories) memories")
    }

    /// The Skills row: "2 new skills this week · tidied 2 days ago".
    var skillsRowSubtitle: String? {
        var parts: [String] = []
        let fresh = newThisWeek.count
        if fresh > 0 { parts.append(fresh == 1 ? String(localized: "1 new skill this week") : String(localized: "\(fresh) new skills this week")) }
        if let last = curator?.lastRunAt { parts.append(String(localized: "tidied \(Formatting.relativePhrase(last))")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide))
    }

    // MARK: A skill

    func node(_ id: String) -> LearningNode? { graph?.node(id) }
    func connections(of id: String) -> [LearningNode] { graph?.connections(of: id) ?? [] }

    /// "Hermes wrote it · used 12 times · yesterday".
    func summary(of skill: LearningNode) -> String {
        var parts = [madeBy(skill)]
        if skill.useCount > 0 { parts.append(skill.useCount == 1 ? String(localized: "used once") : String(localized: "used \(skill.useCount) times")) }
        if let date = skill.date { parts.append(Formatting.relativePhrase(date)) }
        return parts.joined(separator: " · ")
    }

    func madeBy(_ skill: LearningNode) -> String {
        switch skill.createdBy {
        case "agent": String(localized: "Hermes wrote it")
        case "learn": String(localized: "You taught it with /learn")
        default: String(localized: "Used by Hermes")
        }
    }

    func text(of skill: LearningNode) async -> String? {
        if let cached = skillTexts[skill.id] { return cached }
        guard let backend else { return nil }
        guard let text = try? await backend.learnedSkillText(id: skill.id, profile: profile) else { return nil }
        skillTexts[skill.id] = text
        return text
    }

    /// Keep As Is switches still on their way (`docs/chat.md` §4a).
    private var pinChanges = PendingChanges<PinChoice>()

    /// Kept as is, with the switch the person just moved.
    func isPinned(_ skill: LearningNode) -> Bool {
        pinChanges.item(for: skill.id)?.pinned ?? skill.pinned
    }

    /// Keep As Is: the curator never merges, changes or archives a pinned skill. The switch moves
    /// at once; a refusal moves it back and says so.
    func setPinned(_ skill: LearningNode, _ pinned: Bool) async {
        let token = pinChanges.begin(.update(PinChoice(id: skill.id, pinned: pinned)), for: skill.id)
        do {
            let reply = CuratorReply.outcome(try await curatorCommand("\(pinned ? "pin" : "unpin") \(skill.id)"), verb: pinned ? "pin" : "unpin")
            if !reply.ok, pinChanges.isNewest(token, for: skill.id) {
                message = reply.message.isEmpty ? String(localized: "\(gatewayName) didn't change it.") : reply.message
            }
        } catch {
            if pinChanges.isNewest(token, for: skill.id) { message = Self.describe(error) }
        }
        await load()
        pinChanges.settle(token, for: skill.id)
    }

    /// Archive (restorable from Tidying), confirmed first: its page has already closed. A refusal
    /// says so.
    func archive(_ skill: LearningNode) async {
        guard let backend else { return }
        busy.insert(skill.id)
        defer { busy.remove(skill.id) }
        if selectedID == skill.id { selectedID = nil }
        do {
            try await backend.archiveLearnedSkill(id: skill.id, profile: profile)
            toast = String(localized: "Archived \(skill.label). Restore it from Tidying.")
            await load()
            if archived != nil { await loadArchived() }
        } catch {
            message = String(localized: "Couldn't archive \(skill.label). \(Self.describe(error))")
        }
    }

    /// Restore archived skills (an archive, or a merge's originals), one at a time. Their rows say
    /// Restored at once; one the gateway refuses offers Restore again, with why.
    func restore(_ names: [String]) async {
        restoredNames.formUnion(names)
        var failures: [String] = []
        for name in names {
            do {
                let reply = CuratorReply.outcome(try await curatorCommand("restore \(name)"), verb: "restore")
                if !reply.ok {
                    failures.append(reply.message.isEmpty ? name : reply.message)
                    restoredNames.remove(name)
                }
            } catch {
                failures.append(Self.describe(error))
                restoredNames.remove(name)
            }
        }
        if failures.isEmpty {
            toast = names.count == 1 ? String(localized: "Restored \(names[0])") : String(localized: "Restored \(names.count) skills")
        } else {
            message = failures.joined(separator: "\n")
        }
        await load()
        await loadArchived()
    }

    /// Names restored from this page (their rows say so instead of offering Restore again).
    private(set) var restoredNames: Set<String> = []

    /// Saves a SKILL.md (`PUT /api/learning/node`) unless it changed on the gateway since it was
    /// read; nil when saved, else what to say.
    func save(_ skill: LearningNode, content: String, expected: String) async -> String? {
        guard let backend else { return String(localized: "\(gatewayName) is offline. Your text is still here.") }
        do {
            let current = try await backend.learnedSkillText(id: skill.id, profile: profile)
            if current != expected {
                skillTexts[skill.id] = current
                return String(localized: "Hermes changed this skill since you opened it. Copy your text, close and open it again.")
            }
            try await backend.editLearnedSkill(id: skill.id, content: content, profile: profile)
            skillTexts[skill.id] = content
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    // MARK: Leaving for a chat

    /// The chat a skill goes to and the Inspector it opens in: the Bot's chat, or the chat the
    /// window shows.
    private var targetConversation: ConversationModel? {
        switch scope {
        case .bot(let name): roster?.conversation(for: name)
        case .hermes: workspace.currentConversation
        }
    }

    /// Set by whoever shows the page, to close it before a chat takes over (Use in a Chat).
    @ObservationIgnored var onLeave: (() -> Void)?

    /// Use in a Chat: the skill goes into the composer's tray (`Slash.skillChip`).
    func useInChat(_ skill: LearningNode) {
        onLeave?()
        switch scope {
        case .bot(let name):
            workspace.sidebarMode = .bots
            workspace.selection = .bot(name)
            if let conversation = roster?.conversation(for: name), !conversation.skills.contains(skill.id), conversation.skills.count < MessageParts.maxSkills {
                conversation.skills.append(skill.id)
            }
        case .hermes:
            workspace.use(Skill(name: skill.id, category: skill.category))
        }
    }

    /// Edit on iPad and the Mac: the SKILL.md as a File tab of the chat's Inspector.
    struct InspectorTarget: Identifiable {
        let conversation: ConversationModel
        let tabID: String
        var id: String { tabID }
    }

    func openInInspector(_ skillID: String) async -> InspectorTarget? {
        guard let backend, let conversation = targetConversation,
              let path = try? await backend.skillFilePath(name: skillID, profile: profile), !path.isEmpty else { return nil }
        let tab = conversation.inspector.open(.file, key: path, title: "\(skillID) · SKILL.md", present: false)
        skillTexts[skillID] = nil
        return InspectorTarget(conversation: conversation, tabID: tab.id)
    }

    // MARK: Tidying

    func setPaused(_ paused: Bool) async {
        guard let backend else { return }
        curator?.paused = paused
        do {
            try await backend.setCuratorPaused(paused, profile: profile)
        } catch {
            curator?.paused = !paused
            message = Self.describe(error)
        }
        if let fresh = try? await backend.curatorStatus(profile: profile) { curator = fresh }
    }

    /// Tidying turned off in the profile's config (`curator.enabled`, `docs/setup.md` §4.10):
    /// the switch turns it back on (`PUT /api/config`, deep-merged), out of pause too.
    var tidyingIsOff: Bool { curator?.enabled == false }

    func turnOnTidying() async {
        guard let backend else { return }
        curator?.enabled = true
        curator?.paused = false
        do {
            try await backend.updateConfig(.object(["curator": .object(["enabled": .bool(true)])]), profile: profile)
            try await backend.setCuratorPaused(false, profile: profile)
        } catch {
            message = Self.describe(error)
        }
        if let fresh = try? await backend.curatorStatus(profile: profile) { curator = fresh }
    }

    /// Tidy Up Now: the curator runs in the background; the page refreshes when it ends.
    func tidyUpNow() async {
        guard let backend, !isTidying, !tidyingIsOff else { return }
        isTidying = true
        defer { isTidying = false }
        do {
            try await backend.runCurator(profile: profile)
        } catch {
            message = Self.describe(error)
            return
        }
        // A curator pass reviews with a model: minutes, not seconds.
        let deadline = Date.now.addingTimeInterval(20 * 60)
        try? await Task.sleep(for: .seconds(2))
        while Date.now < deadline, !Task.isCancelled {
            guard let state = try? await backend.curatorRunState() else { break }
            if !state.running {
                if let code = state.exitCode, code != 0 { message = String(localized: "The tidy didn't finish (exit \(code)).") }
                break
            }
            try? await Task.sleep(for: .seconds(3))
        }
        await load()
        await loadArchived()
    }

    /// "Every 7 days, when Studio Mac has been idle 2 h".
    var schedule: String {
        guard let curator else { return "" }
        let every: String
        switch curator.intervalHours {
        case let hours? where hours >= 24 && hours % 24 == 0:
            every = hours == 24 ? String(localized: "Every day") : String(localized: "Every \(hours / 24) days")
        case let hours?:
            every = String(localized: "Every \(hours) h")
        case nil:
            every = String(localized: "On a schedule")
        }
        guard let idle = curator.minIdleHours, idle > 0 else { return every }
        let idleText = idle == idle.rounded() ? "\(Int(idle)) h" : String(format: "%.1f h", idle)
        return String(localized: "\(every), when \(gatewayName) has been idle \(idleText)")
    }

    /// "Last tidy 2 days ago: merged 2 overlapping skills, archived 3 unused ones and marked 4 as stale."
    var lastTidySentence: String {
        guard let last = report?.startedAt ?? curator?.lastRunAt else { return String(localized: "Hermes hasn't tidied its skills yet.") }
        let when = Formatting.relativePhrase(last)
        guard let report, report.changedSomething else { return String(localized: "Last tidy \(when): nothing needed changing.") }
        var parts: [String] = []
        let merged = report.merges.count, archived = report.archivedCount
        if merged > 0 { parts.append(merged == 1 ? String(localized: "merged 1 overlapping skill") : String(localized: "merged \(merged) overlapping skills")) }
        if archived > 0 { parts.append(archived == 1 ? String(localized: "archived 1 unused one") : String(localized: "archived \(archived) unused ones")) }
        if report.markedStaleCount > 0 { parts.append(String(localized: "marked \(report.markedStaleCount) as stale")) }
        return String(localized: "Last tidy \(when): \(parts.formatted(.list(type: .and))).")
    }

    /// Skills that are stale now, from the graph.
    var staleSkills: [LearningNode] { (graph?.skills ?? []).filter { $0.state == .stale } }

    // MARK: The map

    /// The layout for a space of this aspect. Until it's ready, the nearest one already laid out
    /// (a rotation or a resize keeps its map), else nothing; the map draws when it lands.
    func positions(aspect: Double) -> [String: LearningLayout.Point] {
        guard let graph else { return [:] }
        let rounded = (aspect * 10).rounded() / 10
        if let ready = layouts[rounded] { return ready }
        if !pendingLayouts.contains(rounded) {
            pendingLayouts.insert(rounded)
            let revision = graphRevision
            Task {
                let positions = await Task.detached(priority: .userInitiated) {
                    LearningLayout.positions(for: graph, aspect: rounded)
                }.value
                guard revision == self.graphRevision else { return }
                self.pendingLayouts.remove(rounded)
                self.layouts[rounded] = positions
            }
        }
        return layouts.min { abs($0.key - rounded) < abs($1.key - rounded) }?.value ?? [:]
    }

    /// Whether a node shows under the current filter.
    func isShown(_ node: LearningNode) -> Bool {
        switch filter {
        case .all: node.state != .archived
        case .skills: node.isSkill && node.state != .archived
        case .memories: !node.isSkill
        case .category(let category): node.category == category && node.state != .archived
        }
    }

    // MARK: `/curator`

    /// `/curator <arg>` in a session of the Bot's (the gateway runs it in the session's slash
    /// worker); the reply is text.
    private func curatorCommand(_ argument: String) async throws -> String {
        guard let roster, roster.isConnected else { throw GatewaySocket.Failure.notConnected }
        let botName: String? = switch scope {
        case .bot(let name): name
        // The gateway's own profile, as the page's REST calls use; else the default one, hidden or not.
        case .hermes: workspace.bot.profileName ?? (roster.visibleBots + roster.hiddenBots).first(where: \.isDefault)?.name
        }
        guard let botName else { throw HermesError.invalidResponse(String(localized: "No session to run /curator in.")) }
        let session = try await roster.conversation(for: botName).runtimeForCommands()
        let reply = try await roster.request("slash.exec", ["session_id": .string(session), "command": .string("/curator \(argument)")], timeout: .seconds(60))
        return reply["output"]?.stringValue ?? reply["message"]?.stringValue ?? ""
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? HermesError, let description = error.errorDescription { return description }
        if let error = error as? GatewayRPCError { return error.message }
        return error.localizedDescription
    }
}

/// A Keep As Is switch on its way (`LearnedModel.setPinned`).
nonisolated struct PinChoice: Identifiable, Sendable {
    var id: String
    var pinned: Bool
}
