import Foundation
import HermesKit
import Observation
import SwiftUI

/// A chat's helpers (`docs/helpers.md`): live teams from `subagent.*` events, reconciled with
/// `subagent.list` on open and resume, saved to the spawn-tree archive when they finish, and
/// loaded back from it for past turns. Owned by the chat's `ConversationModel`.
@MainActor
@Observable
final class HelperStore {
    /// What the views read; published from `staged` at most every 0.25 s, so ten busy helpers don't
    /// redraw the transcript on every tool.
    private(set) var tracker = HelperTracker()
    @ObservationIgnored private var staged = HelperTracker()
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Gateway-wide pause switch and limits (`delegation.status`).
    private(set) var delegation: DelegationStatus?
    /// Live transcripts of the helpers whose detail is open (`subagent.tail`).
    private(set) var tails: [String: HelperTail] = [:]
    /// Notes sent to helpers, by helper id, oldest first.
    private(set) var notes: [String: [HelperNote]] = [:]
    /// Saved runs of this chat, by label (the delegation id).
    private(set) var savedTrees: [String: SpawnTreeEntry] = [:]
    private(set) var loadingTree: String?
    /// "It had already finished" after a Stop that found nothing to stop.
    var message: String?

    /// The teams by id and delegation call, changing only when a team comes or goes: the
    /// transcript reads this, not `tracker`, so a busy team doesn't redraw every row.
    private(set) var teamKeys: [TeamKey] = []

    struct TeamKey: Equatable {
        let id: String
        let callID: String?
    }

    // MARK: Navigation

    /// The team on the Team page (iPhone, iPad portrait) or in the inspector (Mac, iPad landscape).
    var shownTeam: String?
    /// The helper open on the Team page or in the inspector.
    var shownHelper: String?
    /// iPhone: a helper opened straight from the chat, without the Team page under it.
    var pushedHelper: String?

    @ObservationIgnored private weak var conversation: ConversationModel?
    @ObservationIgnored private var tailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var listedTrees = false
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var treeLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saving: Set<String> = []

    init(conversation: ConversationModel) {
        self.conversation = conversation
    }

    struct HelperNote: Identifiable, Equatable {
        enum State: Equatable {
            /// Accepted; it reads it after its current step.
            case waiting
            /// Its next step came: it has it.
            case read
            /// Rejected, or it finished before reading it.
            case missed
        }

        let id = UUID()
        let text: String
        var state: State
        let sentAt = Date.now
    }

    private var client: HelpersClient? {
        guard let roster = conversation?.gatewayRosterForHelpers, roster.isConnected else { return nil }
        return HelpersClient { method, params in try await roster.request(method, params) }
    }

    private var sessionID: String? { conversation?.runtimeSessionID }

    /// The gateway socket is up: helper calls can go out.
    var isConnected: Bool { conversation?.gatewayRosterForHelpers?.isConnected ?? false }

    // MARK: Reading

    var teams: [HelperTeam] { tracker.orderedTeams }
    var hasLiveHelpers: Bool { tracker.hasLiveHelpers }

    func team(forCall callID: String) -> HelperTeam? { tracker.team(forCall: callID) }
    func team(id: String) -> HelperTeam? { tracker.team(id: id) }
    func team(containing helperID: String) -> HelperTeam? { tracker.team(containing: helperID) }
    func helper(_ id: String) -> Helper? { tracker.helper(id) }

    /// Teams no `delegate_task` in the transcript claims, by call or delegation id (events seen
    /// before the call returned, or a chat opened mid-run): shown with the latest reply.
    func unanchoredTeamIDs(claimed: Set<String>) -> [String] {
        teamKeys.filter { key in !claimed.contains(key.id) && !(key.callID.map(claimed.contains) ?? false) }.map(\.id)
    }

    /// The latest team, for ⌥⌘T.
    var latestTeamID: String? { teamKeys.last?.id }

    /// ⌥⌘T: the Team inspector (or page) for the latest team, or closes it.
    func toggleTeam() {
        if shownTeam != nil {
            shownTeam = nil
            shownHelper = nil
        } else {
            shownTeam = latestTeamID
        }
    }

    // MARK: Events

    func receive(_ event: GatewayEvent) {
        let helperID = event.payload["subagent_id"]?.stringValue
        guard staged.apply(type: event.type, payload: event.payload, sessionID: event.sessionID.isEmpty ? sessionID : event.sessionID) else { return }
        if let helperID { updateNotes(helperID: helperID, type: event.type) }
        schedulePublish()
        if let team = staged.team(containing: helperID ?? ""), team.isFinished { save(team) }
    }

