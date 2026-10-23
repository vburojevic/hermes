import Foundation
import HermesKit
import Observation
import SwiftUI

/// Hermes' scheduled jobs, shown as Tasks (`docs/tasks.md`). A change shows at once and settles in
/// place when the gateway answers (`docs/chat.md` §4a): New Task's row appears as the sheet closes,
/// Pause and Delete move the row now, and a refusal puts it back with a note.
@MainActor
@Observable
final class TasksModel {
    /// What the gateway last said.
    private var gatewayJobs: [CronJob] = []
    private var pending = PendingChanges<CronJob>()
    /// Tasks whose Run Now the gateway hasn't answered yet.
    private(set) var starting: Set<String> = []
    /// New tasks the gateway made: the row's id while it was on its way, and the gateway's id, so
    /// a detail opened on the new row keeps working.
    private var madeIDs: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var loadError: HermesError?
    /// What the gateway refused, said once.
    var refusal: RefusedChange?
    /// A new task the gateway refused, kept so New Task can open with it again.
    var refusedDraft: TaskPrefill?

    /// The tasks with every change still on its way: active first by next run, paused last.
    var jobs: [CronJob] {
        pending.applied(to: gatewayJobs).sorted(by: Self.order)
    }

    /// The task with this id, following a new task to the id the gateway gave it.
    func job(id: String) -> CronJob? {
        let id = madeIDs[id] ?? id
        return jobs.first { $0.id == id }
    }

    /// A new task the gateway hasn't made yet: it can't be paused, run or deleted until it has.
    func isAdding(_ job: CronJob) -> Bool {
        job.id.hasPrefix(Self.newPrefix) && pending.isPending(job.id)
    }

    func load(client: HermesClient?) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            gatewayJobs = try await client.jobs()
            loadError = nil
        } catch {
            loadError = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
    }

    /// New Task: the row shows now, and the gateway's job replaces it.
    func create(_ draft: NewCronJob, client: HermesClient?) async {
        guard let client else {
            // New Task has closed: keep what was typed.
            refusedDraft = TaskPrefill(name: draft.name, schedule: draft.schedule, prompt: draft.prompt)
            refusal = RefusedChange(String(localized: "Couldn't add “\(draft.name)”"),
                                    message: String(localized: "The gateway isn't connected. Edit it and try again."))
            return
        }
        let id = Self.newPrefix + UUID().uuidString
        let token = pending.begin(.insert(CronJob(making: draft, id: id)), for: id)
        do {
            let created = try await client.createJob(draft)
            gatewayJobs.removeAll { $0.id == created.id }
            gatewayJobs.append(created)
            madeIDs[id] = created.id
        } catch {
            refusedDraft = TaskPrefill(name: draft.name, schedule: draft.schedule, prompt: draft.prompt)
            refusal = RefusedChange(String(localized: "Couldn't add “\(draft.name)”"), message: Self.reason(error)
                + " " + String(localized: "Edit it and try again."))
        }
        pending.settle(token, for: id)
    }

    func setPaused(_ job: CronJob, _ paused: Bool, client: HermesClient?) async {
        guard let client, !isAdding(job) else { return }
        let token = pending.begin(.update(job.paused(paused)), for: job.id)
        do {
            let updated = paused ? try await client.pauseJob(id: job.id) : try await client.resumeJob(id: job.id)
            take(updated)
        } catch {
            if pending.isNewest(token, for: job.id) {
                refusal = RefusedChange(paused ? String(localized: "Couldn't pause “\(job.name)”") : String(localized: "Couldn't resume “\(job.name)”"), error: error)
            }
        }
        pending.settle(token, for: job.id)
    }

    /// Run Now: the row says it's starting until the gateway has the run.
    func runNow(_ job: CronJob, client: HermesClient?) async {
        guard let client, !isAdding(job), !starting.contains(job.id) else { return }
        starting.insert(job.id)
        defer { starting.remove(job.id) }
        do {
            try await client.runJobNow(id: job.id)
            AccessibilityNotification.Announcement(String(localized: "\(job.name) started")).post()
        } catch {
            refusal = RefusedChange(String(localized: "Couldn't run “\(job.name)”"), error: error, undone: false)
        }
    }

    /// Delete: the row goes now, and comes back if the gateway refuses. No confirmation (§1).
    func remove(_ job: CronJob, client: HermesClient?) async {
        guard let client, !isAdding(job) else { return }
        let token = pending.begin(.remove, for: job.id)
        do {
            try await client.deleteJob(id: job.id)
            gatewayJobs.removeAll { $0.id == job.id }
        } catch {
            if pending.isNewest(token, for: job.id) {
                refusal = RefusedChange(String(localized: "Couldn't delete “\(job.name)”"), error: error)
            }
        }
        pending.settle(token, for: job.id)
    }

    private func take(_ job: CronJob) {
        if let index = gatewayJobs.firstIndex(where: { $0.id == job.id }) {
            gatewayJobs[index] = job
        }
    }

    private static let newPrefix = "new-task-"

    private static func reason(_ error: any Error) -> String {
        (error as? HermesError)?.errorDescription ?? error.localizedDescription
    }

    private static func order(_ lhs: CronJob, _ rhs: CronJob) -> Bool {
        switch (lhs.isPaused, rhs.isPaused) {
        case (false, true): return true
        case (true, false): return false
        default: return (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
        }
    }
}
