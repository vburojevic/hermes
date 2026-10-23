import HermesKit
import SwiftUI

/// A Bot's routines: scheduled prompts whose results land in its Bot Chat.
struct RoutinesView: View {
    let roster: BotRoster
    let botName: String
    /// A routine to show first, by its title: a chat's delivery opened here (`docs/chat.md` §2a).
    var focus: String?
    let onDone: () -> Void

    @State private var model: RoutinesModel
    @State private var isAdding = false
    /// What New Routine opens with: a routine the gateway refused, to edit and try again.
    @State private var draft: RoutineDraft?
    @State private var removing: BotRoutine?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(roster: BotRoster, botName: String, focus: String? = nil, onDone: @escaping () -> Void) {
        self.roster = roster
        self.botName = botName
        self.focus = focus
        self.onDone = onDone
        _model = State(initialValue: RoutinesModel(roster: roster, botName: botName))
    }

    private var routines: [BotRoutine] { model.routines }

    private var bot: BotProfile? { roster.bot(named: botName) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Routines")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // A view-only sheet: the system's close button.
                        Button(role: .close, action: onDone)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isAdding = true
                        } label: {
                            Label("New Routine", systemImage: "plus")
                        }
                        .disabled(!roster.isConnected)
                    }
                }
                .navigationDestination(isPresented: $isAdding) {
                    // Save comes straight back here: the routine shows in the list and settles there.
                    NewRoutineView(roster: roster, botName: botName, draft: draft ?? RoutineDraft()) { saved in
                        isAdding = false
                        draft = nil
                        Task { await model.add(saved) }
                    }
                }
        }
        .task { await model.load() }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .alert(model.refusal?.title ?? "", isPresented: refusalBinding, presenting: model.refusal) { _ in
            if let refused = model.refusedDraft {
                Button("Edit Routine") {
                    model.refusedDraft = nil
                    draft = refused
                    isAdding = true
                }
                Button("Discard", role: .cancel) { model.refusedDraft = nil }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { refusal in
            Text(refusal.message)
        }
        .confirmationDialog("Delete this routine?", isPresented: removeBinding, titleVisibility: .visible, presenting: removing) { routine in
            Button("Delete", role: .destructive) {
                Task { await model.remove(routine) }
            }
        } message: { routine in
            Text("“\(routine.title)” stops running. Its past results stay in the chat.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where routines.isEmpty:
            SkeletonRows()
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .failed(let message) where routines.isEmpty:
            StateMessage(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Couldn't load routines"),
                message: message,
                actionTitle: String(localized: "Try Again"),
                action: { Task { await model.load() } }
            )
        default:
            #if os(macOS)
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                list
            }
            #else
            list
            #endif
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                #if os(iOS)
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                #endif
                if routines.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "alarm")
                                .font(.title.weight(.light))
                                .foregroundStyle(Theme.tertiaryText)
                                .symbolEffect(.wiggle, options: .repeat(.periodic(3, delay: 2.5)), isActive: !reduceMotion)
                                .accessibilityHidden(true)
                            Text("No routines yet")
                                .font(.headline)
                            Text("A morning briefing, a weekly report, a reminder in an hour: \(bot?.title ?? botName) runs it on schedule and posts the result here.")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                            Button("New Routine", systemImage: "plus") { isAdding = true }
                                .prominentGlassButton()
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }
                } else {
                    Section {
                        ForEach(routines) { routine in
                            let adding = model.isAdding(routine)
                            RoutineRow(routine: routine, isAdding: adding, isStarting: model.starting.contains(routine.id)) { paused in
                                Task { await model.setPaused(routine, paused) }
                            }
                            .id(routine.id)
                            .listRowBackground(isFocused(routine) ? Theme.infoTint : nil)
                            .accessibilityAddTraits(isFocused(routine) ? .isSelected : [])
                            .contextMenu {
                                if !adding { actions(for: routine) }
                            }
                            .swipeActions(edge: .trailing) {
                                if !adding {
                                    Button(role: .destructive) {
                                        removing = routine
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await model.runNow(routine) }
                                    } label: {
                                        Label("Run Now", systemImage: "play")
                                    }
                                    .tint(Theme.success)
                                }
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .refreshable { await model.load() }
            .onChange(of: routines.first(where: isFocused)?.id, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// The routine a delivery named; a Bot's routines are told apart by title.
    private func isFocused(_ routine: BotRoutine) -> Bool {
        focus.map { routine.title.caseInsensitiveCompare($0) == .orderedSame } ?? false
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let bot {
                BotFace(appearance: roster.appearance(for: bot), size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(bot?.title ?? botName)
                    .font(.headline)
                Text("Routines run on a schedule, even when this device is asleep.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(for routine: BotRoutine) -> some View {
        Button("Run Now", systemImage: "play") {
            Task { await model.runNow(routine) }
        }
        Button(routine.isPaused ? "Resume" : "Pause", systemImage: routine.isPaused ? "play.circle" : "pause.circle") {
            Task { await model.setPaused(routine, !routine.isPaused) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            removing = routine
        }
    }

    private var refusalBinding: Binding<Bool> {
        Binding(get: { model.refusal != nil }, set: { if !$0 { model.refusal = nil } })
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

private struct RoutineRow: View {
    let routine: BotRoutine
    /// New Routine's row before the gateway has made the routine.
    let isAdding: Bool
    /// Run Now before the gateway has the run.
    let isStarting: Bool
    let setPaused: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(routine.isPaused ? Theme.secondaryText : Theme.primaryText)
                Label(RoutineSchedule.describe(routine.schedule), systemImage: "clock")
                    .labelStyle(TightLabelStyle())
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                if !routine.promptPreview.isEmpty {
                    Text(routine.promptPreview)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    // Still words, not a spinner: the change is shown, the gateway settles it.
                    if isAdding {
                        Label("Adding…", systemImage: "arrow.up.circle")
                            .foregroundStyle(Theme.tertiaryText)
                    } else if isStarting {
                        Label("Starting…", systemImage: "play.circle")
                            .foregroundStyle(Theme.tertiaryText)
                    } else if routine.hasFailed {
                        Label("Last run failed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                    } else if routine.isPaused {
                        Label("Paused", systemImage: "pause.fill")
                            .foregroundStyle(Theme.warning)
                    } else if let next = routine.nextRunAt {
                        Text("Runs \(next.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    if routine.deliversToBotChat {
                        Label("Posts here", systemImage: "bubble.left")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .labelStyle(TightLabelStyle())
                .font(.caption2)
                if let issue = routine.issue, routine.hasFailed {
                    Text(issue)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(get: { !routine.isPaused }, set: { setPaused(!$0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.success)
                .disabled(isAdding)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Builds a routine: what to do, and when.
/// Save comes straight back to the list, where the routine settles (`docs/tasks.md` §5).
struct NewRoutineView: View {
    let roster: BotRoster
    let botName: String
    let onSave: (RoutineDraft) -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var kind: RoutineSchedule.Kind
    @State private var time: Date
    @State private var weekday: Int
    @State private var hours: Int
    @State private var delay: RoutineSchedule.Delay
    @State private var cron: String
    @State private var postsInChat: Bool

    init(roster: BotRoster, botName: String, draft: RoutineDraft, onSave: @escaping (RoutineDraft) -> Void) {
        self.roster = roster
        self.botName = botName
        self.onSave = onSave
        _title = State(initialValue: draft.title)
        _prompt = State(initialValue: draft.prompt)
        _kind = State(initialValue: draft.schedule.kind)
        _time = State(initialValue: draft.schedule.time)
        _weekday = State(initialValue: draft.schedule.weekday)
        _hours = State(initialValue: draft.schedule.hours)
        _delay = State(initialValue: draft.schedule.delay)
        _cron = State(initialValue: draft.schedule.cron)
        _postsInChat = State(initialValue: draft.postsInChat)
    }

    private var routineSchedule: RoutineSchedule {
        RoutineSchedule(kind: kind, time: time, weekday: weekday, hours: hours, delay: delay, cron: cron)
    }

    private var schedule: String { routineSchedule.expression }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schedule.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $title, prompt: Text("Morning briefing"))
                TextField("What should it do?", text: $prompt, prompt: Text("Summarise the news and my calendar for today."), axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                Text("\(roster.bot(named: botName)?.title ?? botName) gets this as a message each time the routine runs.")
            }

            Section("When") {
                Picker("Repeats", selection: $kind) {
                    ForEach(RoutineSchedule.Kind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                switch kind {
                case .daily, .weekdays:
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                case .weekly:
                    Picker("Day", selection: $weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                case .hourly:
                    Stepper(hours == 1 ? String(localized: "Every hour") : String(localized: "Every \(hours) hours"), value: $hours, in: 1...24)
                case .once:
                    Picker("In", selection: $delay) {
                        ForEach(RoutineSchedule.Delay.allCases) { delay in
                            Text(delay.label).tag(delay)
                        }
                    }
                case .custom:
                    TextField("Cron expression", text: $cron, prompt: Text("0 8 * * *"))
                        .font(Theme.Typography.code)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }

            Section {
                Toggle("Post results in the Bot Chat", isOn: $postsInChat)
            } footer: {
                Text(RoutineSchedule.describe(schedule))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Routine")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(RoutineDraft(title: title, prompt: prompt, schedule: routineSchedule, postsInChat: postsInChat))
    }
}

/// Hermes schedules: cron expressions, `every 6h`, and one-shots like `in 30m`
/// (a bare `30m` would repeat).
struct RoutineSchedule: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, hourly, once, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: String(localized: "Every day")
            case .weekdays: String(localized: "Weekdays")
            case .weekly: String(localized: "Every week")
            case .hourly: String(localized: "Every few hours")
            case .once: String(localized: "Once")
            case .custom: String(localized: "Custom (cron)")
            }
        }
    }

    enum Delay: String, CaseIterable, Identifiable {
        case fifteenMinutes = "15m", thirtyMinutes = "30m", oneHour = "1h", threeHours = "3h", tomorrow = "24h"
        var id: String { rawValue }

        var label: String {
            switch self {
            case .fifteenMinutes: String(localized: "15 minutes")
            case .thirtyMinutes: String(localized: "30 minutes")
            case .oneHour: String(localized: "1 hour")
            case .threeHours: String(localized: "3 hours")
            case .tomorrow: String(localized: "24 hours")
            }
        }
    }

    var kind: Kind
    var time: Date
    var weekday: Int
    var hours: Int
    var delay: Delay
    var cron: String

    var expression: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let minute = parts.minute ?? 0, hour = parts.hour ?? 8
        switch kind {
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly: return "\(minute) \(hour) * * \(weekday - 1)"
        case .hourly: return "every \(hours)h"
        case .once: return "in \(delay.rawValue)"
        case .custom: return cron.trimmingCharacters(in: .whitespaces)
        }
    }

    /// A readable line for a stored schedule; unknown forms are shown as they are.
    static func describe(_ schedule: String) -> String {
        let text = schedule.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.hasPrefix("once") || lower.hasPrefix("in ") {
            let rest = lower.replacingOccurrences(of: "once", with: "").replacingOccurrences(of: "in ", with: "").trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? String(localized: "Once") : String(localized: "Once, in \(humanDuration(rest))")
        }
        if lower.hasPrefix("every ") {
            return String(localized: "Every \(humanDuration(String(lower.dropFirst(6))))")
        }
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]), fields[2] == "*", fields[3] == "*" else {
            return text
        }
        let clock = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now)?
            .formatted(date: .omitted, time: .shortened) ?? "\(hour):\(minute)"
        switch fields[4] {
        case "*": return String(localized: "Every day at \(clock)")
        case "1-5": return String(localized: "Weekdays at \(clock)")
        case "0,6", "6,0": return String(localized: "Weekends at \(clock)")
        default:
            let days = fields[4].split(separator: ",").compactMap { Int($0) }.filter { (0...7).contains($0) }
            guard !days.isEmpty, days.count == fields[4].split(separator: ",").count else { return text }
            let names = days.map { Calendar.current.weekdaySymbols[$0 % 7] }
            return String(localized: "\(names.formatted(.list(type: .and))) at \(clock)")
        }
    }

    /// `90m` → "90 minutes", `6h` → "6 hours", `1d` → "1 day".
    private static func humanDuration(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()) else { return trimmed }
        var measurement: Measurement<UnitDuration>
        switch unit {
        case "m": measurement = .init(value: Double(value), unit: .minutes)
        case "h": measurement = .init(value: Double(value), unit: .hours)
        case "d": return value == 1 ? String(localized: "1 day") : String(localized: "\(value) days")
        case "s": measurement = .init(value: Double(value), unit: .seconds)
        default: return trimmed
        }
        if measurement.unit == .minutes, value % 60 == 0, value >= 120 {
            measurement = .init(value: Double(value / 60), unit: .hours)
        }
        return measurement.formatted(.measurement(width: .wide, usage: .asProvided))
    }
}

/// Caption-sized labels: the default icon gap is sized for body text.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
