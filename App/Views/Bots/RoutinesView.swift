import HermesKit
import SwiftUI

/// A Bot's routines: scheduled prompts whose results land in its Bot Chat.
struct RoutinesView: View {
    let roster: BotRoster
    let botName: String
    let onDone: () -> Void

    @State private var routines: [BotRoutine] = []
    @State private var phase = Phase.loading
    @State private var isAdding = false
    @State private var actionError: HermesError?
    @State private var removing: BotRoutine?
    @State private var busy: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

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
                    NewRoutineView(roster: roster, botName: botName) {
                        isAdding = false
                        Task { await load() }
                    }
                }
        }
        .task { await load() }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .alert("Something went wrong", isPresented: errorBinding, presenting: actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
        .confirmationDialog("Delete this routine?", isPresented: removeBinding, titleVisibility: .visible, presenting: removing) { routine in
            Button("Delete", role: .destructive) {
                run(routine) { try await roster.removeRoutine(routine, for: botName) }
            }
        } message: { routine in
            Text("“\(routine.title)” stops running. Its past results stay in the chat.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading where routines.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where routines.isEmpty:
            StateMessage(
                symbol: "exclamationmark.triangle",
                title: String(localized: "Couldn't load routines"),
                message: message,
                actionTitle: String(localized: "Try Again"),
                action: { Task { await load() } }
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
                            RoutineRow(routine: routine, isBusy: busy.contains(routine.id)) { paused in
                                run(routine) { try await roster.setRoutine(routine, paused: paused, for: botName) }
                            }
                            .contextMenu { actions(for: routine) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    removing = routine
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    run(routine) { try await roster.runRoutineNow(routine, for: botName) }
                                } label: {
                                    Label("Run Now", systemImage: "play")
                                }
                                .tint(Theme.success)
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
            .refreshable { await load() }
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
            run(routine) { try await roster.runRoutineNow(routine, for: botName) }
        }
        Button(routine.isPaused ? "Resume" : "Pause", systemImage: routine.isPaused ? "play.circle" : "pause.circle") {
            run(routine) { try await roster.setRoutine(routine, paused: !routine.isPaused, for: botName) }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            removing = routine
        }
    }

    private func load() async {
        if routines.isEmpty { phase = .loading }
        do {
            let fresh = try await roster.routines(for: botName).sorted { lhs, rhs in
                if lhs.isPaused != rhs.isPaused { return !lhs.isPaused }
                return (lhs.nextRunAt ?? .distantFuture) < (rhs.nextRunAt ?? .distantFuture)
            }
            withAnimation(phase == .loaded ? Theme.spring : nil) {
                routines = fresh
            }
            phase = .loaded
        } catch {
            phase = .failed(BotRoster.describe(error))
        }
    }

    private func run(_ routine: BotRoutine, _ action: @escaping () async throws -> Void) {
        busy.insert(routine.id)
        Task {
            defer { busy.remove(routine.id) }
            do {
                try await action()
                await load()
            } catch {
                let failure = HermesError.botMode(error)
                actionError = failure
                AccessibilityNotification.Announcement(failure.errorDescription ?? "").post()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}

private struct RoutineRow: View {
    let routine: BotRoutine
    let isBusy: Bool
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
                    if routine.hasFailed {
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
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Toggle("Enabled", isOn: Binding(get: { !routine.isPaused }, set: { setPaused(!$0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.success)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Builds a routine: what to do, and when.
struct NewRoutineView: View {
    let roster: BotRoster
    let botName: String
    let onDone: () -> Void

    @State private var title = ""
    @State private var prompt = ""
    @State private var kind = RoutineSchedule.Kind.daily
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    @State private var weekday = 2
    @State private var hours = 6
    @State private var delay = RoutineSchedule.Delay.thirtyMinutes
    @State private var cron = "0 8 * * *"
    @State private var postsInChat = true
    @State private var isSaving = false
    @State private var error: String?

    private var schedule: String {
        RoutineSchedule(kind: kind, time: time, weekday: weekday, hours: hours, delay: delay, cron: cron).expression
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !schedule.isEmpty && !isSaving
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
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(Theme.danger)
                } else {
                    Text(RoutineSchedule.describe(schedule))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Routine")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        error = nil
        Task {
            do {
                try await roster.addRoutine(
                    for: botName, title: title, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    schedule: schedule, deliverToBotChat: postsInChat
                )
                AccessibilityNotification.Announcement(String(localized: "Routine saved")).post()
                onDone()
            } catch {
                self.error = BotRoster.describe(error)
                AccessibilityNotification.Announcement(self.error ?? "").post()
            }
            isSaving = false
        }
    }
}

/// Hermes schedules: cron expressions, `every 6h`, and one-shots like `in 30m`
/// (a bare `30m` would repeat).
struct RoutineSchedule {
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
