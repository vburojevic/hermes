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
    /// Voice mode, while it runs (open or minimised).
    @State private var voice: VoiceSession?
    @State private var showsPermissions = false

    private var isWide: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
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
            // The screen stays as chats change (switching is a data change, not a rebuild of
            // the toolbar and composer); the chat's own content starts fresh for each one.
            content
                .id(ObjectIdentifier(conversation))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; refitLift() }
        .safeAreaBar(edge: .bottom) {
            bottomBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0; refitLift() }
        }
        .safeAreaBar(edge: .top) {
            if let roster {
                BotModeBanner(roster: roster)
            } else {
                ConnectionBanner(workspace: workspace)
            }
        }
        .toolbar { toolbar }
        #if os(macOS)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
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
        .onChange(of: conversation.id) {
            // Another chat in the same screen: nothing of the last one's carries over.
            composerFocused = false
            showsPermissions = false
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            AttachmentLoader.load(providers) { conversation.attachments.append($0) }
            return conversation.supportsImages
        }
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { voice.map { !$0.isMinimised } ?? false },
            set: { if !$0 { voice?.isMinimised = true } }
        )) {
            if let voice {
                VoiceModeView(session: voice, onKeyboard: leaveVoiceForKeyboard, onEnd: endVoice)
            }
        }
        .onChange(of: conversation.id) { endVoice() }
        .onDisappear { endVoice() }
        .task(id: conversation.id) {
            guard workspace.voiceModeRequested else { return }
            workspace.voiceModeRequested = false
            try? await Task.sleep(for: .milliseconds(350))
            startVoice()
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "HERMES_OPEN_VOICE") {
                try? await Task.sleep(for: .seconds(1))
                startVoice()
            }
        }
        #endif
        #endif
    }

    // MARK: Requests

    /// While typing on a phone, the card steps aside for a one-line dock.
    private var docksRequest: Bool {
        composerFocused && !isWide
    }

    @ViewBuilder
    private var requestDock: some View {
        if docksRequest {
            NeedsYouDock(conversation: conversation) { composerFocused = false }
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
        } else if let request = conversation.requests.first {
            RequestCard(request: request, conversation: conversation)
                .id(request.id)
        }
    }

    // MARK: Voice mode

    /// Voice mode is designed for iPhone and iPad; the Mac has dictation only for now.
    private var voiceModeAction: (() -> Void)? {
        #if os(iOS)
        startVoice
        #else
        nil
        #endif
    }

    private func startVoice() {
        guard voice == nil else {
            voice?.isMinimised = false
            return
        }
        composerFocused = false
        let session = VoiceSession(conversation: conversation, workspace: workspace)
        voice = session
        session.begin()
    }

    private func endVoice() {
        voice?.end()
        voice = nil
    }

    private func leaveVoiceForKeyboard() {
        endVoice()
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            composerFocused = true
        }
    }

    /// Who asks for approvals here.
    private var askerName: String {
        if let roster, let name = conversation.botName { return roster.bot(named: name)?.title ?? name }
        return "Hermes"
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
            // An existing chat on its way: no greeting, no centred composer, and no spinner
            // unless it takes a moment.
            DelayedProgress()
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
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if conversation.isEmpty {
                EmptyChatView(
                    workspace: workspace,
                    conversation: conversation,
                    centersComposer: centersComposer,
                    composerFocused: $composerFocused
                )
            } else {
                TranscriptView(conversation: conversation, workspace: workspace)
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
                        .glassEffectID("approval", in: bottomGlass)
                        .transition(ComposerView.rowAppears)
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
                if let voice, voice.isMinimised {
                    VoiceMiniBar(session: voice, onEnd: endVoice)
                        .glassEffectID("voice", in: bottomGlass)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onToggleSidebar {
            ToolbarItem(placement: .navigation) {
                Button(action: onToggleSidebar) {
                    SidebarGlyph()
                }
                .accessibilityLabel("Show sidebar")
            }
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

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ModelPickerButton(conversation: conversation, workspace: workspace)
        }
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

/// A spinner that waits a beat before showing, so a fast load doesn't flash one.
private struct DelayedProgress: View {
    @State private var shows = false

    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .opacity(shows ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 0.2)) { shows = true }
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
