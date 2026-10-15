import HermesKit
import SwiftUI

/// The scrolling conversation, following new output while the reader is at the end.
///
/// The latest rows (`recentCount`) sit in a plain stack, measured exactly; older history is lazy
/// above them. At the end the lazy part is entirely out of sight, so nothing there is being
/// measured and the content height holds still: the end is exactly where it is. (One lazy stack
/// for everything kept swapping estimated and measured heights near the bottom, by hundreds of
/// points a frame, which threw the view past the end into an empty screen.)
///
/// Following is explicit: while the reader is at the end, any change of the content or the
/// composer eases the view to the new end. Scrolling up stops it; sending or the arrow resumes.
struct TranscriptView: View {
    let conversation: ConversationModel
    let workspace: BotWorkspace

    @State private var position = ScrollPosition(edge: .bottom)
    /// The view keeps to the latest. Only the person scrolling away turns this off: a big block
    /// arriving at once (a table, code) can put the bottom out of reach for a moment, and that
    /// mustn't stop the chat following the reply.
    @State private var isFollowing = true
    /// The person is dragging or flicking the transcript.
    @State private var isScrolledByHand = false
    /// Read in callbacks, never drawn: kept out of SwiftUI state, or every scroll frame and every
    /// streamed word would redraw the whole transcript.
    @State private var edge = EdgeTracker()
    /// An opened chat stays out of sight for its first frame, until it's at the bottom, rather
    /// than visibly jumping as rows get measured. A chat that appears because you just sent (or a
    /// reply is running) shows at once.
    @State private var settled: Bool
    /// A fold was just tapped: what was tapped stays put and opens downward, instead of following
    /// pushing it up the screen.
    @State private var keepsTop = false
    @State private var keepsTopReset: Task<Void, Never>?
    /// A search result landed here: its row flashes once (`surface` → `canvas`).
    @State private var flashKey: String?
    @State private var flashOn = false

    /// The first row shown. The chat opens on the latest `pageSize` rows; new rows only add below,
    /// and scrolling near the top shows a page more. (Counting from the end instead, each new row
    /// pushed the oldest out above and shifted everything on screen by its height.)
    @State private var firstShownKey: String?
    /// Earlier messages are going in above: the content keeps its bottom in place meanwhile, so
    /// what the reader is looking at stays put.
    @State private var isPrepending = false
    /// The composer's height over the end of the chat (see the end marker).
    @State private var bottomInset: CGFloat = 0
    private static let pageSize = 20
    /// Opening a chat lays out only the latest rows (more than a screen), so the first frame is
    /// cheap while the drawer or the window animates; the rest of the page follows a moment later,
    /// above, out of sight.
    private static let firstFrameRows = 8

    init(conversation: ConversationModel, workspace: BotWorkspace) {
        self.conversation = conversation
        self.workspace = workspace
        _settled = State(initialValue: conversation.pendingUser != nil || conversation.isWorking)
    }

    /// Time for the rest of the first page (`fillWindow`), once the drawer has settled.
    @State private var pageDue = false

