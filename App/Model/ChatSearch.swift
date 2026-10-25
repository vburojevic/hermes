import HermesKit
import SwiftUI

/// Search (`docs/search.md`): chats found by what was said in them, for the drawer (iPhone), the
/// sidebar (iPad, Mac ⌥⌘F) and the ⌘K palette (Mac). One per gateway workspace.
///
/// Full text needs Bot Mode: `GET /api/sessions/search` lives on the `hermes serve` dashboard, not
/// on the API server the chat list comes from. Without it, and offline, chats match by title only.
@MainActor
@Observable
final class ChatSearch {
    enum Filter: String, CaseIterable, Identifiable {
        case all, chats, projects, bots, tasks
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .chats: String(localized: "Chats")
            case .projects: String(localized: "Projects")
            case .bots: String(localized: "Bots")
            case .tasks: String(localized: "Tasks")
            }
        }
    }

    /// Where results came from.
    enum Reach: Equatable {
        /// What was said, on the gateway.
        case fullText
        /// Offline: the chats saved on this device, by title.
        case savedTitles
        /// No Bot Mode: the gateway's chats, by title.
        case titlesOnly
        /// Titles that match, shown while the gateway searches what was said.
        case titlesFirst
    }

    /// One chat found.
    struct Hit: Identifiable, Hashable {
        let result: SessionSearchResult
        /// The Bot whose chats it was found in (the face shown under it).
        var botName: String?
        var id: String { result.id }
    }

    @ObservationIgnored private weak var workspace: BotWorkspace?

    /// What's typed. Each change waits 250 ms, then searches; the request before it is cancelled.
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }

    var filter: Filter = .all {
        didSet { if filter != oldValue { schedule(after: .zero) } }
    }

    private(set) var hits: [Hit] = []
    /// Projects whose name matches (Projects and All).
    private(set) var projects: [HermesProject] = []
    /// The query the shown results are for. While the next ones load, these stay, dimmed.
    private(set) var shownQuery = ""
    private(set) var isLoading = false
    private(set) var reach: Reach = .fullText
    private(set) var failure: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastAnnouncement = Date.distantPast

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// "4 chats mention “reconnect”".
    var countLine: String? {
        guard !shownQuery.isEmpty, !hits.isEmpty || !projects.isEmpty else { return nil }
        let quoted = "“\(shownQuery)”"
        if reach != .fullText {
            return hits.count == 1 ? String(localized: "1 chat title has \(quoted)") : String(localized: "\(hits.count) chat titles have \(quoted)")
        }
        return hits.count == 1 ? String(localized: "1 chat mentions \(quoted)") : String(localized: "\(hits.count) chats mention \(quoted)")
    }

    /// What's shown is for another query than the one typed (dimmed while the search for it runs).
    var showsEarlierQuery: Bool {
        !shownQuery.isEmpty && shownQuery != query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing found for a finished search.
    var isEmpty: Bool { !isLoading && !shownQuery.isEmpty && hits.isEmpty && projects.isEmpty && failure == nil }

    func clear() {
        query = ""
        filter = .all
    }

    // MARK: Searching

    private func schedule(after delay: Duration = .milliseconds(250)) {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hits = []
            projects = []
            shownQuery = ""
            isLoading = false
            failure = nil
            return
        }
        isLoading = true
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.run(text)
        }
    }

    /// Searches again now (pull to refresh, the gateway came back).
    func refresh() {
        schedule(after: .zero)
    }

    private func run(_ text: String) async {
        guard let workspace else { return }
        let filter = filter
        let projectMatches = (filter == .all || filter == .projects) ? matchingProjects(text, in: workspace) : []
        var found: [Hit] = []
        var reach = Reach.fullText
        var failure: String?
        if let roster = workspace.roster, roster.isConnected, workspace.connection.isOnline {
            // Titles that match show while the gateway searches what was said, from the list this
            // device has: only if it hasn't answered in 0.4 s (a busy Mac takes its time), so a
            // quick search doesn't show one list and then another.
            let titles = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, text == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                let matches = Self.titleHits(text, filter: filter, in: workspace)
                guard !matches.isEmpty else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    self.hits = matches
                    self.projects = projectMatches
                    self.shownQuery = text
                    self.reach = .titlesFirst
                    self.failure = nil
                }
            }
            defer { titles.cancel() }
            do {
                found = try await fullText(text, filter: filter, roster: roster, workspace: workspace)
                titles.cancel()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Titles still match: show them, and say why that's all (`docs/setup.md` §4.7).
                failure = String(localized: "Couldn't search what was said (\(error.localizedDescription)). Showing titles that match.")
                found = Self.titleHits(text, filter: filter, in: workspace)
            }
        } else {
            reach = workspace.connection.isOnline ? .titlesOnly : .savedTitles
            found = Self.titleHits(text, filter: filter, in: workspace)
        }
        guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        withAnimation(.smooth(duration: 0.2)) {
            hits = found
            projects = projectMatches
            shownQuery = text
            self.reach = reach
            self.failure = failure
            isLoading = false
        }
        announce()
    }

    /// Chats whose title matches, from the list the app has.
    private static func titleHits(_ text: String, filter: Filter, in workspace: BotWorkspace) -> [Hit] {
        SessionSearch.titleMatches(text, in: workspace.sessions)
            .filter { session in
                switch filter {
                case .tasks: session.source == SessionSearch.taskSource
                case .chats: session.source != SessionSearch.taskSource
                case .projects: workspace.projects.projectID(forSession: session) != nil
                case .bots: false
                case .all: true
                }
            }
            .map { Hit(result: SessionSearchResult(sessionID: $0.id, lineageRoot: $0.lineageRootID, title: $0.title, preview: $0.preview,
                                                   snippet: $0.preview ?? "", source: $0.source, model: $0.model,
                                                   sessionStarted: $0.startedAt, lastActive: $0.lastActive)) }
    }

    /// The gateway's search: the default profile, and each Bot's for All and Bots.
    private func fullText(_ text: String, filter: Filter, roster: BotRoster, workspace: BotWorkspace) async throws -> [Hit] {
        let profile = workspace.bot.profileName
        var found: [Hit] = []
        switch filter {
        case .chats:
            found = try await roster.searchSessions(text, limit: 40, profile: profile, sources: [], excludeSources: [SessionSearch.taskSource])
                .map { Hit(result: $0) }
        case .tasks:
            found = try await roster.searchSessions(text, limit: 40, profile: profile, sources: [SessionSearch.taskSource], excludeSources: [])
                .map { Hit(result: $0) }
        case .projects:
            found = try await roster.searchSessions(text, limit: 60, profile: profile, sources: [], excludeSources: [SessionSearch.taskSource])
                .filter { workspace.projects.projectID(forSessionID: $0.sessionID) != nil || workspace.projects.projectID(forSessionID: $0.lineageRoot ?? "") != nil }
                .map { Hit(result: $0) }
        case .bots, .all:
            if filter == .all {
                found = try await roster.searchSessions(text, limit: 40, profile: profile, sources: [], excludeSources: [])
                    .map { Hit(result: $0) }
            }
            // One search per Bot (its profile), in parallel.
            let bots = roster.visibleBots.filter { !$0.isDefault }.map(\.name)
            let perBot = try await withThrowingTaskGroup(of: [Hit].self) { group in
                for name in bots {
                    group.addTask {
                        let results = (try? await roster.searchSessions(text, limit: 10, profile: name, sources: [], excludeSources: [])) ?? []
                        return results.map { Hit(result: $0, botName: name) }
                    }
                }
                var all: [Hit] = []
                for try await hits in group { all += hits }
                return all
            }
            found += perBot
            found = RowTime.ordered(found, pinned: { _ in false }) { self.time(of: $0) }
        }
        return found
    }

    private func matchingProjects(_ text: String, in workspace: BotWorkspace) -> [HermesProject] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace)
        return workspace.projects.activeProjects.filter { project in
            let name = project.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// The count line, read out when results change, at most once a second.
    private func announce() {
        guard let line = isEmpty ? String(localized: "No chats mention “\(shownQuery)”") : countLine,
              Date.now.timeIntervalSince(lastAnnouncement) >= 1 else { return }
        lastAnnouncement = .now
        AccessibilityNotification.Announcement(line).post()
    }

    // MARK: Its time

    /// The time a result shows and sorts by (`docs/search.md` §2): the row's time for a chat the
    /// app lists (the chat list, a project's chats, a Bot's chat), else when the chat started.
    func time(of hit: Hit) -> Date? {
        hit.result.time(row: workspace.flatMap { rowTime(of: hit, in: $0) })
    }

    private func rowTime(of hit: Hit, in workspace: BotWorkspace) -> Date? {
        let result = hit.result
        if let botName = hit.botName {
            // A Bot's result opens its Bot Chat, but only the Bot Chat itself has the Bot's row time.
            guard let roster = workspace.roster, let bot = roster.bot(named: botName), let chat = bot.canonicalSession,
                  [chat.id, chat.resolvedID].contains(result.sessionID) || result.lineageRoot == chat.id else { return nil }
            return roster.rowTime(for: bot)
        }
        let keys = [result.lineageRoot, result.sessionID].compactMap { $0 }
        if let session = keys.lazy.compactMap(workspace.session(forKey:)).first
            ?? workspace.sessions.first(where: { $0.id == result.sessionID }) {
            return workspace.rowTime(session)
        }
        let projects = workspace.projects!
        for id in keys {
            guard let projectID = projects.projectID(forSessionID: id), let row = projects.chats(in: projectID).first(where: {
                $0.id == id || $0.stableID == id
            }) else { continue }
            return workspace.rowTime(row)
        }
        return nil
    }

    // MARK: Where a chat lives

    enum Place {
        case project(HermesProject, lane: String?)
        case bot(BotProfile, BotAppearance)
        case task(name: String)
    }

    /// The project tile and lane, the Bot's face, or the task it ran for.
    func place(of hit: Hit) -> Place? {
        guard let workspace else { return nil }
        if let botName = hit.botName, let roster = workspace.roster, let bot = roster.bot(named: botName) {
            return .bot(bot, roster.appearance(for: bot))
        }
        if hit.result.isTaskRun {
            return .task(name: hit.result.title ?? String(localized: "Task"))
        }
        let ids = [hit.result.sessionID, hit.result.lineageRoot].compactMap { $0 }
        for id in ids {
            if let projectID = workspace.projects.projectID(forSessionID: id), let project = workspace.projects.projects[projectID] {
                return .project(project, lane: workspace.projects.lane(forSessionID: id))
            }
        }
        return nil
    }
}