    /// The parent turn's `delegate_task` call: where the team card goes.
    func delegationEvent(_ event: GatewayEvent) {
        guard let callID = event.payload["tool_id"]?.stringValue else { return }
        if event.type == "tool.start" {
            staged.delegationStarted(callID: callID)
        } else {
            staged.delegationReturned(callID: callID, result: event.payload["result"], sessionID: event.sessionID.isEmpty ? sessionID : event.sessionID)
        }
        schedulePublish()
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.publishTask = nil
            if self.tracker != self.staged {
                withAnimation(Theme.snappy) { self.tracker = self.staged }
                self.updateKeys()
            }
        }
    }

    private func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        if tracker != staged {
            tracker = staged
            updateKeys()
        }
    }

    private func updateKeys() {
        let keys = tracker.orderedTeams.map { TeamKey(id: $0.id, callID: $0.callID) }
        if keys != teamKeys { teamKeys = keys }
    }

    /// Notes are read at the helper's next step; one it hadn't read when it finished is missed.
    /// Hermes also names a note that never landed in the summary ("[steer did not land — …]"), which
    /// catches one taken for read because a tool ran after it was sent.
    private func updateNotes(helperID: String, type: String) {
        guard var list = notes[helperID], list.contains(where: { $0.state != .missed }) else { return }
        switch type {
        case "subagent.tool", "subagent.thinking", "subagent.progress":
            for index in list.indices where list[index].state == .waiting && Date.now.timeIntervalSince(list[index].sentAt) > 0.3 {
                list[index].state = .read
            }
        case "subagent.complete":
            let summary = staged.helper(helperID)?.summary ?? ""
            let landed = !summary.contains("[steer did not land")
            for index in list.indices where list[index].state != .missed {
                let named = !landed && summary.contains(String(list[index].text.prefix(60)))
                if list[index].state == .waiting || named { list[index].state = .missed }
            }
        default:
            return
        }
        notes[helperID] = list
    }

    // MARK: Snapshots

    /// `subagent.list` for the chat's live session: on open and on every resume.
    func reconcile() async {
        guard let client, let sessionID else { return }
        do {
            let list = try await client.list(sessionID: sessionID)
            staged.reconcile(list: list, sessionID: sessionID)
            publishNow()
            for team in staged.orderedTeams where team.isFinished { save(team) }
        } catch {
            // An older gateway has no `subagent.list` (-32601); a gone session answers 4001.
        }
    }

    func loadStatus() async {
        guard let client else { return }
        if let status = try? await client.status() { delegation = status }
    }

    // MARK: Actions

    /// Stops one helper (`subagent.interrupt`); a waiting one is cancelled the same way.
    func stop(_ helper: Helper) {
        guard let client, let sessionID else { return }
        Task {
            do {
                let found = try await client.interrupt(sessionID: sessionID, helperID: helper.id)
                if !found { message = String(localized: "It had already finished.") }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// A note for one helper (`subagent.steer`): it reads it after its current step.
    func steer(_ helper: Helper, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var note = HelperNote(text: trimmed, state: .waiting)
        guard let client, let sessionID, helper.status.isLive, helper.acceptingSteer else {
            note.state = .missed
            notes[helper.id, default: []].append(note)
            return
        }
        notes[helper.id, default: []].append(note)
        let id = note.id
        Task {
            let result = (try? await client.steer(sessionID: sessionID, helperID: helper.id, text: trimmed)) ?? .rejected
            if result == .rejected {
                staged.steerRejected(helperID: helper.id)
                publishNow()
                setNote(id, of: helper.id, to: .missed)
            }
        }
    }

    private func setNote(_ id: UUID, of helperID: String, to state: HelperNote.State) {
        guard let index = notes[helperID]?.firstIndex(where: { $0.id == id }) else { return }
        notes[helperID]?[index].state = state
    }

    func discardNote(_ note: HelperNote, of helperID: String) {
        notes[helperID]?.removeAll { $0.id == note.id }
    }

    /// "Send to Hermes": the note goes to the parent instead.
    func sendNoteToHermes(_ note: HelperNote, of helperID: String) {
        discardNote(note, of: helperID)
        conversation?.sendMessage(note.text)
    }

    /// "Ask Hermes to Retry": Hermes has no retry call, so the parent is asked.
    func askToRetry(_ helper: Helper, in team: HelperTeam) {
        conversation?.sendMessage(String(localized: "Retry helper \(team.number(of: helper)): \(helper.goal)"))
    }

    /// Stops (or allows again) new helpers on the whole gateway.
    func setPaused(_ paused: Bool) {
        guard let client else { return }
        delegation?.paused = paused
        Task {
            if let value = try? await client.setPaused(paused) { delegation?.paused = value }
            await loadStatus()
        }
    }

    // MARK: Live transcript

    /// Polls `subagent.tail` every 2 s while a helper's detail is on screen.
    func startTail(_ helperID: String) {
        guard tailTasks[helperID] == nil else { return }
        tailTasks[helperID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = self.client, let sessionID = self.sessionID, self.helper(helperID)?.status.isLive == true,
                   let tail = try? await client.tail(sessionID: sessionID, helperID: helperID) {
                    if tail.available || self.tails[helperID] == nil { self.tails[helperID] = tail }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopTail(_ helperID: String) {
        tailTasks.removeValue(forKey: helperID)?.cancel()
    }

    // MARK: Spawn trees

    /// Saves a finished team (Hermes doesn't); the label is its delegation id, so the turn finds it
    /// again after a restart. Never a team known only from its failures; and one that finished out
    /// of sight only if no record of it exists (another device may have watched it to the end).
    private func save(_ team: HelperTeam) {
        guard team.savedPath == nil, !team.isPartial, !saving.contains(team.id), let client, let key = conversation?.sessionID else { return }
        saving.insert(team.id)
        Task {
            if team.all.contains(where: \.endedUnseen) {
                await listSavedTrees()
                if savedTrees[team.id] != nil {
                    saving.remove(team.id)
                    return
                }
            }
            if let path = try? await client.save(team, sessionKey: key, label: team.id) {
                staged.markSaved(teamID: team.id, path: path)
                publishNow()
            }
            saving.remove(team.id)
        }
    }

    /// The saved runs of this chat (once), for past turns' summaries. Callers share one request,
    /// which outlives a row that scrolls away or turns into a team while it runs.
    func listSavedTrees() async {
        if listedTrees { return }
        if let listing {
            await listing.value
            return
        }
        guard let client, let key = conversation?.sessionID else { return }
        let task = Task { [weak self] in
            guard let entries = try? await client.savedTrees(sessionKey: key) else { return }
            // One run per label: the fullest record, then the newest.
            var byLabel: [String: SpawnTreeEntry] = [:]
            for entry in entries {
                guard let label = entry.label, !label.isEmpty else { continue }
                if let kept = byLabel[label], kept.count > entry.count || (kept.count == entry.count && (kept.finishedAt ?? .distantPast) >= (entry.finishedAt ?? .distantPast)) {
                    continue
                }
                byLabel[label] = entry
            }
            self?.savedTrees = byLabel
            self?.listedTrees = true
        }
        listing = task
        await task.value
        listing = nil
    }

    /// Loads a past run's team from the archive, or fills in one known only from its failures.
    func loadTree(delegationID: String) async {
        if let running = treeLoads[delegationID] {
            await running.value
            return
        }
        guard staged.team(id: delegationID).map(\.isPartial) ?? true, let entry = savedTrees[delegationID], let client else { return }
        loadingTree = delegationID
        let task = Task { [weak self] in
            guard let team = try? await client.loadTree(path: entry.path, teamID: delegationID) else { return }
            self?.staged.load(tree: team)
            self?.publishNow()
        }
        treeLoads[delegationID] = task
        await task.value
        treeLoads[delegationID] = nil
        if loadingTree == delegationID { loadingTree = nil }
    }

    /// Called when the person leaves the chat.
    func pause() {
        tailTasks.values.forEach { $0.cancel() }
        tailTasks = [:]
    }
}

/// A past turn's delegation, from its stored `delegate_task` result.
struct StoredDelegation: Equatable {
    var delegationID: String
    var count: Int
    var goals: [String]

    init?(tool: ToolActivity) {
        guard tool.name == "delegate_task", let object = HelperTracker.object(tool.result.map(JSONValue.string)),
              let id = object["delegation_id"]?.stringValue else { return nil }
        delegationID = id
        let goals: [String] = if case .array(let rows)? = object["goals"] { rows.compactMap(\.stringValue) } else { [] }
        self.goals = goals
        count = object["count"]?.truncatedIntValue ?? goals.count
    }
}

extension EnvironmentValues {
    /// The chat's helpers, for the transcript's team cards.
    @Entry var helperStore: HelperStore?
}

/// Who the composer is writing to while steering a helper ("To helper 1 · it reads this after its
/// current step").
struct HelperSteerTarget: Equatable {
    var helperID: String
    var number: String
}
