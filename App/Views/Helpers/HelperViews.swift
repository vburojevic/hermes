import HermesKit
import SwiftUI

// Helpers in the chat (`blocks/subagents.elyx`): content, so surface fills, never glass.

enum HelperFormat {
    /// "1:42", "10:00", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "6 min", "45 s", "1 h 5 min".
    static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return String(localized: "\(total) s") }
        if total < 3600 { return String(localized: "\((total + 30) / 60) min") }
        return String(localized: "\(total / 3600) h \((total % 3600) / 60) min")
    }

    /// For VoiceOver: "1 minute 42".
    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, seconds)) ?? clock(seconds)
    }

    /// "41k".
    static func tokens(_ count: Int) -> String {
        count >= 1000 ? "\(Int((Double(count) / 1000).rounded()))k" : "\(count)"
    }

    /// "Claude Sonnet 4.6" from `anthropic/claude-sonnet-4.6`.
    static func model(_ id: String?) -> String? {
        id.map(ModelNames.display)
    }

    /// "Sonnet" for the metric tile.
    static func shortModel(_ id: String?) -> String? {
        guard let name = model(id) else { return nil }
        let words = name.split(separator: " ")
        if words.count >= 2, words[0].lowercased() == "claude" { return String(words[1]) }
        return words.first.map(String.init) ?? name
    }

    static func elapsed(_ helper: Helper, now: Date) -> TimeInterval? {
        if let seconds = helper.durationSeconds, helper.status.isFinished { return seconds }
        guard let start = helper.startedAt else { return nil }
        return (helper.finishedAt ?? now).timeIntervalSince(start)
    }

    /// "Timed out after 10 min", "Failed: …", "Stopped".
    static func failureLine(_ helper: Helper) -> String {
        switch helper.status {
        case .timeout:
            if let seconds = helper.durationSeconds { return String(localized: "Timed out after \(span(seconds))") }
            return helper.failureText ?? String(localized: "Timed out")
        case .interrupted:
            return String(localized: "Stopped")
        default:
            return helper.failureText ?? String(localized: "Failed")
        }
    }

    /// "Running · 1:42", "Done in 0:58", "Timed out after 10 min", "Waiting for a free slot".
    static func statusLine(_ helper: Helper, team: HelperTeam?, now: Date) -> String {
        switch helper.status {
        case .queued:
            return String(localized: "Waiting for a free slot · starts when one finishes")
        case .running:
            let kids = team?.children(of: helper.id) ?? []
            if !kids.isEmpty { return String(localized: "Running · leading \(kids.count) helpers") }
            return elapsed(helper, now: now).map { String(localized: "Running · \(clock($0))") } ?? String(localized: "Running")
        case .completed:
            if helper.endedUnseen { return String(localized: "Finished") }
            return elapsed(helper, now: now).map { String(localized: "Done in \(clock($0))") } ?? String(localized: "Done")
        default:
            return failureLine(helper)
        }
    }

    /// "Helper 1 of 4, Audit the app targets for strict concurrency, running, 1 minute 42".
    static func accessibility(_ helper: Helper, team: HelperTeam, now: Date) -> String {
        let number = team.number(of: helper)
        let count = helper.parentID == nil ? team.total : team.children(of: helper.parentID ?? "").count
        var parts = [String(localized: "Helper \(number) of \(count)"), helper.goal]
        switch helper.status {
        case .queued: parts.append(String(localized: "waiting for a free slot"))
        case .running: parts.append(String(localized: "running"))
        case .completed: parts.append(String(localized: "done"))
        case .interrupted: parts.append(String(localized: "stopped"))
        default: parts.append(failureLine(helper))
        }
        if let seconds = elapsed(helper, now: now), helper.status != .queued { parts.append(spoken(seconds)) }
        return parts.joined(separator: ", ")
    }
}

/// The helper's number in a rounded tile (`helperBadge*`): ink while it runs, quiet otherwise.
struct HelperBadge: View {
    let number: String
    var isRunning = false
    var size: CGFloat = 26

