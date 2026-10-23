import HermesKit
import SwiftUI

/// Hermes' reply, top to bottom (`docs/chat.md` §1): the turn header, the plan, the steps
/// with their attachments, the answer, its sources, the actions, then quiet notes.
struct AssistantTurnView: View, Equatable {
    let turn: AssistantTurn
    /// Steers sent into this turn that Hermes hasn't read yet (dashed until it does).
    var pendingSteers: [FollowUpRecord] = []
    var status: String?
    /// `status` says the message waits for the gateway ("Waiting for MacBook Pro…"): a wait, so
    /// its words hold still.
    var statusWaits = false
    /// Hermes waits on a question or other request on its card (`docs/chat.md` §4a): the header
    /// says so, still and orange, rather than shimmering the tool asking it.
    var waitsForAnswer = false
    var isStopping = false
    var onBranch: BranchAction?
    /// Helper teams no call in the transcript claims: the latest reply shows them.
    var extraTeamIDs: [String] = []
    /// The chat the turn's notes act on: whose memory they open, which board Open Board shows.
    var memoryContext: MemoryNoteContext?
    /// The row's identity in the transcript, what a turn without calls keeps its fold by.
    var rowKey: String?
    /// It answers a voice message: it opens with the Bot's voice (`docs/voice.md` §2). The
    /// latest such reply may play by itself.
    var answersVoice: SpokenReply = .none

    enum SpokenReply: Equatable {
        case none, earlier, latest
    }

