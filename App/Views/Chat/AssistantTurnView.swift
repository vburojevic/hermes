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
        if let warning = turn.warning, !turn.isWorking {
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

/// The turn header and, unfolded, the plan and the step timeline. Folded, the steps' attachments
/// (diffs, output, results) stay in view: they're what the turn produced.
struct WorkSummaryView: View {
    let turn: AssistantTurn
    var status: String?
    var isStopping = false
    var onHeaderTap: () -> Void = {}

    @AppStorage(PreferenceKey.expandAgentActivity) private var expandWhileWorking = false
    @State private var userExpanded: Bool?

    private var isExpanded: Bool {
        userExpanded ?? (turn.isWorking && expandWhileWorking)
    }

    private var hasSteps: Bool { !turn.steps.isEmpty || !turn.plan.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isExpanded {
                if !turn.plan.isEmpty {
                    PlanCard(plan: turn.plan)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !turn.steps.isEmpty {
                    StepTimeline(steps: turn.steps)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if !turn.isWorking {
                // Only steps with something to show: an empty one would still take the stack's
                // spacing, and a turn of a hundred tool calls left a screen of blank space.
                ForEach(turn.steps) { step in
                    if case .tool(let tool) = step, tool.hasAttachments {
                        ToolAttachments(tool: tool)
                    }
                }
            }
        }
        .animation(Theme.spring, value: isExpanded)
        .animation(Theme.spring, value: turn.steps.count)
        .animation(Theme.spring, value: turn.plan)
    }

    private var header: some View {
        Button {
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
                    ShimmerText(text: workingTitle)
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
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiaryText)
                        .contentTransition(.symbolEffect(.replace))
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

/// The steps in order, joined by a rail; consecutive subagents share one step.
private struct StepTimeline: View {
    let steps: [AssistantStep]

    private enum Entry: Identifiable {
        case step(AssistantStep)
        case subagents([SubagentActivity])

        var id: String {
            switch self {
            case .step(let step): step.id
            case .subagents(let agents): "agents-" + (agents.first?.id ?? "")
            }
        }
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        for step in steps {
            if case .subagent(let agent) = step {
                if case .subagents(var agents)? = entries.last {
                    agents.append(agent)
                    entries[entries.count - 1] = .subagents(agents)
                } else {
                    entries.append(.subagents([agent]))
                }
            } else {
                entries.append(.step(step))
            }
        }
        return entries
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isLast = index == entries.count - 1
                switch entry {
                case .step(let step):
                    StepRow(step: step, isLast: isLast)
                    if case .tool(let tool) = step, tool.hasAttachments {
                        ToolAttachments(tool: tool)
                            .padding(.bottom, isLast ? 0 : 14)
                    }
                case .subagents(let agents):
                    SubagentsRow(agents: agents, isLast: isLast)
                }
            }
        }
    }
}

/// One rail position: a 26 pt node (or a small dot for narration) with the line to the next step.
private struct Rail<Node: View>: View {
    let isLast: Bool
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
        .frame(width: 26)
    }
}

private struct StepNode: View {
    let symbol: String
    var status: ToolActivity.Status = .succeeded

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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status == .failed ? Theme.danger : Theme.secondaryText)
            }
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

private struct StepRow: View {
    let step: AssistantStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            rail
            content
                .padding(.top, isNarration ? 0 : 3)
                .padding(.bottom, isLast ? 0 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isNarration: Bool {
        if case .narration = step { true } else { false }
    }

    @ViewBuilder
    private var rail: some View {
        switch step {
        case .reasoning:
            Rail(isLast: isLast) { StepNode(symbol: "brain") }
        case .narration:
            Rail(isLast: isLast, topPadding: 8) {
                Circle()
                    .fill(Theme.placeholderText)
                    .frame(width: 7, height: 7)
                    .frame(width: 26)
                    .padding(.bottom, 4)
            }
        case .tool(let tool):
            Rail(isLast: isLast) { StepNode(symbol: ToolDescriptor.describe(tool.name).symbol, status: tool.status) }
        case .subagent:
            Rail(isLast: isLast) { StepNode(symbol: "person.2") }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .reasoning(_, let text):
            ReasoningText(text: text)
        case .narration(_, let text):
            MarkdownView(text: text, tone: .secondary)
                .equatable()
                .environment(\.markdownBodyFont, Theme.Typography.compactMessage)
        case .tool(let tool):
            ToolStepView(tool: tool)
        case .subagent:
            EmptyView()
        }
    }
}

private struct ReasoningText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reasoning")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
            if text.count > 280 {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(Theme.spring) { expanded.toggle() }
                }
                .font(.footnote.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
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

/// A tool call: its title (present tense while it runs), the duration, what it worked on, and
/// a one-line result. Diffs, output and results follow it as attachments.
private struct ToolStepView: View {
    let tool: ToolActivity

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 6)
                if tool.status != .running, let duration = durationText {
                    Text(duration)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(tool.status == .failed ? Theme.danger : Theme.tertiaryText)
                }
            }
            if let preview = tool.preview, !preview.isEmpty {
                Text(preview)
                    .font(isSearch ? .footnote : Theme.Typography.code)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if isSearch, tool.status != .running {
                let sites = tool.searchResults.compactMap(\.site)
                if !sites.isEmpty {
                    Text(Array(NSOrderedSet(array: sites)).compactMap { $0 as? String }.prefix(3).joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            if tool.status == .failed, let line = failureLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
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

/// What a finished tool call produced: a diff, its output, web results, a risk note.
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
                if let output = tool.commandOutput, output.lines.count > 1 || output.failed {
                    OutputBlock(output: output, command: tool.preview)
                }
                let results = tool.searchResults
                if results.count > 1 {
                    SearchResultsCard(results: results)
                }
            }
        }
    }
}

extension ToolActivity {
    /// Whether the step has a diff, output, results or a risk note to show.
    var hasAttachments: Bool {
        guard status != .running else { return false }
        if risk != nil || displayDiff != nil || searchResults.count > 1 { return true }
        if let output = commandOutput { return output.lines.count > 1 || output.failed }
        return false
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
