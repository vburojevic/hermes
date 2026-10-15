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
        model.jobs.first { $0.id == selectedID } ?? model.jobs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 360)
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
        // The list draws its own large title.
        .toolbar(removing: .title)
        #if os(macOS)
        .toolbar {
            if let job = selected {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(job.isPaused ? "Resume" : "Pause") { togglePause(job) }
                    Button("Run Now") { runNow(job) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.ink)
                        .keyboardShortcut(.defaultAction)
                    TaskMoreMenu(job: job, onCreate: onCreate, remove: remove)
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
                        TaskRow(job: job)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(isSelected ? Theme.rowSelected : Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .contextMenu {
                        Button("Run Now", systemImage: "play.circle") { runNow(job) }
                        Button(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause") { togglePause(job) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { remove(job) }
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
        .background(Theme.canvas)
    }

    private func remove(_ job: CronJob) {
        Task { await model.remove(job, client: workspace.client) }
    }
}

/// The … menu: New Task, Delete.
private struct TaskMoreMenu: View {
    let job: CronJob
    let onCreate: () -> Void
    let remove: (CronJob) -> Void

    var body: some View {
        Menu {
            Button("New Task…", systemImage: "plus", action: onCreate)
            Divider()
            Button("Delete Task", systemImage: "trash", role: .destructive) { remove(job) }
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

    private var current: CronJob { model.jobs.first { $0.id == job.id } ?? job }

    var body: some View {
        Form {
            Section {
                Text(current.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
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
            if let error = current.lastError, !error.isEmpty {
                Section("Last error") {
                    Text(error)
                        .font(Theme.Typography.code)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                }
            }
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
                primary: String(localized: "Run Now"), symbol: "play.fill"
            ) {
                runNow(current)
            }
            .frame(maxWidth: 520)
        }
        #endif
    }

    @ViewBuilder
    private var runsSection: some View {
        if let runs, !runs.isEmpty {
            Section {
                ForEach(runs) { run in
                    Button {
                        open(run)
                    } label: {
                        RunRow(run: run)
                    }
                    .buttonStyle(.plain)
                    .disabled(run.sessionID == nil)
                }
            } header: {
                Text("Recent runs · \(current.repeatCompleted ?? runs.count)")
            } footer: {
                #if os(macOS)
                Text("Each run is a chat; click one to read it or continue it.")
                #else
                Text("Each run is a chat; tap one to read it or continue it.")
                #endif
            }
        } else if runs == nil, !runsFailed, workspace.roster?.isConnected == true {
            Section("Recent runs") {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    /// The run history lives on the Bot Mode dashboard.
    private func loadRuns() async {
        guard let roster = workspace.roster, roster.isConnected else {
            runsFailed = true
            return
        }
        do {
            runs = try await roster.cronRuns(jobID: job.id, profile: workspace.bot.profileName)
        } catch {
            runsFailed = true
        }
    }

    private func open(_ run: CronRun) {
        guard let id = run.sessionID else { return }
        var session = HermesSession(id: id)
        session.title = current.name
        session.source = SessionSearch.taskSource
        session.startedAt = run.startedAt
        workspace.sidebarMode = .chats
        workspace.open(session)
    }
}

/// One run (`runRow`, `runRowFailed`): how it went, when and how long, what it said.
private struct RunRow: View {
    let run: CronRun

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(run.failed ? Theme.danger : Theme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if let line = run.failed ? (run.error ?? run.summary) : run.summary {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(run.failed ? Theme.danger : Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if run.sessionID != nil {
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

    /// "Today 07:30 · 41 s".
    private var title: String {
        var parts: [String] = []
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
        case let target?: target.split(separator: ":").first.map { $0.capitalized } ?? target
        }
    }
}