    var body: some View {
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        let separators = Self.separators(in: all, from: first, datesOpening: conversation.openedWithHistory)
        let answeredRoutines = Self.answeredRoutines(in: all, from: first)
        let rows = all[first...].map { DisplayRow(key: conversation.displayID(for: $0), item: $0) }
        let unclaimed = Self.unclaimedTeams(in: all, store: conversation.helpers)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if first > 0 || conversation.hasEarlierMessages {
                    // Earlier messages come in as the reader nears the top, a page at a time.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
                ForEach(rows, id: \.key) { shown in
                    rowView(shown.item, date: separators[shown.item.id], extraTeams: shown.item.id == unclaimed.turnID ? unclaimed.teams : [], answered: answeredRoutines.contains(shown.item.id))
                        .background {
                            if flashKey == shown.key {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.surface)
                                    .opacity(flashOn ? 1 : 0)
                                    .padding(-10)
                            }
                        }
                        .transition(Self.insertion(for: shown.item))
                }
                ForEach(conversation.processes) { process in
                    ProcessCard(process: process, onStop: { conversation.stopProcess(process) }, onDismiss: { conversation.dismissProcess(process) })
                }
                ForEach(conversation.asides) { aside in
                    AsideCard(aside: aside) { conversation.dismissAside(aside) }
                        .transition(.growIn.combined(with: .opacity))
                }
                // Mid-turn messages not settled into the transcript yet: a steer carried to the
                // next turn, a missed one, a background run.
                ForEach(settlingFollowUps) { record in
                    FollowUpRecordRow(record: record, conversation: conversation)
                        .transition(.asymmetric(insertion: .growIn.combined(with: .opacity), removal: .opacity))
                }
                // While a turn runs the card is about an earlier one, and its Try Again can't act yet.
                if let failure = conversation.turnError, !conversation.isWorking {
                    TurnErrorRow(
                        failure: failure,
                        retry: conversation.retryLastMessage,
                        reload: conversation.reload,
                        dismiss: conversation.dismissTurnError
                    )
                    .transition(.growIn.combined(with: .opacity))
                }
                // The end of the chat, to scroll to (scrolling to an edge doesn't animate). It
                // reaches the composer's height below the end and takes no room, so aligned with
                // the bottom of the view the end sits on the composer, not under it.
                Color.clear
                    .frame(height: bottomInset)
                    .id(Self.endID)
                    .padding(.top, -30) // no stack spacing above it
                    .padding(.bottom, -bottomInset)
            }
            .scrollTargetLayout()
            .animation(Theme.spring, value: conversation.asides)
            .animation(.smooth(duration: 0.32), value: conversation.followUps)
            .animation(.smooth(duration: 0.3), value: conversation.turnError)
            .frame(maxWidth: Theme.readableWidth)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .environment(\.references, references)
        .environment(\.helperStore, conversation.isBotChat ? nil : conversation.helpers)
        .environment(\.checkpoints, conversation.usesGateway ? conversation.checkpoints : nil)
        // Opened from search: land on the message that matched (`docs/search.md`).
        .task(id: conversation.searchFocus?.id) { await landOnSearchMatch() }
        // ⌘F: the shown match.
        .onChange(of: findTarget) { _, id in
            guard let id, let item = conversation.rows.first(where: { $0.id == id }) else { return }
            Task { await land(on: item) }
        }
        // Which replies can be undone: listed when a chat with file edits opens, as an edit
        // lands, and when a turn ends.
        .task(id: checkpointTrigger) {
            guard conversation.usesGateway, conversation.rows.contains(where: Self.editsFiles) else { return }
            await conversation.checkpoints.refresh()
        }
        .environment(\.disclosureWillToggle, DisclosureAction {
            keepsTop = true
            keepsTopReset?.cancel()
            keepsTopReset = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                keepsTop = false
            }
        })
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        #if DEBUG
        .onScrollGeometryChange(for: String.self) { g in
            guard UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") else { return "" }
            return "off=\(Int(g.contentOffset.y)) size=\(Int(g.contentSize.height)) cont=\(Int(g.containerSize.height)) vis=\(Int(g.visibleRect.minY))-\(Int(g.visibleRect.maxY)) ins=\(Int(g.contentInsets.top))/\(Int(g.contentInsets.bottom))"
        } action: { _, line in
            if !line.isEmpty { print("SCROLLLOG \(Int(CACurrentMediaTime() * 1000) % 100_000)ms \(line) follow=\(isFollowing) keepsTop=\(keepsTop)") }
        }
        #endif
        .onScrollGeometryChange(for: ScrollEdge.self) { geometry in
            ScrollEdge(
                // How far the end of the chat is below the composer's top edge (the visible rect
                // runs under the composer).
                distance: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY,
                height: geometry.contentSize.height,
                inset: geometry.contentInsets.bottom,
                container: geometry.containerSize.height,
                nearTop: geometry.visibleRect.minY + geometry.contentInsets.top < 400
            )
        } action: { old, new in
            edge.distance = new.distance
            if new.inset != bottomInset { bottomInset = new.inset }
            // Near the top while reading back (or a short page that doesn't fill the screen):
            // the next page of earlier messages, from memory or from the gateway.
            let fillsScreen = new.height > new.container
            if new.nearTop, !old.nearTop || isScrolledByHand || !fillsScreen, !isFollowing || isScrolledByHand || !fillsScreen {
                showEarlier()
            }
            if isScrolledByHand {
                if isFollowing != (new.distance <= 72) { isFollowing = new.distance <= 72 }
                return
            }
            // Following: the content grew (text, a row opening, a reply settling) or the composer
            // or window changed. Ease to the new end; a big change goes at once.
            guard isFollowing, !keepsTop, settled, abs(new.distance) > 0.5 else { return }
            let changed = new.height != old.height || new.inset != old.inset || new.container != old.container
            guard changed else { return }
            #if os(macOS)
            // The Mac keeps to the very end, at once: the bottom anchor (`sizeChangeAnchor`) then
            // carries growing content in the same layout pass. Easing after it instead moved the
            // chat in steps, pauses and jumps (the Mac's scroll view doesn't blend a new scroll
            // animation into one under way), which read as the whole window jittering. Inside the
            // transaction that opened a row the request would take that animation, so: none.
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) { scrollToLatest() }
            #else
            if abs(new.distance) < 600 {
                withAnimation(.easeOut(duration: 0.24)) { scrollToLatest() }
            } else {
                scrollToLatest()
            }
            #endif
            settleSoon()
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating:
                if !isScrolledByHand { isScrolledByHand = true }
            case .idle:
                if isScrolledByHand, isFollowing != (edge.distance <= 72) { isFollowing = edge.distance <= 72 }
                if isScrolledByHand { isScrolledByHand = false }
            case .animating:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: conversation.rows.count, initial: true) { pinWindow() }
        // Sending brings the chat to its end. (On the Mac, at the end already, the bottom anchor
        // carries the new message in; a scroll animation on top of it only fought it.)
        .onChange(of: conversation.sentTurns) {
            #if os(macOS)
            let wasAway = !isFollowing || edge.distance > 1
            #else
            let wasAway = true
            #endif
            isFollowing = true
            if wasAway { withAnimation(Self.rowsAnimation) { scrollToLatest() } }
        }
        .overlay(alignment: .bottom) {
            if !isFollowing {
                Button {
                    isFollowing = true
                    withAnimation(Theme.spring) { scrollToLatest() }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .padding(.bottom, 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel("Scroll to latest")
            }
        }
        .animation(Theme.snappy, value: isFollowing)
        .task {
            LoadTrace.mark(conversation.stableKey, "transcript appeared (\(conversation.rows.count) rows)")
            // The rows on screen are measured exactly, so the first offset is the end already;
            // one frame later, make sure (out of sight), then show. Long only if it isn't there.
            for delay in [16, 60, 60] {
                try? await Task.sleep(for: .milliseconds(delay))
                if edge.distance <= 16 { break } // (negative: everything fits on screen)
                scrollToLatest()
            }
            if !settled {
                LoadTrace.mark(conversation.stableKey, "transcript settled, showing")
                withAnimation(.easeOut(duration: 0.15)) { settled = true }
            }
            // After the opening animation (the drawer closing), the rest of the page.
            try? await Task.sleep(for: .milliseconds(450))
            pageDue = true
        }
        .modifier(WhenSettled(isDue: pageDue, action: fillWindow))
        .opacity(settled ? 1 : 0)
        .modifier(TakesOfferedSize())
    }

    private func firstShownIndex(in all: [TranscriptItem]) -> Int {
        if let firstShownKey, let index = all.firstIndex(where: { conversation.displayID(for: $0) == firstShownKey }) {
            return index
        }
        return max(0, all.count - (settled ? Self.pageSize : Self.firstFrameRows))
    }

    /// The rest of the first page, above the rows on screen: the end stays where it is.
    private func fillWindow() {
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        let target = max(0, all.count - Self.pageSize)
        guard target < first, !isPrepending, !isScrolledByHand else { return }
        let key = conversation.displayID(for: all[target])
        let keep = conversation.displayID(for: all[first])
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        withTransaction(instant) { firstShownKey = key }
        Task { @MainActor in
            withTransaction(instant) {
                if isFollowing { scrollToLatest() } else { position.scrollTo(id: keep, anchor: .top) }
            }
            try? await Task.sleep(for: .milliseconds(250))
            isPrepending = false
        }
    }

    /// Scrolls to the first message with the search result's words and flashes it. A message
    /// not loaded yet brings in older pages, at most 5.
    private func landOnSearchMatch() async {
        guard let focus = conversation.searchFocus else { return }
        for _ in 0..<60 where conversation.loadState != .loaded || conversation.rows.isEmpty || !settled {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        var target = focus.target(in: conversation.rows)
        var pages = 0
        while target == nil, conversation.hasEarlierMessages, pages < 5, !Task.isCancelled {
            await conversation.loadEarlier()
            pages += 1
            target = focus.target(in: conversation.rows)
        }
        if conversation.searchFocus?.id == focus.id { conversation.searchFocus = nil }
        guard let target, !Task.isCancelled else { return }
        await land(on: target)
    }

    /// The row in-chat find is on.
    private var findTarget: String? {
        guard conversation.findText != nil else { return nil }
        let matches = conversation.findMatches
        return matches.indices.contains(conversation.findIndex) ? matches[conversation.findIndex].id : nil
    }

    /// Brings a row into the window, scrolls it to the middle and flashes it once.
    private func land(on target: TranscriptItem) async {
        let all = conversation.rows
        let key = conversation.displayID(for: target)
        if let index = all.firstIndex(where: { $0.id == target.id }), index < firstShownIndex(in: all) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { firstShownKey = key }
        }
        isFollowing = false
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation(.smooth(duration: 0.35)) { position.scrollTo(id: key, anchor: .center) }
        flashKey = key
        flashOn = true
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(.easeOut(duration: 0.8)) { flashOn = false }
        try? await Task.sleep(for: .milliseconds(850))
        if flashKey == key { flashKey = nil }
    }

    /// Fixes the window's top once there are rows, so later rows only add below it.
    private func pinWindow() {
        let all = conversation.rows
        guard !all.isEmpty else { return }
        let key = conversation.displayID(for: all[firstShownIndex(in: all)])
        if key != firstShownKey { firstShownKey = key }
    }

    /// The next page of earlier messages, keeping the row that was first on screen where it is.
    private func showEarlier() {
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        guard !isPrepending else { return }
        guard first > 0 else {
            // Everything held is on screen: ask the gateway for the page before it.
            guard conversation.hasEarlierMessages, !conversation.isLoadingEarlier else { return }
            Task {
                await conversation.loadEarlier()
                showEarlier()
            }
            return
        }
        let target = max(0, first - Self.pageSize)
        let key = conversation.displayID(for: all[target])
        let keep = conversation.displayID(for: all[first])
        let answers = ConversationModel.answers(in: all[target..<first])
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        Task { @MainActor in
            // Their Markdown parsed off the main thread first: a page of replies parsed in the
            // frame they go in stuttered the scroll.
            await MarkdownCache.prewarm(answers)
            withTransaction(instant) { firstShownKey = key }
            Task { @MainActor in
                withTransaction(instant) { position.scrollTo(id: keep, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(250))
                isPrepending = false
            }
        }
    }

    private func rowView(_ item: TranscriptItem, date: Date?, extraTeams: [String], answered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if let date {
                DateSeparator(date: date)
            }
            row(for: item, extraTeams: extraTeams, answered: answered)
        }
    }

    /// Routine deliveries a reply follows (among the rows shown): the reply carries what the
    /// routine brought, so the delivery folds (`RoutineDeliveryRow`).
    static func answeredRoutines(in rows: [TranscriptItem], from first: Int) -> Set<String> {
        var answered: Set<String> = []
        for index in rows.indices.dropFirst(first).dropLast() {
            guard case .user(let entry) = rows[index], entry.routineName != nil else { continue }
            if case .assistant = rows[index + 1] { answered.insert(entry.id) }
        }
        return answered
    }

    /// Helper teams no `delegate_task` in the chat claims (seen before the call returned, or a chat
    /// opened mid-run), for the latest reply. Reads only the store's team list, which changes when
    /// a team comes or goes, not on every helper event.
    static func unclaimedTeams(in rows: [TranscriptItem], store: HelperStore) -> (turnID: String?, teams: [String]) {
        guard !store.teamKeys.isEmpty else { return (nil, []) }
        var claimed = Set<String>()
        var latest: String?
        for item in rows {
            guard case .assistant(let turn) = item else { continue }
            latest = turn.id
            for step in turn.steps {
                guard case .tool(let tool) = step, tool.name == "delegate_task" else { continue }
                if let call = tool.callID { claimed.insert(call) }
                if let stored = StoredDelegation(tool: tool) { claimed.insert(stored.delegationID) }
            }
        }
        return (latest, store.unanchoredTeamIDs(claimed: claimed))
    }

    /// Where the end of the chat is, and what moves it.
    private struct ScrollEdge: Equatable {
        var distance: CGFloat
        var height: CGFloat
        var inset: CGFloat
        var container: CGFloat
        var nearTop: Bool
    }

    /// Steers still waiting in the running turn show inside it; the rest after the transcript.
    private var settlingFollowUps: [FollowUpRecord] {
        let liveID = conversation.live.map { $0.isFinished ? nil : $0.turn.id } ?? nil
        return conversation.followUps.filter { !($0.state == .steerWaiting && $0.turnID == liveID && liveID != nil) }
    }

    final class EdgeTracker {
        /// Not measured yet: as far from the end as can be.
        var distance: CGFloat = .greatestFiniteMagnitude
        var flip = false
        var settle: Task<Void, Never>?
    }

    /// A row and the identity it's drawn under (`ConversationModel.displayID(for:)`).
    private struct DisplayRow {
        let key: String
        let item: TranscriptItem
    }

    /// New rows open up their room as they come in (`GrowIn`), so the chat following them glides
    /// up instead of jumping by the row's height; your message rises from the composer, replies
    /// and Bot messages fade up into place.
    private static func insertion(for item: TranscriptItem) -> AnyTransition {
        switch item {
        case .user(let entry) where entry.sender == nil && entry.routineName == nil:
            .asymmetric(
                insertion: .growIn.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing))
                    .combined(with: .opacity.animation(.easeOut(duration: 0.18))),
                removal: .identity
            )
        default:
            .asymmetric(insertion: .growIn.combined(with: .opacity), removal: .identity)
        }
    }

    /// Time separators (`dateSeparator`): before the first message of each day and after a gap
    /// of more than an hour.
    /// - Parameter datesOpening: the first message of today gets one too (a chat opened with its
    ///   history). A chat started here gets none until a gap, so none appears above it later.
    /// - Parameter first: only rows from here on (the ones shown) get lines, so a streamed token
    ///   doesn't walk the whole history.
    static func separators(in rows: [TranscriptItem], from first: Int = 0, datesOpening: Bool) -> [String: Date] {
        var result: [String: Date] = [:]
        let calendar = Calendar.current
        // The nearest dated row above the window decides the first shown row's line.
        var previous: Date? = rows[..<min(first, rows.count)].reversed().lazy.compactMap(Self.date(of:)).first
        for row in rows[min(first, rows.count)...] {
            guard let date = Self.date(of: row) else { continue }
            if let previous {
                if !calendar.isDate(date, inSameDayAs: previous) || date.timeIntervalSince(previous) > 3600 {
                    result[row.id] = date
                }
            } else if !calendar.isDateInToday(date) || datesOpening {
                result[row.id] = date
            }
            previous = date
        }
        return result
    }

    private static func date(of row: TranscriptItem) -> Date? {
        switch row {
        case .user(let entry): entry.timestamp
        case .assistant(let turn): turn.startedAt
        case .command(let command): command.timestamp
        case .notice: nil
        }
    }

    /// What this chat's text can name: its gateway's Bots, files, and the skills and commands
    /// it knows. Drawn as pills and cards.
    private var references: ReferenceContext {
        ReferenceContext(workspace: workspace, catalog: conversation.slashCatalog)
    }

    private static let endID = "transcript-end"

    /// What stays put when the content changes size: the bottom while following the end on the
    /// Mac (the content moves up in the same layout pass as it grows: a scroll request resolves
    /// against the previous frame, so following by scrolling trailed every change by a frame) and
    /// while earlier messages go in above; the top otherwise (reading back, opening a fold).
    private var sizeChangeAnchor: UnitPoint {
        #if os(macOS)
        if isFollowing, !isScrolledByHand, !keepsTop { return .bottom }
        #endif
        return isPrepending ? .bottom : .top
    }

    /// Once things stop moving, make sure the end really is on the composer: a change that lands
    /// while a scroll is under way can leave it short.
    private func settleSoon() {
        edge.settle?.cancel()
        edge.settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isFollowing, !isScrolledByHand, !keepsTop, abs(edge.distance) > 1 else { return }
            withAnimation(.easeOut(duration: 0.24)) { scrollToLatest() }
        }
    }

    private func scrollToLatest() {
        #if os(macOS)
        // The very end, above the composer: the bottom anchor holds on to the content only while
        // it's exactly there (the end marker sits the stack's bottom padding short of it).
        position.scrollTo(edge: .bottom)
        #else
        // The same request twice is no change to a scroll position, so a second follow while the
        // first is under way would be dropped: alternate between two anchors that mean the same.
        edge.flip.toggle()
        position.scrollTo(id: Self.endID, anchor: UnitPoint(x: edge.flip ? 0.5 : 0.25, y: 1))
        #endif
    }

    private struct CheckpointTrigger: Hashable {
        let chat: UUID
        let completed: Int
        let items: Int
        let working: Bool
        let liveEdits: Int
        let gateway: Bool
    }

    private var checkpointTrigger: CheckpointTrigger {
        CheckpointTrigger(
            chat: conversation.id, completed: conversation.completedTurns, items: conversation.items.count,
            working: conversation.isWorking, liveEdits: conversation.live.map { TurnFileEdits(turn: $0.snapshot).paths.count } ?? 0,
            gateway: conversation.usesGateway
        )
    }

    private static func editsFiles(_ item: TranscriptItem) -> Bool {
        if case .assistant(let turn) = item { return !TurnFileEdits(turn: turn).isEmpty }
        return false
    }

    /// How rows come and go (`ConversationModel.animateRows` uses the same).
    static let rowsAnimation = Animation.smooth(duration: 0.36)

    @ViewBuilder
    private func row(for item: TranscriptItem, extraTeams: [String] = [], answered: Bool = false) -> some View {
        switch item {
        case .user(let entry):
            if entry.isSteer {
                FollowUpBubble(text: entry.text, caption: .steerRead(after: nil))
            } else if let caption = conversation.caption(for: entry) {
                CaptionedUserRow(caption: caption) {
                    UserBubble(entry: entry, images: conversation.images(for: entry), conversation: conversation.isBotChat ? nil : conversation, reactions: conversation.reactions[entry.id] ?? [])
                }
            } else if let sender = entry.sender {
                AgentMessageRow(entry: entry, sender: sender, roster: workspace.roster)
            } else if let routine = entry.routineName {
                RoutineDeliveryRow(entry: entry, name: routine, isAnswered: answered)
            } else if let command = command(in: entry) {
                CommandBubble(name: command.name, argument: command.argument, isBotChat: conversation.isBotChat)
            } else {
                UserBubble(entry: entry, images: conversation.images(for: entry), conversation: conversation.isBotChat ? nil : conversation, reactions: conversation.reactions[entry.id] ?? [])
            }
        case .assistant(let turn):
            AssistantTurnView(
                turn: turn,
                pendingSteers: turn.id == conversation.live?.turn.id ? conversation.followUps.filter { $0.state == .steerWaiting && $0.turnID == turn.id } : [],
                status: turn.isWorking ? conversation.liveStatus : nil,
                isStopping: turn.isWorking && conversation.isStopping,
                onBranch: branchAction(for: turn.id),
                extraTeamIDs: extraTeams
            )
        case .notice(let notice) where notice.kind == "background-sent":
            if let caption = FollowUpRecord(text: notice.text, state: .background(answer: ""), turnID: nil).caption {
                FollowUpBubble(text: notice.text, caption: caption)
            }
        case .notice(let notice) where notice.kind == "background":
            BackgroundCard(prompt: conversation.backgroundResults[notice.id]?.prompt ?? "", answer: conversation.backgroundResults[notice.id]?.answer ?? notice.text)
        case .notice(let notice) where notice.kind.hasPrefix("receipt:"):
            ReceiptRow(notice: notice, conversation: conversation)
        case .notice(let notice) where notice.kind == "failed_turn":
            FailedTurnRow(notice: notice)
        case .notice(let notice) where notice.kind == "restored":
            RestoredNoteRow(note: conversation.restoredNotes[notice.id] ?? RestoredNote(title: notice.text, details: [], warnings: []))
        case .notice(let notice):
            NoticeRow(notice: notice)
        case .command(let command):
            CommandRow(entry: command, isBotChat: conversation.isBotChat)
        }
    }

    /// A message that is a command renders as a command card: kept from when it was sent, or
    /// a leading `/word` the app or gateway knows in text from another client.
    private func command(in entry: UserEntry) -> MessageParts.Command? {
        if let parts = entry.parts { return parts.command }
        guard entry.skillNames.isEmpty, entry.fileNames.isEmpty, let parsed = SlashCommands.parse(entry.text) else { return nil }
        if conversation.slashCatalog?.skillNames.contains(parsed.name) == true { return nil }
        if SlashCommands.known(parsed.name) != nil || conversation.slashCatalog?.commands.contains(where: { $0.name == parsed.name }) == true {
            return MessageParts.Command(name: parsed.name, argument: parsed.argument)
        }
        return nil
    }

    /// Holds the conversation, not a fresh closure, so finished turns compare equal and don't
    /// re-render while a reply streams.
    private func branchAction(for itemID: String) -> BranchAction? {
        guard !conversation.isBotChat else { return nil } // Bot Chats are one conversation
        guard let key = conversation.stableKey, workspace.session(forKey: key) != nil,
              workspace.capabilities?.features.sessionFork != false || conversation.canBranchFromPoint
        else { return nil }
        let latest = conversation.items.last { if case .assistant = $0 { true } else { false } }?.id
        return BranchAction(conversation: conversation, itemID: itemID, isLatest: latest == itemID)
    }
}

