import HermesKit
import SwiftUI

/// Hermes' reply, top to bottom (`docs/chat.md` §1): the turn header, the plan, the steps
/// with their attachments, the answer, its sources, the actions, then quiet notes.
struct AssistantTurnView: View {
    let turn: AssistantTurn
    var status: String?
    var isStopping = false
    var onBranch: BranchAction?

    @AppStorage(PreferenceKey.showUsage) private var alwaysShowsUsage = false
    @State private var showsUsage = false

    private var showsWork: Bool {
        !turn.steps.isEmpty || !turn.plan.isEmpty || (turn.isWorking && turn.answer.isEmpty)
    }

    /// What the memory tool kept during the turn (`memoryNote`).
    private var remembered: [String] {
        turn.steps.compactMap { step in
            if case .tool(let tool) = step, tool.status == .succeeded { return tool.rememberedText }
            return nil
        }
    }

    /// Pages the turn found, cited under the reply.
    private var sources: [SearchResult] {
        turn.steps.flatMap { step -> [SearchResult] in
            if case .tool(let tool) = step { return tool.searchResults }
            return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsWork {
                WorkSummaryView(turn: turn, status: status, isStopping: isStopping) {
                    if turn.usage != nil { withAnimation(Theme.spring) { showsUsage.toggle() } }
                }
            }
            if let models = turn.models {
                ModelsCard(progress: models, isWorking: turn.isWorking)
            }
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer)
                    .equatable()
                    .contextMenu { replyMenu }
            }
            if !turn.isWorking, !turn.answer.isEmpty, !sources.isEmpty {
                SourcesRow(results: sources)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `Overlays.replyMenu`.
    @ViewBuilder
    private var replyMenu: some View {
        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(turn.copyableText) }
        Button("Read Aloud", systemImage: "speaker.wave.2") { SpeechController.shared.toggle(turn.copyableText) }
        ShareLink(item: turn.copyableText) { Label("Share…", systemImage: "square.and.arrow.up") }
        if let onBranch, onBranch.isLatest, !turn.isWorking {
            Divider()
            Button("Try Again", systemImage: "arrow.clockwise") { onBranch.tryAgain() }
            let models = onBranch.models
            if !models.isEmpty {
                Menu("Try Again with…", systemImage: "cpu") {
                    ForEach(models, id: \.0) { model, title in
                        Button(title) { onBranch.tryAgain(with: model) }
                    }
                }
            }
        }
        if let onBranch {
            Divider()
            Button("Branch from Here", systemImage: "arrow.triangle.branch") { onBranch() }
        }
        if turn.usage != nil {
            Button(showsUsage ? "Hide Usage" : "Show Usage", systemImage: "chart.bar") {
                withAnimation(Theme.spring) { showsUsage.toggle() }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch turn.state {
        case .stopped:
            Text("Stopped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.surface, in: Capsule())
            if !turn.copyableText.isEmpty {
                MessageActions(text: turn.copyableText, onBranch: onBranch) { replyMenu }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.warning)
        case .complete:
            if !turn.copyableText.isEmpty {
                MessageActions(text: turn.copyableText, onBranch: onBranch) { replyMenu }
            }
            if let usage = turn.usage, alwaysShowsUsage || showsUsage {
                UsageFooter(usage: usage)
                    .transition(.opacity)
            }
        case .streaming, .waitingForApproval:
            EmptyView()
        }
        // Shown as soon as Hermes warns, not only once the turn ends: a quiet note, not the status line.
        if let warning = turn.warning {
            TurnWarnings(text: warning)
        }
        if !turn.isWorking {
            ForEach(remembered, id: \.self) { text in
                TurnNote(symbol: "brain", text: String(localized: "Remembered: \(text)"))
            }
        }
        if let onBranch, onBranch.isLatest, !turn.isWorking, let percent = turn.usage?.contextPercent, percent >= 80 {
            ContextNotice(percent: percent) { onBranch.conversation.runCommand("compress", argument: nil) }
        }
    }
}

// MARK: - Actions

private struct MessageActions<More: View>: View {
    let text: String
    var onBranch: BranchAction?
    /// The rest of the reply menu (Try Again, Branch from Here, Show Usage…).
    @ViewBuilder var more: () -> More

    @State private var copied = false
    @State private var speech = SpeechController.shared

    var body: some View {
        HStack(spacing: 2) {
            Button {
                Pasteboard.copy(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")

            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Share")
            .accessibilityLabel("Share")

            Button {
                speech.toggle(text)
            } label: {
                Image(systemName: speech.isSpeaking(text) ? "stop.circle" : "speaker.wave.2")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(speech.isSpeaking(text) ? "Stop reading" : "Read aloud")
            .accessibilityLabel(speech.isSpeaking(text) ? "Stop reading" : "Read aloud")

            if let onBranch {
                Button { onBranch() } label: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .help("Branch from here")
                .accessibilityLabel("Branch from here")
            }

            Menu(content: more) {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .buttonStyle(IconButtonStyle(size: 32))
        .foregroundStyle(Theme.tertiaryText)
        .font(.system(size: 13, weight: .medium))
        .padding(.leading, -8)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }
}

// MARK: - Work summary

/// The turn header and, unfolded, the plan and the steps. Folded, only what the turn changed or
/// warned about stays in view (diffs, risk notes); everything else is a tap away in its step.
struct WorkSummaryView: View {
    let turn: AssistantTurn
    var status: String?
    var isStopping = false
    var onHeaderTap: () -> Void = {}

    @AppStorage(PreferenceKey.expandAgentActivity) private var expandWhileWorking = false
    @State private var userExpanded: Bool? = Disclosure.debugOpens("turns") ? true : nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.disclosureWillToggle) private var willToggle

    private var isExpanded: Bool {
        userExpanded ?? (turn.isWorking && expandWhileWorking)
    }

    private var hasSteps: Bool { !turn.steps.isEmpty || !turn.plan.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    if !turn.plan.isEmpty {
                        PlanCard(plan: turn.plan)
                    }
                    if !turn.steps.isEmpty {
                        StepTimeline(steps: turn.steps)
                    }
                }
                .transition(Disclosure.transition(reduceMotion: reduceMotion))
            } else if !turn.isWorking {
                // Only steps with something to keep in view: an empty one would still take the
                // stack's spacing, and a turn of a hundred tool calls left a screen of blank space.
                ForEach(turn.steps) { step in
                    if case .tool(let tool) = step, tool.hasFoldedAttachments {
                        ToolAttachments(tool: tool)
                    }
                }
            }
        }
        .animation(Disclosure.animation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(.smooth(duration: 0.3), value: turn.steps.count)
        .animation(.smooth(duration: 0.3), value: turn.plan)
    }

    private var header: some View {
        Button {
            willToggle()
            userExpanded = !isExpanded
            onHeaderTap()
        } label: {
            HStack(spacing: 6) {
                if turn.state == .waitingForApproval {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    Text("Waiting for your approval")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.warning)
                } else if turn.isWorking {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                    // A ticker: the new status rolls up as the old one leaves, never both at once.
                    ZStack(alignment: .leading) {
                        ShimmerText(text: workingTitle)
                            .id(workingTitle)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .offset(y: 10).combined(with: .opacity),
                                removal: .offset(y: -10).combined(with: .opacity)
                            ))
                    }
                    .clipped()
                    .animation(.smooth(duration: 0.28), value: workingTitle)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 14, height: 14)
                    Text(doneTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
                if hasSteps, turn.state != .waitingForApproval {
                    DisclosureChevron(isOpen: isExpanded)
                }
                if turn.isWorking, let started = turn.startedAt {
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Formatting.duration(context.date.timeIntervalSince(started)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasSteps && turn.usage == nil)
        .accessibilityLabel(turn.isWorking ? workingTitle : doneTitle)
        .accessibilityHint(!hasSteps ? "" : (isExpanded ? "Hides the steps" : "Shows the steps"))
    }

    private var workingTitle: String {
        if isStopping { return String(localized: "Stopping…") }
        if turn.state == .waitingForApproval { return String(localized: "Waiting for your approval") }
        if let status { return status }
        if let current = turn.steps.last {
            switch current {
            case .tool(let tool) where tool.status == .running:
                return ToolDescriptor.describe(tool.name).activeTitle + "…"
            case .subagent(let agent) where agent.status == .running:
                return String(localized: "Working with subagents…")
            default:
                break
            }
        }
        return turn.answer.isEmpty ? String(localized: "Thinking…") : String(localized: "Writing…")
    }

    private var doneTitle: String {
        let duration = turn.finishedAt.flatMap { end in turn.startedAt.map { end.timeIntervalSince($0) } }
        let tools = turn.toolCount
        let time = duration.map { Formatting.duration($0) }
        switch (tools, time) {
        case (0, let time?): return String(localized: "Thought for \(time)")
        case (0, nil): return String(localized: "Thoughts")
        case (let count, let time?): return count == 1
            ? String(localized: "Worked for \(time) · 1 tool")
            : String(localized: "Worked for \(time) · \(count) tools")
        case (let count, nil): return count == 1 ? String(localized: "Used 1 tool") : String(localized: "Used \(count) tools")
        }
    }
}

/// How every fold in a turn opens and closes: the height eases, the content fades in just behind
/// it and drops a few points into place; closing fades out quickly so nothing hangs over the
/// rows below. Reduce Motion: a plain fade.
enum Disclosure {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.34)
    }

    /// `-HERMES_EXPAND_STEPS turns|all` (Debug) opens every turn, or every turn and row, for screenshots.
    static func debugOpens(_ level: String) -> Bool {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "HERMES_EXPAND_STEPS") {
        case "all": return true
        case let value?: return value == level
        case nil: return false
        }
        #else
        return false
        #endif
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)).animation(.smooth(duration: 0.3).delay(0.05)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

/// Called just before a fold in the transcript opens or closes, so the transcript keeps what was
/// tapped in place instead of anchoring the change to the bottom. Always equal: swapping it in
/// must not redraw every row that reads it.
struct DisclosureAction: Equatable {
    var action: @MainActor () -> Void = {}

    @MainActor func callAsFunction() { action() }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var disclosureWillToggle = DisclosureAction()
}

/// A chevron that turns rather than swaps: right when closed, down when open.
private struct DisclosureChevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.tertiaryText)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// The steps on a rail, one compact row each; a row opens to its details. Three or more of the
/// same tool in a row fold into one row ("Ran 6 commands") that opens to those steps, so a long
/// turn reads as a handful of lines. Consecutive subagents share one row.
private struct StepTimeline: View {
    let steps: [AssistantStep]

    enum Entry: Identifiable {
        case step(AssistantStep)
        case run([ToolActivity])
        case subagents([SubagentActivity])

        var id: String {
            switch self {
            case .step(let step): step.id
            case .run(let tools): "run-" + (tools.first?.id ?? "")
            case .subagents(let agents): "agents-" + (agents.first?.id ?? "")
            }
        }
    }

    static let runThreshold = 3

    static func entries(_ steps: [AssistantStep]) -> [Entry] {
        var entries: [Entry] = []
        var pending: [ToolActivity] = []
        func flush() {
            if pending.count >= runThreshold {
                entries.append(.run(pending))
            } else {
                entries += pending.map { .step(.tool($0)) }
            }
            pending = []
        }
        for step in steps {
            switch step {
            case .tool(let tool):
                if let last = pending.last, ToolRunLine.kind(of: last.name) != ToolRunLine.kind(of: tool.name) {
                    flush()
                }
                pending.append(tool)
            case .subagent(let agent):
                flush()
                if case .subagents(var agents)? = entries.last {
                    agents.append(agent)
                    entries[entries.count - 1] = .subagents(agents)
                } else {
                    entries.append(.subagents([agent]))
                }
            default:
                flush()
                entries.append(.step(step))
            }
        }
        flush()
        return entries
    }

    var body: some View {
        let entries = Self.entries(steps)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isLast = index == entries.count - 1
                switch entry {
                case .step(.tool(let tool)):
                    ToolStepLine(tool: tool, isLast: isLast)
                case .step(.reasoning(_, let text)):
                    ReasoningLine(text: text, isLast: isLast)
                case .step(.narration(_, let text)):
                    NarrationLine(text: text, isLast: isLast)
                case .step(.subagent):
                    EmptyView()
                case .run(let tools):
                    ToolRunLine(tools: tools, isLast: isLast)
                case .subagents(let agents):
                    SubagentsRow(agents: agents, isLast: isLast)
                }
            }
        }
    }
}

/// One rail position: the node (or a small dot for narration) with the line to the next step.
private struct Rail<Node: View>: View {
    let isLast: Bool
    var width: CGFloat = 26
    var topPadding: CGFloat = 0
    @ViewBuilder let node: Node

