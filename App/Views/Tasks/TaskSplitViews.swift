import HermesKit
import SwiftUI

/// Tasks on iPad and Mac (`screens/ipad/tasks.elyx` → `ipadTasks`, `screens/mac/tasks.elyx` →
/// `macTasks`, `docs/tasks.md` §4): the list beside the selected task's detail: prompt, schedule,
/// delivery, model, skills, then recent runs. Pause and Run Now float in a bottom glass bar on iPad
/// and sit in the toolbar on the Mac (Run Now the default button). The selected task is kept per
/// window.
struct TasksSplitView: View {
    let workspace: BotWorkspace
    let model: TasksModel
    let onCreate: () -> Void
    let togglePause: (CronJob) -> Void
    let runNow: (CronJob) -> Void
    /// Asks first (`docs/tasks.md` §1).
    let remove: (CronJob) -> Void

    @SceneStorage("tasks.selected") private var selectedID: String?
    #if os(macOS)
    @State private var hoveredID: String?
    #endif

    private var selected: CronJob? {
        selectedID.flatMap(model.job(id:)) ?? model.jobs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                #if os(macOS)
                // 340 pt, as `macTasks` has it; a narrow window takes it down to 240 pt so the
                // detail keeps its share (`docs/tasks.md` §4).
                .frame(minWidth: 240, idealWidth: 340, maxWidth: 340)
                #else
                // Half the room, between 240 and 360 pt: the detail keeps its share beside the
                // iPad's sidebar (`docs/tasks.md` §4).
                .frame(minWidth: 240, idealWidth: 360, maxWidth: 360)
                #endif
            Divider()
            Group {
                if let job = selected {
                    TaskDetailPane(job: job, model: model, workspace: workspace, togglePause: togglePause,
                                   runNow: runNow, remove: remove)
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
                    TaskMoreMenu(job: job, canDelete: !model.isAdding(job), remove: remove)
                }
            }
        }
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem {
                Button("New Task", systemImage: "plus", action: onCreate)
                    .help("New Task (⌘N)")
            }
            // Pushed to the trailing side, as the design has them.
            ToolbarSpacer(.flexible)
            if let job = selected {
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
                    .accessibilityAddTraits(.isHeader)
                #else
                Text("Tasks")
                    .font(.title.weight(.bold))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                #endif
                ForEach(model.jobs) { job in
                    let isSelected = job.id == selected?.id
                    let isAdding = model.isAdding(job)
                    Button {
                        selectedID = job.id
                    } label: {
                        // No chevrons: the row selects, it doesn't go anywhere (`ipadTasks`, `macTasks`).
                        TaskRow(job: job, isAdding: isAdding, isStarting: model.starting.contains(job.id), showsChevron: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(rowFill(job, isSelected: isSelected), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .onHover { inside in
                        if inside { hoveredID = job.id } else if hoveredID == job.id { hoveredID = nil }
                    }
                    #endif
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .contextMenu {
                        if !isAdding {
                            TaskActions(job: job, togglePause: togglePause, runNow: runNow, remove: remove)
                        }
                    }
                    .taskAccessibilityActions(job, isAdding: isAdding, togglePause: togglePause, runNow: runNow, remove: remove)
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

    private func rowFill(_ job: CronJob, isSelected: Bool) -> Color {
        if isSelected { return Theme.rowSelected }
        #if os(macOS)
        if hoveredID == job.id { return Theme.rowHover }
        #endif
        return Self.rowBackground
    }

    /// iPad: white cards on the grouped grey. Mac: plain rows on the window's white.
    #if os(macOS)
    private static let listBackground = Theme.canvas
    private static let rowBackground = Color.clear
    #else
    private static let listBackground = Theme.groupedBackground
    private static let rowBackground = Theme.groupedCell
    #endif
}

/// A task's row menu on every device: Run Now, Pause or Resume, Delete.
struct TaskActions: View {
    let job: CronJob
    let togglePause: (CronJob) -> Void
    let runNow: (CronJob) -> Void
    let remove: (CronJob) -> Void

    var body: some View {
        Button("Run Now", systemImage: "play.circle") { runNow(job) }
        Button(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play.circle" : "pause.circle") { togglePause(job) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { remove(job) }
    }
}

extension View {
    /// The row menu's actions for VoiceOver, which reads a row as one element.
    func taskAccessibilityActions(_ job: CronJob, isAdding: Bool, togglePause: @escaping (CronJob) -> Void,
                                  runNow: @escaping (CronJob) -> Void, remove: @escaping (CronJob) -> Void) -> some View {
        accessibilityActions {
            if !isAdding {
                Button("Run Now") { runNow(job) }
                Button(job.isPaused ? "Resume" : "Pause") { togglePause(job) }
                Button("Delete") { remove(job) }
            }
        }
    }
}

/// The … menu: New Task (on the Mac, where + isn't beside it), Delete Task.
private struct TaskMoreMenu: View {
    let job: CronJob
    let canDelete: Bool
    var onCreate: (() -> Void)?
    let remove: (CronJob) -> Void

    var body: some View {
        Menu {
            if let onCreate {
                Button("New Task…", systemImage: "plus", action: onCreate)
                Divider()
            }
            Button("Delete Task", systemImage: "trash", role: .destructive) { remove(job) }
                .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
        .help("More")
    }
}

/// The selected task: prompt, schedule, skills, recent runs (each a chat). On iPhone it is pushed
/// over the list (`taskDetail`); on iPad and Mac it sits beside it.
struct TaskDetailPane: View {
    let job: CronJob
    let model: TasksModel
    let workspace: BotWorkspace
    let togglePause: (CronJob) -> Void
    let runNow: (CronJob) -> Void
    /// Asks first (`docs/tasks.md` §1).
    let remove: (CronJob) -> Void
    /// iPhone: its own page, whose Schedule says how the last run went and how many there have
    /// been where iPad and Mac say where results go and the model (`taskDetail`).
    var isPushed = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var skillTile: CGFloat = 28
    @State private var runs: [CronRun]?
    @State private var runsFailed = false

    private var current: CronJob { model.job(id: job.id) ?? job }

    var body: some View {
        chrome(form)
            .task(id: RunsTrigger(id: job.id, isRunning: current.isRunning)) { await loadRuns() }
            #if os(iOS)
            // Pause / Run Now in a bottom glass bar over the scroll-edge fade.
            .safeAreaBar(edge: .bottom) { actions }
            #endif
    }

    private var form: some View {
        Form {
            Section {
            } header: {
                // The title on the page, not on a cell.
                Text(current.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.primaryText)
                    .textCase(nil)
                    .accessibilityAddTraits(.isHeader)
            }
            Section("Prompt") {
                Text(current.prompt.isEmpty ? String(localized: "No prompt") : current.prompt)
                    .textSelection(.enabled)
            }
            Section("Schedule") {
                scheduleRows
            }
            if !current.skills.isEmpty {
                Section("Skills") {
                    ForEach(current.skills, id: \.self) { name in
                        Label {
                            Text(name)
                        } icon: {
                            Image(systemName: SkillGlyph.symbol(name: name))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.inkForeground)
                                .frame(width: skillTile, height: skillTile)
                                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            TaskProblemSection(job: current)
            TaskRunsSection(runs: runs, failed: runsFailed, isConnected: workspace.roster?.isConnected == true,
                            total: current.runsCounted, runningSince: current.runningSince) { run in
                TaskRuns.open(run, of: current, in: workspace)
            }
            if isPushed, model.isAdding(current) {
                Section {
                } footer: {
                    Text("Hermes is still adding this task.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var scheduleRows: some View {
        row("Runs", Text(ScheduleText.humanize(current.scheduleDisplay)))
        if current.isPaused {
            row("Next run", Text("Paused"))
        } else if let next = current.nextRunAt {
            row("Next run", Text(TaskTimes.label(next)))
        }
        if isPushed {
            if let last = current.lastRunAt {
                row("Last run", lastRun(last))
            }
            if let completed = current.repeatCompleted, completed > 0 {
                row("Completed runs", Text("\(completed)"))
            }
        } else {
            row("Results go to", Text(TaskTimes.delivery(current.deliver)))
            if let name = current.model {
                row("Model", Text(ModelNames.display(name)))
            }
        }
    }

    /// "Today 07:30 · OK", or "· Failed" in red.
    private func lastRun(_ date: Date) -> Text {
        let when = Text(TaskTimes.label(date))
        if current.hasFailed {
            return Text("\(when) · \(Text("Failed").foregroundStyle(Theme.danger))")
        }
        if current.lastStatus?.lowercased() == "ok" {
            return Text("\(when) · OK")
        }
        return when
    }

    /// A label and its value side by side, or the value under its label at the accessibility
    /// sizes, where side by side leaves neither room (`taskDetailAx5`).
    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: Text) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(Theme.primaryText)
                value
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent {
                value
            } label: {
                Text(label)
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var actions: some View {
        let isStarting = model.starting.contains(current.id)
        let pause = current.isPaused ? String(localized: "Resume") : String(localized: "Pause")
        let pauseSymbol = current.isPaused ? "play" : "pause.fill"
        let run = isStarting ? String(localized: "Starting…") : String(localized: "Run Now")
        Group {
            if typeSize.isAccessibilitySize {
                // One above the other, full width: side by side, neither label fits (`taskDetailAx5`).
                VStack(spacing: 10) {
                    Button { togglePause(current) } label: {
                        Label(pause, systemImage: pauseSymbol).frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    Button { runNow(current) } label: {
                        Label(run, systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .prominentGlassButton()
                    .disabled(isStarting)
                }
                .font(.body.weight(.semibold))
                .controlSize(.extraLarge)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                PairedSheetButtons(
                    secondary: pause,
                    onSecondary: { togglePause(current) },
                    secondarySymbol: pauseSymbol,
                    primary: run, symbol: "play.fill",
                    primaryEnabled: !isStarting
                ) {
                    runNow(current)
                }
            }
        }
        .disabled(model.isAdding(current))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
    #endif

    /// iPhone: the page's title for the back menu and VoiceOver, drawn large in the form, and the
    /// … menu at the top right (`taskDetail`).
    @ViewBuilder
    private func chrome(_ content: some View) -> some View {
        #if os(iOS)
        if isPushed {
            content
                .navigationTitle(current.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        TaskMoreMenu(job: current, canDelete: !model.isAdding(current), remove: remove)
                    }
                }
        } else {
            content
        }
        #else
        content
        #endif
    }

    /// The runs are read again when the task is another or a run starts or ends.
    private struct RunsTrigger: Equatable {
        let id: String
        let isRunning: Bool
    }

    private func loadRuns() async {
        if let loaded = await TaskRuns.load(job, model: model, workspace: workspace) {
            runs = loaded
            runsFailed = false
        } else {
            runsFailed = true
        }
    }
}

/// A task's recent runs, each a chat (`runHistory`), in the task's detail on every device. The run
/// going on now leads them (`docs/tasks.md` §4).
struct TaskRunsSection: View {
    /// Nil until they're read.
    let runs: [CronRun]?
    let failed: Bool
    let isConnected: Bool
    /// How many times the task has run, the run going on now included, when Hermes counts
    /// (`CronJob.runsCounted`).
    let total: Int?
    /// When the run going on now started (`live_execution`).
    var runningSince: Date?
    let open: (CronRun) -> Void

    var body: some View {
        if let runs = runs.map({ CronRun.withLiveRun($0, runningSince: runningSince) }), !runs.isEmpty {
            Section {
                ForEach(runs) { run in
                    if run.isLive, run.sessionID == nil {
                        // Its chat isn't listed yet: nothing to open, but nothing wrong either.
                        RunRow(run: run, opens: false)
                    } else {
                        Button {
                            open(run)
                        } label: {
                            RunRow(run: run, opens: run.sessionID != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(run.sessionID == nil)
                    }
                }
            } header: {
                Text("Recent runs · \(count(runs))")
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
                    .accessibilityLabel(Text("Loading runs"))
            }
        }
    }

    /// Every run Hermes counts, or the ones shown when it doesn't count.
    private func count(_ shown: [CronRun]) -> Int {
        total ?? shown.count
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

/// One run (`runRow`, `runRowFailed`, `runRowRunning`): how it went, when and how long, what it
/// said. A run that opens as a chat ends in a chevron; one read in place (`runRowReadOnly`) expands
/// to its whole reply (`runRowExpanded`, `docs/tasks.md` §5). The run going on now counts its time
/// up and says so in a line that shimmers (`docs/chat.md` §4a).
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
        if run.isLive, let start = run.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { context in
                row(now: context.date)
            }
        } else {
            row(now: .now)
        }
    }

    private func row(now: Date) -> some View {
        HStack(alignment: isExpanded ? .top : .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(run.isLive ? Theme.secondaryText : run.failed ? Theme.danger : Theme.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(now: now))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                if run.isLive {
                    ShimmerText(text: String(localized: "Running now"), font: .footnote, tone: .row)
                } else if let line {
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
        .accessibilityLabel(Text(accessibilityText(now: now)))
    }

    private var symbol: String {
        if run.isLive { return "clock" }
        return run.failed ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    /// What it said, or what went wrong.
    var line: String? { run.failed ? (run.error ?? reply ?? run.summary) : (reply ?? run.summary) }

    /// "Today 07:30 · 41 s", after the routine's name when there is one; the run going on now
    /// counts up to `now`.
    private func title(now: Date) -> String {
        var parts: [String] = []
        if let routine { parts.append(routine) }
        if let start = run.startedAt { parts.append(TaskTimes.label(start)) }
        if run.isLive, let start = run.startedAt {
            parts.append(TaskTimes.duration(now.timeIntervalSince(start)))
        } else if let duration = run.duration {
            parts.append(TaskTimes.duration(duration))
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityText(now: Date) -> String {
        let title = title(now: now)
        if run.isLive { return String(localized: "Running now, \(title)") }
        let outcome = run.failed ? String(localized: "Failed") : String(localized: "Finished")
        // Tasks reads what the run said; a routine's row keeps its outcome and time, as an
        // expanded one would read out the whole reply.
        guard routine == nil, let line, !isReading else { return "\(outcome), \(title)" }
        return "\(outcome), \(title), \(line)"
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

    /// "41 s", "2 min 5 s", "1 hr 3 min".
    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
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