    /// A reply compares by what it's drawn from, so one that's done is skipped while another
    /// streams in (`.equatable()` in the transcript). SwiftUI's own comparison of these fields
    /// never held: every reply in the chat redrew, actions and menus included, for each word.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.status == rhs.status && lhs.statusWaits == rhs.statusWaits && lhs.isStopping == rhs.isStopping
            && lhs.waitsForAnswer == rhs.waitsForAnswer
            && lhs.rowKey == rhs.rowKey && lhs.pendingSteers == rhs.pendingSteers
            && lhs.extraTeamIDs == rhs.extraTeamIDs && lhs.onBranch == rhs.onBranch
            && lhs.memoryContext == rhs.memoryContext && lhs.answersVoice == rhs.answersVoice
    }

    @Environment(\.helperStore) private var helperStore
    @Environment(\.quoteActions) private var quoteActions
    @Environment(\.checkpoints) private var checkpoints
    /// Artifacts and pages open in the chat's Inspector (`docs/inspector.md`).
    @Environment(\.inspectorModel) private var inspector
    @AppStorage(PreferenceKey.showUsage) private var alwaysShowsUsage = false
    @AppStorage(PreferenceKey.expandAgentActivity) private var expandWhileWorking = false
    @State private var showsUsage = false
    /// Outside a chat (no `disclosures`): the person opened or closed the steps here.
    @State private var localExpanded: Bool? = Disclosure.debugOpens("turns") ? true : nil
    @Environment(\.disclosures) private var disclosures
    /// Who reads this chat's replies aloud, and in which voice (`docs/voice.md` §3).
    @Environment(\.listenContext) private var listenContext
    @Environment(\.widgetHost) private var widgetHost
    @Namespace private var steerSpace

    /// What the turn's fold is remembered by: its first call's id (`AssistantTurn.foldKey`), else
    /// the row's identity in the transcript.
    private var foldKey: String { turn.foldKey ?? rowKey ?? turn.id }

    /// The person opened or closed the steps; `nil` follows the preference.
    private var userExpanded: Bool? {
        disclosures?.turn(foldKey) ?? localExpanded
    }

    private var isExpanded: Bool {
        userExpanded ?? (turn.isWorking && expandWhileWorking)
    }

    private func setExpanded(_ isOpen: Bool) {
        if let disclosures {
            disclosures.setTurn(foldKey, open: isOpen)
        } else {
            localExpanded = isOpen
        }
    }

    /// What the reply reads as right now (`AssistantTurn.reading`): what Hermes said between steps
    /// stays in this place, muted, while it works with the steps folded; the reply once it's there.
    private var shownText: (text: String, isInterim: Bool)? {
        turn.reading(stepsOpen: isExpanded)
    }

    private var showsWork: Bool {
        !turn.steps.isEmpty || !turn.plan.isEmpty || (turn.isWorking && turn.answer.isEmpty)
    }

    /// What the memory tool did during the turn (`memoryNote`).
    private var memoryChanges: [MemoryChange] { turn.memoryChanges }

    /// Pages the turn found, cited under the reply.
    private var sources: [SearchResult] {
        turn.steps.flatMap { step -> [SearchResult] in
            if case .tool(let tool) = step { return tool.searchResults }
            return []
        }
    }

    /// The turn handed work to helpers (`delegate_task`), or shows a team nothing else claims.
    /// Only then does it read the helpers, so a busy team redraws just its own turn.
    private var delegates: Bool {
        !extraTeamIDs.isEmpty || turn.steps.contains { step in
            if case .tool(let tool) = step { return tool.name == "delegate_task" }
            return false
        }
    }

    var body: some View {
        let teams = delegates ? helperStore.map { TurnTeams.slots(for: turn, extra: extraTeamIDs, store: $0) } ?? [] : []
        VStack(alignment: .leading, spacing: 12) {
            // Hermes warns as the agent starts (a compression setting, a refusal): above the work.
            if let warning = turn.warning {
                TurnWarnings(text: warning)
                    // Its own animation: one on the whole turn animated whatever else changed with it.
                    .transition(.opacity.combined(with: .offset(y: -6)).animation(.smooth(duration: 0.32)))
            }
            if showsWork {
                WorkSummaryView(turn: turn, status: status, statusWaits: statusWaits, waitsForAnswer: waitsForAnswer, isStopping: isStopping, helpers: HelperHeadline(teams), isExpanded: isExpanded) {
                    setExpanded(!isExpanded)
                    if turn.usage != nil { withAnimation(Theme.spring) { showsUsage.toggle() } }
                }
                .equatable()
            }
            if let models = turn.models {
                ModelsCard(progress: models, isWorking: turn.isWorking)
            }
            // The team where the delegation happened, after what Hermes said before it.
            if let helperStore, !teams.isEmpty {
                TurnTeams(slots: teams, turnIsWorking: turn.isWorking, store: helperStore)
            }
            // Steers Hermes read come before what it went on to say. With the steps folded, the
            // risk notes from after each steer show after it, where the page was read.
            let afterSteers = showsWork && !isExpanded && !turn.isWorking ? Array(turn.foldedAttachmentGroups.dropFirst()) : []
            ForEach(Array(steerBubbles.filter { !$0.isPending }.enumerated()), id: \.element.id) { index, bubble in
                steerBubble(bubble)
                if afterSteers.indices.contains(index) {
                    ForEach(afterSteers[index]) { tool in
                        ToolAttachments(tool: tool)
                    }
                }
            }
            // Audio the Bot sent plays before its words (`listenStrip`, `docs/voice.md` §2).
            ForEach(turn.audio) { audio in
                ListenStrip(audio: audio)
            }
            // A reply to a voice message opens with the Bot's voice reading it (replies in kind).
            if answersVoice != .none, !turn.isWorking, !turn.answer.isEmpty, let reading = listenReading {
                ReplyListenStrip(reading: reading, isLatest: answersVoice == .latest,
                                 isFresh: turn.finishedAt.map { Date.now.timeIntervalSince($0) < 60 } ?? false)
            }
            if let shown = shownText {
                // Widgets draw where their directives are (`docs/widgets.md` §2); the sentence Listen
                // is reading is lit up (`docs/voice.md` §3).
                ReplyBody(text: turn.isWorking ? StreamingMarkdown.displayed(shown.text) : replyText(shown.text), streaming: turn.isWorking, caches: !turn.isWorking,
                          highlight: turn.isWorking ? nil : ListenPlayer.shared.highlight(for: turn.id))
                    .equatable()
                    // Only the tone eases; the words switch at once, never drawn over each other.
                    .animation(.smooth(duration: 0.3)) { $0.opacity(shown.isInterim ? 0.55 : 1) }
                    .contextMenu { replyMenu }
                    // Code and tables scroll sideways themselves: those replies take Reply from the menu.
                    .modifier(SwipeToReply(isEnabled: canQuote && !Self.scrollsSideways(turn.answer)) {
                        quoteActions.reply(.assistant(turn), quoteActions.assistantName, turn.copyableText)
                    })
                    // A reply that arrives whole (Bots answer that way) fades in under the
                    // message instead of appearing in a frame. Only within a turn already shown:
                    // rows that come in carry their own transition.
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }
            // One still waiting sits at the end, where it was sent; read, it glides into place.
            ForEach(steerBubbles.filter(\.isPending)) { bubble in
                steerBubble(bubble)
            }
            // What the reply made or opened, as cards that open in the Inspector (`artifactCard`).
            if let inspector, !turn.isWorking {
                TurnInspectorCards(turn: turn, inspector: inspector)
            }
            if !turn.isWorking, !turn.answer.isEmpty, !sources.isEmpty {
                SourcesRow(results: sources)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.32), value: steerBubbles)
    }

    private func steerBubble(_ bubble: SteerBubbleItem) -> some View {
        FollowUpBubble(text: bubble.text, caption: bubble.caption, isPending: bubble.isPending)
            .matchedGeometryEffect(id: bubble.id, in: steerSpace)
            // One leaves only to show after the transcript (carried over, missed): no fade over the reply.
            .transition(.asymmetric(insertion: .offset(y: 14).combined(with: .opacity), removal: .identity))
    }

    struct SteerBubbleItem: Identifiable, Equatable {
        let id: String
        let text: String
        let caption: FollowUpBubbleCaption
        let isPending: Bool
    }

    /// Steers Hermes read (with the step they came after), then those still waiting.
    private var steerBubbles: [SteerBubbleItem] {
        let read = turn.steers.enumerated().map { index, note in
            SteerBubbleItem(id: "steer-\(index)", text: note.text, caption: .steerRead(after: turn.stepTitle(before: note.afterStep)), isPending: false)
        }
        let waiting = pendingSteers.enumerated().compactMap { index, record in
            record.caption.map { SteerBubbleItem(id: "steer-\(read.count + index)", text: record.text, caption: $0, isPending: true) }
        }
        return read + waiting
    }

    /// A finished reply without its artifacts' code: each shows as a card instead.
    /// This reply, to read aloud (Listen): the text the chat draws, so the sentence being read
    /// lights up in it, and each widget as its words (a scheduled report as a brief, `docs/voice.md` §3).
    private var listenReading: ListenPlayer.Reading? {
        guard let listenContext, !turn.answer.isEmpty else { return nil }
        let store = widgetHost?.store
        let words = SpokenWidgets.words(of: replyText(turn.answer), inlineWidgets: WidgetSettings.rendersInlineBlocks) { store?.payload($0) }
        return words.text.isEmpty ? nil : ListenPlayer.Reading(id: turn.id, text: words.text, context: listenContext, isPrivate: words.isPrivate)
    }

    private func replyText(_ text: String) -> String {
        guard inspector != nil else { return text }
        return ArtifactDetector.liftingArtifacts(from: text).text
    }

    /// The files this reply's tools wrote, when it wrote any.
    private var fileEdits: TurnFileEdits? {
        let edits = TurnFileEdits(turn: turn)
        return edits.isEmpty ? nil : edits
    }

    /// A finished reply can be quoted (`docs/inbox.md` §4).
    private var canQuote: Bool {
        quoteActions.isEnabled && !turn.isWorking && !turn.copyableText.isEmpty
    }

    /// Code blocks and tables scroll sideways: a swipe there is theirs.
    static func scrollsSideways(_ text: String) -> Bool {
        text.containsBytes("```") || text.containsBytes("\n|")
    }

    /// `Overlays.replyMenu`.
    @ViewBuilder
    private var replyMenu: some View {
        if canQuote {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                quoteActions.reply(.assistant(turn), quoteActions.assistantName, turn.copyableText)
            }
            Button("Reply to Words…", systemImage: "text.quote") {
                quoteActions.choose(.assistant(turn), quoteActions.assistantName, turn.copyableText)
            }
            Divider()
        }
        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(turn.copyableText) }
        #if os(iOS)
        if quoteActions.isEnabled, !turn.isWorking, !turn.copyableText.isEmpty {
            Button("Select Text", systemImage: "selection.pin.in.out") {
                quoteActions.select(quoteActions.assistantName, turn.copyableText)
            }
        }
        #endif
        if let reading = listenReading {
            if ListenPlayer.shared.isReading(turn.id) {
                Button("Stop Listening", systemImage: "stop.circle") { ListenPlayer.shared.stop() }
            } else {
                Button("Listen", systemImage: "speaker.wave.2") { ListenPlayer.shared.play(reading) }
            }
        }
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
        if let checkpoints, fileEdits != nil {
            Divider()
            // Off: the off sheet, which offers Turn On.
            Button("Undo File Changes…", systemImage: "arrow.uturn.backward") { checkpoints.undo(turnID: turn.id) }
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
                MessageActions(text: turn.copyableText, listen: listenReading, onBranch: onBranch) { replyMenu }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Theme.Typography.caption.weight(.medium))
                .foregroundStyle(Theme.warning)
        case .complete:
            if !turn.copyableText.isEmpty {
                MessageActions(text: turn.copyableText, listen: listenReading, onBranch: onBranch) { replyMenu }
            }
            if let usage = turn.usage, alwaysShowsUsage || showsUsage {
                UsageFooter(usage: usage)
                    .transition(.opacity)
            }
        case .streaming, .waitingForApproval:
            EmptyView()
        }
        // Skills Hermes wrote in this turn (`docs/learned.md` §6), before what it remembered.
        if !turn.isWorking, case let learned = turn.createdSkills, !learned.isEmpty {
            LearnedSkillNotes(names: learned, context: memoryContext)
        }
        if !turn.isWorking, !memoryChanges.isEmpty {
            MemoryNotes(changes: memoryChanges, context: memoryContext)
        }
        // What Hermes's background self-review of this reply did (`review.summary`): quietly here,
        // never a row of its own between the turn and the next (`docs/chat.md` §1, 13).
        if !turn.isWorking, let review = turn.review {
            TurnNote(symbol: "checkmark.seal", text: String(localized: "Reviewed this reply · \(review)"))
        }
        // Cards Hermes put on a board (`kanban_create`, `docs/board.md` §4).
        if !turn.isWorking, let memoryContext, case let cards = turn.addedCards, !cards.isEmpty {
            CardsAddedNote(cards: cards, context: memoryContext)
        }
        if let onBranch, onBranch.isLatest, !turn.isWorking, let percent = turn.usage?.contextPercent, percent >= 80 {
            ContextNotice(percent: percent) { onBranch.conversation.runCommand("compress", argument: nil) }
        }
    }
}

