import Foundation
import HermesKit
import Observation
import SwiftUI

/// One Bot's routines (`docs/tasks.md` §5). A change shows at once and settles in place when the
/// gateway answers (`docs/chat.md` §4a): the switch flips, a deleted row goes, a new routine shows
/// as New Routine closes, and a refusal puts it back with a note.
@MainActor
@Observable
final class RoutinesModel {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    let roster: BotRoster
    let botName: String

    /// What the gateway last said.
    private var gatewayRoutines: [BotRoutine] = []
    private var pending = PendingChanges<BotRoutine>()
    private(set) var phase = Phase.loading
    /// Routines whose Run Now the gateway hasn't answered yet.
    private(set) var starting: Set<String> = []
    /// What the gateway refused, said once.
    var refusal: RefusedChange?
    /// A new routine the gateway refused, kept so New Routine can open with it again.
    var refusedDraft: RoutineDraft?

    init(roster: BotRoster, botName: String) {
        self.roster = roster
        self.botName = botName
    }

    /// The routines with every change still on its way: active first by next run, paused last.
    var routines: [BotRoutine] {
        pending.applied(to: gatewayRoutines).sorted { lhs, rhs in
            if lhs.isPaused != rhs.isPaused { return !lhs.isPaused }
            return (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
        }
    }

    /// A new routine the gateway hasn't made yet: it can't be paused, run or deleted until it has.
    func isAdding(_ routine: BotRoutine) -> Bool {
        routine.id.hasPrefix(Self.newPrefix) && pending.isPending(routine.id)
    }

    func load() async {
        if gatewayRoutines.isEmpty, pending.isEmpty { phase = .loading }
        do {
            let fresh = try await roster.routines(for: botName)
            withAnimation(phase == .loaded ? Theme.spring : nil) {
                gatewayRoutines = fresh
            }
            phase = .loaded
        } catch {
            phase = .failed(BotRoster.describe(error))
        }
    }

    /// New Routine: the row shows now, and the gateway's job replaces it.
    func add(_ draft: RoutineDraft) async {
        let id = Self.newPrefix + UUID().uuidString
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = draft.schedule.expression
        let made = BotRoutine(making: title, for: botName, prompt: prompt, schedule: schedule,
                              deliver: draft.postsInChat ? "bot-chat" : "local", id: id)
        let token = pending.begin(.insert(made), for: id)
        phase = .loaded
        do {
            let created = try await roster.addRoutine(for: botName, title: title, prompt: prompt,
                                                      schedule: schedule, deliverToBotChat: draft.postsInChat)
            if let created {
                gatewayRoutines.removeAll { $0.id == created.id }
                gatewayRoutines.append(created)
            } else {
                // An answer without the job: read the list before the row settles.
                await load()
            }
            AccessibilityNotification.Announcement(String(localized: "Routine saved")).post()
        } catch {
            refusedDraft = draft
            refusal = RefusedChange(String(localized: "Couldn't add “\(title)”"),
                                    message: BotRoster.describe(error) + " " + String(localized: "Edit it and try again."))
            AccessibilityNotification.Announcement(refusal?.message ?? "").post()
        }
        pending.settle(token, for: id)
    }

    func setPaused(_ routine: BotRoutine, _ paused: Bool) async {
        guard !isAdding(routine) else { return }
        let token = pending.begin(.update(routine.paused(paused)), for: routine.id)
        do {
            if let updated = try await roster.setRoutine(routine, paused: paused, for: botName),
               let index = gatewayRoutines.firstIndex(where: { $0.id == updated.id }) {
                gatewayRoutines[index] = updated
            } else {
                await load()
            }
        } catch {
            if pending.isNewest(token, for: routine.id) {
                refuse(paused ? String(localized: "Couldn't pause “\(routine.title)”") : String(localized: "Couldn't resume “\(routine.title)”"), error)
            }
        }
        pending.settle(token, for: routine.id)
    }

    /// Delete (asked first in the view): the row goes now, and comes back if the gateway refuses.
    func remove(_ routine: BotRoutine) async {
        guard !isAdding(routine) else { return }
        let token = pending.begin(.remove, for: routine.id)
        do {
            try await roster.removeRoutine(routine, for: botName)
            gatewayRoutines.removeAll { $0.id == routine.id }
        } catch {
            if pending.isNewest(token, for: routine.id) {
                refuse(String(localized: "Couldn't delete “\(routine.title)”"), error)
            }
        }
        pending.settle(token, for: routine.id)
    }

    /// Run Now: the row says it's starting until the gateway has the run.
    func runNow(_ routine: BotRoutine) async {
        guard !isAdding(routine), !starting.contains(routine.id) else { return }
        starting.insert(routine.id)
        defer { starting.remove(routine.id) }
        do {
            try await roster.runRoutineNow(routine, for: botName)
            AccessibilityNotification.Announcement(String(localized: "\(routine.title) started")).post()
        } catch {
            refuse(String(localized: "Couldn't run “\(routine.title)”"), error, undone: false)
        }
    }

    private func refuse(_ title: String, _ error: any Error, undone: Bool = true) {
        let note = RefusedChange(title, error: HermesError.botMode(error), undone: undone)
        refusal = note
        AccessibilityNotification.Announcement("\(note.title). \(note.message)").post()
    }

    private static let newPrefix = "new-routine-"
}

/// What New Routine collects, kept when the gateway refuses it so it can open again.
struct RoutineDraft: Equatable {
    var title = ""
    var prompt = ""
    var schedule = RoutineSchedule(kind: .daily, time: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now,
                                   weekday: 2, hours: 6, delay: .thirtyMinutes, cron: "0 8 * * *")
    var postsInChat = true
}
