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
/// composer eases the view to the new end. Scrolling up stops it; the arrow resumes.
///
/// Sending reads like a new page: your message glides up to just under the top bar and the reply
/// fills in below it, from its first line. Nothing chases the reply down the screen; when it runs
/// past the bottom, the arrow says there's more. Until the reply fills the screen, blank room
/// after it (`runway`) is what lets the message sit at the top.
struct TranscriptView: View {
    let conversation: ConversationModel
    let workspace: BotWorkspace
    /// A tap on the chat itself (not its arrow back to the latest), while the keyboard is up.
    var onTap: (() -> Void)?

    @State private var position = ScrollPosition(edge: .bottom)
    /// The view keeps to the latest. Only the person scrolling away turns this off: a big block
    /// arriving at once (a table, code) can put the bottom out of reach for a moment, and that
    /// mustn't stop the chat following the reply.
    @State private var isFollowing = true
    /// The person is dragging or flicking the transcript.
    @State private var isScrolledByHand = false
    /// The newest turn's message, which sending put at the top: the turn is read from there.
    @State private var anchorKey: String?
    /// The view holds `anchorKey` where it is instead of following the reply.
    @State private var holdsTurn = false
    /// Blank room after the newest turn, so its message can sit at the top while the reply is
    /// shorter than the screen. Only the end of the chat draws it (`TranscriptEnd`): it changes
    /// with each word of a short reply, and as the transcript's state it redrew the whole list.
    @State private var runwayRoom = RunwayRoom()
    private var runway: CGFloat { runwayRoom.height }
    /// From sending until the message is at the top: the chat's decorative loops (the reply's
    /// shimmer, faces) hold still, so the glide has the main thread to itself.
    @State private var isGliding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// The last row shown, while reading back far from the end; `nil` shows through the end.
    /// Every row in the window costs every scroll frame (each view's place depends on the
    /// scroll), so reading back keeps a few pages around the screen, never the whole chat: rows
    /// well below go as earlier pages come in above, and come back as the reader returns.
    @State private var lastShownKey: String?
    /// Earlier messages are going in above: the content keeps its bottom in place meanwhile, so
    /// what the reader is looking at stays put.
    @State private var isPrepending = false
    /// Later rows are going back in below (`showLater`).
    @State private var isAppending = false
    /// Blank room at the top where rows that went above the screen were (`dropAbove`): the rows
    /// below stay exactly where they were, so nothing on screen moves, and coming back
    /// (`bringBackAbove`) they take their room again. A scroll can't be moved in the same pass
    /// as content above it changes while it's moving (the size-change anchor holds only at the
    /// very edge, and a scroll position's correction lands a frame late, a flash of other rows).
    @State private var aboveRoom: CGFloat = 0
    /// Rows whose place in the content is read (`edge.frames`), for `dropAbove`.
    @State private var measuredKeys: Set<String> = []
    /// The composer's height over the end of the chat (see the end marker).
    @State private var bottomInset: CGFloat = 0
    /// Rows that arrived at the end while the reader was up in the history.
    @State private var arrivalsBelow = 0
    /// The New Messages line (`docs/inbox.md` §4): placed when the chat opens with something new,
    /// gone when it closes. Never for messages that arrive while it's open.
    @State private var divider: NewMessagesMarker?
    /// Counted messages below the view not seen yet, oldest first: from the line, and those that
    /// arrive while the reader is up in the history (`newMessagesPill`).
    @State private var unseenBelow: [String] = []
    /// The pill's first tap went to the first new message; the next goes to the end.
    @State private var jumpedToFirst = false
    /// Taps on the pill (a light tap of haptics each).
    @State private var jumps = 0
    @AppStorage(PreferenceKey.openChatsAt) private var openChatsAt = OpenChatsAt.firstUnread
    @AppStorage(TalkPreferences.Key.replies) private var voiceReplies = VoiceReplies.Setting.whenISpeak.rawValue
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    /// Only the window in front reads: a chat in a window behind another isn't being read.
    @Environment(\.controlActiveState) private var windowState
    private var isReadingWindow: Bool { windowState == .key }
    #else
    private var isReadingWindow: Bool { true }
    #endif
    /// Choosing words to quote (`ChooseQuoteSheet`).
    @State private var choosingQuote: QuoteChoice?
    /// A reply open in Select Text.
    @State private var selectingText: SelectTextChoice?
    private static let pageSize = 20
    /// Opening a chat lays out only the latest rows (more than a screen), so the first frame is
    /// cheap while the drawer or the window animates; the rest of the page follows a moment later,
    /// above, out of sight. At most this many, fewer when they're long (`openingRows`).
    private static let firstFrameRows = 8
    /// The fewest rows a chat opens with, and the room they must cover at the least: two and a
    /// half screens (a screen taken as 900 points until the view has measured its own).
    private static let leastOpeningRows = 3
    private static let openingScreens: CGFloat = 2.5
    private static let assumedScreen: CGFloat = 900
    /// A page of rows (the first, and each earlier one) covers this many screens at the least, or
    /// is `pageSize` rows, whichever is fewer: twenty long replies of code were a dozen screens, all
    /// built in the moments after a chat opened (or in one frame as an earlier page came in).
    private static let pageScreens: CGFloat = 6

    init(conversation: ConversationModel, workspace: BotWorkspace, onTap: (() -> Void)? = nil) {
        self.conversation = conversation
        self.workspace = workspace
        self.onTap = onTap
        _settled = State(initialValue: conversation.pendingUser != nil || conversation.isWorking)
    }

    /// Time for the rest of the first page (`fillWindow`), once the drawer has settled.
    @State private var pageDue = false
    /// Calls whose turns are open under their card (Transcript).
    @State private var openCalls: Set<UUID> = []