    var body: some View {
        Text(number)
            .font(.system(size: number.count > 2 ? size * 0.46 : size * 0.5, weight: .bold).monospacedDigit())
            .foregroundStyle(isRunning ? Theme.inkForeground : Theme.secondaryText)
            .padding(.horizontal, number.count > 2 ? 4 : 0)
            .frame(minWidth: size, minHeight: size)
            .background(isRunning ? Theme.ink : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The trailing state: the elapsed time counting up, ✓ + duration, ✕ + duration, or an hourglass.
/// Nothing spins: the turn header is the turn's one live line (`docs/helpers.md` §2).
struct HelperStateLabel: View {
    let helper: Helper

    var body: some View {
        TimelineView(.periodic(from: .now, by: helper.status == .running ? 1 : 86_400)) { context in
            HStack(spacing: 5) {
                switch helper.status {
                case .queued:
                    Image(systemName: "hourglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                case .running:
                    if let seconds = HelperFormat.elapsed(helper, now: context.date) {
                        Text(HelperFormat.clock(seconds))
                    }
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    if let seconds = HelperFormat.elapsed(helper, now: context.date), !helper.endedUnseen {
                        Text(HelperFormat.clock(seconds))
                    }
                case .interrupted:
                    Image(systemName: "stop.circle.fill").foregroundStyle(Theme.tertiaryText)
                    if let seconds = helper.durationSeconds { Text(HelperFormat.clock(seconds)) }
                default:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                    if let seconds = helper.durationSeconds { Text(HelperFormat.clock(seconds)) }
                }
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Theme.tertiaryText)
        }
        .accessibilityHidden(true)
    }
}

/// One helper in the team card (`helperRow*`): badge, goal, live line, state.
struct HelperRow: View {
    let helper: Helper
    let team: HelperTeam
    var showsChevron = true

    /// What it's doing, what it found, or why it stopped.
    private var line: (text: String, mono: Bool, danger: Bool)? {
        switch helper.status {
        case .queued:
            return (String(localized: "Waiting for a free slot"), false, false)
        case .running:
            if let tool = helper.currentTool {
                let preview = helper.currentToolPreview.map { $0.isEmpty ? "" : "  \($0)" } ?? ""
                return ("\(tool)\(preview)", true, false)
            }
            return helper.thinking.map { ($0, false, false) }
        case .completed:
            return helper.cleanSummary.map { ($0, false, false) }
        default:
            return (HelperFormat.failureLine(helper), false, helper.status != .interrupted)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HelperBadge(number: team.number(of: helper), isRunning: helper.status == .running)
            VStack(alignment: .leading, spacing: 2) {
                Text(helper.goal)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(helper.status == .queued ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(2)
                if let line {
                    Text(line.text)
                        .font(line.mono ? .caption.monospaced() : .caption)
                        .foregroundStyle(line.danger ? Theme.danger : Theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HelperStateLabel(helper: helper)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .modifier(ThrottledAccessibility(isLive: helper.status == .running, text: { HelperFormat.accessibility(helper, team: team, now: $0) }))
    }
}

/// VoiceOver hears a live line at most every 2 s (`docs/helpers.md` §6).
struct ThrottledAccessibility: ViewModifier {
    /// Only a running helper's line changes on its own; a finished one holds still.
    var isLive = true
    let text: (Date) -> String

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: isLive ? 2 : 86_400)) { context in
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text(context.date))
                .accessibilityAddTraits([.isButton, .updatesFrequently])
        }
    }
}

/// The live team in the turn (`teamCard`): "4 helpers · 1 running", "1 of 4 done", a row per
/// helper, then Open Team.
struct TeamCard: View {
    let team: HelperTeam
    let openTeam: () -> Void
    let openHelper: (Helper) -> Void

    private static let maxRows = 5

    /// Running first when there are more than five; otherwise in `task_index` order.
    private var rows: (shown: [Helper], more: Int) {
        let all = team.topLevel
        guard all.count > Self.maxRows else { return (all, 0) }
        let running = all.filter { $0.status == .running }
        let rest = all.filter { $0.status != .running }
        let shown = Array((running + rest).prefix(Self.maxRows))
        return (shown, all.count - shown.count)
    }

    private var headline: String {
        let running = team.runningCount
        let helpers = team.everyone == 1 ? String(localized: "1 helper") : String(localized: "\(team.everyone) helpers")
        return running > 0 ? String(localized: "\(helpers) · \(running) running") : helpers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Text("\(team.doneCount) of \(team.everyone) done")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            let shown = rows
            ForEach(Array(shown.shown.enumerated()), id: \.element.id) { index, helper in
                if index > 0 { Divider().overlay(Theme.hairline) }
                Button { openHelper(helper) } label: {
                    HelperRow(helper: helper, team: team)
                }
                .buttonStyle(.plain)
            }
            if shown.more > 0 {
                Divider().overlay(Theme.hairline)
                Button(action: openTeam) {
                    Text("+\(shown.more) more")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)
            Button(action: openTeam) {
                HStack {
                    Text("Open Team")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcutForTeam()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .animation(Theme.snappy, value: team)
    }
}

private extension View {
    @ViewBuilder
    func keyboardShortcutForTeam() -> some View {
        #if os(macOS)
        self.help("Open Team (⌥⌘T)")
        #else
        self
        #endif
    }
}

/// The folded team after the work is done (`teamSummary`): "Worked with 4 helpers · 6 min" and
/// a red "1 failed" tag.
struct TeamSummaryRow: View {
    let count: Int
    let duration: TimeInterval?
    let failed: Int
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "person.2")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                // "Worked with 4 helpers · 6 min", or "4 helpers · 6 min" where that won't fit.
                ViewThatFits(in: .horizontal) {
                    Text(title).lineLimit(1)
                    Text(shortTitle).lineLimit(1)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                if failed > 0 {
                    TagLabel(title: String(localized: "\(failed) failed"), style: .danger)
                }
                if isLoading {
                    Spinner(size: .mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 520, minHeight: 46, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed > 0 ? "\(title), \(String(localized: "\(failed) failed"))" : title)
        .accessibilityHint("Opens the team")
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        let helpers = count == 1 ? String(localized: "Worked with 1 helper") : String(localized: "Worked with \(count) helpers")
        guard let duration, duration > 0 else { return helpers }
        return "\(helpers) · \(HelperFormat.span(duration))"
    }

    private var shortTitle: String {
        let helpers = count == 1 ? String(localized: "1 helper") : String(localized: "\(count) helpers")
        guard let duration, duration > 0 else { return helpers }
        return "\(helpers) · \(HelperFormat.span(duration))"
    }
}

/// One helper on the Team page or in the inspector (`helperCard*`).
struct HelperCard: View {
    let helper: Helper
    let team: HelperTeam
    let store: HelperStore
    var cellFill: Color = Theme.groupedCell
    let open: () -> Void
    let steer: () -> Void

    @State private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 10) {
                    HelperBadge(number: team.number(of: helper), isRunning: helper.status == .running)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(helper.goal)
                            .font(.headline)
                            .foregroundStyle(helper.status == .queued ? Theme.secondaryText : Theme.primaryText)
                            .multilineTextAlignment(.leading)
                        statusLine
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(ThrottledAccessibility(isLive: helper.status == .running, text: { HelperFormat.accessibility(helper, team: team, now: $0) }))

            if let metrics {
                Text(metrics)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            content
            missedNotes
            actions
            nested
        }
        .padding(14)
        .background(cellFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .confirmationDialog("Stop helper \(team.number(of: helper))?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Helper", role: .destructive) { store.stop(helper) }
        } message: {
            Text("It has written files. What it wrote so far stays.")
        }
    }

    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: helper.status == .running ? 1 : 86_400)) { context in
            HStack(spacing: 5) {
                switch helper.status {
                // Running: the line's own time counts up; nothing spins.
                case .running: EmptyView()
                case .queued: Image(systemName: "hourglass").foregroundStyle(Theme.secondaryText)
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .interrupted: Image(systemName: "stop.circle.fill").foregroundStyle(Theme.tertiaryText)
                default: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                }
                Text(HelperFormat.statusLine(helper, team: team, now: context.date))
                    .foregroundStyle(helper.status.isFailure ? Theme.danger : Theme.secondaryText)
            }
            .font(.footnote)
        }
    }

    /// "Claude Sonnet 4.6 · 12 tools · 41k tokens · read 18 files".
    private var metrics: String? {
        guard helper.status != .queued else { return nil }
        var parts: [String] = []
        if let model = HelperFormat.model(helper.model) { parts.append(model) }
        if helper.toolCount > 0 { parts.append(helper.toolCount == 1 ? String(localized: "1 tool") : String(localized: "\(helper.toolCount) tools")) }
        if let tokens = helper.totalTokens { parts.append(String(localized: "\(HelperFormat.tokens(tokens)) tokens")) }
        if !helper.filesRead.isEmpty {
            parts.append(helper.filesRead.count == 1 ? String(localized: "read 1 file") : String(localized: "read \(helper.filesRead.count) files"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch helper.status {
        case .running:
            let lines = helper.recentTools.suffix(3)
            if !lines.isEmpty {
                TailBox(lines: lines.map { ($0.tool, $0.preview, false) })
            }
        case .completed:
            if let summary = helper.cleanSummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !helper.filesWritten.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(helper.filesWritten, id: \.self) { path in
                        FilePill(path: path, size: .regular)
                    }
                }
            }
        case .queued:
            EmptyView()
        default:
            let tail: [TailBox.Line] = helper.outputTail.suffix(3).map { ($0.tool, $0.preview, $0.isError) }
            // Without a tail the status line already says why.
            if !tail.isEmpty {
                TailBox(lines: tail)
            }
        }
    }

    @ViewBuilder
    private var missedNotes: some View {
        ForEach((store.notes[helper.id] ?? []).filter { $0.state == .missed }) { note in
            HelperMissedNoteCard(note: note, number: team.number(of: helper), store: store, helperID: helper.id)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch helper.status {
        case .running:
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    if helper.hasWritten { confirmingStop = true } else { store.stop(helper) }
                } label: {
                    Text("Stop")
                }
                .buttonStyle(HelperActionStyle(isDestructive: true))
                if helper.acceptingSteer {
                    Button(action: steer) {
                        Text("Steer…")
                    }
                    .buttonStyle(HelperActionStyle())
                }
            }
        case .queued:
            Button(role: .destructive) { store.stop(helper) } label: {
                Text("Cancel")
            }
            .buttonStyle(HelperActionStyle(isDestructive: true))
        case .failed, .error, .timeout:
            if helper.parentID == nil {
                Button { store.askToRetry(helper, in: team) } label: {
                    Text("Ask Hermes to Retry")
                }
                .buttonStyle(HelperActionStyle())
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var nested: some View {
        let kids = team.children(of: helper.id)
        if !kids.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(kids.enumerated()), id: \.element.id) { index, kid in
                    NestedHelperRow(helper: kid, team: team, isLast: index == kids.count - 1)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// A helper card's secondary actions: Stop (red), Steer…, Cancel, Ask Hermes to Retry.
struct HelperActionStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isDestructive ? Theme.danger : Theme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Theme.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Mono lines: tool, then what it did; errors in red.
struct TailBox: View {
    typealias Line = (tool: String, text: String, isError: Bool)
    let lines: [Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text("\(Text(line.tool).foregroundStyle(line.isError ? Theme.danger : Theme.secondaryText))  \(Text(line.text).foregroundStyle(line.isError ? Theme.danger : Theme.primaryText))")
                    .font(.caption.monospaced())
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A helper started by a helper, under its lead (`nestedHelperRow*`), numbered 1.1, 1.2…
struct NestedHelperRow: View {
    let helper: Helper
    let team: HelperTeam
    let isLast: Bool

    var body: some View {
        HStack(spacing: 10) {
            TreeLine(isLast: isLast)
                .frame(width: 18)
            HelperBadge(number: team.number(of: helper), isRunning: helper.status == .running, size: 24)
            Text(helper.goal)
                .font(.footnote)
                .foregroundStyle(helper.status == .running ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch helper.status {
                case .running: HelperStateLabel(helper: helper)
                case .queued: Image(systemName: "hourglass").foregroundStyle(Theme.secondaryText)
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .interrupted: Image(systemName: "stop.circle.fill").foregroundStyle(Theme.tertiaryText)
                default: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                }
            }
            .font(.footnote)
        }
        .frame(minHeight: 40)
        .modifier(ThrottledAccessibility(isLive: helper.status == .running, text: { HelperFormat.accessibility(helper, team: team, now: $0) }))
    }
}

private struct TreeLine: View {
    let isLast: Bool

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let x = geometry.size.width * 0.35
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: isLast ? geometry.size.height / 2 : geometry.size.height))
                path.move(to: CGPoint(x: x, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(Theme.hairline, lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

/// A note the helper never read (`steerMissed`): "Helper 1 finished before reading your note",
/// with Send to Hermes (a steer to the parent) and Discard.
struct HelperMissedNoteCard: View {
    let note: HelperStore.HelperNote
    let number: String
    let store: HelperStore
    let helperID: String

    var body: some View {
        SteerMissedCard(
            text: note.text,
            title: String(localized: "Helper \(number) finished before reading your note"),
            sendTitle: String(localized: "Send to Hermes"),
            alignment: .leading,
            onDiscard: { store.discardNote(note, of: helperID) },
            onSend: { store.sendNoteToHermes(note, of: helperID) }
        )
    }
}
