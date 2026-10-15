import HermesKit
import SwiftUI

/// Where helpers open, set by the chat for its layout (`docs/helpers.md` §3): pushed on iPhone
/// and iPad portrait, in the inspector on Mac and iPad landscape.
struct HelperNavigator {
    var openTeam: (_ teamID: String) -> Void
    var openHelper: (_ helperID: String, _ teamID: String) -> Void
}

extension EnvironmentValues {
    @Entry var helperNavigator: HelperNavigator?
}

private extension View {
    /// A title only on a pushed page: in the inspector the window keeps the chat's.
    @ViewBuilder
    func pageTitle(_ title: String, isPage: Bool) -> some View {
        if isPage { navigationTitle(title) } else { self }
    }
}

// MARK: - In the turn

/// One turn's helpers: the live team card where the delegation happened, folded into its
/// summary once every helper is done and the turn has ended.
struct TurnTeams: View {
    let slots: [Slot]
    let turnIsWorking: Bool
    let store: HelperStore

    @Environment(\.helperNavigator) private var navigator

    enum Slot: Identifiable {
        case team(HelperTeam)
        /// A past run not loaded yet: from the turn's stored `delegate_task` result.
        case stored(StoredDelegation)

        var id: String {
            switch self {
            case .team(let team): team.id
            case .stored(let stored): stored.delegationID
            }
        }
    }

    /// The turn's teams, by its `delegate_task` calls (live by call id, stored by delegation id),
    /// then any `extra` ones.
    static func slots(for turn: AssistantTurn, extra: [String], store: HelperStore) -> [Slot] {
        var seen = Set<String>()
        var slots: [Slot] = []
        for step in turn.steps {
            guard case .tool(let tool) = step, tool.name == "delegate_task" else { continue }
            let stored = StoredDelegation(tool: tool)
            let team = tool.callID.flatMap(store.team(forCall:)) ?? stored.flatMap { store.team(id: $0.delegationID) }
            if let team {
                if seen.insert(team.id).inserted { slots.append(.team(team)) }
            } else if let stored, seen.insert(stored.delegationID).inserted {
                slots.append(.stored(stored))
            }
        }
        for id in extra where !seen.contains(id) {
            if let team = store.team(id: id) {
                seen.insert(id)
                slots.append(.team(team))
            }
        }
        return slots
    }

    var body: some View {
        ForEach(slots) { slot in
            switch slot {
            case .team(let team):
                if team.isFinished, !turnIsWorking {
                    TeamSummaryRow(count: team.everyone, duration: team.duration, failed: team.failedCount) {
                        navigator?.openTeam(team.id)
                    }
                    .transition(.opacity)
                    // Known only from its failures: the saved tree has everyone.
                    .task(id: team.isPartial ? "\(team.id)-\(store.isConnected)" : "") {
                        guard team.isPartial else { return }
                        await store.listSavedTrees()
                        await store.loadTree(delegationID: team.id)
                    }
                } else {
                    TeamCard(
                        team: team,
                        openTeam: { navigator?.openTeam(team.id) },
                        openHelper: { navigator?.openHelper($0.id, team.id) }
                    )
                    .transition(.opacity)
                }
            case .stored(let stored):
                StoredTeamRow(stored: stored, store: store)
            }
        }
    }
}

/// What the turn header says about its helpers: how many, and whether any still work.
struct HelperHeadline: Equatable {
    let count: Int
    let isWorking: Bool

    init?(_ slots: [TurnTeams.Slot]) {
        guard !slots.isEmpty else { return nil }
        var count = 0
        var working = false
        for slot in slots {
            switch slot {
            case .team(let team):
                count += team.everyone
                working = working || team.isLive
            case .stored(let stored):
                count += stored.count
            }
        }
        self.count = count
        isWorking = working
    }
}

/// A past turn's team before its saved tree is loaded: loads it on sight (`spawn_tree.list` once
/// for the chat, then `spawn_tree.load`).
private struct StoredTeamRow: View {
    let stored: StoredDelegation
    let store: HelperStore

    @Environment(\.helperNavigator) private var navigator

    private var entry: SpawnTreeEntry? { store.savedTrees[stored.delegationID] }

