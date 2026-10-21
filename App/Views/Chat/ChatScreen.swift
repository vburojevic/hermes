import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// One conversation: transcript, composer, and the toolbar with the model picker.
struct ChatScreen: View {
    @Bindable var conversation: ConversationModel
    let workspace: BotWorkspace
    /// Set on compact layouts, where the sidebar is a drawer.
    var onToggleSidebar: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(PreferenceKey.haptics) private var hapticsEnabled = true
    @State private var composerFocused = false
    /// The bottom bar's glass: the approval card and error banner grow out of the composer's.
    @Namespace private var bottomGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Heights for lifting the composer to the middle of an empty chat. Content plus bar is the
    // same however high the composer sits, so the lift never feeds back into itself.
    @State private var contentHeight: CGFloat = 0
    @State private var barHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var chipsHeight: CGFloat = 0
    @State private var lift: CGFloat = 0
    /// Where the top bar (and any banner under it) ends: menus above the composer stop there.
    @State private var ceiling: CGFloat?
    @State private var showsPermissions = false
    /// The card stepped aside for the dock (`docksWhileTyping`), changed with an animation.
    @State private var docksRequest = false
    /// The chat with its inspector, for choosing where the Team opens.
    @State private var screenSize: CGSize = .zero

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    /// The Inspector sits beside the chat on the Mac and iPad in landscape; iPhone and iPad in
    /// portrait use its sheet (`docs/inspector.md` §1).
    private var usesInspectorPanel: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular && screenSize.width > screenSize.height && screenSize.width >= 700
        #endif
    }

    /// The Team opens in the Inspector's Team tab; on iPhone a helper still pushes its own page.
    private var helperNavigator: HelperNavigator {
        let store = conversation.helpers
        let inspector = conversation.inspector
        let helpersInInspector = isWide
        return HelperNavigator(
            openTeam: { id in
                store.pushedHelper = nil
                store.shownHelper = nil
                inspector.openTeam(id)
            },
            openHelper: { helperID, teamID in
                if helpersInInspector {
                    store.shownHelper = helperID
                    inspector.openTeam(teamID)
                } else {
                    store.pushedHelper = helperID
                }
            }
        )
    }

    /// Set when this is a Bot's Bot Chat.
    private var roster: BotRoster? {
        conversation.isBotChat ? workspace.roster : nil
    }

    /// A new chat in a project shows the project's own suggestions above the composer.
    private var startsInProject: Bool {
        conversation.sessionID == nil && !conversation.isBotChat && workspace.projects.isAvailable
            && (conversation.placement ?? workspace.projects.defaultPlacement).projectID != nil
    }

    /// Wide layouts centre the composer on an empty chat, like Grok on the web and Mac.
    private var centersComposer: Bool {
        isWide && conversation.isKnownEmpty
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            CeilingMarker(ceiling: $ceiling)
            // The screen stays as chats change (switching is a data change, not a rebuild of
            // the toolbar and composer); the chat's own content starts fresh for each one.
            content
                .id(ObjectIdentifier(conversation))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; refitLift() }
        .safeAreaBar(edge: .bottom) {
            bottomBar
                .environment(\.composerCeiling, ceiling)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0; refitLift() }
        }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                if let roster {
                    BotModeBanner(roster: roster)
                } else {
                    ConnectionBanner(workspace: workspace)
                }
                // ⌘F: find in the loaded chat (`docs/search.md` §2).
                if conversation.findText != nil {
                    FindInChatBar(conversation: conversation)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: conversation.findText == nil)
        }
        #if os(macOS)
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
        .environment(\.helperNavigator, helperNavigator)
        .environment(\.inspectorModel, conversation.inspector)
        .modifier(HelperPresentation(conversation: conversation, workspace: workspace, navigator: helperNavigator))
        #if os(macOS)
        // The Inspector makes the chat a split view column, sized by AppKit from the chat's
        // minimum. A question card counts at its narrowest, picks as tall as their text, so with
        // one up that minimum passed the window's height: the chat was laid out taller than its
        // window, and while the window wasn't on screen AppKit kept re-solving it until it threw
        // (`docs/development.md`). The chat takes the room it's given.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        #endif
        // The Inspector: tabs for what the chat shows, beside it or in a sheet.
        .modifier(InspectorPresentation(conversation: conversation, workspace: workspace, usesPanel: usesInspectorPanel))
        #if os(iOS)
        // Outside the inspector column: inside it, iPad drops the chat's toolbar (model picker,
        // New Chat) even while the inspector is closed.
        .toolbar { toolbar }
        #endif
        // Review, Undo, the timeline and the off state (`docs/checkpoints.md`).
        .modifier(CheckpointSheets(model: conversation.checkpoints))
        // Hermes asks before switching to an expensive model (`config.set` → `confirm_required`).
        .alert(
            String(localized: "Switch to \(ModelNames.display(conversation.modelConfirmation?.selection.model ?? ""))?"),
            isPresented: Binding(get: { conversation.modelConfirmation != nil }, set: { if !$0 { conversation.modelConfirmation = nil } }),
            presenting: conversation.modelConfirmation
        ) { confirmation in
            Button(String(localized: "Switch")) { conversation.confirmModel(confirmation) }
            Button(String(localized: "Keep Current Model"), role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message.isEmpty ? String(localized: "Hermes asks before switching to this model.") : confirmation.message)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screenSize = $0 }
        // Steer from the inspector: the chat's composer takes the note.
        .onChange(of: conversation.helperSteerTarget) { _, target in
            if target != nil, isWide { composerFocused = true }
        }
        .navigationTitle(navigationTitle)
        .toolbarTitleDisplayMode(.inline)
        .task(id: conversation.id) {
            conversation.loadIfNeeded()
        }
        // First send in an empty chat on iPad and Mac: the centred composer glides to the bottom.
        .onChange(of: centersComposer) {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.42, extraBounce: 0.04)) {
                updateLift()
            }
        }
        .modifier(ChatHaptics(conversation: conversation, enabled: hapticsEnabled))
        .onChange(of: docksWhileTyping) { _, docks in
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.cardMotion) { docksRequest = docks }
        }
        .onChange(of: conversation.id) {
            // Another chat in the same screen: nothing of the last one's carries over.
            composerFocused = false
            showsPermissions = false
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            // A chat that can't send pictures doesn't take them (the composer's own drop says so).
            guard conversation.supportsImages else { return false }
            AttachmentLoader.load(providers) { conversation.attachments.append($0) }
            return true
        }
        #if DEBUG
        // `-HERMES_OPEN_VOICE YES` starts Talk in the first chat that opens.
        .task {
            if UserDefaults.standard.bool(forKey: "HERMES_OPEN_VOICE"), !TalkCenter.shared.isActive {
                try? await Task.sleep(for: .seconds(1))
                startTalk()
            }
        }
        #endif
        // ⌥⌘V (Chat → Talk): start a call here; the menu ends one.
        .onChange(of: workspace.voiceToggleRequests) { startTalk() }
        // Type, in the call: the cursor goes to this chat's field.
        .onChange(of: TalkCenter.shared.typeRequests) {
            guard TalkCenter.shared.session?.conversation === conversation else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                composerFocused = true
            }
        }
        // The call minimised (`talkMinimised`): its pill at the top of the chat.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let call = TalkCenter.shared.session, !TalkCenter.shared.isExpanded {
                CallPill(session: call)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: TalkCenter.shared.isExpanded)
        // While this chat is on screen its Inspector keeps its previews; switching away or
        // leaving cancels the task, and they're let go a while later.
        .task(id: conversation.id) {
            let inspector = conversation.inspector
            let shown = conversation
            inspector.chatOnScreen()
            // While it shows, its background processes are looked at every 5 s (`docs/background-processes.md`
            // §1) and a turn going on elsewhere every 10 s.
            shown.screenChanged(shown: true)
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            shown.screenChanged(shown: false)
            inspector.chatLeftScreen()
        }
        .task(id: conversation.id) {
            guard workspace.voiceModeRequested else { return }
            workspace.voiceModeRequested = false
            try? await Task.sleep(for: .milliseconds(350))
            startTalk()
        }
    }

    // MARK: Requests

    /// While typing on a phone, the card steps aside for a one-line dock.
    private var docksWhileTyping: Bool {
        composerFocused && !isWide
    }

    @ViewBuilder
    private var requestDock: some View {
        if docksRequest {
            NeedsYouDock(conversation: conversation) { composerFocused = false }
                .modifier(DockSlot(id: "dock", glass: bottomGlass))
        } else if let approval = conversation.pendingApproval {
            ApprovalCard(
                approval: approval,
                asker: askerName,
                waiting: conversation.waitingApprovals,
                onChoice: { conversation.respond(to: approval, with: $0) },
                onChoiceForAll: conversation.respondToAll,
                extras: conversation.usesGateway ? ApprovalCard.Extras(
                    explain: { conversation.deny(approval, saying: String(localized: "Explain what this command does and why you need it.")) },
                    denyWithNote: { conversation.deny(approval, saying: $0) },
                    allowEverything: {
                        conversation.setAllowsEverything(true)
                        conversation.respond(to: approval, with: .once, quietly: true)
                    },
                    showPermissions: { showsPermissions = true }
                ) : nil
            )
            .sheet(isPresented: $showsPermissions) {
                ChatPermissionsSheet(conversation: conversation)
            }
            .modifier(DockSlot(id: "approval", glass: bottomGlass))
        } else if let request = conversation.requests.first {
            RequestCard(request: request, conversation: conversation)
                .id(request.id)
                .modifier(DockSlot(id: "approval", glass: bottomGlass))
        }
    }

    // MARK: Talk

    /// Talk (`docs/voice.md` §4): full screen on iPhone and iPad portrait, a panel on iPad
    /// landscape, its own window on the Mac.
    private var voiceModeAction: (() -> Void)? {
        startTalk
    }

    private func startTalk() {
        composerFocused = false
        TalkCenter.shared.start(conversation: conversation, workspace: workspace)
    }

    /// Who asks for approvals here.
    private var askerName: String {
        if let roster, let name = conversation.botName { return roster.bot(named: name)?.title ?? name }
        return "Hermes"
    }

    /// Who reads this chat's replies aloud (`docs/voice.md` §3).
    private var listenContext: ListenContext {
        let audio = conversation.audioBackend
        let speaker = conversation.botName.map { roster?.bot(named: $0)?.title ?? $0 } ?? "Hermes"
        var appearance = BotAppearance(profile: "hermes")
        if let roster = workspace.roster {
            if let name = conversation.botName, let bot = roster.bot(named: name) {
                appearance = roster.appearance(for: bot)
            } else if let main = roster.visibleBots.first(where: \.isDefault) {
                appearance = roster.appearance(for: main)
            }
        }
        let title = navigationTitle
        // When Listen falls back to this device's voice, the mini player says why (`docs/voice.md` §6.1).
        let setup = VoiceSetup.of(workspace)
        let botName = conversation.botName
        let note = setup.status("listen", profile: botName).flatMap { $0.state == .limited ? $0 : nil }
        return ListenContext(title: title.isEmpty ? speaker : title, speaker: speaker, appearance: appearance,
                             backend: audio?.client, profile: audio?.profile, setupNote: note,
                             onSpeechFailure: { [weak setup] why in setup?.noteSpeechFailure(why, profile: botName) })
    }

    private var navigationTitle: String {
        if let roster, let name = conversation.botName {
            return roster.bot(named: name)?.title ?? name
        }
        guard let key = conversation.stableKey, let session = workspace.session(forKey: key) else { return "" }
        return session.displayTitle
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch conversation.loadState {
        case .idle where conversation.isEmpty && !conversation.isKnownEmpty,
             .loading where conversation.isEmpty:
            // An existing chat on its way: no greeting, no centred composer, and the chat's shape
            // if it takes a moment.
            ChatSkeleton()
        case .failed(let error) where conversation.isEmpty:
            StateMessage(
                symbol: "exclamationmark.bubble",
                title: String(localized: "Couldn't load this chat"),
                message: error.errorDescription,
                actionTitle: String(localized: "Try Again"),
                action: conversation.reload
            )
        default:
            if conversation.isEmpty, let roster, let name = conversation.botName {
                if roster.hasLoaded || roster.state.isOnline {
                    BotHelloView(
                        roster: roster,
                        botName: name,
                        conversation: conversation,
                        workspace: workspace,
                        centersComposer: centersComposer,
                        composerFocused: $composerFocused
                    )
                } else {
                    ChatSkeleton()
                }
            } else if conversation.isEmpty {
                EmptyChatView(
                    workspace: workspace,
                    conversation: conversation,
                    centersComposer: centersComposer,
                    composerFocused: $composerFocused
                )
            } else {
                Group {
                    #if os(iOS)
                    // A tap on the chat puts the keyboard away, as dragging it down does.
                    TranscriptView(conversation: conversation, workspace: workspace, onTap: composerFocused ? { composerFocused = false } : nil)
                    #else
                    TranscriptView(conversation: conversation, workspace: workspace)
                    #endif
                }
                // Voice messages and the Bot's audio play from the chat's gateway; replies are
                // read in the Bot's voice (`docs/voice.md` §2, §3).
                .environment(\.clipBackend, conversation.audioBackend?.client)
                .environment(\.listenContext, listenContext)
                .task(id: workspace.roster?.isConnected) {
                    await VoiceSetup.of(workspace).checkIfStale(profile: conversation.botName)
                }
            }
        }
    }

    /// How far to raise the composer so it sits a little above the middle of an empty chat,
    /// leaving room above it for the greeting.
    /// Measurements only re-fit a centred composer (window resized, keyboard shown); the glide
    /// down on the first send is `onChange(of: centersComposer)`'s, animated.
    private func refitLift() {
        if centersComposer { updateLift() }
    }

    private func updateLift() {
        let target: CGFloat
        if centersComposer, contentHeight > 0, barHeight > 0 {
            let total = contentHeight + barHeight
            let bottomPadding: CGFloat = isWide ? 14 : 6
            let fromBottom = total * 0.5 - composerHeight / 2 - chipsHeight - bottomPadding
            target = max(0, min(fromBottom, total - composerHeight - chipsHeight - 220))
        } else {
            target = 0
        }
        if abs(target - lift) > 0.5 { lift = target }
    }

    @ViewBuilder
    private var centredChips: some View {
        if let roster, let name = conversation.botName {
            BotSuggestionChips(roster: roster, botName: name, conversation: conversation, focused: $composerFocused, centered: true)
        } else {
            ChatSuggestionChips(conversation: conversation, focused: $composerFocused, centered: true)
        }
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                if conversation.pendingApproval != nil || !conversation.requests.isEmpty {
                    requestDock
                        .transition(reduceMotion ? .opacity : .risesFromComposer)
                }
                if let banner = conversation.banner {
                    ErrorBanner(error: banner) { conversation.banner = nil }
                        .glassEffectID("banner", in: bottomGlass)
                        .transition(ComposerView.rowAppears)
                }
                if let goal = conversation.goal {
                    GoalBar(goal: goal, onClear: conversation.clearGoal)
                        .glassEffectID("goal", in: bottomGlass)
                        .transition(ComposerView.rowAppears)
                }
                // A reply being read aloud, from this chat or another (`miniPlayer`): 12 pt above
                // the composer (the stack's 10 and 2 more), riding up with it as it grows
                // (`docs/voice.md` §3).
                if ListenPlayer.shared.isActive {
                    ListenMiniPlayer()
                        .glassEffectID("listen", in: bottomGlass)
                        .padding(.bottom, 2)
                        .transition(ComposerView.rowAppears)
                }
                // iPhone and iPad portrait: the Inspector's pill (`inspectorPill`) above the composer.
                if !usesInspectorPanel, !conversation.inspector.tabs.isEmpty, !conversation.inspector.isPresented {
                    InspectorPill(inspector: conversation.inspector)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(ComposerView.rowAppears)
                }
                ComposerView(conversation: conversation, workspace: workspace, focused: $composerFocused, onVoiceMode: voiceModeAction)
                    .glassEffectID("composer", in: bottomGlass)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
                if centersComposer, !startsInProject {
                    centredChips
                        .padding(.top, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height + 16 } action: { chipsHeight = $0 }
                        .transition(ComposerView.rowAppears)
                }
            }
        }
        .frame(maxWidth: Theme.readableWidth + 40)
        .padding(.horizontal, isWide ? 20 : 10)
        .padding(.bottom, (isWide ? 14 : 6) + lift)
    }

    // MARK: Toolbar

    /// Leading. On iPad `.navigation` lands on the trailing side while the Team inspector is open.
    #if os(iOS)
    private static let sidebarPlacement = ToolbarItemPlacement.topBarLeading
    #else
    private static let sidebarPlacement = ToolbarItemPlacement.navigation
    #endif

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onToggleSidebar {
            ToolbarItem(placement: Self.sidebarPlacement) {
                SidebarButton(action: onToggleSidebar)
                    .hermesTip(DrawerTip())
            }
            .sidebarButtonGlass()
        }
        if let roster, let name = conversation.botName {
            botToolbar(roster: roster, name: name)
        } else {
            sessionToolbar
        }
    }

    @ToolbarContentBuilder
    private func botToolbar(roster: BotRoster, name: String) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            BotChatTitle(roster: roster, botName: name, conversation: conversation)
        }
        inspectorToolbarItem
        ToolbarItem(placement: .primaryAction) {
            Button {
                roster.routinesBot = name
            } label: {
                Image(systemName: "alarm")
            }
            .accessibilityLabel("Routines")
            .help("Routines")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let bot = roster.bot(named: name) {
                    BotActions(roster: roster, bot: bot)
                }
                Divider()
                Button("Compact Chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                    conversation.draft = "/compact"
                    conversation.send()
                }
                .disabled(conversation.isWorking || conversation.sessionID == nil)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    /// The Inspector's button (Mac, iPad): ink while the panel is open.
    @ToolbarContentBuilder
    private var inspectorToolbarItem: some ToolbarContent {
        if isWide {
            ToolbarItem(placement: .primaryAction) {
                InspectorToolbarButton(inspector: conversation.inspector)
            }
        }
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ModelPickerButton(conversation: conversation, workspace: workspace)
        }
        inspectorToolbarItem
        ToolbarItem(placement: .primaryAction) {
            Button {
                workspace.startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New chat")
            .help("New chat (⌘N)")
            .disabled(conversation.isEmpty && conversation.sessionID == nil)
        }
    }
}