    var body: some View {
        // The running reply is listed by its outline: its words would redraw the whole list.
        let all = conversation.listRows
        let first = firstShownIndex(in: all)
        let end = windowEnd(in: all, from: first)
        let reachesEnd = end == all.count
        let separators = Self.separators(in: all, from: first, datesOpening: conversation.openedWithHistory)
        let rows = all[first..<end].map { DisplayRow(key: conversation.displayID(for: $0), item: $0) }
        // Calls that ended fold into their card (`callSummary`, `docs/voice.md` §4.3).
        let calls = TalkCenter.shared.records(for: conversation.sessionID)
        let folds = CallFolding.folds(Array(all[first..<end]), spans: calls.map { .init(id: $0.id, start: $0.startedAt, end: $0.endedAt) })
        let unclaimed = Self.unclaimedTeams(in: all, store: conversation.helpers)
        // Replies to a voice message open with the Bot's voice (`docs/voice.md` §2).
        let spokenReplies = VoiceReplies.turns(in: all, setting: VoiceReplies.Setting(rawValue: voiceReplies) ?? .whenISpeak)
        let latestReply = all.last { if case .assistant = $0 { true } else { false } }?.id
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if showsLoadingRow(first: first) {
                    // Earlier messages come in as the reader nears the top, a page at a time. A
                    // still skeleton of their lines, not a spinner (`docs/chat.md` §4a).
                    SkeletonRows(count: 1, twoLines: false)
                        .frame(height: Self.loadingRowHeight)
                }
                ForEach(rows, id: \.key) { shown in
                    RowEdges {
                        callFolded(shown.item, folds: folds, calls: calls) {
                            rowView(shown.item, date: separators[shown.item.id], extraTeams: shown.item.id == unclaimed.turnID ? unclaimed.teams : [],
                                    spokenReplies: spokenReplies, latestReply: latestReply)
                        }
                    }
                        .background {
                            if flashKey == shown.key {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Theme.surface)
                                    .opacity(flashOn ? 1 : 0)
                                    .padding(-10)
                            }
                            if measuredKeys.contains(shown.key) {
                                Color.clear
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: { frame in
                                        edge.frames[shown.key] = frame
                                    }
                            }
                            if shown.key == anchorKey {
                                Color.clear
                                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).minY } action: { top in
                                        edge.anchorTop = top
                                        updateRunway()
                                    }
                                    // The message went (a failed send): no room is kept for it.
                                    // (Not when the next message took over.)
                                    .onDisappear {
                                        guard anchorKey == shown.key else { return }
                                        edge.anchorTop = nil
                                        updateRunway()
                                    }
                            }
                        }
                        // Rows the window brings back in (pages, rows that went) aren't new: at
                        // full height at once. Grown in, they took a pass at no height first, and
                        // on the Mac that pass was drawn, the chat moving by their height.
                        .transition(isPrepending || isAppending ? .identity : Self.insertion(for: shown.item, holding: holdsTurn))
                }
                if reachesEnd {
                    ForEach(conversation.asides) { aside in
                        AsideCard(aside: aside) { conversation.dismissAside(aside) }
                            .transition(.growIn.combined(with: .opacity).animation(Theme.spring))
                    }
                    // Mid-turn messages not settled into the transcript yet: a steer carried to the
                    // next turn, a missed one, a background run.
                    ForEach(settlingFollowUps) { record in
                        FollowUpRecordRow(record: record, conversation: conversation)
                            .transition(.asymmetric(insertion: .growIn.combined(with: .opacity), removal: .opacity)
                                .animation(.smooth(duration: 0.32)))
                    }
                    // While a turn runs the card is about an earlier one, and its Try Again can't act yet.
                    if let failure = conversation.turnError, !conversation.isWorking {
                        TurnErrorRow(
                            failure: failure,
                            conversation: conversation,
                            retry: conversation.retryLastMessage,
                            reload: conversation.reload,
                            dismiss: conversation.dismissTurnError
                        )
                        .transition(.growIn.combined(with: .opacity).animation(.smooth(duration: 0.3)))
                    }
                } else {
                    // Later messages come back in as the reader nears the bottom (`showLater`).
                    SkeletonRows(count: 1, twoLines: false)
                }
                // The end of the chat, to scroll to (scrolling to an edge doesn't animate). It
                // reaches the composer's height below the end and takes no room, so aligned with
                // the bottom of the view the end sits on the composer, not under it. While the
                // newest turn is shorter than the screen it sits `runway` lower: the room that
                // lets the turn's message stay at the top.
                TranscriptEnd(room: runwayRoom, bottomInset: bottomInset) { top in
                    edge.tailEnd = top - runway
                    // The room after a sent message is in: the glide can reach it.
                    if edge.landing, edge.landingArmed { land() }
                    updateRunway()
                }
            }
            .scrollTargetLayout()
            .transformEnvironment(\.pausesDecorativeMotion) { paused in
                paused = paused || isGliding
            }
            // No animation on the whole stack: each card above brings its own, so a reload or a
            // reply streaming in the same moment doesn't move every row with it.
            .frame(maxWidth: Theme.readableWidth)
            .padding(.horizontal, 20)
            .padding(.top, 20 + aboveRoom)
            .padding(.bottom, Self.bottomPadding)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.contentSpace))
        }
        .environment(\.references, references)
        .environment(\.widgetHost, conversation.widgetHost)
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
        .environment(\.disclosures, conversation.disclosures)
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
        // Buttons and links in the chat still work; the tap also puts the keyboard away.
        .simultaneousGesture(TapGesture().onEnded { onTap?() }, isEnabled: onTap != nil)
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
                top: geometry.contentOffset.y + geometry.contentInsets.top,
                height: geometry.contentSize.height,
                inset: geometry.contentInsets.bottom,
                container: geometry.containerSize.height,
                visibleTop: geometry.visibleRect.minY + geometry.contentInsets.top
            )
        } action: { old, new in
            // How far the chat's last content is below the composer: the runway after it is
            // blank, and nothing to come back to.
            let distance = new.distance - runway
            edge.distance = distance
            edge.top = new.top
            edge.container = new.container
            if new.inset != bottomInset { bottomInset = new.inset }
            // The room between the bars a turn has to fill (the container is what the insets
            // leave): as it is now, keyboard and all, so the chat never scrolls past its message
            // at the top into blank. Also without the keyboard (the smallest inset seen is the
            // composer alone; none at all is the first frame, before the bars): the runway takes
            // that room the moment the keyboard starts to go (`keyboardWillHide`), before the
            // view grows, or the scroll view would pull the message down to fill it.
            if new.inset > 0 { edge.minInset = min(edge.minInset, new.inset) }
            let viewport = new.container + new.inset - min(edge.minInset, new.inset) - Self.landingGap
            let room = new.container - Self.landingGap
            if abs(viewport - edge.viewport) > 0.5 || abs(room - edge.room) > 0.5 {
                edge.viewport = viewport
                edge.room = room
                updateRunway()
            }
            // The message held at the top was pulled down anyway (the view grew with nothing to
            // warn of it: the composer losing a line, the keyboard dragged away): back up it goes.
            if edge.pinned, holdsTurn, runway > 0, !isScrolledByHand, !edge.landing, let anchor = edge.anchorTop,
               new.top < anchor - Self.landingGap - 1 {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { position.scrollTo(y: anchor - Self.landingGap) }
            }
            // Near the top while reading back (or a short page that doesn't fill the screen):
            // the next page of earlier messages, from memory or from the gateway.
            let fillsScreen = new.height > new.container
            // Near the top of the rows shown (below any room left by rows gone above). Rows that
            // went come back from further off, so they're in before the reader gets there.
            let reach = edge.droppedAbove.isEmpty ? Self.nearTop : Self.nearEdge
            let nearTop = new.visibleTop < 20 + aboveRoom + reach
            let wasNearTop = old.visibleTop < 20 + aboveRoom + reach
            if nearTop, !wasNearTop || isScrolledByHand || !fillsScreen, !isFollowing || isScrolledByHand || !fillsScreen {
                showEarlier()
            }
            // Back down near the last row shown, far back in the chat: later rows come back in.
            if lastShownKey != nil, distance < Self.nearEdge {
                showLater()
            }
            if isScrolledByHand {
                let atEnd = distance <= 72 && lastShownKey == nil
                if isFollowing != atEnd { isFollowing = atEnd }
                return
            }
            // Sending: the glide to the message is on its way.
            if edge.landing { return }
            // Reading the newest turn from its start: nothing moves the view. Past the bottom,
            // the arrow shows there's more.
            if holdsTurn {
                if isFollowing != (distance <= 72) { isFollowing = distance <= 72 }
                return
            }
            // Following: the content grew (text, a row opening, a reply settling) or the composer
            // or window changed. Ease to the new end; a big change goes at once.
            guard isFollowing, !keepsTop, settled, abs(distance) > 0.5 else { return }
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
            if abs(distance) < 600 {
                withAnimation(.easeOut(duration: 0.24)) { scrollToLatest() }
            } else {
                scrollToLatest()
            }
            #endif
            settleSoon()
        }
        .onScrollPhaseChange { _, phase in scrollPhaseChanged(to: phase) }
        #if DEBUG
        // A scroll run (`-HERMES_SCROLL_RUN`) moves the chat as a finger would.
        .onReceive(NotificationCenter.default.publisher(for: ScrollRun.drags)) { note in
            scrollPhaseChanged(to: note.object as? Bool == true ? .interacting : .idle)
        }
        .onReceive(NotificationCenter.default.publisher(for: ScrollRun.jumpToEnd)) { _ in jumpToEnd() }
        #endif
        #if os(iOS)
        // The keyboard going: the runway takes its room before the view grows (`updateRunway`).
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            edge.keyboardHiding = true
            updateRunway()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            edge.keyboardHiding = false
            updateRunway()
        }
        #endif
        .onChange(of: all.count, initial: true) {
            pinWindow()
            edge.trim?.cancel()
            edge.trim = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                trimWindow()
            }
        }
        // Sending turns the page: the message glides up to the top.
        .onChange(of: conversation.sentTurns) { beginLanding() }
        .overlay(alignment: .bottom) {
            if !isFollowing && settled {
                ActivityJumpPill(pill: pill, conversation: conversation, workspace: workspace, face: botFace, action: jump)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .scale(scale: 0.9)).combined(with: .opacity))
            }
        }
        .modifier(InboxBehaviour(view: self, rowCount: all.count, lastRowID: all.last?.id))

        .animation(Theme.snappy, value: isFollowing)
        .onAppear {
            // The chat's first message (the transcript appears with it): it goes to the top too.
            if conversation.pendingUser != nil, conversation.isWorking { beginLanding() }
        }
        .task {
            LoadTrace.mark(conversation.stableKey, "transcript appeared (\(conversation.rows.count) rows)")
            // Something new since it was read: open at the New Messages line (`docs/inbox.md` §4).
            // Nothing new: back where it was left, if it was left scrolled up.
            let opening: UnreadStore.Opening? = if let key = conversation.inboxKey { await workspace.unread.opening(for: key) } else { nil }
            LoadTrace.mark(conversation.stableKey, "opening: \(opening == nil ? "nothing new" : "since \(opening?.since?.timeIntervalSince1970 ?? 0), seen \(opening?.seenThrough ?? "-")")")
            if let opening, await openAtNew(opening) {
                // Placed; shown below.
            } else if opening == nil, await openWhereLeft() {
                // Back where it was left.
            } else {
                // The rows on screen are measured exactly, so the first offset is the end already;
                // one frame later, make sure (out of sight), then show. Long only if it isn't there.
                for delay in [16, 60, 60] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    if edge.distance <= 16 { break } // (negative: everything fits on screen)
                    scrollToLatest()
                }
            }
            if !settled {
                LoadTrace.mark(conversation.stableKey, "transcript settled, showing")
                #if DEBUG && os(iOS)
                FrameMonitor.shared.mark("chat showing")
                #endif
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
        return settled ? pageStart(in: all, above: all.count) : max(0, all.count - openingRows(in: all))
    }

    /// How many of the latest rows a chat opens with: enough to cover the screen a couple of times
    /// over, by their height at the least. A chat of long replies (code, tables) built eight of
    /// them in the frame it opened, half a second; two or three cover the screen.
    private func openingRows(in all: [TranscriptItem]) -> Int {
        let room = max(edge.container, Self.assumedScreen) * Self.openingScreens
        var height: CGFloat = 0
        var count = 0
        for item in all.reversed() {
            count += 1
            height += item.leastHeight
            if count >= Self.firstFrameRows || (count >= Self.leastOpeningRows && height >= room) { break }
        }
        return count
    }

    /// Where a page of rows ending just above `end` starts: `pageSize` rows back, or fewer when they
    /// cover `pageScreens` screens already (by their height at the least).
    private func pageStart(in all: [TranscriptItem], above end: Int) -> Int {
        let room = max(edge.container, Self.assumedScreen) * Self.pageScreens
        let floor = max(0, end - Self.pageSize)
        var height: CGFloat = 0
        var index = end
        while index > floor, height < room {
            index -= 1
            height += all[index].leastHeight
        }
        return index
    }

    /// Past the last row shown: the end of the chat unless the reader is far back in it.
    private func windowEnd(in all: [TranscriptItem], from first: Int) -> Int {
        guard let lastShownKey, let index = all.firstIndex(where: { conversation.displayID(for: $0) == lastShownKey }) else {
            return all.count
        }
        return min(all.count, max(first, index + 1))
    }

    /// A chat read at its end keeps its latest page in the window, not every row since it opened:
    /// each streamed word redraws the window, and on the Mac AppKit walks every view in it per
    /// frame (drag regions, the cursor, focus), so a chat kept open all day slowed down turn by
    /// turn. Rows well above the screen go once rows stop coming; scrolling up brings them back a
    /// page at a time.
    ///
    /// Only while the view sits on the very end and follows it: the end is held, so nothing on
    /// screen moves. A sent message held at the top (`holdsTurn`) is held by a point, which
    /// stayed where it was as the rows above went, and the view showed blank room past the end
    /// until it caught up.
    private func trimWindow() {
        guard isFollowing, !holdsTurn, runway == 0, settled, !isScrolledByHand, !edge.landing, !isGliding,
              !isPrepending, abs(edge.distance) <= Self.bottomPadding + 4,
              divider == nil, flashKey == nil, conversation.searchFocus == nil, conversation.findText == nil
        else { return }
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        let visible = Set(edge.visibleKeys)
        guard let firstVisible = all.firstIndex(where: { visible.contains(conversation.displayID(for: $0)) }) else { return }
        // A page kept, and never a row on screen or just above it.
        let target = min(all.count - Self.pageSize, firstVisible - 2)
        guard target - first >= Self.trimSlack else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG trim \(first)->\(target) of \(all.count)") }
        #endif
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        withTransaction(instant) {
            firstShownKey = conversation.displayID(for: all[target])
            forgetRoomAbove()
            scrollToLatest()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            isPrepending = false
        }
    }

    private func scrollPhaseChanged(to phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            if !isScrolledByHand { isScrolledByHand = true }
            edge.pinned = false // where the person scrolls it, it stays
            if edge.landing || isGliding { abandonGlide() }
        case .idle:
            // (The end of the window isn't the end of the chat while reading far back.)
            let atEnd = edge.distance <= 72 && lastShownKey == nil
            if isScrolledByHand, isFollowing != atEnd { isFollowing = atEnd }
            // Scrolled down to the end of a reply longer than the screen: follow it from here.
            if isScrolledByHand, holdsTurn, runway == 0, atEnd { holdsTurn = false }
            if isScrolledByHand { isScrolledByHand = false }
        case .animating:
            break
        @unknown default:
            break
        }
    }

    /// Rows past a page before the window is trimmed, so it isn't trimmed after every turn.
    private static let trimSlack = 10

    /// Rows the window grows by per frame as it fills.
    private static let fillStep = 3

    /// Rows kept past the screen on the side the reader is leaving, reading back.
    private static let keptBeyond = 10

    /// How near the top a page of earlier messages comes in.
    private static let nearTop: CGFloat = 400

    /// How near an edge of the window rows held back come in: early enough to be built, a few a
    /// frame, before the reader gets there.
    private static let nearEdge: CGFloat = 1200

    /// The loading row above the rows shown, and the room it takes with the stack's spacing.
    private static let loadingRowHeight: CGFloat = 20
    private static let loadingRoom: CGFloat = loadingRowHeight + 30

    /// The rest of the first page, above the rows on screen: the end stays where it is. A few
    /// rows a frame: the page's twelve in one frame took up to half a second in chats of long
    /// replies and tables, a freeze just as the chat had opened.
    private func fillWindow() {
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        let target = pageStart(in: all, above: all.count)
        guard target < first, !isPrepending, !isScrolledByHand, lastShownKey == nil else { return }
        // By key, nearest first: rows can come in while the window fills.
        let keys = stride(from: first - 1, through: target, by: -1).map { conversation.displayID(for: all[$0]) }
        var keep = conversation.displayID(for: all[first])
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        Task { @MainActor in
            var added = 0
            while added < keys.count, !isScrolledByHand {
                added = min(keys.count, added + Self.fillStep)
                let key = keys[added - 1]
                withTransaction(instant) { firstShownKey = key }
                await Task.yield()
                withTransaction(instant) {
                    if isFollowing { scrollToLatest() } else { position.scrollTo(id: keep, anchor: .top) }
                }
                keep = key
                await withCheckedContinuation { done in NextFrame.run { done.resume() } }
            }
            try? await Task.sleep(for: .milliseconds(250))
            isPrepending = false
        }
    }

    /// Scrolls to the first message with the search result's words and flashes it. A message
    /// not loaded yet brings in older pages, at most 5. Waits for the opening animation (on
    /// iPhone the drawer slides away over the chat) and the first page, so the flash is seen.
    private func landOnSearchMatch() async {
        guard let focus = conversation.searchFocus else { return }
        for _ in 0..<60 where conversation.loadState != .loaded || conversation.rows.isEmpty || !settled || !pageDue {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<10 where isPrepending {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        // The result's own message, from earlier pages if it takes them; only then a looser match.
        var target = focus.match(in: conversation.rows)
        var pages = 0
        while target == nil, conversation.hasEarlierMessages, pages < 5, !Task.isCancelled {
            await conversation.loadEarlier()
            pages += 1
            target = focus.match(in: conversation.rows)
        }
        if target == nil { target = focus.target(in: conversation.rows) }
        LoadTrace.mark(conversation.stableKey, "search: \(target.map { "landing on \($0.id)" } ?? "no match") after \(pages) earlier pages, \(conversation.rows.count) rows\(Task.isCancelled ? ", cancelled" : "")")
        guard !Task.isCancelled else { return }
        if let target { await land(on: target) }
        // Last: the focus is this task's id, and clearing it cancels the task (and its flash).
        if conversation.searchFocus?.id == focus.id { conversation.searchFocus = nil }
    }

    /// The row in-chat find is on.
    private var findTarget: String? {
        guard conversation.findText != nil else { return nil }
        let matches = conversation.findMatches
        return matches.indices.contains(conversation.findIndex) ? matches[conversation.findIndex].id : nil
    }

    /// Brings a row into the window, scrolls it to the middle and flashes it once. A row already
    /// on screen (a passage just quoted) only flashes.
    private func land(on target: TranscriptItem, scrolls: Bool = true) async {
        let all = conversation.rows
        let key = conversation.displayID(for: target)
        if let index = all.firstIndex(where: { $0.id == target.id }) { bringIntoWindow(index, of: all) }
        if scrolls {
            isFollowing = false
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.smooth(duration: 0.35)) { position.scrollTo(id: key, anchor: .center) }
        }
        flashKey = key
        flashOn = true
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(.easeOut(duration: 0.8)) { flashOn = false }
        try? await Task.sleep(for: .milliseconds(850))
        if flashKey == key { flashKey = nil }
        // Rows that came in on the way and are well off screen go again.
        dropBelow()
        dropAbove()
    }

    /// Fixes the window's top once there are rows, so later rows only add below it.
    private func pinWindow() {
        let all = conversation.rows
        guard !all.isEmpty else { return }
        let key = conversation.displayID(for: all[firstShownIndex(in: all)])
        if key != firstShownKey { firstShownKey = key }
    }

    /// The next page of earlier messages, keeping the row that was first on screen where it is.
    /// Rows that went above while reading back come back first, exactly where they were
    /// (`bringBackAbove`). Then rows well below the screen go (`dropBelow`).
    private func showEarlier() {
        guard !isPrepending, !isAppending else { return }
        if !edge.droppedAbove.isEmpty { return bringBackAbove() }
        let all = conversation.rows
        let first = firstShownIndex(in: all)
        guard first > 0 else {
            // Everything held is on screen: ask the gateway for the page before it.
            guard conversation.hasEarlierMessages, !conversation.isLoadingEarlier else { return }
            Task {
                await conversation.loadEarlier()
                showEarlier()
            }
            return
        }
        let target = pageStart(in: all, above: first)
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
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG earlier page \(first)->\(target)") }
            #endif
            withTransaction(instant) { firstShownKey = key }
            Task { @MainActor in
                withTransaction(instant) { position.scrollTo(id: keep, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(250))
                isPrepending = false
                await withCheckedContinuation { done in NextFrame.run { done.resume() } }
                dropBelow()
            }
        }
    }

    /// Rows that went above the screen come back, a few a frame, each into the room it left
    /// (`aboveRoom`): the content keeps its length and nothing on screen moves.
    private func bringBackAbove() {
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        Task { @MainActor in
            for _ in 0..<(Self.pageSize / Self.fillStep) {
                guard let rows = edge.droppedAbove.last else { break }
                let all = conversation.rows
                guard let index = all.firstIndex(where: { conversation.displayID(for: $0) == rows.key }) else {
                    // Gone (a reload): no room is kept for them.
                    edge.droppedAbove = []
                    withTransaction(instant) { aboveRoom = 0 }
                    break
                }
                edge.droppedAbove.removeLast()
                let loadingChange = Self.loadingRoom * (rowRoomChange(first: firstShownIndex(in: all), to: index))
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print(String(format: "SCROLLLOG back above %@ %.0f", rows.key, rows.height)) }
                #endif
                withTransaction(instant) {
                    firstShownKey = rows.key
                    aboveRoom = edge.droppedAbove.isEmpty ? 0 : max(0, aboveRoom - rows.height - loadingChange)
                }
                await withCheckedContinuation { done in NextFrame.run { done.resume() } }
            }
            try? await Task.sleep(for: .milliseconds(250))
            isPrepending = false
            dropBelow()
        }
    }

    /// The loading row above the rows shown: more is held above them, or the gateway has more.
    private func showsLoadingRow(first: Int) -> Bool {
        first > 0 || conversation.hasEarlierMessages
    }

    /// 1 when the loading row appears as the first row shown goes from `first` to `next`, -1 when
    /// it goes, 0 otherwise.
    private func rowRoomChange(first: Int, to next: Int) -> CGFloat {
        let before = showsLoadingRow(first: first), after = showsLoadingRow(first: next)
        return before == after ? 0 : after ? 1 : -1
    }

    /// Back down near the last row shown while reading back: the rows after it go back in, a few
    /// a frame, below the screen (the top anchor: nothing on screen moves). Then rows well above
    /// the screen go (`dropAbove`).
    private func showLater() {
        guard let lastShownKey, !isAppending, !isPrepending else { return }
        let all = conversation.rows
        guard let last = all.firstIndex(where: { conversation.displayID(for: $0) == lastShownKey }) else {
            // The row went (a reload): through the end, as before.
            self.lastShownKey = nil
            return
        }
        let target = min(all.count - 1, last + Self.pageSize)
        guard target > last else {
            self.lastShownKey = nil
            return
        }
        let keys = (last + 1...target).map { conversation.displayID(for: all[$0]) }
        let reachesEnd = target == all.count - 1
        let answers = ConversationModel.answers(in: all[(last + 1)...target])
        var instant = Transaction()
        instant.disablesAnimations = true
        isAppending = true
        Task { @MainActor in
            await MarkdownCache.prewarm(answers)
            var added = 0
            while added < keys.count {
                added = min(keys.count, added + Self.fillStep)
                let key: String? = added == keys.count && reachesEnd ? nil : keys[added - 1]
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG later in \(added)/\(keys.count)") }
                #endif
                withTransaction(instant) { self.lastShownKey = key }
                await withCheckedContinuation { done in NextFrame.run { done.resume() } }
            }
            isAppending = false
            // Still at the last row shown (a quick scroll, or one resting there): the next rows.
            if !dropAbove(), self.lastShownKey != nil, edge.distance < Self.nearEdge { showLater() }
        }
    }

    /// Reading back: rows more than `keptBeyond` below the screen leave the window. Only rows
    /// below change, so with the top anchor the view keeps its place.
    private func dropBelow() {
        guard !isFollowing, !isPrepending, !isAppending, !edge.landing, !isGliding, flashKey == nil else { return }
        let all = conversation.rows
        let visible = Set(edge.visibleKeys)
        guard let lastVisible = all.lastIndex(where: { visible.contains(conversation.displayID(for: $0)) }) else { return }
        let end = windowEnd(in: all, from: firstShownIndex(in: all))
        let target = lastVisible + Self.keptBeyond
        guard end - 1 - target >= Self.trimSlack else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG drop below \(end - 1)->\(target) of \(all.count)") }
        #endif
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { lastShownKey = conversation.displayID(for: all[target]) }
    }

    /// Reading back down: rows more than `keptBeyond` above the screen leave the window, and the
    /// room they took stays (`aboveRoom`), so the content keeps its length and nothing on screen
    /// moves. They're measured first, a few rows at a time, to come back the same way.
    @discardableResult
    private func dropAbove() -> Bool {
        guard !isFollowing, !isPrepending, !isAppending, !edge.landing, !isGliding, flashKey == nil else {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG no drop above: following \(isFollowing) prepending \(isPrepending) appending \(isAppending)") }
            #endif
            return false
        }
        let all = conversation.rows
        let visible = Set(edge.visibleKeys)
        guard let firstVisible = all.firstIndex(where: { visible.contains(conversation.displayID(for: $0)) }) else { return false }
        let first = firstShownIndex(in: all)
        let target = firstVisible - Self.keptBeyond
        guard target - first >= Self.trimSlack else {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print("SCROLLLOG no drop above: first \(first), first on screen \(firstVisible)") }
            #endif
            return false
        }
        // The first row of each few, and the row that becomes first.
        var marks = Array(stride(from: first, to: target, by: Self.fillStep))
        marks.append(target)
        let keys = marks.map { conversation.displayID(for: all[$0]) }
        var instant = Transaction()
        instant.disablesAnimations = true
        isPrepending = true
        Task { @MainActor in
            defer {
                measuredKeys = []
                edge.frames = [:]
            }
            edge.frames = [:]
            measuredKeys = Set(keys)
            for _ in 0..<6 where keys.contains(where: { edge.frames[$0] == nil }) {
                await withCheckedContinuation { done in NextFrame.run { done.resume() } }
            }
            let frames = keys.compactMap { edge.frames[$0] }
            // Not measured (rows changed meanwhile), or the reader went on: another time.
            guard frames.count == keys.count, !isFollowing, !edge.landing, !isGliding,
                  let firstNow = conversation.rows.firstIndex(where: { conversation.displayID(for: $0) == keys[0] }),
                  firstNow == firstShownIndex(in: conversation.rows) else {
                isPrepending = false
                return
            }
            let dropped = zip(keys, zip(frames, frames.dropFirst())).map { key, pair in (key: key, height: pair.1.minY - pair.0.minY) }
            let removed = frames[frames.count - 1].minY - frames[0].minY
            let loadingChange = Self.loadingRoom * rowRoomChange(first: first, to: target)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") { print(String(format: "SCROLLLOG drop above %d->%d of %d, room +%.0f", first, target, all.count, removed - loadingChange)) }
            #endif
            withTransaction(instant) {
                firstShownKey = keys[keys.count - 1]
                aboveRoom += removed - loadingChange
            }
            edge.droppedAbove.append(contentsOf: dropped)
            await withCheckedContinuation { done in NextFrame.run { done.resume() } }
            try? await Task.sleep(for: .milliseconds(250))
            isPrepending = false
            if lastShownKey != nil, edge.distance < Self.nearEdge { showLater() }
        }
        return true
    }

    /// A row the app is about to scroll to goes into the window: rows between it and the window
    /// come in with it, and once the reader moves on, the ones well off screen go again.
    private func bringIntoWindow(_ index: Int, of all: [TranscriptItem]) {
        var instant = Transaction()
        instant.disablesAnimations = true
        if index < firstShownIndex(in: all) {
            withTransaction(instant) {
                firstShownKey = conversation.displayID(for: all[index])
                forgetRoomAbove()
            }
        }
        if lastShownKey != nil, index >= windowEnd(in: all, from: firstShownIndex(in: all)) {
            let last = index + Self.keptBeyond
            withTransaction(instant) { lastShownKey = last < all.count - 1 ? conversation.displayID(for: all[last]) : nil }
        }
    }

    /// Far back in the chat, to the end: the window becomes the end's page at once and the view
    /// goes to it (there's no gliding through rows that aren't there).
    private func showEndPage() {
        let all = conversation.rows
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            lastShownKey = nil
            if !all.isEmpty { firstShownKey = conversation.displayID(for: all[max(0, all.count - Self.pageSize)]) }
            forgetRoomAbove()
            scrollToLatest()
        }
    }

    /// The window moved to the end or to a row the app scrolls to: rows that went above don't
    /// come back into their room any more.
    private func forgetRoomAbove() {
        edge.droppedAbove = []
        if aboveRoom != 0 { aboveRoom = 0 }
    }

    private func rowView(_ item: TranscriptItem, date: Date?, extraTeams: [String], spokenReplies: Set<String>, latestReply: String?) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if let date {
                DateSeparator(date: date)
            }
            if let divider, divider.rowID == item.id {
                NewMessagesDivider(count: divider.count)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.contentSpace)).minY } action: { top in
                        edge.dividerTop = top
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }
            row(for: item, extraTeams: extraTeams, spokenReplies: spokenReplies, latestReply: latestReply)
        }
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
        /// Where the view is, as the point `ScrollPosition.scrollTo(y:)` takes (below the top bar).
        var top: CGFloat
        var height: CGFloat
        var inset: CGFloat
        var container: CGFloat
        /// The top of what's visible, under the top bar, in the content's coordinates.
        var visibleTop: CGFloat
    }

    /// Steers still waiting in the running turn show inside it; the rest after the transcript.
    private var settlingFollowUps: [FollowUpRecord] {
        let liveID = conversation.liveTurnID
        return conversation.followUps.filter { !($0.state == .steerWaiting && $0.turnID == liveID && liveID != nil) }
    }

    @Observable final class RunwayRoom {
        var height: CGFloat = 0
    }

    /// The end of the chat (see the end marker in `body`), with the runway below the newest turn.
    private struct TranscriptEnd: View {
        let room: RunwayRoom
        let bottomInset: CGFloat
        /// Where the end is in the content (its top, before the runway).
        let onMove: (CGFloat) -> Void

        var body: some View {
            Color.clear
                .frame(height: bottomInset)
                .id(TranscriptView.endID)
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(TranscriptView.contentSpace)).minY }, action: onMove)
                .padding(.top, room.height - 30) // no stack spacing above it
                .padding(.bottom, -bottomInset)
        }
    }

    final class EdgeTracker {
        /// Not measured yet: as far from the end as can be.
        var distance: CGFloat = .greatestFiniteMagnitude
        var flip = false
        var settle: Task<Void, Never>?
        /// Where the newest turn's message starts and the chat's content ends, in the content's
        /// own coordinates.
        var anchorTop: CGFloat?
        var tailEnd: CGFloat?
        /// The smallest bottom inset seen (the composer without the keyboard), and the room
        /// between the bars a turn fills.
        var minInset: CGFloat = .greatestFiniteMagnitude
        var viewport: CGFloat = 0
        /// The room between the bars as it is now (less than `viewport` while the keyboard is up).
        var room: CGFloat = 0
        /// The keyboard is on its way down: the runway takes the room it leaves already.
        var keyboardHiding = false
        /// A sent message glided to the top and sits there, not moved by hand since.
        var pinned = false
        /// The height between the bars.
        var container: CGFloat = 0
        /// Where the view is (`ScrollEdge.top`).
        var top: CGFloat = 0
        /// A message was just sent: the glide to it waits for the room after it.
        var landing = false
        /// The runway for the sent message has gone in; the glide goes once it's laid out.
        var landingArmed = false
        var landingFallback: Task<Void, Never>?
        /// Counts glides, so a glide waiting for its frame (or its end) knows it's still the latest.
        var glide = 0
        /// Where the New Messages line is, in the content's coordinates.
        var dividerTop: CGFloat?
        /// Where the rows in `measuredKeys` are, in the content's coordinates.
        var frames: [String: CGRect] = [:]
        /// Rows gone above the screen, nearest last: the first row of each few and the room
        /// they took (rows and spacing), so they come back exactly where they were.
        var droppedAbove: [(key: String, height: CGFloat)] = []
        /// The rows on screen, top to bottom (their display keys).
        var visibleKeys: [String] = []
        /// The window's next trim (`trimWindow`), once rows stop coming.
        var trim: Task<Void, Never>?
    }

    /// A row and the identity it's drawn under (`ConversationModel.displayID(for:)`).
    private struct DisplayRow {
        let key: String
        let item: TranscriptItem
    }

    /// The message you send takes its room at once (the chat glides it up to the top) and
    /// settles in with a little scale. Rows coming in while a turn is read from its start fade in
    /// where they belong: below the message, in room that's already there. Elsewhere (following
    /// the end) new rows open up their room as they come in (`GrowIn`), so the chat following them
    /// glides up instead of jumping by the row's height.
    private static func insertion(for item: TranscriptItem, holding: Bool) -> AnyTransition {
        switch item {
        case .user(let entry) where entry.sender == nil && entry.routineName == nil && entry.id.hasPrefix("local-"):
            .asymmetric(
                insertion: .scale(scale: 0.96, anchor: .bottomTrailing)
                    .combined(with: .opacity.animation(.easeOut(duration: 0.2))),
                removal: .identity
            )
        // The reply starting with your message: it fades in below it.
        case .assistant(let turn) where turn.isWorking:
            .asymmetric(insertion: .opacity, removal: .identity)
        default:
            holding
                ? .asymmetric(insertion: .opacity, removal: .identity)
                : .asymmetric(insertion: .growIn.combined(with: .opacity), removal: .identity)
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
        conversation.stableReferences(ReferenceContext(workspace: workspace, conversation: conversation, catalog: conversation.slashCatalog))
    }

    private static let endID = "transcript-end"
    nonisolated private static let contentSpace = "transcript-content"
    /// Between the top bar and a message sending put at the top.
    private static let landingGap: CGFloat = 14
    private static let bottomPadding: CGFloat = 12
    /// The glide of a sent message up to the top: off at once, eased into place, and done at a
    /// set time. (A spring's `.smooth(duration: 0.5)` crept the last few points for a while.)
    private static let landingDuration = 0.42
    private static let landingMotion = Animation.timingCurve(0.32, 0, 0.12, 1, duration: landingDuration)

    /// A message was sent: it becomes the turn the chat holds at the top. The glide waits a frame
    /// or two for the message's place and the room after it to be measured (`updateRunway`).
    private func beginLanding() {
        guard let entry = conversation.pendingUser else {
            isFollowing = true
            withAnimation(Self.rowsAnimation) { scrollToLatest() }
            return
        }
        #if DEBUG && os(iOS)
        FrameMonitor.shared.mark("send: landing begins")
        #endif
        // Sent from far back in the chat: the end's page first, and the glide starts from its end.
        let fromFarBack = lastShownKey != nil
        if fromFarBack { showEndPage() }
        // Not part of the send's animation: nothing on screen changes with it.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            anchorKey = conversation.displayID(for: .user(entry))
            holdsTurn = true
            isFollowing = true
            isGliding = !reduceMotion
            // Held where it is by a point, not by the end's id. A position held by id keeps that
            // view in place as the content changes: the runway going in below dragged the whole
            // chat up by its height in one frame, before the glide had begun.
            if !fromFarBack { position.scrollTo(y: edge.top) }
        }
        edge.anchorTop = nil
        edge.pinned = false
        edge.landing = true
        edge.landingArmed = false
        edge.landingFallback?.cancel()
        edge.landingFallback = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, edge.landing else { return }
            land()
        }
    }

    private func land() {
        cancelLanding()
        guard anchorKey != nil else { return endGlide() }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HERMES_SCROLL_LOG") {
            // (Formatted, not `Int(_:)`: the smallest inset is infinite until one is seen.)
            let numbers = [edge.anchorTop ?? -1, edge.tailEnd ?? -1, runway, edge.viewport, edge.minInset].map { String(format: "%.0f", Double($0)) }
            print("SCROLLLOG land anchorTop/tailEnd/runway/viewport/minInset=\(numbers.joined(separator: "/"))")
        }
        #endif
        if reduceMotion {
            scrollToAnchor()
            edge.pinned = true
            return
        }
        // The send's first frame (the message, the reply's row, the emptied composer) is its
        // heaviest. Started in it, the glide's clock ran while that frame drew, and the message
        // stood still, then leapt to catch up. Started on the frame after, it moves from its
        // first step.
        edge.glide += 1
        let glide = edge.glide
        NextFrame.run {
            guard edge.glide == glide else { return }
            guard anchorKey != nil, !isScrolledByHand else { return endGlide() }
            #if DEBUG && os(iOS)
            FrameMonitor.shared.mark("send: glide starts")
            #endif
            withAnimation(Self.landingMotion) { scrollToAnchor() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.landingDuration))
                guard edge.glide == glide else { return }
                endGlide()
                edge.pinned = true
            }
        }
    }

    /// The message is at the top (or the person took over): the loops move again.
    private func endGlide() {
        if isGliding {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { isGliding = false }
        }
    }

    private func cancelLanding() {
        edge.landing = false
        edge.landingArmed = false
        edge.landingFallback?.cancel()
    }

    /// The person scrolled while a message was on its way up: it stops where it is.
    private func abandonGlide() {
        cancelLanding()
        edge.glide += 1
        endGlide()
    }

    /// The newest turn's message to the top, a little under the bar. (A point scroll measures
    /// from under the top bar; scrolling to the message's id put it flush against the bar.)
    private func scrollToAnchor() {
        // Never measured (the message didn't show): the end, as before.
        guard let top = edge.anchorTop else { return scrollToLatest() }
        position.scrollTo(y: top - Self.landingGap)
    }

    /// The runway is the room under the top bar less what the newest turn already fills. It
    /// changes only below what's on screen, so it goes in without animation. Once it's in place,
    /// a pending glide goes.
    private func updateRunway() {
        var target: CGFloat = 0
        let room = edge.keyboardHiding || edge.room <= 0 ? edge.viewport : min(edge.room, edge.viewport)
        if anchorKey != nil, let top = edge.anchorTop, let end = edge.tailEnd, room > 0 {
            target = max(0, (room - (end - top)).rounded(.up))
        }
        if abs(target - runway) > 0.5 {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { runwayRoom.height = target }
            if edge.landing, edge.anchorTop != nil { edge.landingArmed = true }
        } else if edge.landing, edge.anchorTop != nil {
            land()
        }
    }

    /// What stays put when the content changes size: the bottom while following the end on the
    /// Mac (the content moves up in the same layout pass as it grows: a scroll request resolves
    /// against the previous frame, so following by scrolling trailed every change by a frame) and
    /// while earlier messages go in above; the top otherwise (reading back, opening a fold).
    private var sizeChangeAnchor: UnitPoint {
        #if os(macOS)
        if isFollowing, !isScrolledByHand, !keepsTop, !holdsTurn { return .bottom }
        #endif
        return isPrepending ? .bottom : .top
    }

    /// Once things stop moving, make sure the end really is on the composer: a change that lands
    /// while a scroll is under way can leave it short.
    private func settleSoon() {
        edge.settle?.cancel()
        edge.settle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isFollowing, !isScrolledByHand, !keepsTop, !holdsTurn, !edge.landing, abs(edge.distance) > 1 else { return }
            withAnimation(.easeOut(duration: 0.24)) { scrollToLatest() }
        }
    }

    private func scrollToLatest() {
        #if os(macOS)
        // The very end, above the composer: the bottom anchor holds on to the content only while
        // it's exactly there (the end marker sits the stack's bottom padding short of it).
        position.scrollTo(edge: .bottom)
        #else
        // The newest turn keeps its room after it (`runway`): the end of what's there goes on the
        // composer, not the end of the room. (A point scroll puts that point under the top bar.)
        if runway > 0, let end = edge.tailEnd, edge.container > 0 {
            position.scrollTo(y: end - edge.container)
            return
        }
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
            // A mirror that changes only with the count: reading `live` here redrew the whole
            // transcript, and diffed every edit, on every streamed word.
            working: conversation.isWorking, liveEdits: conversation.liveEditedFiles,
            gateway: conversation.usesGateway
        )
    }

    private static func editsFiles(_ item: TranscriptItem) -> Bool {
        if case .assistant(let turn) = item { return !TurnFileEdits.paths(in: turn).isEmpty }
        return false
    }

    /// How rows come and go (`ConversationModel.animateRows` uses the same).
    static let rowsAnimation = Animation.smooth(duration: 0.36)

    @ViewBuilder
    private func row(for item: TranscriptItem, extraTeams: [String] = [], spokenReplies: Set<String> = [], latestReply: String? = nil) -> some View {
        switch item {
        case .user(let entry):
            if let answer = WidgetAnswer.parse(entry.text), !answer.mid.isEmpty {
                // A widget's answer shows as what was done, not as its message, and once: Try Again
                // sends the same one again (`docs/widgets.md` §5).
                if !conversation.widgetFacts.isRepeat(rowID: entry.id, of: answer) { ActionBubble(answer: answer) }
            } else if entry.isSteer {
                FollowUpBubble(text: entry.text, caption: .steerRead(after: nil))
            } else if let caption = conversation.caption(for: entry) {
                CaptionedUserRow(caption: caption) {
                    UserBubble(entry: entry, images: conversation.images(for: entry), conversation: conversation.isBotChat ? nil : conversation, reactions: conversation.reactions[entry.id] ?? [])
                }
            } else if let sender = entry.sender {
                AgentMessageRow(entry: entry, sender: sender, roster: workspace.roster)
            } else if let routine = entry.routineName {
                RoutineDeliveryRow(entry: entry, name: routine)
            } else if let command = command(in: entry) {
                CommandBubble(name: command.name, argument: command.argument, isBotChat: conversation.isBotChat)
            } else {
                UserBubble(entry: entry, images: conversation.images(for: entry), conversation: conversation.isBotChat ? nil : conversation, reactions: conversation.reactions[entry.id] ?? [])
                    .modifier(SpokenMark(isSpoken: SpokenMessages.shared.isSpoken(entry.id, session: conversation.sessionID)))
            }
        case .assistant(let turn):
            TurnRow(
                listed: turn,
                conversation: conversation,
                isLive: turn.id == conversation.liveOutline?.id,
                onBranch: branchAction(for: turn.id),
                extraTeamIDs: extraTeams,
                memoryContext: MemoryNoteContext(workspace: workspace, conversation: conversation),
                rowKey: conversation.displayID(for: item),
                answersVoice: !spokenReplies.contains(turn.id) ? .none : turn.id == latestReply ? .latest : .earlier
            )
            .equatable()
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
            CommandRow(entry: command, isBotChat: conversation.isBotChat, job: conversation.job(forCommand: command.id),
                       setup: conversation.workspace?.setup)
        }
    }

    /// A row of a call that ended: hidden behind the call's card unless its Transcript is open,
    /// with the card after the call's last row.
    @ViewBuilder
    private func callFolded(_ item: TranscriptItem, folds: CallFolding.Folds, calls: [CallRecord], @ViewBuilder row: () -> some View) -> some View {
        // A group, not a stack: a hidden row leaves no gap behind.
        Group {
            if folds.rows[item.id].map(openCalls.contains) ?? true {
                row()
            }
            if let id = folds.cardAfter[item.id], let record = calls.first(where: { $0.id == id }) {
                CallSummaryCard(
                    record: record,
                    showsTurns: Binding(get: { openCalls.contains(id) }, set: { if $0 { openCalls.insert(id) } else { openCalls.remove(id) } }),
                    onTalkAgain: { TalkCenter.shared.start(conversation: conversation, workspace: workspace) }
                )
            }
        }
    }

    /// A reply's row. The running reply reads its turn from the chat here, so a streamed word
    /// redraws this row only: the list has it by its outline (`ConversationModel.listRows`),
    /// which holds still meanwhile. Every reply is this one view, so one that finishes keeps
    /// its place and its state.
    private struct TurnRow: View, Equatable {
        /// The stored reply, or the running one's outline.
        let listed: AssistantTurn
        let conversation: ConversationModel
        let isLive: Bool
        let onBranch: BranchAction?
        let extraTeamIDs: [String]
        let memoryContext: MemoryNoteContext?
        let rowKey: String
        /// The reply answers a voice message (`AssistantTurnView.answersVoice`).
        let answersVoice: AssistantTurnView.SpokenReply
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.listed == rhs.listed && lhs.conversation === rhs.conversation && lhs.isLive == rhs.isLive
                && lhs.onBranch == rhs.onBranch && lhs.extraTeamIDs == rhs.extraTeamIDs
                && lhs.memoryContext == rhs.memoryContext && lhs.rowKey == rhs.rowKey
                && lhs.answersVoice == rhs.answersVoice
        }

        var body: some View {
            let turn = isLive ? conversation.liveTurn ?? listed : listed
            // Every chat, a Bot's included, shows the header's live line from the moment the
            // message goes: no typing bubble, never an empty gap. Until Hermes has the message it
            // says so ("Waiting for MacBook Pro…"), then "Thinking…" (`docs/chat.md` §4, §4a).
            let delivery = isLive && turn.answer.isEmpty && turn.steps.isEmpty ? conversation.deliveryNote : nil
            AssistantTurnView(
                turn: turn,
                pendingSteers: turn.id == conversation.liveTurnID ? conversation.followUps.filter { $0.state == .steerWaiting && $0.turnID == turn.id } : [],
                status: turn.isWorking ? delivery.map { TranscriptView.words(for: $0, gateway: conversation.gatewayName) } ?? conversation.liveStatus : nil,
                statusWaits: delivery == .waiting,
                isStopping: turn.isWorking && conversation.isStopping,
                onBranch: onBranch,
                extraTeamIDs: extraTeamIDs,
                memoryContext: memoryContext,
                rowKey: rowKey,
                answersVoice: answersVoice
            )
            .equatable()
        }
    }

    /// What the live line says while the message is on its way.
    static func words(for delivery: ConversationModel.Delivery, gateway: String) -> String {
        switch delivery {
        case .sending: String(localized: "Sending…")
        case .waiting: String(localized: "Waiting for \(gateway)…")
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

// MARK: - Unread (`docs/inbox.md` §4)

extension TranscriptView {
    /// The transcript's part of the inbox (`docs/inbox.md` §4), applied apart so the body stays
    /// quick to type-check.
    struct InboxBehaviour: ViewModifier {
        let view: TranscriptView
        let rowCount: Int
        let lastRowID: String?

        func body(content: Content) -> some View {
            view.inbox(content, rowCount: rowCount, lastRowID: lastRowID)
        }
    }

    fileprivate func inbox(_ content: some View, rowCount: Int, lastRowID: String?) -> some View {
        content
            .sensoryFeedback(.selection, trigger: unseenBelow.count) { old, new in new > old && !isFollowing }
            .sensoryFeedback(.impact(weight: .light), trigger: jumps)
            // Something new at the end while the reader is up in the history: the pill counts it.
            // (Earlier pages coming in above don't change the last row.)
            .onChange(of: lastRowID) {
                guard !isFollowing else { return }
                arrivalsBelow += 1
                if let last = conversation.rows.last, UnreadCounter.counts(last), !unseenBelow.contains(last.id) { unseenBelow.append(last.id) }
            }
            // A reply finished below while the reader is up in the history.
            .onChange(of: conversation.completedTurns) {
                guard !isFollowing, let turn = conversation.rows.last(where: { if case .assistant = $0 { true } else { false } }),
                      UnreadCounter.counts(turn), !unseenBelow.contains(turn.id) else { return }
                unseenBelow.append(turn.id)
            }
            // What's on screen: the line's messages count as seen as they come into view, and this
            // device remembers how far it got (`docs/inbox.md` §4).
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.4) { keys in
                sawRows(keys)
            }
            // What's on screen as the chat appears counts from then.
            .onChange(of: settled) { _, shown in
                if shown { sawRows(edge.visibleKeys) }
            }
            // Read on the gateway once the newest message has been on screen for a second.
            .task(id: ReadTrigger(atEnd: isFollowing && settled, rows: rowCount, active: scenePhase == .active && isReadingWindow,
                                  lastActive: conversation.stableKey.flatMap { workspace.session(forKey: $0)?.lastActive }
                                    ?? conversation.botName.flatMap { workspace.roster?.bot(named: $0)?.lastActive })) {
                guard isFollowing, settled, scenePhase == .active, isReadingWindow else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, isFollowing else { return }
                markRead()
            }
            // VoiceOver hears the turn three times: "Ada is thinking", "Replying", "Reply finished".
            // Never each step, never the words as they stream (`docs/chat.md` §4a).
            .onChange(of: replyPhase) { old, new in
                guard let words = ReplyPhase.announcement(from: old, to: new, name: botTitle ?? "Hermes") else { return }
                AccessibilityNotification.Announcement(words).post()
            }
            .onChange(of: conversation.flashRequest) { _, request in
                guard let request, let item = conversation.rows.first(where: { $0.id == request.rowID }) else { return }
                Task { await land(on: item, scrolls: !isRowVisible(request.rowID)) }
            }
            .onChange(of: conversation.jumpToLatestRequests) { jumpToEnd() }
            .onChange(of: isFollowing, initial: true) { _, following in
                if conversation.isReadingBack == following { conversation.isReadingBack = !following }
            }
            .accessibilityRotor("Unread") {
                ForEach(unreadRotorKeys, id: \.self) { key in
                    AccessibilityRotorEntry(Text(key == unreadRotorKeys.first && divider != nil ? "New messages" : "New message"), id: key)
                }
            }
            .environment(\.quoteActions, QuoteActions(reply: { item, author, passage in
                conversation.reply(to: item.id, author: author, passage: passage)
            }, choose: { item, author, text in
                choosingQuote = QuoteChoice(item: item, author: author, text: text)
            }, select: { author, text in
                selectingText = SelectTextChoice(author: author, text: text)
            }, jump: { rowID in
                guard let item = conversation.rows.first(where: { $0.id == rowID }) else { return }
                Task { await land(on: item) }
            }, assistantName: botTitle ?? "Hermes", chat: conversation.inboxKey))
            .sheet(item: $choosingQuote) { choice in
                ChooseQuoteSheet(author: choice.author, text: choice.text) { passage in
                    conversation.reply(to: choice.item.id, author: choice.author, passage: passage)
                }
            }
            #if os(iOS)
            .sheet(item: $selectingText) { choice in
                SelectTextSheet(author: choice.author, text: choice.text)
            }
            // On iPhone and iPad a reply's words aren't selectable in place (Select Text in its
            // menu instead): every selectable text made laying out a chat a fifth heavier as it
            // opened and scrolled.
            .environment(\.selectsText, Self.selectsInPlace)
            #endif
            .onDisappear(perform: rememberPlace)
    }

    struct ReadTrigger: Hashable {
        let atEnd: Bool
        let rows: Int
        let active: Bool
        let lastActive: Date?
    }

    struct QuoteChoice: Identifiable {
        let item: TranscriptItem
        let author: String
        let text: String
        var id: String { item.id }
    }

    /// Debug `-HERMES_INLINE_SELECTION YES` selects in place as before, to measure the difference.
    private static var selectsInPlace: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "HERMES_INLINE_SELECTION")
        #else
        false
        #endif
    }

    struct SelectTextChoice: Identifiable {
        let author: String
        let text: String
        var id: String { text }
    }

    /// What the pill says: new messages below (the first tap goes to the first of them), else
    /// the running turn, else the arrow.
    fileprivate var pill: JumpPill {
        JumpPill.choose(mention: nil, newCount: unseenBelow.count, firstNewRowID: unseenBelow.first,
                        isLive: conversation.isWorking || conversation.runsElsewhere)
    }

    fileprivate static func activityLine(_ conversation: ConversationModel, _ workspace: BotWorkspace) -> ActivityLine? {
        guard conversation.isWorking || conversation.runsElsewhere, let key = conversation.inboxKey else { return nil }
        return workspace.activity.line(for: key)
    }

    /// The pill reads the activity line itself: it changes as the turn works, and read by the
    /// transcript it redrew the whole list each time.
    private struct ActivityJumpPill: View {
        let pill: JumpPill
        let conversation: ConversationModel
        let workspace: BotWorkspace
        let face: BotAppearance?
        let action: () -> Void

        var body: some View {
            JumpPillView(pill: pill, activity: TranscriptView.activityLine(conversation, workspace), face: face, action: action)
        }
    }

    /// Where the running turn is, for VoiceOver: thinking once Hermes has the message, then
    /// replying.
    fileprivate var replyPhase: ReplyPhase {
        if conversation.isReplying { return .replying }
        return conversation.turnMood == .idle ? .idle : .thinking
    }

    /// The Bot's name in its chat.
    fileprivate var botTitle: String? {
        conversation.botName.flatMap { workspace.roster?.bot(named: $0)?.title }
    }

    /// A Bot chat's pill leads with its face (`newMessagesPillBot`).
    fileprivate var botFace: BotAppearance? {
        guard let name = conversation.botName, let roster = workspace.roster, let bot = roster.bot(named: name) else { return nil }
        return roster.appearance(for: bot)
    }

    fileprivate var unreadRotorKeys: [String] {
        let rows = conversation.listRows
        var ids = unseenBelow
        if let divider, !ids.contains(divider.rowID) { ids.insert(divider.rowID, at: 0) }
        var seen = Set<String>()
        return ids.compactMap { id in rows.first { $0.id == id }.map(conversation.displayID(for:)) }.filter { seen.insert($0).inserted }
    }

    /// The pill: to the first new message, then (or with nothing new) to the end.
    fileprivate func jump() {
        jumps += 1
        if case .newMessages(_, let first) = pill, !jumpedToFirst {
            jumpedToFirst = true
            reveal(first)
        } else {
            jumpToEnd()
        }
    }

    /// The end of the chat, following it again: what's there is read (⌘↓, the pill).
    fileprivate func jumpToEnd() {
        isFollowing = true
        holdsTurn = false
        jumpedToFirst = false
        unseenBelow = []
        if lastShownKey != nil {
            showEndPage()
        } else {
            withAnimation(Theme.spring) { scrollToLatest() }
        }
        markRead()
    }

    /// A row a quarter of the way down, brought into the window first.
    fileprivate func reveal(_ rowID: String) {
        let all = conversation.rows
        guard let index = all.firstIndex(where: { $0.id == rowID }) else { return }
        let key = conversation.displayID(for: all[index])
        bringIntoWindow(index, of: all)
        isFollowing = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { position.scrollTo(id: key, anchor: UnitPoint(x: 0.5, y: 0.25)) }
            try? await Task.sleep(for: .milliseconds(450))
            followIfAtEnd()
            dropBelow()
            dropAbove()
        }
    }

    /// A scroll the app made (not the reader) that ended at the end: the chat follows again,
    /// and what's there is read a second later.
    fileprivate func followIfAtEnd() {
        guard !isFollowing, !isScrolledByHand, edge.distance <= 72, lastShownKey == nil else { return }
        isFollowing = true
        jumpedToFirst = false
    }

    fileprivate func isRowVisible(_ rowID: String) -> Bool {
        guard let item = conversation.rows.first(where: { $0.id == rowID }) else { return false }
        return edge.visibleKeys.contains(conversation.displayID(for: item))
    }

    /// Rows came on screen: the new ones above them count as seen, and this device remembers how
    /// far it got.
    fileprivate func sawRows(_ keys: [String]) {
        edge.visibleKeys = keys
        // Laid out out of sight while the chat opens isn't seen.
        guard settled, !keys.isEmpty else { return }
        let rows = conversation.rows
        let shown = Set(keys)
        guard let lastIndex = rows.lastIndex(where: { shown.contains(conversation.displayID(for: $0)) }) else { return }
        if let chat = conversation.inboxKey {
            let previous = workspace.unread.seenThrough(chat).flatMap { id in rows.lastIndex { $0.id == id } } ?? -1
            if lastIndex > previous { workspace.unread.setSeenThrough(chat, rowID: rows[lastIndex].id) }
        }
        if !unseenBelow.isEmpty {
            let remaining = unseenBelow.filter { id in (rows.firstIndex { $0.id == id } ?? .max) > lastIndex }
            if remaining != unseenBelow { unseenBelow = remaining }
        }
        if unseenBelow.isEmpty, jumpedToFirst { jumpedToFirst = false }
    }

    /// Read on the gateway: the newest message has been on screen for a second in the window in
    /// front, or the reader jumped to it; a Bot Chat too, also while the Bot works (`docs/inbox.md`
    /// §4). Opening a chat partway up, a window behind another or a locked Mac reads nothing.
    fileprivate func markRead() {
        guard let key = conversation.inboxKey, BotRoster.isInFront, isReadingWindow else { return }
        if let last = conversation.rows.last { workspace.unread.setSeenThrough(key, rowID: last.id) }
        workspace.unread.markRead(key)
    }

    /// Opens at the New Messages line, a quarter of the way down, with a little of what was read
    /// above it; when everything new fits, at the end with the line in view. Returns whether the
    /// chat opened at the line.
    fileprivate func openAtNew(_ opening: UnreadStore.Opening) async -> Bool {
        var marker = NewMessagesMarker.find(in: conversation.rows, since: opening.since, seenThrough: opening.seenThrough)
        // The rows this device kept may stop short of what's new: give the gateway a moment.
        var waited = 0
        while marker == nil, conversation.loadState != .loaded, waited < 1200, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 100
            marker = NewMessagesMarker.find(in: conversation.rows, since: opening.since, seenThrough: opening.seenThrough)
        }
        LoadTrace.mark(conversation.stableKey, "new messages line: \(marker.map { "above \($0.rowID), \($0.count) new" } ?? "none") in \(conversation.rows.count) rows")
        guard let marker, !Task.isCancelled else { return false }
        let all = conversation.rows
        guard let index = all.firstIndex(where: { $0.id == marker.rowID }) else { return false }
        divider = marker
        unseenBelow = all[index...].filter(UnreadCounter.counts).map(\.id)
        guard openChatsAt == .firstUnread else { return false }
        // The whole page goes in at once, so filling the window later doesn't move the line.
        let windowStart = min(index, max(0, all.count - Self.pageSize))
        if windowStart < firstShownIndex(in: all) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { firstShownKey = conversation.displayID(for: all[windowStart]) }
        }
        // A lot new: a page past the line to begin with; the rest comes in as it's read.
        if index + Self.pageSize + Self.keptBeyond < all.count - 1 {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { lastShownKey = conversation.displayID(for: all[index + Self.pageSize]) }
        }
        isFollowing = false
        for _ in 0..<12 where edge.dividerTop == nil {
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(16))
        guard let top = edge.dividerTop else { return false }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { position.scrollTo(y: max(0, top - edge.container * 0.25)) }
        try? await Task.sleep(for: .milliseconds(60))
        // Everything new fits on screen: open at the end; the line is still there.
        if let end = edge.tailEnd, end - top <= edge.container - 24 {
            isFollowing = true
            withTransaction(instant) { scrollToLatest() }
            try? await Task.sleep(for: .milliseconds(60))
        }
        followIfAtEnd()
        return true
    }

    /// Opens where the chat was left scrolled up (`docs/inbox.md` §4).
    fileprivate func openWhereLeft() async -> Bool {
        guard let key = conversation.inboxKey, let rowID = workspace.unread.scrollRow(key) else { return false }
        let all = conversation.rows
        guard let index = all.firstIndex(where: { $0.id == rowID }) else { return false }
        let windowStart = min(index, max(0, all.count - Self.pageSize))
        var instant = Transaction()
        instant.disablesAnimations = true
        if windowStart < firstShownIndex(in: all) {
            withTransaction(instant) { firstShownKey = conversation.displayID(for: all[windowStart]) }
        }
        // A page past it, not every row to the end (`lastShownKey`).
        if index + Self.pageSize < all.count - 1 {
            withTransaction(instant) { lastShownKey = conversation.displayID(for: all[index + Self.pageSize]) }
        }
        isFollowing = false
        try? await Task.sleep(for: .milliseconds(16))
        withTransaction(instant) { position.scrollTo(id: conversation.displayID(for: all[index]), anchor: .top) }
        try? await Task.sleep(for: .milliseconds(60))
        return true
    }

    /// Leaving: a chat left scrolled up opens there next time.
    fileprivate func rememberPlace() {
        guard let key = conversation.inboxKey else { return }
        guard !isFollowing, let top = edge.visibleKeys.first,
              let item = conversation.rows.first(where: { conversation.displayID(for: $0) == top }) else {
            workspace.unread.setScrollRow(key, rowID: nil)
            return
        }
        workspace.unread.setScrollRow(key, rowID: item.id)
    }
}