    private var duration: TimeInterval? {
        guard let start = entry?.startedAt, let end = entry?.finishedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    var body: some View {
        TeamSummaryRow(
            count: entry?.count ?? stored.count,
            duration: duration,
            failed: 0,
            isLoading: store.loadingTree == stored.delegationID
        ) {
            Task {
                await store.loadTree(delegationID: stored.delegationID)
                if store.team(id: stored.delegationID) != nil { navigator?.openTeam(stored.delegationID) }
            }
        }
        // Hermes keeps no record of a run the app wasn't open for.
        .disabled(entry == nil)
        .task(id: "\(stored.delegationID)-\(store.isConnected)") {
            await store.listSavedTrees()
            await store.loadTree(delegationID: stored.delegationID)
        }
    }
}

// MARK: - Team page and inspector

/// Everyone on a team (`teamPage`, `macTeamInspector`): the switch that stops Hermes starting
/// more helpers, then a card per helper, running first.
struct TeamView: View {
    enum Style { case page, inspector }

    let store: HelperStore
    let conversation: ConversationModel
    let workspace: BotWorkspace
    let teamID: String
    let style: Style

    private var team: HelperTeam? { store.team(id: teamID) }

    private var cellFill: Color { style == .page ? Theme.groupedCell : Theme.sheetCell }