// MARK: - Actions

private struct MessageActions<More: View>: View {
    let text: String
    /// The reply to read aloud; `nil` while it's written or has no words.
    var listen: ListenPlayer.Reading?
    var onBranch: BranchAction?
    /// The rest of the reply menu (Try Again, Branch from Here, Show Usage…).
    @ViewBuilder var more: () -> More

    @State private var copied = false

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

            if let listen {
                // Listen (`docs/voice.md` §3): the reply in the Bot's own voice.
                let isListening = ListenPlayer.shared.isReading(listen.id)
                Button {
                    ListenPlayer.shared.toggle(listen)
                } label: {
                    Image(systemName: isListening ? "stop.circle" : "speaker.wave.2")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help(isListening ? "Stop listening" : "Listen")
                .accessibilityLabel(isListening ? "Stop listening" : "Listen")
            }

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
struct WorkSummaryView: View, Equatable {
    let turn: AssistantTurn
    var status: String?
    var statusWaits = false
    var waitsForAnswer = false
    var isStopping = false
    /// The turn's helpers: they keep it working after its reply (background delegation).
    var helpers: HelperHeadline?
    /// Whether the steps show; the reply owns it, as what it shows below depends on it.
    let isExpanded: Bool
    /// The header was tapped: open or close the steps.
    var onToggle: () -> Void = {}

    /// The header shows whether the answer has begun, never its words: while they stream in it
    /// holds still (`.equatable()` in the reply). What `onToggle` acts on is compared here too.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.status == rhs.status, lhs.statusWaits == rhs.statusWaits, lhs.waitsForAnswer == rhs.waitsForAnswer,
              lhs.isStopping == rhs.isStopping, lhs.helpers == rhs.helpers,
              lhs.isExpanded == rhs.isExpanded, lhs.turn.answer.isEmpty == rhs.turn.answer.isEmpty else { return false }
        var left = lhs.turn, right = rhs.turn
        left.answer = ""
        right.answer = ""
        return left == right
    }
    /// The title on screen: each status stays at least `titleHold`, so the words change at most 4
    /// times a second (`docs/chat.md` §4a).
    @State private var shownTitle: String?
    @State private var titleShownAt = Date.distantPast
    @State private var pendingTitle: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.disclosureWillToggle) private var willToggle