/// Sent, finished and needs-you taps. Changes within one chat count, not a switch to another chat
/// with other counts (the screen stays as chats change).
private struct ChatHaptics: ViewModifier {
    let conversation: ConversationModel
    let enabled: Bool

    private struct Count: Equatable {
        let chat: UUID
        let value: Int
    }

    private struct Request: Equatable {
        let chat: UUID
        let id: String?
    }

    private var sent: Count { Count(chat: conversation.id, value: conversation.sentTurns) }
    private var completed: Count { Count(chat: conversation.id, value: conversation.completedTurns) }
    private var approval: Request { Request(chat: conversation.id, id: conversation.pendingApproval?.id) }

    private func sameChat(_ old: Count, _ new: Count) -> Bool { enabled && old.chat == new.chat }

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(weight: .light), trigger: sent, condition: sameChat)
            .sensoryFeedback(.success, trigger: completed, condition: sameChat)
            .sensoryFeedback(.warning, trigger: approval) { (old: Request, new: Request) -> Bool in
                enabled && old.chat == new.chat && new.id != nil
            }
    }
}

/// A chat on its way (`chatSkeleton`, `docs/chat.md` §4): the shape of a chat, newest at the
/// bottom as the transcript lays it out, so the messages arrive into the room they'll take
/// instead of replacing a spinner. It waits a beat before showing, so a fast load doesn't flash
/// it, and holds still: an idle placeholder doesn't wake the CPU.
private struct ChatSkeleton: View {
    @State private var shows = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(alignment: .leading, spacing: 30) {
                Spacer(minLength: 0)
                bubble(width: min(260, width * 0.5))
                reply(lines: [1, 0.96, 0.88, 0.52], width: width)
                bubble(width: min(180, width * 0.36))
                reply(lines: [1, 0.92, 0.64], width: width)
            }
            .frame(width: width, height: proxy.size.height, alignment: .bottom)
        }
        .frame(maxWidth: Theme.readableWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading the chat"))
        // Gone as the chat fades in (`TranscriptView`'s `settled`): one crossfade, no blank frame.
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.25)) { shows = true }
        }
    }

    /// Your message: a bubble's height and shape, on the right.
    private func bubble(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
            .fill(Theme.surface)
            .frame(width: width, height: 44)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// A reply: lines of text, the last one short.
    private func reply(lines: [CGFloat], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines.indices, id: \.self) { index in
                Capsule()
                    .fill(Theme.surface)
                    .frame(width: width * lines[index], height: 12)
            }
        }
    }
}