/// "Today 09:41" between turns (`dateSeparator`).
private struct DateSeparator: View {
    let date: Date

    private var label: String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today \(time)") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.tertiaryText)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(notice.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// A stored turn that didn't finish (`failed_turn`). Its sentence says what to check before
/// sending again, so it shows whole, not cut to a notice's two lines.
private struct FailedTurnRow: View {
    let notice: Notice

    var body: some View {
        Label {
            Text(notice.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.warning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct TurnErrorRow: View {
    let failure: TurnFailure
    let retry: () -> Void
    let reload: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            HStack(spacing: 8) {
                if failure.canRetry {
                    Button("Try Again", action: retry)
                        .prominentGlassButton()
                } else {
                    Button("Reload", action: reload)
                        .prominentGlassButton()
                }
                Button("Dismiss", action: dismiss)
                    .glassButton()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.Radius.card)
    }
}

/// Runs `action` once it's due and the drawer isn't sliding (`isSliding`). Reading the slide
/// here, not in the transcript, keeps the slide's start and end from redrawing the transcript.
private struct WhenSettled: ViewModifier {
    let isDue: Bool
    let action: () -> Void
    @Environment(\.isSliding) private var isSliding

    func body(content: Content) -> some View {
        content.onChange(of: isDue && !isSliding) { _, ready in
            if ready { action() }
        }
    }
}

/// The transcript takes the space it's offered without measuring its rows. Asked for a size
/// without one (the Mac window works out its minimum and maximum on every layout pass), a scroll
/// view measures all of its content: in a long chat, much of each frame while a reply streamed in
/// or a message went out.
private struct TakesOfferedSize: ViewModifier {
    func body(content: Content) -> some View {
        OfferedSize { content }
    }

    private struct OfferedSize: Layout {
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 320))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// A row that takes its height gradually as it appears: the space for it opens over the
/// animation instead of in one frame. The row itself is laid out at full size from the start.
struct GrowIn: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        HeightFraction(fraction: progress) { content }
    }
}

extension AnyTransition {
    static let growIn = AnyTransition.modifier(active: GrowIn(progress: 0), identity: GrowIn(progress: 1))
}

/// Lays its content out as proposed and claims only `fraction` of its height (the content draws
/// past it, top-aligned). The proposal passes through untouched: at full height it changes
/// nothing, so the lazy stack measures rows exactly as without it.
private struct HeightFraction: Layout {
    var fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(proposal)
        guard fraction < 1 else { return size }
        return CGSize(width: size.width, height: size.height * max(fraction, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        guard fraction < 1 else {
            child.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            return
        }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: proposal.height))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }

    // Every row keeps this layout (a transition's identity stays applied), and the default
    // alignment answer asks the whole row again: the transcript's stack, aligning its rows, walked
    // every row's contents on each layout pass. A row's edges are its own frame's.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
}