    private static let titleHold: TimeInterval = 0.25

    private var isWaiting: Bool { turn.state == .waitingForApproval || (waitsForAnswer && turn.isWorking && !isStopping) }

    private var helpersWorking: Bool { helpers?.isWorking == true }

    private var title: String {
        if turn.state == .waitingForApproval { return String(localized: "Waiting for your approval") }
        if isWaiting { return String(localized: "Waiting for your answer") }
        if turn.isWorking, !turn.answer.isEmpty, !isStopping, status == nil { return streamingTitle }
        return turn.isWorking || helpersWorking ? workingTitle : doneTitle
    }

    /// The header's one live line moves until the reply's words arrive; then they are the sign,
    /// and it holds still (`docs/chat.md` §4a).
    private var shimmers: Bool {
        guard !isWaiting, !(statusWaits && status != nil) else { return false }
        if turn.isWorking { return turn.answer.isEmpty || status != nil || isStopping }
        return helpersWorking
    }

    /// Thinking for more than 10 s says for how long: "Thinking… · 12s".
    private var countsThinking: Bool {
        turn.isWorking && turn.answer.isEmpty && status == nil && !isStopping && !isWaiting && !helpersWorking
            && shownTitle == String(localized: "Thinking…")
    }

    static func thinking(_ title: String, since started: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 10 else { return title }
        return "\(title) · \(Formatting.duration(elapsed))"
    }