/// Shown under the toolbar when Bot Mode's backend is unreachable or needs a sign-in.
private struct BotModeBanner: View {
    let roster: BotRoster

    var body: some View {
        switch roster.state {
        case .failed(let message):
            BotModeProblem(roster: roster, message: message, needsSignIn: false)
                .padding(.horizontal, 12)
                .frame(maxWidth: Theme.readableWidth + 40)
        case .signInRequired(let message):
            BotModeProblem(roster: roster, message: message, needsSignIn: true)
                .padding(.horizontal, 12)
                .frame(maxWidth: Theme.readableWidth + 40)
        default:
            EmptyView()
        }
    }
}

/// Shown under the toolbar when the gateway can't be reached.
struct ConnectionBanner: View {
    let workspace: BotWorkspace
    @Environment(AppModel.self) private var app
    @Environment(WindowRouter.self) private var router: WindowRouter?
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        if case .failed(let error) = workspace.connection {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.errorDescription ?? "")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.primaryText)
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                if error == .missingAPIKey || error == .unauthorized {
                    Button("Edit Gateway") {
                        router?.sheet = .editGateway(workspace.bot)
                    }
                    .cardButton()
                    .controlSize(.small)
                } else if Self.isDeviceSetting(error) {
                    // A setting on this device is in the way (`docs/setup.md` §4.15).
                    Button("Open Settings") { DeviceSetup.openSettings(.localNetwork) }
                        .cardButton()
                        .controlSize(.small)
                } else {
                    Button("Retry") {
                        Task { await workspace.connect() }
                    }
                    .cardButton()
                    .controlSize(.small)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .frame(maxWidth: Theme.readableWidth + 40)
        }
    }

    /// Local Network, Wi-Fi or Mobile Data turned off for Hermes.
    static func isDeviceSetting(_ error: HermesError) -> Bool {
        guard case .unreachable(_, let reason) = error else { return false }
        return reason == .localNetworkDenied || reason == .mobileDataOff || reason == .wifiOff
    }
}