/// Reply with a quote from a message (`docs/inbox.md` §4): the menu's Reply, a swipe, or chosen
/// words; and a quote's way back to its passage.
struct QuoteActions: Equatable {
    var reply: @MainActor (TranscriptItem, String, String) -> Void = { _, _, _ in }
    var choose: @MainActor (TranscriptItem, String, String) -> Void = { _, _, _ in }
    /// Select Text: a reply's words in a sheet to select and copy (author, text).
    var select: @MainActor (String, String) -> Void = { _, _ in }
    var jump: @MainActor (String) -> Void = { _ in }
    /// Who the assistant's replies are from: "Hermes", or the Bot.
    var assistantName = "Hermes"
    /// The chat this is, for where its quotes came from (`QuoteMemory`).
    var chat: String?
    /// Off outside a transcript (previews, the welcome tour).
    var isEnabled = true

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var quoteActions = QuoteActions(isEnabled: false)
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
    let conversation: ConversationModel
    let retry: () -> Void
    let reload: () -> Void
    let dismiss: () -> Void
    @State private var addingKey = false
    @State private var choosingProvider = false
    @State private var keySaved = false
    @State private var signingIn = false
    @State private var signedIn = false
    @State private var fixFailed: String?

    /// A provider that refused Hermes's key or sign-in, or none set up (`docs/setup.md` §4.3).
    private var setup: SetupStatus? {
        failure.provider?.status(gatewayName: conversation.gatewayName)
    }