    var body: some View {
        VStack(spacing: 0) {
            node
                .padding(.top, topPadding)
            if !isLast {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1.5)
                    .frame(minHeight: 8, maxHeight: .infinity)
            }
        }
        .frame(width: width)
    }
}

private struct StepNode: View {
    let symbol: String
    var status: ToolActivity.Status = .succeeded
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle()
                .fill(status == .failed ? Theme.dangerTint : Theme.surface)
            if status != .failed {
                Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status == .failed ? "xmark" : symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(status == .failed ? Theme.danger : Theme.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One step on the rail: its node, a title line (with the time and a chevron) and a one-line
/// preview. Tapping opens what's behind it; `accessory` (a risk note, a failure line) stays in
/// view either way.
private struct StepLine<Accessory: View, Details: View>: View {
    let symbol: String
    var status: ToolActivity.Status = .succeeded
    let title: String
    var preview: String?
    var monospacedPreview = false
    var trailing: String?
    var trailingIsAlert = false
    let isLast: Bool
    var compact = false
    let hasDetails: Bool
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let details: () -> Details

    @State private var isOpen = Disclosure.debugOpens("all")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.disclosureWillToggle) private var willToggle

    private var nodeSize: CGFloat { compact ? 20 : 26 }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            Rail(isLast: isLast, width: nodeSize) { StepNode(symbol: symbol, status: status, size: nodeSize) }
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    willToggle()
                    withAnimation(Disclosure.animation(reduceMotion: reduceMotion)) { isOpen.toggle() }
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .disabled(!hasDetails)
                .accessibilityElement(children: .combine)
                .accessibilityHint(hasDetails ? (isOpen ? "Hides the details" : "Shows the details") : "")
                accessory()
                if isOpen {
                    details()
                        .transition(Disclosure.transition(reduceMotion: reduceMotion))
                }
            }
            .padding(.top, compact ? 1 : 3)
            .padding(.bottom, isLast ? 0 : (compact ? 10 : 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(trailingIsAlert ? Theme.danger : Theme.tertiaryText)
                }
                if hasDetails {
                    DisclosureChevron(isOpen: isOpen)
                }
            }
            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(monospacedPreview ? .caption.monospaced() : .footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension StepLine where Accessory == EmptyView {
    init(
        symbol: String, status: ToolActivity.Status = .succeeded, title: String, preview: String? = nil,
        monospacedPreview: Bool = false, trailing: String? = nil, isLast: Bool, compact: Bool = false,
        hasDetails: Bool, @ViewBuilder details: @escaping () -> Details
    ) {
        self.init(
            symbol: symbol, status: status, title: title, preview: preview, monospacedPreview: monospacedPreview,
            trailing: trailing, isLast: isLast, compact: compact, hasDetails: hasDetails,
            accessory: { EmptyView() }, details: details
        )
    }
}

/// Collapses whitespace and newlines for a one-line preview.
private func oneLine(_ text: String?) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }.joined(separator: " ")
    return line.isEmpty ? nil : line
}

private struct ReasoningLine: View {
    let text: String
    let isLast: Bool

