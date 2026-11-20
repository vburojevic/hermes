import HermesKit
import SwiftUI

struct TasksView: View {
    let workspace: BotWorkspace

    @State private var model = TasksModel()
    @State private var isCreating = false
    /// What New Task opens with when something suggested the task.
    @State private var prefill: TaskPrefill?
    /// The task open on iPhone, pushed over the list.
    @State private var opened: CronJob?
    /// The task Delete is asking about (`docs/tasks.md` §1).
    @State private var deleting: CronJob?
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
                #if os(iOS)
                // iPad: over the list, after the sidebar button, so the sidebar button keeps the
                // top left and … keeps the detail's top right (`ipadTasks`).
                ToolbarItem(placement: usesSplit ? .topBarLeading : .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New task")
                    .help("New task")
                }
                #else
                // Mac: + leads the toolbar in every state (`macTasksEmpty`); once there are tasks
                // the split puts it there with the selected task's buttons after it.
                if model.jobs.isEmpty {
                    ToolbarItem {
                        Button("New Task", systemImage: "plus") { isCreating = true }
                            .help("New Task (⌘N)")
                    }
                }
                #endif
            }
            .task(id: LoadTrigger(workspace: workspace)) {
                // Read when Tasks opens and again whenever the gateway comes online (a late
                // connect, a reconnect, a new address). Offline, a read only says why the list is
                // empty: a list already shown stays as it is.
                guard workspace.connection.isOnline || model.jobs.isEmpty else { return }
                await model.load(client: workspace.client)
            }
            .task(id: workspace.pendingNewTask) {
                // Something suggested a task (setup's morning briefing): New Task, filled in.
                guard let pending = workspace.pendingNewTask else { return }
                workspace.pendingNewTask = nil
                prefill = pending
                isCreating = true
            }
            .modifier(TasksRefresh(model: model, workspace: workspace))
            .refreshable { await model.load(client: workspace.client) }
            .sheet(isPresented: $isCreating, onDismiss: { prefill = nil }) {
                #if os(macOS)
                NewTaskView(prefill: prefill) { draft in
                    Task { await model.create(draft, client: workspace.client) }
                }
                #else
                NavigationStack {
                    NewTaskView(prefill: prefill) { draft in
                        Task { await model.create(draft, client: workspace.client) }
                    }
                }
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

    private var content: some View {
        // One alert for every Delete: swipe, menus, VoiceOver and the detail's … menu. A list a
        // pushed detail covers can't show it, so on iPhone the detail asks while it's open.
        states.modifier(deleteAlert(isPresented: deletingBinding(when: usesSplit || opened == nil)))
    }

    private func deleteAlert(isPresented: Binding<Bool>) -> some ViewModifier {
        DeleteAlert(title: deleteTitle, isPresented: isPresented, job: deleting) { job in
            if opened?.id == job.id { opened = nil }
            Task { await model.remove(job, client: workspace.client) }
        }
    }

    @ViewBuilder
    private var states: some View {
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
            loading
        } else if model.jobs.isEmpty {
            StateMessage(
                symbol: "calendar.badge.clock",
                title: String(localized: "No scheduled tasks"),
                message: String(localized: "Ask Hermes to do something on a schedule, like a morning briefing or a nightly backup check, and it runs on its own."),
                actionTitle: String(localized: "New Task")
            ) {
                isCreating = true
            }
        } else if usesSplit {
            TasksSplitView(workspace: workspace, model: model, onCreate: { isCreating = true }, togglePause: togglePause,
                           runNow: runNow, remove: { deleting = $0 })
        } else {
            phoneList
        }
    }

    /// The first read. The Mac draws it as the split: skeleton rows in the list beside an empty
    /// detail (`macTasksLoading`, `docs/tasks.md` §4).
    @ViewBuilder
    private var loading: some View {
        let rows = SkeletonRows()
            .accessibilityLabel(Text("Loading tasks"))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        HStack(spacing: 0) {
            rows
                .frame(minWidth: 240, idealWidth: 340, maxWidth: 340)
            Divider()
            Theme.groupedBackground
                .accessibilityHidden(true)
        }
        #else
        rows
        #endif
    }

    /// iPhone: the list, each task pushing its detail (`tasks`, `taskDetail`).
    private var phoneList: some View {
        List {
            Section {
                ForEach(model.jobs) { job in
                    let isAdding = model.isAdding(job)
                    Button {
                        opened = job
                    } label: {
                        TaskRow(job: job, isAdding: isAdding, isStarting: model.starting.contains(job.id))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if !isAdding {
                            Button(role: .destructive) {
                                deleting = job
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
                            TaskActions(job: job, togglePause: togglePause, runNow: runNow, remove: { deleting = $0 })
                        }
                    }
                    .taskAccessibilityActions(job, isAdding: isAdding, togglePause: togglePause, runNow: runNow,
                                              remove: { deleting = $0 })
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
        .navigationDestination(item: $opened) { job in
            TaskDetailPane(job: job, model: model, workspace: workspace, togglePause: togglePause, runNow: runNow,
                           remove: { deleting = $0 }, isPushed: true)
                .background(Theme.groupedBackground)
                // The list's tasks stop while the detail covers it, so the detail keeps the reads
                // going: Run Now pressed here still turns into Running now.
                .modifier(TasksRefresh(model: model, workspace: workspace))
                .modifier(deleteAlert(isPresented: deletingBinding(when: true)))
        }
    }

    private func togglePause(_ job: CronJob) {
        Task { await model.setPaused(job, !job.isPaused, client: workspace.client) }
    }

    private func runNow(_ job: CronJob) {
        Task { await model.runNow(job, client: workspace.client) }
    }

    private var deleteTitle: String {
        deleting.map { String(localized: "Delete “\($0.name)”?") } ?? ""
    }

    /// Whether the Delete alert shows here: `shows` says whether this view is the one on screen.
    private func deletingBinding(when shows: Bool) -> Binding<Bool> {
        Binding(get: { shows && deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var refusalBinding: Binding<Bool> {
        Binding(get: { model.refusal != nil }, set: { if !$0 { model.refusal = nil } })
    }

    /// Delete's confirmation (`docs/tasks.md` §1).
    private struct DeleteAlert: ViewModifier {
        let title: String
        @Binding var isPresented: Bool
        let job: CronJob?
        let delete: (CronJob) -> Void

        func body(content: Content) -> some View {
            content.alert(title, isPresented: $isPresented, presenting: job) { job in
                Button("Delete", role: .destructive) { delete(job) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Hermes won't run it again.")
            }
        }
    }

    /// While a Run Now waits for its run, or a run is going on, Tasks reads the list now and then,
    /// so the row and the detail show the run start and end (`docs/tasks.md` §1).
    private struct TasksRefresh: ViewModifier {
        let model: TasksModel
        let workspace: BotWorkspace

        func body(content: Content) -> some View {
            content.task(id: model.refreshInterval) {
                guard let interval = model.refreshInterval else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await model.load(client: workspace.client)
                }
            }
        }
    }

    /// What Tasks reads the list again for: another gateway, a new address for it, or the gateway
    /// coming online or going offline.
    private struct LoadTrigger: Equatable {
        let workspace: UUID
        let address: URL
        let isOnline: Bool

        init(workspace: BotWorkspace) {
            self.workspace = workspace.id
            address = workspace.bot.baseURL
            isOnline = workspace.connection.isOnline
        }
    }
}

/// A task (`screens/iphone/tasks.elyx`): icon tile, name, the schedule in words, and a tag
/// for what's next: when it runs, how the last run went, or that it's paused. A run going on now
/// is a line that shimmers and counts up (`taskRowRunning`, `docs/chat.md` §4a).
struct TaskRow: View {
    let job: CronJob
    /// New Task's row before the gateway has made the task.
    var isAdding = false
    /// Run Now before the list shows the run (`docs/tasks.md` §1).
    var isStarting = false
    /// On iPhone the row pushes the task; in the iPad and Mac list it selects it.
    var showsChevron = true

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var tile: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // At accessibility sizes the words get the whole width (`tasksAx5`).
            if !typeSize.isAccessibilitySize {
                Image(systemName: "calendar.badge.clock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: tile, height: tile)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(schedule)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                status
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
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
        } else if let since = job.runningSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                ShimmerText(text: String(localized: "Running now · \(TaskTimes.duration(context.date.timeIntervalSince(since)))"),
                            font: .footnote, tone: .row)
            }
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

/// What New Task opens with, when something suggested the task (setup's morning briefing).
struct TaskPrefill: Hashable {
    var name: String
    var schedule: String
    var prompt: String

    /// A blank task, as + opens it: ⌘N from the menu bar asks for one this way.
    static var empty: TaskPrefill {
        TaskPrefill(name: "", schedule: NewTaskView.defaultSchedule, prompt: "")
    }

    /// "Get a morning briefing" (`setupReady`).
    static var morningBriefing: TaskPrefill {
        TaskPrefill(
            name: String(localized: "Morning briefing"),
            schedule: "every day at 07:30",
            prompt: String(localized: "Good morning. Give me today's weather, what's on my calendar, and anything that needs me. Keep it short.")
        )
    }
}

/// New Task (`newTask`, `macNewTask`). Create closes it at once: the task shows in the list and
/// settles there when the gateway has made it, or comes back here with the gateway's reason
/// (`docs/tasks.md` §1). On the Mac it is a form with labels on the left and its own buttons, as
/// tall as what it holds.
struct NewTaskView: View {
    var prefill: TaskPrefill?
    let onCreate: (NewCronJob) -> Void

    static let defaultSchedule = "every day at 09:00"

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var schedule = Self.defaultSchedule
    @State private var prompt = ""
    @FocusState private var nameFocused: Bool

    private static let presets = ["in 30m", "every 1h", "every day at 09:00", "0 9 * * 1"]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !schedule.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        content
            .onAppear {
                nameFocused = true
                guard let prefill, name.isEmpty, prompt.isEmpty else { return }
                name = prefill.name
                if !prefill.schedule.isEmpty { schedule = prefill.schedule }
                prompt = prefill.prompt
            }
    }

    #if os(macOS)
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Task")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Form {
                TextField("Name:", text: $name, prompt: Text("Morning briefing"))
                    .focused($nameFocused)
                TextField("Prompt:", text: $prompt, prompt: Text("Summarize overnight news and my calendar"), axis: .vertical)
                    .lineLimit(3...8)
                LabeledContent("Schedule:") {
                    VStack(alignment: .leading, spacing: 10) {
                        scheduleField
                            .labelsHidden()
                        presetChips
                        Text(Self.hint)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
    #else
    private var content: some View {
        Form {
            Section("Task") {
                TextField("Name", text: $name, prompt: Text("Morning briefing"))
                    .focused($nameFocused)
                TextField("What should Hermes do?", text: $prompt, prompt: Text("Summarize overnight news and my calendar"), axis: .vertical)
                    .lineLimit(3...8)
            }
            Section {
                scheduleField
                presetChips
            } header: {
                Text("Schedule")
            } footer: {
                Text(Self.hint)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: save)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
                    .disabled(!canSave)
            }
        }
    }
    #endif

    private var scheduleField: some View {
        TextField("Schedule", text: $schedule)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button {
                        schedule = preset
                    } label: {
                        ChipLabel(title: preset, isActive: schedule == preset)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(schedule == preset ? .isSelected : [])
                }
            }
        }
    }

    private static let hint = String(localized: "Hermes understands “in 30m”, “every 2h”, “every day at 09:00”, “every weekday at 08:00” and cron expressions such as “0 9 * * 1”.")

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