    private var canAddKey: Bool {
        if case .key? = failure.provider?.kind { return setup?.fix != nil && conversation.canSaveProviderKey }
        return false
    }

    private var canSignIn: Bool {
        (failure.provider?.signsInFromApp ?? false) && conversation.canSaveProviderKey && !signedIn
    }

    /// What the card says once the fix worked.
    private var fixed: String? {
        if keySaved { return String(localized: "Key saved on \(conversation.gatewayName). Try again.") }
        if signedIn { return String(localized: "Signed in again. Try again.") }
        return nil
    }

    private var canChooseProvider: Bool {
        failure.provider?.kind == .notConfigured && conversation.canSaveProviderKey && conversation.workspace != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                // Hermes's own words are already in the turn above, as its failure note.
                Text(fixed ?? setup?.detail ?? failure.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
            } icon: {
                Image(systemName: fixed != nil ? "checkmark.circle.fill" : (setup != nil ? "key.fill" : "exclamationmark.triangle.fill"))
                    .foregroundStyle(fixed != nil ? Theme.success : Theme.warning)
            }
            if signingIn {
                HStack(spacing: 8) {
                    Spinner()
                    Text("Waiting for the sign-in in the browser…")
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            } else if let fixFailed {
                Text(fixFailed)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let setup, fixed == nil, !canAddKey, !canChooseProvider, !canSignIn || fixFailed != nil {
                SetupSteps(steps: setup.steps)
                if let docs = setup.docs {
                    SetupDocsLink(url: docs).font(.footnote)
                }
            }
            HStack(spacing: 8) {
                if canAddKey, !keySaved {
                    Button(setup?.fix?.title ?? String(localized: "Add Key…")) { addingKey = true }
                        .prominentGlassButton()
                } else if canSignIn, let problem = failure.provider {
                    Button(setup?.fix?.title ?? String(localized: "Sign In…")) { signIn(problem) }
                        .prominentGlassButton()
                        .disabled(signingIn)
                } else if canChooseProvider {
                    Button(setup?.fix?.title ?? String(localized: "Choose a Provider…")) { choosingProvider = true }
                        .prominentGlassButton()
                }
                if failure.canRetry {
                    if (canAddKey && !keySaved) || canSignIn || canChooseProvider {
                        Button("Try Again", action: retry).glassButton()
                    } else {
                        Button("Try Again", action: retry).prominentGlassButton()
                    }
                } else {
                    Button("Reload", action: reload)
                        .prominentGlassButton()
                    // Hermes didn't confirm it got the message: sending it again is the person's call.
                    if failure.mayResend {
                        Button("Send Again", action: retry).glassButton()
                    }
                }
                Button("Dismiss", action: dismiss)
                    .glassButton()
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.Radius.card)
        .sheet(isPresented: $addingKey) {
            if let problem = failure.provider {
                ProviderKeySheet(problem: problem, gatewayName: conversation.gatewayName) { key in
                    try await conversation.saveProviderKey(key, for: problem)
                    keySaved = true
                }
            }
        }
        .sheet(isPresented: $choosingProvider) {
            if let workspace = conversation.workspace {
                SetupFlowView(workspace: workspace, startAt: .model, modelOnly: true) { choosingProvider = false }
                    #if os(macOS)
                    .frame(width: 560, height: 680)
                    #endif
            }
        }
    }

    private func signIn(_ problem: ProviderProblem) {
        signingIn = true
        fixFailed = nil
        Task {
            defer { signingIn = false }
            do {
                if try await conversation.signInToProvider(problem) {
                    signedIn = true
                } else {
                    fixFailed = String(localized: "The sign-in didn't finish. Try again, or run the command below.")
                }
            } catch {
                fixFailed = (error as? BackendClient.Failure)?.errorDescription ?? error.localizedDescription
            }
        }
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

    private nonisolated struct OfferedSize: Layout {
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

    nonisolated var animatableData: Double {
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

/// A transcript row, as proposed, with its edges its own frame's. The transcript's stack lines its
/// rows up by their leading edge and asks each where that is; a row answers by asking its own
/// stacks all the way down, measuring their text, on every layout pass. Rows that grew in had
/// `HeightFraction` to stop that, but the reply being written fades in instead, so each redraw of
/// it had the stack measure the whole reply again.
private nonisolated struct RowEdges: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }
}

/// Lays its content out as proposed and claims only `fraction` of its height (the content draws
/// past it, top-aligned). The proposal passes through untouched: at full height it changes
/// nothing, so the lazy stack measures rows exactly as without it.
private nonisolated struct HeightFraction: Layout {
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

/// A turn as VoiceOver hears it (`docs/chat.md` §4a).
enum ReplyPhase: Equatable {
    case idle, thinking, replying

    static func announcement(from old: Self, to new: Self, name: String) -> String? {
        switch (old, new) {
        case (.idle, .thinking): String(localized: "\(name) is thinking")
        case (_, .replying) where old != .replying: String(localized: "Replying")
        case (.thinking, .idle), (.replying, .idle): String(localized: "Reply finished")
        default: nil
        }
    }
}