    var body: some View {
        StepLine(symbol: "brain", title: String(localized: "Thought"), preview: oneLine(text), isLast: isLast, hasDetails: true) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the agent said between tool calls: its own words, so they stay readable on the rail.
private struct NarrationLine: View {
    let text: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rail(isLast: isLast, topPadding: 8) {
                Circle()
                    .fill(Theme.placeholderText)
                    .frame(width: 7, height: 7)
                    .frame(width: 26)
                    .padding(.bottom, 4)
            }
            MarkdownView(text: text, tone: .secondary)
                .equatable()
                .environment(\.markdownBodyFont, Theme.Typography.compactMessage)
                .padding(.bottom, isLast ? 0 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tool call as one row: its title (present tense while it runs), the time, and what it worked
/// on. A failure line and a risk note stay in view; the command, output, diff and results open
/// with a tap.
private struct ToolStepLine: View {
    let tool: ToolActivity
    let isLast: Bool
    var compact = false

    private var descriptor: ToolDescriptor { ToolDescriptor.describe(tool.name) }
    private var isSearch: Bool { !tool.searchResults.isEmpty || tool.name == "web_search" }

    private var title: String {
        switch tool.status {
        case .running: descriptor.activeTitle
        case .succeeded: descriptor.doneTitle
        case .failed: tool.name == "terminal" ? String(localized: "Command failed") : descriptor.doneTitle
        }
    }

    var body: some View {
        StepLine(
            symbol: descriptor.symbol, status: tool.status, title: title,
            preview: oneLine(tool.preview), monospacedPreview: !isSearch,
            trailing: tool.status == .running ? nil : durationText, trailingIsAlert: tool.status == .failed,
            isLast: isLast, compact: compact, hasDetails: tool.hasDetails
        ) {
            if tool.status == .failed, let line = failureLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
            }
            if let risk = tool.risk {
                RiskNote(risk: risk)
            }
        } details: {
            ToolDetails(tool: tool)
        }
    }

    private var durationText: String? {
        let time = tool.duration.map { Formatting.duration($0) }
        if tool.status == .failed, let code = tool.commandOutput?.exitCode, code != 0 {
            return [String(localized: "exit \(code)"), time].compactMap { $0 }.joined(separator: " · ")
        }
        return time
    }

    private var failureLine: String? {
        let text = tool.commandOutput?.lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? tool.result
        return text.map { String($0.prefix(200)) }
    }
}

/// Three or more calls of one tool in a row, as one row that opens to them.
private struct ToolRunLine: View {
    let tools: [ToolActivity]
    let isLast: Bool

    /// Tools that read as the same kind of step share a run (a command and reading its terminal).
    static func kind(of name: String) -> String {
        ToolDescriptor.describe(name).symbol
    }

    private var descriptor: ToolDescriptor { ToolDescriptor.describe(tools.first?.name ?? "") }
    private var isRunning: Bool { tools.contains { $0.status == .running } }
    private var failures: Int { tools.filter { $0.status == .failed }.count }

    private var title: String {
        let count = tools.count
        let name = tools.first?.name ?? ""
        switch Self.kind(of: name) {
        case "terminal": return isRunning ? String(localized: "Running commands · \(count)") : String(localized: "Ran \(count) commands")
        case "doc.text": return isRunning ? String(localized: "Reading files · \(count)") : String(localized: "Read \(count) files")
        case "pencil.line": return isRunning ? String(localized: "Editing files · \(count)") : String(localized: "Edited \(count) files")
        case "square.and.pencil": return isRunning ? String(localized: "Writing files · \(count)") : String(localized: "Wrote \(count) files")
        case "globe": return isRunning ? String(localized: "Searching the web · \(count)") : String(localized: "Searched the web \(count) times")
        case "doc.richtext": return isRunning ? String(localized: "Reading pages · \(count)") : String(localized: "Read \(count) pages")
        case "doc.text.magnifyingglass": return isRunning ? String(localized: "Searching files · \(count)") : String(localized: "Searched files \(count) times")
        default:
            return isRunning ? "\(descriptor.activeTitle) · \(count)" : "\(descriptor.doneTitle) · \(count)×"
        }
    }

    private var duration: String? {
        let total = tools.compactMap(\.duration).reduce(0, +)
        return total > 0 ? Formatting.duration(total) : nil
    }

    var body: some View {
        StepLine(
            symbol: descriptor.symbol, status: isRunning ? .running : .succeeded, title: title,
            preview: oneLine((tools.last(where: { $0.status == .running }) ?? tools.last)?.preview),
            monospacedPreview: Self.kind(of: tools.first?.name ?? "") != "globe",
            trailing: isRunning ? nil : duration, isLast: isLast, hasDetails: true
        ) {
            if failures > 0 {
                Text(failures == 1 ? String(localized: "1 failed") : String(localized: "\(failures) failed"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.danger)
            }
        } details: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    ToolStepLine(tool: tool, isLast: index == tools.count - 1, compact: true)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Behind a tool row: the whole command or arguments, then whatever the call produced.
private struct ToolDetails: View {
    let tool: ToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let output = tool.commandOutput
            // The output block opens with the command itself; without one, show it here in full.
            if output == nil || output?.lines.isEmpty == true, let preview = tool.preview, !preview.isEmpty {
                Text(preview)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let diff = tool.displayDiff {
                DiffCard(path: tool.filePath ?? tool.preview ?? "file", diff: diff)
            }
            if let output, !output.lines.isEmpty {
                OutputBlock(output: output, command: tool.preview)
            }
            let results = tool.searchResults
            if !results.isEmpty {
                SearchResultsCard(results: results)
            } else if output == nil, tool.displayDiff == nil, let result = tool.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                Text(String(result.prefix(600)))
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
    }
}

/// "Delegated to subagents": each task's goal and how it's going, in one box.
private struct SubagentsRow: View {
    let agents: [SubagentActivity]
    let isLast: Bool

    private var status: ToolActivity.Status {
        if agents.contains(where: { $0.status == .running }) { return .running }
        return agents.contains(where: { $0.status == .failed }) ? .failed : .succeeded
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rail(isLast: isLast) { StepNode(symbol: "person.2", status: status == .failed ? .succeeded : status) }
            VStack(alignment: .leading, spacing: 8) {
                Text(agents.count == 1 ? "Delegated to a subagent" : "Delegated to subagents")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Group {
                                switch agent.status {
                                case .running: ProgressView().controlSize(.mini)
                                case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                                }
                            }
                            .font(.system(size: 13))
                            .frame(width: 14, height: 14)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.goal)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                                if let summary = agent.summary, !summary.isEmpty, agent.status != .running {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a folded turn keeps in view: the files it changed and any risk note. The rest (commands,
/// output, results) is in the steps.
struct ToolAttachments: View {
    let tool: ToolActivity

    var body: some View {
        if tool.status != .running {
            VStack(alignment: .leading, spacing: 10) {
                if let risk = tool.risk {
                    RiskNote(risk: risk)
                }
                if let diff = tool.displayDiff {
                    DiffCard(path: tool.filePath ?? tool.preview ?? "file", diff: diff)
                }
            }
        }
    }
}

extension ToolActivity {
    /// Whether a folded turn keeps something of this step in view (a diff, a risk note).
    var hasFoldedAttachments: Bool {
        status != .running && (risk != nil || displayDiff != nil)
    }

    /// Whether the step's row opens to anything: the full command, output, a diff, results.
    var hasDetails: Bool {
        guard status != .running else { return false }
        if displayDiff != nil || !searchResults.isEmpty || commandOutput != nil { return true }
        if preview?.isEmpty == false { return true }
        return result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// "Branch into a new chat", as a value that stays equal while it targets the same
/// conversation (a closure never compares equal and would re-render every row).
/// What a reply's actions act on. Holds the conversation, not fresh closures, so finished turns
/// compare equal and don't re-render while another reply streams.
struct BranchAction {
    let conversation: ConversationModel
    var itemID: String?
    /// The newest reply: Try Again reruns it.
    var isLatest = false

    func callAsFunction() {
        if let itemID, conversation.canBranchFromPoint {
            conversation.branch(at: .through(itemID))
        } else {
            conversation.branch()
        }
    }

    func tryAgain(with model: ModelSelection? = nil) {
        if let model { conversation.model = model }
        conversation.retryLastMessage()
    }

    var models: [(ModelSelection, String)] {
        guard let options = conversation.workspace?.modelOptions else { return [] }
        return options.usableProviders.flatMap { provider in
            (provider.featuredModels ?? Array(provider.models.prefix(4))).map {
                (ModelSelection(provider: provider.slug, model: $0), "\(ModelNames.display($0)) · \(provider.name)")
            }
        }
        .prefix(8)
        .map { $0 }
    }
}
