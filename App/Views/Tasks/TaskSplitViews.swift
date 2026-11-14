import HermesKit
import SwiftUI

/// Tasks on iPad and Mac (`screens/ipad/tasks.elyx` → `ipadTasks`, `screens/mac/tasks.elyx` →
/// `macTasks`, `docs/tasks.md` §4): the list beside the selected task's detail: prompt, schedule,
/// delivery, skills, then recent runs. Pause and Run Now float in a bottom glass bar on iPad and
/// sit in the toolbar on the Mac (Run Now the default button). The selected task is kept per
/// window.
struct TasksSplitView: View {
    let workspace: BotWorkspace
    let model: TasksModel
    let onCreate: () -> Void
    let togglePause: (CronJob) -> Void
    let runNow: (CronJob) -> Void

    @SceneStorage("tasks.selected") private var selectedID: String?

    private var selected: CronJob? {
        selectedID.flatMap(model.job(id:)) ?? model.jobs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            // Half the room, between 240 and 360 pt: the detail keeps its share in a narrow
            // window (the Mac's smallest, the iPad's sidebar beside it) (`docs/tasks.md` §4).
            list
                .frame(minWidth: 240, idealWidth: 360, maxWidth: 360)
            Divider()
            Group {
                if let job = selected {
                    TaskDetailPane(job: job, model: model, workspace: workspace, togglePause: togglePause, runNow: runNow)
                        .id(job.id)
                } else {
                    ContentUnavailableView("No task selected", systemImage: "calendar.badge.clock")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.groupedBackground)
        }
        // The list and the detail draw their own large titles.
        .toolbar(removing: .title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job = selected {
                ToolbarItem(placement: .topBarTrailing) {
                    TaskMoreMenu(job: job, canDelete: !model.isAdding(job), onCreate: onCreate, remove: remove)
                }
            }
        }
        #endif
        #if os(macOS)
        .toolbar {
            if let job = selected {
                // Pushed to the trailing side, as the design has them.
                ToolbarSpacer(.flexible)
                ToolbarItemGroup(placement: .automatic) {
                    Button(job.isPaused ? "Resume" : "Pause") { togglePause(job) }
                        .disabled(model.isAdding(job))
                    Button("Run Now") { runNow(job) }
                        .inkDefaultButton()
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isAdding(job) || model.starting.contains(job.id))
                    TaskMoreMenu(job: job, canDelete: !model.isAdding(job), onCreate: onCreate, remove: remove)
                }
            }
        }
        #endif
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                #if os(iOS)
                Text("Tasks")
                    .font(.largeTitle.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                #else
                Text("Tasks")
                    .font(.title.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                #endif
                ForEach(model.jobs) { job in
                    let isSelected = job.id == selected?.id
                    Button {
                        selectedID = job.id
                    } label: {
                        TaskRow(job: job, isAdding: model.isAdding(job), isStarting: model.starting.contains(job.id))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isSelected ? Theme.rowSelected : Self.rowBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .contextMenu {
                        if !model.isAdding(job) {
                            Button("Run Now", systemImage: "play.circle") { runNow(job) }
                            Button(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause") { togglePause(job) }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { remove(job) }
                        }
                    }
                }
                Text("Ask Hermes in any chat to add one.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Self.listBackground)
    }

    /// iPad: white cards on the grouped grey. Mac: plain rows on the window's white.
    #if os(macOS)
    private static let listBackground = Theme.canvas
    private static let rowBackground = Color.clear
    #else
    private static let listBackground = Theme.groupedBackground
    private static let rowBackground = Theme.groupedCell
    #endif

    private func remove(_ job: CronJob) {
        Task { await model.remove(job, client: workspace.client) }
    }
}

/// The … menu: New Task, Delete.
private struct TaskMoreMenu: View {
    let job: CronJob
    let canDelete: Bool
    let onCreate: () -> Void
    let remove: (CronJob) -> Void

    var body: some View {
        Menu {
            #if os(macOS)
            // iPad has + in the toolbar.
            Button("New Task…", systemImage: "plus", action: onCreate)
            Divider()
            #endif
            Button("Delete Task", systemImage: "trash", role: .destructive) { remove(job) }
                .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }
}

/// The selected task: prompt, schedule, skills, recent runs (each a chat).
struct TaskDetailPane: View {
    let job: CronJob
    let model: TasksModel
    let workspace: BotWorkspace
    let togglePause: (CronJob) -> Void
    let runNow: (CronJob) -> Void

    @State private var runs: [CronRun]?
    @State private var runsFailed = false

    private var current: CronJob { model.job(id: job.id) ?? job }

    var body: some View {
        Form {
            Section {
            } header: {
                // The title on the page, not on a cell.
                Text(current.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .textCase(nil)
            }
            Section("Prompt") {
                Text(current.prompt.isEmpty ? String(localized: "No prompt") : current.prompt)
                    .textSelection(.enabled)
            }
            Section("Schedule") {
                LabeledContent("Runs", value: ScheduleText.humanize(current.scheduleDisplay))
                if current.isPaused {
                    LabeledContent("Next run", value: String(localized: "Paused"))
                } else if let next = current.nextRunAt {
                    LabeledContent("Next run", value: TaskTimes.label(next))
                }
                LabeledContent("Results go to", value: TaskTimes.delivery(current.deliver))
            }
            if !current.skills.isEmpty {
                Section("Skills") {
                    ForEach(current.skills, id: \.self) { name in
                        Label {
                            Text(name)
                        } icon: {
                            Image(systemName: SkillGlyph.symbol(name: name))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.inkForeground)
                                .frame(width: 28, height: 28)
                                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            TaskProblemSection(job: current)
            runsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task(id: job.id) { await loadRuns() }
        #if os(iOS)
        // Pause / Run Now in a bottom glass bar over the scroll-edge fade.
        .safeAreaBar(edge: .bottom) {
            PairedSheetButtons(
                secondary: current.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                onSecondary: { togglePause(current) },
                secondarySymbol: current.isPaused ? "play" : "pause.fill",
                primary: String(localized: "Run Now"), symbol: "play.fill"
            ) {
                runNow(current)
            }
            .disabled(model.isAdding(current))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        #endif
    }

    private var runsSection: some View {
        TaskRunsSection(runs: runs, failed: runsFailed, isConnected: workspace.roster?.isConnected == true,
                        total: current.repeatCompleted) { run in
            TaskRuns.open(run, of: current, in: workspace)
        }
    }

    private func loadRuns() async {
        if let loaded = await TaskRuns.load(job, model: model, workspace: workspace) {
            runs = loaded
        } else {
            runsFailed = true
        }
    }
}

/// A task's recent runs, each a chat (`runHistory`), in the task's detail on every device.
struct TaskRunsSection: View {
    /// Nil until they're read.
    let runs: [CronRun]?
    let failed: Bool
    let isConnected: Bool
    /// How many times the task has run, when Hermes counts (`repeat.completed`).
    let total: Int?
    let open: (CronRun) -> Void

    var body: some View {
        if let runs, !runs.isEmpty {
            Section {
                ForEach(runs) { run in
                    Button {
                        open(run)
                    } label: {
                        RunRow(run: run, opens: run.sessionID != nil)
                    }
                    .buttonStyle(.plain)
                    .disabled(run.sessionID == nil)
                }
            } header: {
                Text("Recent runs · \(total ?? runs.count)")
            } footer: {
                #if os(macOS)
                Text("Each run is a chat; click one to read it or continue it.")
                #else
                Text("Each run is a chat; tap one to read it or continue it.")
                #endif
            }
        } else if runs == nil, !failed, isConnected {
            Section("Recent runs") {
                SkeletonRows(count: 2)
            }
        }
    }
}

enum TaskRuns {
    /// The run history lives on the Bot Mode dashboard. Most runs of a frequent task say nothing,
    /// so it asks for Hermes's most and keeps the ones with something in them (`docs/tasks.md` §5).
    /// Nil when they can't be read.
    static func load(_ job: CronJob, model: TasksModel, workspace: BotWorkspace) async -> [CronRun]? {
        // A new task has no runs, and no id on the gateway yet.
        if model.isAdding(job) { return [] }
        guard let roster = workspace.roster, roster.isConnected else { return nil }
        guard let all = try? await roster.cronRuns(jobID: job.id, profile: workspace.bot.profileName, limit: 100) else { return nil }
        return ScheduledRuns.shown(all)
    }

    /// Opens a run in Chats, like any chat; it isn't listed there (`docs/tasks.md` §1).
    static func open(_ run: CronRun, of job: CronJob, in workspace: BotWorkspace) {
        open(run, titled: job.name, in: workspace)
    }

    /// Opens a run titled after its task or routine.
    static func open(_ run: CronRun, titled title: String, in workspace: BotWorkspace) {
        guard let id = run.sessionID else { return }
        var session = HermesSession.opened(id: id)
        session.title = title
        session.source = SessionSearch.taskSource
        session.startedAt = run.startedAt
        // An opened run with no count would be taken for an empty one.
        session.messageCount = run.messageCount
        workspace.sidebarMode = .chats
        workspace.open(session)
    }
}

/// One run (`runRow`, `runRowFailed`): how it went, when and how long, what it said. A run that
/// opens as a chat ends in a chevron; one read in place (`runRowReadOnly`) expands to its whole
/// reply (`runRowExpanded`, `docs/tasks.md` §5).
struct RunRow: View {
    let run: CronRun
    /// The routine it belongs to, on a list of every routine's runs.
    var routine: String?
    var opens: Bool
    /// What it said, read from the run's chat: Hermes's row carries only a preview of the prompt.
    var reply: String?
    /// Reading `reply`: the line is a placeholder until it comes.
    var isReading = false
    /// All of it, not one line.
    var isExpanded = false

    var body: some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 12) {
            Image(systemName: run.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(run.failed ? Theme.danger : Theme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if let line {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(run.failed ? Theme.danger : isExpanded ? Theme.primaryText : Theme.secondaryText)
                        .lineLimit(isExpanded ? nil : 1)
                        .redacted(reason: isReading ? .placeholder : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(run.failed ? String(localized: "Failed") : String(localized: "Finished")), \(title)"))
    }

    /// What it said, or what went wrong.
    var line: String? { run.failed ? (run.error ?? reply ?? run.summary) : (reply ?? run.summary) }

    /// "Today 07:30 · 41 s", after the routine's name when there is one.
    private var title: String {
        var parts: [String] = []
        if let routine { parts.append(routine) }
        if let start = run.startedAt { parts.append(TaskTimes.label(start)) }
        if let duration = run.duration { parts.append(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) }
        return parts.joined(separator: " · ")
    }
}

enum TaskTimes {
    /// "Today 07:30", "Tomorrow 07:30", "Sunday 07:30", "12 Oct, 07:30".
    static func label(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        if abs(date.timeIntervalSinceNow) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.wide))) \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    /// Where results go: "This chat", "Telegram", "Hermes app · push".
    static func delivery(_ deliver: String?) -> String {
        switch deliver?.lowercased() {
        case nil, "", "local": String(localized: "Kept on the gateway")
        case "origin": String(localized: "Where it was made")
        case "apppush": String(localized: "Hermes app notifications")
        case let target?: target.split(separator: ":").first.map { $0.capitalized } ?? target
        }
    }
}