    private func show(_ new: String) {
        pendingTitle?.cancel()
        let wait = Self.titleHold - Date.now.timeIntervalSince(titleShownAt)
        // The first title, the end of the turn and an approval show at once.
        guard shownTitle != nil, wait > 0, turn.isWorking, !isWaiting else {
            shownTitle = new
            titleShownAt = .now
            return
        }
        pendingTitle = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            shownTitle = title
            titleShownAt = .now
        }
    }

    private var hasSteps: Bool { !turn.steps.isEmpty || !turn.plan.isEmpty }

    /// The `terminal` and `message_agent` calls that started background processes.
    private var processSteps: [(tool: ToolActivity, id: String)] {
        turn.steps.compactMap { step in
            guard case .tool(let tool) = step, let id = tool.startedProcessID else { return nil }
            return (tool, id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // What the turn did to files: one row, the diffs a tap away (`turnChanges`).
            TurnChangesRow(turn: turn)
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    if !turn.plan.isEmpty {
                        PlanCard(plan: turn.plan)
                    }
                    if !turn.steps.isEmpty {
                        StepTimeline(steps: turn.steps, steers: turn.steers)
                    }
                }
                .transition(Disclosure.transition(reduceMotion: reduceMotion))
            } else if !turn.isWorking {
                // Only steps with something to keep in view: an empty one would still take the
                // stack's spacing, and a turn of a hundred tool calls left a screen of blank space.
                // Risk notes from after a steer show after it, in the reply (`foldedAttachmentGroups`).
                ForEach(turn.foldedAttachmentGroups[0]) { tool in
                    ToolAttachments(tool: tool)
                }
                // The processes it started stay on their rail, folded or not (`processStep`).
                let started = processSteps
                if !started.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        // The rail runs down every step, the last one's too (`processStep`).
                        ForEach(started, id: \.tool.id) { step in
                            ProcessStepLine(tool: step.tool, processID: step.id, isLast: false)
                        }
                    }
                }
            }
        }
        // Only the person's tap animates the fold. A new step fades in on its own (`StepTimeline`)
        // and the plan animates inside its card: animated here, every change that came with them
        // (a reply's text growing, a reload) animated too, and heights moved while it streamed.
        .animation(Disclosure.animation(reduceMotion: reduceMotion), value: isExpanded)
    }

    /// Steps or usage to show: a tap opens them.
    private var opens: Bool { hasSteps || turn.usage != nil }

    private var header: some View {
        Button {
            guard opens else { return }
            willToggle()
            onToggle()
        } label: {
            HStack(spacing: 6) {
                TurnGlyph(isWaiting: isWaiting)
                let shown = shownTitle ?? title
                let started = turn.startedAt
                let counts = countsThinking && started != nil
                // One title throughout, so its words cross-fade; it ticks each second only while
                // "Thinking…" counts.
                TimelineView(.periodic(from: started ?? .now, by: counts ? 1 : 86_400)) { context in
                    TickerTitle(
                        id: shown, text: counts ? Self.thinking(shown, since: started ?? context.date, now: context.date) : shown,
                        shimmers: shimmers, tint: isWaiting ? Theme.warning : Theme.tertiaryText
                    )
                }
                if hasSteps, !isWaiting {
                    DisclosureChevron(isOpen: isExpanded)
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .animation(.smooth(duration: 0.32), value: turn.isWorking)
            .animation(.smooth(duration: 0.32), value: isWaiting)
            .animation(.smooth(duration: 0.25), value: hasSteps)
            .onChange(of: title, initial: true) { _, new in show(new) }
        }
        .buttonStyle(.plain)
        // Not `.disabled`: that dims the live line ("Thinking…" before any step) below its colour.
        .accessibilityRemoveTraits(opens ? [] : .isButton)
        .accessibilityLabel(title)
        .accessibilityHint(!hasSteps ? "" : (isExpanded ? "Hides the steps" : "Shows the steps"))
    }

    private var workingTitle: String {
        if isStopping { return String(localized: "Stopping…") }
        if turn.state == .waitingForApproval { return String(localized: "Waiting for your approval") }
        if let status { return status }
        if let helpers, helpers.isWorking {
            return helpers.count == 1 ? String(localized: "Working with 1 helper…") : String(localized: "Working with \(helpers.count) helpers…")
        }
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
        return String(localized: "Thinking…")
    }

    /// While the reply streams: still words, what it took so far ("Working · 3 tools").
    private var streamingTitle: String {
        if let helpers, helpers.count > 0 {
            return helpers.count == 1 ? String(localized: "Working · 1 helper") : String(localized: "Working · \(helpers.count) helpers")
        }
        switch turn.toolCount {
        case 0: return String(localized: "Working")
        case 1: return String(localized: "Working · 1 tool")
        case let count: return String(localized: "Working · \(count) tools")
        }
    }

    private var doneTitle: String {
        let duration = turn.finishedAt.flatMap { end in turn.startedAt.map { end.timeIntervalSince($0) } }
        let tools = turn.toolCount
        let time = duration.map { Formatting.duration($0) }
        if let helpers, helpers.count > 0 {
            let team = helpers.count == 1 ? String(localized: "1 helper") : String(localized: "\(helpers.count) helpers")
            return time.map { String(localized: "Worked for \($0) · \(team)") } ?? String(localized: "Worked with \(team)")
        }
        // Tools and no reply: what it did, never a bare count that reads as a reply gone missing.
        if let line = WorkLine.text(for: turn) { return line }
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

/// The header's leading mark: a still sparkle, or a raised hand while waiting for you. Nothing
/// spins: the words are the turn's one live line (`docs/chat.md` §4a).
private struct TurnGlyph: View {
    let isWaiting: Bool

    var body: some View {
        ZStack {
            if isWaiting {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: 14, height: 14)
        .animation(.smooth(duration: 0.32), value: isWaiting)
        .accessibilityHidden(true)
    }
}

/// The header's words, cross-fading to the next (`docs/chat.md` §4a). They shimmer while the
/// turn works and nothing streams yet. `id` is the words without what counts up, so "Thinking… ·
/// 12s" ticking to 13s changes in place rather than fading.
private struct TickerTitle: View {
    let id: String
    let text: String
    let shimmers: Bool
    let tint: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if shimmers {
                    ShimmerText(text: text)
                } else {
                    // Still words may take a second line: a finished turn's line says what it did.
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id(id)
            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }
        .animation(.easeInOut(duration: 0.2), value: id)
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
    /// The chat's folds (`DisclosureState`); nil outside a chat, where a row keeps its own.
    @Entry var disclosures: DisclosureState? = nil
}

/// Which folds in a chat are open (turns, steps, change cards), kept by the chat rather than by
/// each row's view. A row's view goes and comes back when the reply hands over to its stored rows,
/// a reload rebuilds them or the page window moves: a fold kept there closed itself, or another
/// row's opened. Keyed by Hermes's call ids, the same live, stored and cached. Only a tap changes it.
@MainActor @Observable
final class DisclosureState {
    /// One observed box per fold, so a tap redraws the row it belongs to and nothing else: with
    /// one dictionary for every fold, opening one redrew every reply in the chat, inside the
    /// tap's animation.
    @ObservationIgnored private var folds: [String: Fold] = [:]

    @MainActor @Observable
    final class Fold {
        /// The person's choice for a turn, if they made one.
        var turn: Bool?
        /// A step, run or change card the person opened.
        var isOpen = false
    }

    private func fold(_ key: String) -> Fold {
        if let fold = folds[key] { return fold }
        let fold = Fold()
        folds[key] = fold
        return fold
    }

    /// The person's choice for a turn, if they made one.
    func turn(_ key: String) -> Bool? { fold(key).turn }

    func setTurn(_ key: String, open isOpen: Bool) { fold(key).turn = isOpen }

    func isOpen(_ key: String) -> Bool { fold(key).isOpen }

    func toggle(_ key: String) { fold(key).isOpen.toggle() }
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
    /// Where Hermes read the person's steers (`steerStep`).
    var steers: [SteerNote] = []

    enum Entry: Identifiable {
        case step(AssistantStep)
        /// A call that started a background process: its step shows the process.
        case process(ToolActivity, id: String)
        case run([ToolActivity])
        case subagents([SubagentActivity])
        case steer(SteerNote, index: Int)

        var id: String {
            switch self {
            case .step(let step): step.id
            case .process(let tool, _): tool.id
            case .run(let tools): "run-" + (tools.first?.id ?? "")
            case .subagents(let agents): "agents-" + (agents.first?.id ?? "")
            case .steer(_, let index): "steer-\(index)"
            }
        }
    }

    /// The steps with each steer where it was read; runs don't fold across a steer.
    static func entries(_ steps: [AssistantStep], steers: [SteerNote]) -> [Entry] {
        guard !steers.isEmpty else { return entries(steps) }
        var result: [Entry] = []
        var start = 0
        for (index, steer) in steers.enumerated() {
            let end = min(max(steer.afterStep, start), steps.count)
            result += entries(Array(steps[start..<end]))
            result.append(.steer(steer, index: index))
            start = end
        }
        result += entries(Array(steps[start...]))
        return result
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
            case .tool(let tool) where tool.startedProcessID != nil:
                flush()
                entries.append(.process(tool, id: tool.startedProcessID ?? ""))
            case .tool(let tool) where tool.name == "browser_vault":
                // Signing in, a code, a card: each says what happened, never folded into a run
                // (`docs/web.md` §4).
                flush()
                entries.append(.step(step))
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
        let entries = Self.entries(steps, steers: steers)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isLast = index == entries.count - 1
                Group {
                switch entry {
                case .step(.tool(let tool)):
                    ToolStepLine(tool: tool, isLast: isLast)
                case .process(let tool, let id):
                    ProcessStepLine(tool: tool, processID: id, isLast: isLast)
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
                case .steer(let note, _):
                    SteerStepLine(text: note.text, isLast: isLast)
                }
                }
                // A step that starts fades in by itself; the rows around it don't animate with it.
                .transition(.opacity.animation(.smooth(duration: 0.25)))
            }
        }
    }
}

/// Where Hermes picked up a steer (`steerStep`): an ink node, "Read your note" and the note.
private struct SteerStepLine: View {
    let text: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rail(isLast: isLast) {
                Image(systemName: FollowUpMode.steer.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkForeground)
                    .frame(width: 26, height: 26)
                    .background(Theme.ink, in: Circle())
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Read your note")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                Text("“\(text)”")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(3)
            }
            .padding(.top, 3)
            .padding(.bottom, isLast ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

extension AssistantTurn {
    /// The step before position `index`, as its row names it: what a steer was read after.
    func stepTitle(before index: Int) -> String? {
        guard index > 0, index <= steps.count else { return nil }
        for step in steps[..<index].reversed() {
            switch step {
            case .tool(let tool):
                if tool.status == .failed, tool.name == "terminal" { return String(localized: "Command failed") }
                return ToolDescriptor.describe(tool.name).doneTitle
            case .subagent:
                return String(localized: "Worked with subagents")
            case .reasoning:
                return String(localized: "Thought")
            case .narration:
                continue
            }
        }
        return nil
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
            // A running step shows its tool's glyph too: nothing spins, the turn header is the
            // turn's one live line (`docs/chat.md` §4a).
            Image(systemName: status == .failed ? "xmark" : symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(status == .failed ? Theme.danger : Theme.secondaryText)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One step on the rail: its node, a title line (with the time, counting up while it runs, and a
/// chevron) and a one-line preview. Tapping opens what's behind it; `accessory` (a risk note, a failure line) stays in
/// view either way.
private struct StepLine<Accessory: View, Details: View>: View {
    let symbol: String
    var status: ToolActivity.Status = .succeeded
    let title: String
    var preview: String?
    var monospacedPreview = false
    var trailing: String?
    var trailingIsAlert = false
    /// When the running step began: its time counts up in place of `trailing`.
    var runningSince: Date?
    let isLast: Bool
    var compact = false
    let hasDetails: Bool
    /// What the chat remembers this row open by (`DisclosureState`); nil keeps it here.
    var disclosureKey: String?
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let details: () -> Details

    @State private var localOpen = Disclosure.debugOpens("all")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.disclosureWillToggle) private var willToggle
    @Environment(\.disclosures) private var disclosures

    private var isOpen: Bool {
        guard let disclosureKey, let disclosures else { return localOpen }
        return disclosures.isOpen(disclosureKey) || Disclosure.debugOpens("all")
    }

    private func toggle() {
        if let disclosureKey, let disclosures {
            disclosures.toggle(disclosureKey)
        } else {
            localOpen.toggle()
        }
    }

    private var nodeSize: CGFloat { compact ? 20 : 26 }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 10) {
            Rail(isLast: isLast, width: nodeSize) { StepNode(symbol: symbol, status: status, size: nodeSize) }
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    willToggle()
                    withAnimation(Disclosure.animation(reduceMotion: reduceMotion)) { toggle() }
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
                if let runningSince {
                    TimelineView(.periodic(from: runningSince, by: 1)) { context in
                        Text(Formatting.duration(context.date.timeIntervalSince(runningSince)))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                    }
                } else if let trailing {
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
        monospacedPreview: Bool = false, trailing: String? = nil, runningSince: Date? = nil, isLast: Bool, compact: Bool = false,
        hasDetails: Bool, disclosureKey: String? = nil, @ViewBuilder details: @escaping () -> Details
    ) {
        self.init(
            symbol: symbol, status: status, title: title, preview: preview, monospacedPreview: monospacedPreview,
            trailing: trailing, runningSince: runningSince, isLast: isLast, compact: compact, hasDetails: hasDetails, disclosureKey: disclosureKey,
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
    /// Browser and Passwords steps say the site and where a login came from (`docs/web.md` §4).
    private var web: WebStep? { WebStep.describe(name: tool.name, arguments: tool.arguments, result: tool.result, isRunning: tool.status == .running) }

    private var title: String {
        if let web { return web.title }
        switch tool.status {
        case .running: return descriptor.activeTitle
        case .succeeded: return descriptor.doneTitle
        case .failed: return tool.name == "terminal" ? String(localized: "Command failed") : descriptor.doneTitle
        }
    }

    /// A "no" from the person (not filled, not saved) is a quiet note, not a failure.
    private var status: ToolActivity.Status {
        web?.declined == true ? .succeeded : tool.status
    }

    var body: some View {
        let web = web
        StepLine(
            symbol: web?.symbol ?? descriptor.symbol, status: status, title: title,
            preview: web.map { $0.preview } ?? oneLine(tool.preview), monospacedPreview: web.map(\.previewIsAddress) ?? !isSearch,
            trailing: tool.status == .running ? nil : durationText, trailingIsAlert: status == .failed,
            runningSince: tool.status == .running ? tool.startedAt : nil, isLast: isLast, compact: compact, hasDetails: tool.hasDetails, disclosureKey: "step:\(tool.id)"
        ) {
            if let failure = web?.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(web?.declined == true ? Theme.secondaryText : Theme.danger)
                    .lineLimit(3)
            } else if tool.status == .failed, let line = failureLine {
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

/// A background process this turn started (`processStep`, `docs/background-processes.md` §4), in
/// place of the call that started it: its name, the live state, the command and its latest line.
/// Tap: the Terminal on this process. Long-press: Copy Command, Copy Output, Stop.
private struct ProcessStepLine: View {
    let tool: ToolActivity
    let processID: String
    let isLast: Bool

    @Environment(\.inspectorModel) private var inspector
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var conversation: ConversationModel? { inspector?.conversation }
    private var process: BackgroundProcess? { conversation?.processes.first { $0.id == processID } }
    private var command: String { process?.shownCommand ?? ProcessNaming.clean(tool.startedCommand ?? "") }
    private var name: String {
        if let message { return String(localized: "Message to \(message.name(botName: { conversation?.botTitle($0) }))") }
        return process?.name ?? tool.startedProcessName ?? ProcessNaming.name(for: tool.startedCommand ?? "", botName: { conversation?.botTitle($0) })
    }

    /// A message to another Bot: the step shows what it said and what came back, not a command.
    private var message: BotMessageStep? { BotMessageStep(tool) }

    /// The answer to a message: the reply Hermes carried back when its delivery finished, else the
    /// Bot's own message in this chat after it.
    private var answer: (text: String, failed: Bool)? {
        guard let message, let rows = conversation?.rows else { return nil }
        switch TranscriptBuilder.finished(process: processID, in: rows)?.answer {
        case .replied(let text)?: return (text, false)
        case .failed(let reason)?: return (reason, true)
        case nil: break
        }
        if let error = message.error { return (error, true) }
        return message.reply(in: rows, sentBy: tool.id).map { ($0.text, false) }
    }

    /// No process here: the gateway no longer lists it (or never got asked).
    private var state: BackgroundProcess.State? {
        if let process { return process.state }
        return conversation?.processTracker.hasListed == true ? .ended : nil
    }

    private var latest: String? {
        process?.latestLine(botName: { conversation?.botTitle($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rail(isLast: isLast) { node }
            VStack(alignment: .leading, spacing: 6) {
                // Only a running process's time changes; an idle chat doesn't wake for the others.
                TimelineView(.periodic(from: .now, by: state == .running ? 15 : 86_400)) { context in
                    titleRow(now: context.date)
                }
                snippet
            }
            .padding(.top, 3)
            .padding(.bottom, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { inspector?.openTerminal(processID) }
        .contextMenu { menu }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Show Output")) { inspector?.openTerminal(processID) }
        .accessibilityAction(named: Text("Copy Command")) { Pasteboard.copy(command) }
        .accessibilityActions {
            if process?.isRunning == true {
                Button("Stop") { conversation?.stopProcess(processID) }
            }
        }
    }

    private var node: some View {
        ZStack {
            Circle().fill(state == .failed ? Theme.dangerTint : Theme.surface)
            if state != .failed {
                Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            Image(systemName: state == .failed ? "xmark" : "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state == .failed ? Theme.danger : Theme.secondaryText)
                .contentTransition(.opacity)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private func titleRow(now: Date) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let state {
                ProcessStateGlyph(state: state)
                Text(process?.stateLabel(now: now) ?? String(localized: "Ended"))
                    .font(.footnote)
                    .foregroundStyle(state == .failed ? Theme.danger : Theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var snippet: some View {
        if let message {
            messageSnippet(message)
        } else if !command.isEmpty || latest != nil {
            commandSnippet
        }
    }

    /// What the message said, a few lines with Show More, and the answer under it.
    private func messageSnippet(_ message: BotMessageStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.text.isEmpty {
                ExpandableText(text: message.text, markdown: true, lines: 3)
            }
            if let answer {
                VStack(alignment: .leading, spacing: 4) {
                    Label(answer.failed ? String(localized: "Not delivered") : String(localized: "\(message.name(botName: { conversation?.botTitle($0) })) replied"),
                          systemImage: answer.failed ? "exclamationmark.triangle" : "arrowshape.turn.up.left")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(answer.failed ? Theme.danger : Theme.secondaryText)
                    ExpandableText(text: answer.text, markdown: !answer.failed, lines: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var commandSnippet: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !command.isEmpty {
                Text(verbatim: "$ " + command)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if let latest {
                Text(verbatim: latest)
                    .foregroundStyle(state == .failed ? Theme.danger : Theme.secondaryText)
            }
        }
        .font(Theme.Typography.code)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var menu: some View {
        Button("Copy Command", systemImage: "doc.on.doc") { Pasteboard.copy(command) }
        // The output is read when copied, not while the menu is built (the step would redraw for it).
        Button("Copy Output", systemImage: "text.alignleft") {
            Pasteboard.copy(conversation?.processTracker[processID]?.output.text ?? "")
        }
        .disabled(latest == nil)
        if process?.isRunning == true {
            Button("Stop", systemImage: "stop.fill", role: .destructive) { conversation?.stopProcess(processID) }
        }
    }

    /// "Release build, running for 3 minutes, make release, latest: Signing Hermes.app" (§9).
    private var spoken: String {
        var parts = [name]
        if let process {
            let time = process.duration().map(BackgroundProcess.spokenDuration)
            switch process.state {
            case .running:
                parts.append(process.isStopping ? String(localized: "stopping") : time.map { String(localized: "running for \($0)") } ?? String(localized: "running"))
            case .finished: parts.append(time.map { String(localized: "finished after \($0)") } ?? String(localized: "finished"))
            case .failed: parts.append(process.exitCode.map { String(localized: "failed with exit code \($0)") } ?? String(localized: "failed"))
            case .stopped: parts.append(time.map { String(localized: "stopped after \($0)") } ?? String(localized: "stopped"))
            case .ended: parts.append(String(localized: "ended"))
            }
        } else if state == .ended {
            parts.append(String(localized: "ended"))
        }
        if let message {
            if !message.text.isEmpty { parts.append(BotMentions.stripMarkdown(message.text)) }
            if let answer { parts.append(answer.failed ? answer.text : String(localized: "reply: \(BotMentions.stripMarkdown(answer.text))")) }
            return parts.joined(separator: ", ")
        }
        if !command.isEmpty { parts.append(command) }
        if let latest { parts.append(String(localized: "latest: \(latest)")) }
        return parts.joined(separator: ", ")
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
        let kind = Self.kind(of: tools.first?.name ?? "")
        guard isRunning else { return ToolDescriptor.doneTitle(symbol: kind, count: count) ?? "\(descriptor.doneTitle) · \(count)×" }
        switch kind {
        case "terminal": return String(localized: "Running commands · \(count)")
        case "doc.text": return String(localized: "Reading files · \(count)")
        case "pencil.line": return String(localized: "Editing files · \(count)")
        case "square.and.pencil": return String(localized: "Writing files · \(count)")
        case "globe": return String(localized: "Searching the web · \(count)")
        case "doc.richtext": return String(localized: "Reading pages · \(count)")
        case "doc.text.magnifyingglass": return String(localized: "Searching files · \(count)")
        default: return "\(descriptor.activeTitle) · \(count)"
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
            trailing: isRunning ? nil : duration,
            runningSince: isRunning ? tools.compactMap { $0.status == .running ? $0.startedAt : nil }.min() : nil,
            isLast: isLast, hasDetails: true,
            disclosureKey: tools.first.map { "run:\($0.id)" }
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
                DiffCard(path: tool.filePath ?? tool.preview ?? "file", diff: diff, disclosureKey: "diff:\(tool.id)")
            }
            if let output, !output.lines.isEmpty {
                OutputBlock(output: output, command: tool.preview)
            }
            let results = tool.searchResults
            if !results.isEmpty {
                SearchResultsCard(results: results)
            } else if output == nil, tool.displayDiff == nil, !WebStep.hidesArguments(tool.name),
                      let result = tool.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                // Never for typing or Passwords: their results carry usernames (`docs/web.md` §4.1).
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
                                // Still while it runs: the turn header is the one live line.
                                case .running: Image(systemName: "circle.dotted").foregroundStyle(Theme.tertiaryText)
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

/// What a folded turn keeps in view: a risk note. Its changes are the Changes row; the rest
/// (commands, output, results, each edit's diff) is in the steps.
struct ToolAttachments: View {
    let tool: ToolActivity

    var body: some View {
        if tool.status != .running, let risk = tool.risk {
            RiskNote(risk: risk)
        }
    }
}

extension ToolActivity {
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
struct BranchAction: Equatable {
    let conversation: ConversationModel
    var itemID: String?
    /// The newest reply: Try Again reruns it.
    var isLatest = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation === rhs.conversation && lhs.itemID == rhs.itemID && lhs.isLatest == rhs.isLatest
    }

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

/// While a reply streams, a bold or code span that has opened but not closed yet would show its
/// raw markers (`**`, a backtick) until the rest arrives; shown closed, it reads as it will.
enum StreamingMarkdown {
    static func displayed(_ text: String) -> String {
        // Inside an open code block the text is code already.
        guard text.countBytes("```") % 2 == 0 else { return text }
        let start = text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
        let head = String(text[..<start])
        var paragraph = String(text[start...])
        // Half of a "**" that has just arrived.
        if paragraph.hasSuffix("*"), !paragraph.hasSuffix("**"), !paragraph.hasSuffix(" *"), paragraph.count > 1 {
            paragraph.removeLast()
        }
        let spans = paragraph.replacingOccurrences(of: "```", with: "")
        let opensCode = spans.filter { $0 == "`" }.count % 2 == 1
        let opensBold = !opensCode && spans.components(separatedBy: "**").count % 2 == 0
        if opensCode {
            if paragraph.hasSuffix("`") {
                paragraph.removeLast() // only just opened: nothing to show in it yet
            } else {
                paragraph += "`"
            }
        } else if opensBold {
            if paragraph.hasSuffix("**") {
                paragraph.removeLast(2)
            } else {
                // A closer must touch the text before it to close anything.
                while paragraph.last?.isWhitespace == true { paragraph.removeLast() }
                paragraph += "**"
            }
        }
        return head + paragraph
    }
}