    private var title: String {
        guard let team else { return String(localized: "Team") }
        return team.everyone == 1 ? String(localized: "Team · 1 helper") : String(localized: "Team · \(team.everyone) helpers")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if style == .inspector {
                    InspectorHeader(title: title, onClose: { store.shownTeam = nil })
                }
                pauseSwitch
                if let team {
                    sections(team)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, style == .page ? 16 : 12)
            .padding(.bottom, 24)
            .frame(maxWidth: style == .page ? 640 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .background(style == .page ? Theme.groupedBackground : Color.clear)
        .pageTitle(title, isPage: style == .page)
        #if os(iOS)
        .toolbarTitleDisplayMode(style == .page ? .large : .inline)
        #endif
        .task { await store.loadStatus() }
        .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var pauseSwitch: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A switch on the trailing side, as in grouped settings on every platform.
            HStack {
                Text("Hermes can start more helpers")
                    .font(.body)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 8)
                Toggle("Hermes can start more helpers", isOn: Binding(
                    get: { !(store.delegation?.paused ?? false) },
                    set: { store.setPaused(!$0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(cellFill, in: RoundedRectangle(cornerRadius: style == .page ? 14 : 12, style: .continuous))
            .disabled(store.delegation == nil)
            if style == .page {
                Text(pauseFooter)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
        }
        .accessibilityHint(pauseFooter)
    }

    /// The switch is the gateway's, not the chat's.
    private var pauseFooter: String {
        let limit = store.delegation?.maxConcurrentChildren ?? 10
        return String(localized: "Turn off to stop new helpers on \(workspace.bot.name); running ones finish. Up to \(limit) run at once.")
    }

    @ViewBuilder
    private func sections(_ team: HelperTeam) -> some View {
        let top = team.topLevel
        let groups: [(String, [Helper])] = [
            (String(localized: "Running"), top.filter { $0.status == .running }),
            (String(localized: "Waiting"), top.filter { $0.status == .queued }),
            (String(localized: "Finished"), top.filter(\.status.isFinished)),
        ]
        ForEach(groups, id: \.0) { name, helpers in
            if !helpers.isEmpty {
                if style == .page {
                    Text("\(name) · \(helpers.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(helpers) { helper in
                    HelperCard(
                        helper: helper,
                        team: team,
                        store: store,
                        cellFill: cellFill,
                        open: { store.shownHelper = helper.id },
                        steer: { steer(helper, in: team) }
                    )
                }
            }
        }
    }

    /// On a page the helper's detail opens with its own composer; in the inspector the chat's
    /// composer takes the note.
    private func steer(_ helper: Helper, in team: HelperTeam) {
        conversation.helperSteerTarget = HelperSteerTarget(helperID: helper.id, number: team.number(of: helper))
        if style == .page { store.shownHelper = helper.id }
    }
}

/// The inspector's own title row: the toolbar belongs to the chat.
private struct InspectorHeader: View {
    let title: String
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("Back to Team")
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Hide Team")
                .help("Hide Team (⌥⌘T)")
            }
        }
        .padding(.leading, onBack == nil ? 4 : 0)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// The Team inspector (Mac, iPad landscape): the team, or one helper in it.
struct TeamInspector: View {
    let store: HelperStore
    let conversation: ConversationModel
    let workspace: BotWorkspace

    var body: some View {
        Group {
            if let helperID = store.shownHelper, store.helper(helperID) != nil {
                HelperDetailView(store: store, conversation: conversation, workspace: workspace, helperID: helperID, style: .inspector)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let teamID = store.shownTeam {
                TeamView(store: store, conversation: conversation, workspace: workspace, teamID: teamID, style: .inspector)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Theme.snappy, value: store.shownHelper)
    }
}

// MARK: - One helper

/// One helper (`helperDetail`): who it is, four numbers, and its live transcript; Stop and Steer
/// float in a bottom glass bar. On a page Steer opens a composer here (`helperSteer`).
struct HelperDetailView: View {
    enum Style { case page, inspector }

    let store: HelperStore
    let conversation: ConversationModel
    let workspace: BotWorkspace
    let helperID: String
    let style: Style

    @State private var composerFocused = false
    @State private var confirmingStop = false
    @State private var position = ScrollPosition(edge: .top)
    /// Following the newest line, until the person scrolls up.
    @State private var follows = true
    @State private var isDragging = false

    private var helper: Helper? { store.helper(helperID) }
    private var team: HelperTeam? { store.team(containing: helperID) }
    private var cellFill: Color { style == .page ? Theme.groupedCell : Theme.sheetCell }
    private var isSteering: Bool { conversation.helperSteerTarget?.helperID == helperID }

    var body: some View {
        Group {
            if let helper, let team {
                content(helper, team)
            } else {
                StateMessage(symbol: "person.2", title: String(localized: "Helper not found"), message: nil)
            }
        }
        .background(style == .page ? Theme.groupedBackground : Color.clear)
        .onAppear { store.startTail(helperID) }
        .onDisappear {
            store.stopTail(helperID)
            if style == .page, isSteering { conversation.helperSteerTarget = nil }
        }
    }

    private func content(_ helper: Helper, _ team: HelperTeam) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if style == .inspector {
                    InspectorHeader(title: String(localized: "Team"), onBack: { store.shownHelper = nil }, onClose: { store.shownTeam = nil; store.shownHelper = nil })
                }
                header(helper, team)
                metrics(helper)
                transcript(helper)
                notes(helper, team)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: style == .page ? 640 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollPhaseChange { _, phase in isDragging = phase == .interacting || phase == .decelerating }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
        } action: { _, atEnd in
            if isDragging { follows = atEnd }
        }
        .onChange(of: store.tails[helperID]?.text) {
            guard follows else { return }
            withAnimation(.easeOut(duration: 0.24)) { position.scrollTo(edge: .bottom) }
        }
        .safeAreaBar(edge: .bottom) { bottomBar(helper, team) }
        .toolbar { toolbar(helper, team) }
        .pageTitle(String(localized: "Helper \(team.number(of: helper))"), isPage: style == .page)
        #if os(iOS)
        // The header says who it is (`helperDetail`: back and … only).
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        #endif
        .confirmationDialog("Stop helper \(team.number(of: helper))?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Helper", role: .destructive) { store.stop(helper) }
        } message: {
            Text("It has written files. What it wrote so far stays.")
        }
        .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Header

    private func header(_ helper: Helper, _ team: HelperTeam) -> some View {
        let number = team.number(of: helper)
        let count = helper.parentID.map { team.children(of: $0).count } ?? team.total
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HelperBadge(number: number, isRunning: helper.status == .running, size: 26)
                Text("Helper \(number) of \(count)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                HelperStatusTag(helper: helper, team: team)
            }
            Text(helper.goal)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, style == .page ? 4 : 0)
    }

    /// Model, tools, tokens and files read (`metricTile`). Hermes reports tokens and files when a
    /// helper finishes; until then they read "—".
    private func metrics(_ helper: Helper) -> some View {
        HStack(spacing: 8) {
            MetricTile(value: HelperFormat.shortModel(helper.model) ?? "—", label: String(localized: "model"), fill: cellFill)
            MetricTile(value: "\(helper.toolCount)", label: helper.toolCount == 1 ? String(localized: "tool") : String(localized: "tools"), fill: cellFill)
            MetricTile(value: helper.totalTokens.map(HelperFormat.tokens) ?? "—", label: String(localized: "tokens"), fill: cellFill)
            MetricTile(
                value: helper.status.isFinished ? "\(helper.filesRead.count)" : "—",
                label: String(localized: "files read"),
                fill: cellFill
            )
        }
    }

    // MARK: Transcript

    private func transcript(_ helper: Helper) -> some View {
        let tail = store.tails[helperID]
        var lines = tail.map { HelperTranscript.parse($0.text, truncated: $0.truncated) } ?? []
        // Hermes lets the transcript go when a helper ends: the last poll may miss how it ended.
        if !lines.isEmpty, helper.status.isFinished {
            if let summary = helper.cleanSummary {
                if !lines.contains(.text(summary)) { lines.append(.text(summary)) }
            } else if helper.status.isFailure || helper.status == .interrupted {
                lines.append(.result(name: "", text: HelperFormat.failureLine(helper), isError: helper.status.isFailure))
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(helper.status.isLive ? "What it's doing" : "What it did")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if helper.status == .running, tail?.available == true {
                    LiveTag()
                }
            }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        TranscriptLine(line: line, isFirst: index == 0)
                    }
                }
                .textSelection(.enabled)
            } else {
                fallback(helper)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cellFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// No live transcript (it hasn't started, or it finished and Hermes let it go): what the events said.
    @ViewBuilder
    private func fallback(_ helper: Helper) -> some View {
        let tools = helper.status.isFinished && !helper.outputTail.isEmpty ? helper.outputTail : helper.recentTools
        VStack(alignment: .leading, spacing: 3) {
            if helper.status == .queued {
                Text("It starts when a slot is free.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(Array(tools.enumerated()), id: \.offset) { _, line in
                TranscriptLine(line: .tool(name: line.tool, arguments: line.preview), isError: line.isError, isFirst: false)
            }
            if let summary = helper.cleanSummary {
                TranscriptLine(line: .text(summary), isFirst: tools.isEmpty)
            } else if helper.status.isFailure {
                TranscriptLine(line: .result(name: "", text: HelperFormat.failureLine(helper), isError: true), isFirst: tools.isEmpty)
            } else if helper.status == .running, tools.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Notes sent to it, as a steer shows in the chat: waiting, read, or missed.
    @ViewBuilder
    private func notes(_ helper: Helper, _ team: HelperTeam) -> some View {
        let number = team.number(of: helper)
        ForEach(store.notes[helperID] ?? []) { note in
            switch note.state {
            case .missed:
                HelperMissedNoteCard(note: note, number: number, store: store, helperID: helperID)
            case .waiting:
                FollowUpBubble(
                    text: note.text,
                    caption: FollowUpBubbleCaption(symbol: FollowUpMode.steer.symbol, text: String(localized: "To helper \(number) · waiting for its next step"), spins: true),
                    isPending: true
                )
            case .read:
                FollowUpBubble(
                    text: note.text,
                    caption: FollowUpBubbleCaption(symbol: FollowUpMode.steer.symbol, text: String(localized: "To helper \(number) · read"))
                )
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func bottomBar(_ helper: Helper, _ team: HelperTeam) -> some View {
        if style == .page, isSteering {
            ComposerView(conversation: conversation, workspace: workspace, focused: $composerFocused, onVoiceMode: nil)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .onAppear { composerFocused = true }
                .transition(ComposerView.rowAppears)
        } else if helper.status.isLive || (helper.status.isFailure && helper.parentID == nil) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    switch helper.status {
                    case .running:
                        stopButton(helper, title: String(localized: "Stop"))
                        if helper.acceptingSteer {
                            prominentButton(String(localized: "Steer"), symbol: "arrow.turn.up.right") {
                                conversation.helperSteerTarget = HelperSteerTarget(helperID: helper.id, number: team.number(of: helper))
                            }
                        }
                    case .queued:
                        stopButton(helper, title: String(localized: "Cancel"))
                    default:
                        prominentButton(String(localized: "Ask Hermes to Retry"), symbol: "arrow.clockwise") {
                            store.askToRetry(helper, in: team)
                        }
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func stopButton(_ helper: Helper, title: String) -> some View {
        Button(role: .destructive) {
            if helper.hasWritten { confirmingStop = true } else { store.stop(helper) }
        } label: {
            Label(title, systemImage: helper.status == .queued ? "xmark" : "stop.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }

    private func prominentButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.inkForeground)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.ink)
        .controlSize(.large)
    }

    @ToolbarContentBuilder
    private func toolbar(_ helper: Helper, _ team: HelperTeam) -> some ToolbarContent {
        if style == .page {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let text = store.tails[helperID]?.text, !text.isEmpty {
                        Button("Copy Transcript", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                    }
                    Button("Copy Goal", systemImage: "text.quote") { Pasteboard.copy(helper.goal) }
                    if store.shownTeam != team.id {
                        Button("Open Team", systemImage: "person.2") { store.pushedHelper = nil; store.shownTeam = team.id }
                    }
                    if helper.status.isLive {
                        Divider()
                        Button(helper.status == .queued ? "Cancel Helper" : "Stop Helper", systemImage: "stop", role: .destructive) {
                            if helper.hasWritten { confirmingStop = true } else { store.stop(helper) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }
}

/// "● Running · 1:42" by the helper's number.
private struct HelperStatusTag: View {
    let helper: Helper
    let team: HelperTeam

    private var color: Color {
        switch helper.status {
        case .running: Theme.warning
        case .completed: Theme.success
        case .queued, .interrupted: Theme.tertiaryText
        default: Theme.danger
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text(now: context.date))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private func text(now: Date) -> String {
        switch helper.status {
        case .queued: String(localized: "Waiting")
        case .running: HelperFormat.elapsed(helper, now: now).map { String(localized: "Running · \(HelperFormat.clock($0))") } ?? String(localized: "Running")
        case .completed: HelperFormat.elapsed(helper, now: now).map { String(localized: "Done · \(HelperFormat.clock($0))") } ?? String(localized: "Done")
        case .interrupted: String(localized: "Stopped")
        case .timeout: String(localized: "Timed out")
        default: String(localized: "Failed")
        }
    }
}

/// A number and what it counts (`metricTile`).
private struct MetricTile: View {
    let value: String
    let label: String
    let fill: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "● Live" while the transcript streams.
private struct LiveTag: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.danger).frame(width: 7, height: 7)
            Text("Live")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("Live")
    }
}

/// One transcript line in mono (`helperTranscript`): what it said, ▸ a tool, the result indented.
private struct TranscriptLine: View {
    let line: HelperTranscript.Line
    var isError = false
    let isFirst: Bool

    private static let font = Font.system(.footnote, design: .monospaced)

    var body: some View {
        switch line {
        case .text(let text):
            Text(text)
                .font(Self.font)
                .foregroundStyle(Theme.primaryText)
                .padding(.top, isFirst ? 0 : 8)
                .padding(.bottom, 4)
        case .thinking(let text):
            Text(text)
                .font(Self.font)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(3)
        case .tool(let name, let arguments):
            Text("\(Text("▸").foregroundStyle(Theme.tertiaryText)) \(Text(name).foregroundStyle(isError ? Theme.danger : Theme.primaryText)) \(Text(arguments).foregroundStyle(isError ? Theme.danger : Theme.primaryText))")
                .font(Self.font)
                .lineLimit(3)
        case .result(_, let text, let isError):
            if !text.isEmpty, text != "done" {
                Text(text)
                    .font(Self.font)
                    .foregroundStyle(isError ? Theme.danger : Theme.secondaryText)
                    .lineLimit(4)
                    .padding(.leading, 14)
            }
        }
    }
}
