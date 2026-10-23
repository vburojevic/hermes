import HermesKit
import SwiftUI

struct TasksView: View {
    let workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    @State private var model = TasksModel()
    @State private var isCreating = false
    /// What New Task opens with when something suggested the task.
    @State private var prefill: TaskPrefill?
    @State private var inspecting: CronJob?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad (regular width) and Mac: the list beside the selected task (`ipadTasks`, `macTasks`).
    private var usesSplit: Bool {
        #if os(macOS)
        true
        #else
        sizeClass == .regular
        #endif
    }

    var body: some View {
        content
            .background(Theme.canvas)
            .navigationTitle("Tasks")
            .toolbar {
                if let onToggleSidebar {
                    ToolbarItem(placement: .navigation) {
                        SidebarButton(action: onToggleSidebar)
                    }
                    .sidebarButtonGlass()
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                    .help("New task")
                }
                #endif
            }
            .task(id: workspace.id) { await model.load(client: workspace.client) }
            .task(id: workspace.pendingNewTask) {
                // Something suggested a task (setup's morning briefing): New Task, filled in.
                guard let pending = workspace.pendingNewTask else { return }
                workspace.pendingNewTask = nil
                prefill = pending
                isCreating = true
            }
            .refreshable { await model.load(client: workspace.client) }
            .sheet(isPresented: $isCreating, onDismiss: { prefill = nil }) {
                NavigationStack {
                    NewTaskView(prefill: prefill) { draft in
                        Task { await model.create(draft, client: workspace.client) }
                    }
                }
                #if os(macOS)
                .frame(width: 520, height: 560)
                #endif
            }
            .sheet(item: $inspecting) { job in
                NavigationStack {
                    TaskDetailView(job: job, model: model, workspace: workspace)
                }
                #if os(macOS)
                .frame(width: 520, height: 520)
                #endif
            }
            .alert(model.refusal?.title ?? "", isPresented: refusalBinding, presenting: model.refusal) { _ in
                if let draft = model.refusedDraft {
                    Button("Edit Task") {
                        model.refusedDraft = nil
                        prefill = draft
                        isCreating = true
                    }
                    Button("Discard", role: .cancel) { model.refusedDraft = nil }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { refusal in
                Text(refusal.message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.jobs.isEmpty {
            StateMessage(
                symbol: "calendar.badge.exclamationmark",
                title: String(localized: "Couldn't load tasks"),
                message: error.errorDescription,
                actionTitle: String(localized: "Try Again")
            ) {
                Task { await model.load(client: workspace.client) }
            }
        } else if model.jobs.isEmpty && model.isLoading {
            SkeletonRows()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if model.jobs.isEmpty {
            StateMessage(
                symbol: "calendar.badge.clock",
                title: String(localized: "No scheduled tasks"),
                message: String(localized: "Ask Hermes to do something on a schedule — a morning briefing, a nightly backup check — and it runs on its own."),
                actionTitle: String(localized: "New Task")
            ) {
                isCreating = true
            }
        } else if usesSplit {
            TasksSplitView(workspace: workspace, model: model, onCreate: { isCreating = true }, togglePause: togglePause, runNow: runNow)
        } else {
            List {
                Section {
                ForEach(model.jobs) { job in
                    let isAdding = model.isAdding(job)
                    Button {
                        inspecting = job
                    } label: {
                        TaskRow(job: job, isAdding: isAdding, isStarting: model.starting.contains(job.id))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if !isAdding {
                            Button(role: .destructive) {
                                Task { await model.remove(job, client: workspace.client) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                togglePause(job)
                            } label: {
                                Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause")
                            }
                            .tint(Theme.warning)
                        }
                    }
                    .contextMenu {
                        if !isAdding {
                            Button("Run Now", systemImage: "play.circle") { runNow(job) }
                            Button(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause") { togglePause(job) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await model.remove(job, client: workspace.client) }
                            }
                        }
                    }
                }
                } footer: {
                    Text("Tasks are the gateway's scheduled jobs. Ask Hermes to “check the backups every morning” in any chat to add one.")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            #endif
        }
    }

    private func togglePause(_ job: CronJob) {
        Task { await model.setPaused(job, !job.isPaused, client: workspace.client) }
    }

    private func runNow(_ job: CronJob) {
        Task { await model.runNow(job, client: workspace.client) }
    }

    private var refusalBinding: Binding<Bool> {
        Binding(get: { model.refusal != nil }, set: { if !$0 { model.refusal = nil } })
    }
}

/// A task (`screens/iphone/tasks.elyx`): icon tile, name, the schedule in words, and a tag
/// for what's next: when it runs, how the last run went, or that it's paused.
struct TaskRow: View {
    let job: CronJob
    /// New Task's row before the gateway has made the task.
    var isAdding = false
    /// Run Now before the gateway has the run.
    var isStarting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(schedule)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                status
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 10)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var schedule: String {
        let words = ScheduleText.humanize(job.scheduleDisplay)
        return job.skills.isEmpty ? words : "\(words) · \(job.skills.joined(separator: ", "))"
    }

    @ViewBuilder
    private var status: some View {
        // Still words, not a spinner: the change is shown, the gateway settles it (`docs/chat.md` §4a).
        if isAdding {
            TagLabel(title: String(localized: "Adding…"), symbol: "arrow.up.circle")
        } else if isStarting {
            TagLabel(title: String(localized: "Starting…"), symbol: "play.circle")
        } else if job.isPaused {
            TagLabel(title: String(localized: "Paused"), symbol: "pause.fill", style: .warning)
        } else if job.hasFailed {
            TagLabel(title: String(localized: "Last run failed"), symbol: "exclamationmark.triangle.fill", style: .danger)
        } else if job.deliveryFailed {
            TagLabel(title: String(localized: "Results didn't arrive"), symbol: "tray.and.arrow.down", style: .warning)
        } else if job.missedRun {
            TagLabel(title: String(localized: "Last run didn't start"), symbol: "exclamationmark.triangle", style: .warning)
        } else if let next = job.nextRunAt, next > .now {
            TagLabel(title: String(localized: "Next run in \(Self.span(until: next))"), symbol: "clock")
        } else if let last = job.lastRunAt {
            TagLabel(title: String(localized: "Last ran \(Self.span(until: last)) ago"), symbol: "checkmark", style: .success)
        } else if job.nextRunAt != nil {
            TagLabel(title: String(localized: "Due now"), symbol: "clock")
        }
    }

    /// "21 h", "3 min", "2 d".
    private static func span(until date: Date) -> String {
        let seconds = abs(date.timeIntervalSinceNow)
        let duration = Duration.seconds(seconds)
        if seconds < 3600 {
            return duration.formatted(.units(allowed: [.minutes], width: .abbreviated, maximumUnitCount: 1))
        } else if seconds < 86_400 * 2 {
            return duration.formatted(.units(allowed: [.hours], width: .abbreviated, maximumUnitCount: 1))
        }
        return duration.formatted(.units(allowed: [.days], width: .abbreviated, maximumUnitCount: 1))
    }
}

private struct TaskDetailView: View {
    let job: CronJob
    let model: TasksModel
    let workspace: BotWorkspace
    @Environment(\.dismiss) private var dismiss

    private var current: CronJob {
        model.job(id: job.id) ?? job
    }

    var body: some View {
        Form {
            Section("Prompt") {
                Text(current.prompt.isEmpty ? String(localized: "No prompt") : current.prompt)
                    .textSelection(.enabled)
            }
            Section("Schedule") {
                LabeledContent("Runs", value: ScheduleText.humanize(current.scheduleDisplay))
                if let next = current.nextRunAt {
                    LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                }
                if let last = current.lastRunAt {
                    LabeledContent("Last run", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let completed = current.repeatCompleted, completed > 0 {
                    LabeledContent("Completed runs", value: "\(completed)")
                }
            }
            if !current.skills.isEmpty {
                Section("Skills") {
                    Text(current.skills.joined(separator: ", "))
                }
            }
            TaskProblemSection(job: current)
            Section {
                Button(model.starting.contains(current.id) ? "Starting…" : "Run Now", systemImage: "play.circle") {
                    let job = current
                    Task { await model.runNow(job, client: workspace.client) }
                }
                .disabled(model.starting.contains(current.id))
                Button(current.isPaused ? "Resume" : "Pause", systemImage: current.isPaused ? "play" : "pause") {
                    let job = current
                    Task { await model.setPaused(job, !job.isPaused, client: workspace.client) }
                }
            } footer: {
                if model.isAdding(current) {
                    Text("Hermes is still adding this task.")
                }
            }
            .disabled(model.isAdding(current))
        }
        .formStyle(.grouped)
        .navigationTitle(current.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// What New Task opens with, when something suggested the task (setup's morning briefing).
struct TaskPrefill: Hashable {
    var name: String
    var schedule: String
    var prompt: String

    /// "Get a morning briefing" (`setupReady`).
    static var morningBriefing: TaskPrefill {
        TaskPrefill(
            name: String(localized: "Morning briefing"),
            schedule: "every day at 07:30",
            prompt: String(localized: "Good morning. Give me today's weather, what's on my calendar, and anything that needs me. Keep it short.")
        )
    }
}

/// New Task. Create closes it at once: the task shows in the list and settles there when the
/// gateway has made it, or comes back here with the gateway's reason (`docs/tasks.md` §1).
private struct NewTaskView: View {
    var prefill: TaskPrefill?
    let onCreate: (NewCronJob) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = "every day at 09:00"
    @State private var prompt = ""

    private static let presets = ["in 30m", "every 1h", "every day at 09:00", "0 9 * * 1"]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !schedule.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("Name", text: $name, prompt: Text("Morning briefing"))
                TextField("What should Hermes do?", text: $prompt, prompt: Text("Summarise overnight news and my calendar"), axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                TextField("Schedule", text: $schedule)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.self) { preset in
                            Button {
                                schedule = preset
                            } label: {
                                ChipLabel(title: preset, isActive: schedule == preset)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Hermes understands “in 30m”, “every 2h”, “every day at 09:00”, “every weekday at 08:00” and cron expressions such as “0 9 * * 1”.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Task")
        .onAppear {
            guard let prefill, name.isEmpty, prompt.isEmpty else { return }
            name = prefill.name
            schedule = prefill.schedule
            prompt = prefill.prompt
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: save).disabled(!canSave)
            }
        }
    }

    private func save() {
        onCreate(NewCronJob(
            name: name.trimmingCharacters(in: .whitespaces),
            schedule: schedule.trimmingCharacters(in: .whitespaces),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss()
    }
}

/// What went wrong with a task's last run, and what it means (`docs/setup.md` §4.11): a run that
/// failed, results that didn't arrive where they go, or a run that never started.
struct TaskProblemSection: View {
    let job: CronJob

    var body: some View {
        if let problem = job.problem {
            Section {
                Text(problem)
                    .font(Theme.Typography.code)
                    .foregroundStyle(job.hasFailed ? Theme.danger : Theme.primaryText)
                    .textSelection(.enabled)
                if job.deliveryFailed || job.missedRun {
                    SetupDocsLink(url: GatewaySetup.Docs.cronDelivery)
                }
            } header: {
                Text(title)
            } footer: {
                if job.deliveryFailed {
                    Text("The task ran, but Hermes couldn't send its result to \(job.deliver ?? "its destination"). Set that up on the gateway, or have the task deliver somewhere else.")
                } else if job.missedRun {
                    Text("Hermes couldn't start the task when it was due. It tries again at the next run.")
                }
            }
        }
    }

    private var title: String {
        if job.hasFailed { return String(localized: "Last error") }
        if job.deliveryFailed { return String(localized: "Results didn't arrive") }
        return String(localized: "Last run didn't start")
    }
}