/// A dismissible error above the composer.
struct ErrorBanner: View {
    let error: HermesError
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.danger)
            Text(error.errorDescription ?? "")
                .font(.footnote)
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
                    // 44pt to hit, without making the banner taller.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -14)
                    .padding(.trailing, -10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Where helpers show (`docs/helpers.md` §3) outside the Inspector: on iPhone the Team page and a
/// helper push onto the chat's stack. The Team tab is the Inspector's (`InspectorPresentation`).
private struct HelperPresentation: ViewModifier {
    let conversation: ConversationModel
    let workspace: BotWorkspace
    let navigator: HelperNavigator

    func body(content: Content) -> some View {
        let store = conversation.helpers
        content
            .navigationDestination(item: Binding(
                get: { store.pushedHelper },
                set: { store.pushedHelper = $0 }
            )) { helperID in
                HelperDetailView(store: store, conversation: conversation, workspace: workspace, helperID: helperID, style: .page)
            }
    }
}

/// What the slot above the composer shows: a card, the next one, or the dock while you type. The
/// contents blur across. The dock's glass is its own: sharing the card's, the change from one to
/// the other happened in a frame; as two, one flows into the other.
private struct DockSlot: ViewModifier {
    let id: String
    let glass: Namespace.ID

    func body(content: Content) -> some View {
        content
            .glassEffectID(id, in: glass)
            .transition(.blurReplace)
    }
}
