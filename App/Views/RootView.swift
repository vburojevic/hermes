import HermesKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Onboarding until a gateway exists, then the main interface.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #endif
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    /// This window's sheets.
    @State private var router = WindowRouter()

    var body: some View {
        Group {
            if let workspace = app.currentWorkspace {
                MainView(workspace: workspace)
                    .id(workspace.id)
                    .task(id: workspace.id) {
                        workspace.keepConnected()
                        if !workspace.connection.isOnline {
                            await workspace.connect()
                        }
                        #if DEBUG
                        if let session = app.takeLaunchSession() {
                            workspace.selection = .session(session)
                        }
                        // `-HERMES_OPEN tasks|skills|bot:<name>` opens a page (screenshots).
                        switch UserDefaults.standard.string(forKey: "HERMES_OPEN") {
                        case "tasks": workspace.selection = .tasks
                        case "skills": workspace.selection = .skills
                        case let page? where page.hasPrefix("bot:"):
                            workspace.sidebarMode = .bots
                            workspace.selection = .bot(String(page.dropFirst(4)))
                        case let page? where page.hasPrefix("group:"):
                            workspace.sidebarMode = .bots
                            let id = String(page.dropFirst(6))
                            workspace.selection = .group(id)
                            // `-HERMES_GROUP_SEND <text>` posts in it once it loads.
                            if let text = UserDefaults.standard.string(forKey: "HERMES_GROUP_SEND") {
                                for _ in 0..<40 where workspace.roster?.groupRooms.chat(for: id) == nil {
                                    try? await Task.sleep(for: .milliseconds(250))
                                }
                                if let chat = workspace.roster?.groupRooms.chat(for: id) {
                                    try? await Task.sleep(for: .seconds(1))
                                    chat.draft = text
                                    chat.send()
                                }
                            }
                        case "projects":
                            workspace.sidebarMode = .chats
                            workspace.selection = .allProjects
                        case let page? where page.hasPrefix("project:"):
                            // `-HERMES_OPEN project:<id>` (and `-HERMES_PROJECT_LANE <lane id>`).
                            workspace.sidebarMode = .chats
                            workspace.projects.focusLane = UserDefaults.standard.string(forKey: "HERMES_PROJECT_LANE")
                            if let expand = UserDefaults.standard.string(forKey: "HERMES_PROJECT_EXPAND") {
                                workspace.projects.expandedIDs.insert(expand)
                            }
                            workspace.selection = .project(String(page.dropFirst(8)))
                        case let page? where page.hasPrefix("project-chat:"):
                            workspace.sidebarMode = .chats
                            for _ in 0..<40 where !workspace.projects.isAvailable {
                                try? await Task.sleep(for: .milliseconds(250))
                            }
                            workspace.startNewChat(inProject: String(page.dropFirst(13)))
                        default: break
                        }
                        await openProjectSheet(in: workspace)
                        await sendDebugMessage(in: workspace)
                        await openDebugHelpers(in: workspace)
                        #endif
                    }
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.didBecomeActive() }
        }
        .sheet(item: $router.sheet, onDismiss: router.sheetDidDismiss) { sheet in
            sheetContent(sheet)
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(get: { app.storageError != nil }, set: { if !$0 { app.storageError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.storageError ?? "")
        }
        .onOpenURL { url in
            router.open(url)
        }
        #if DEBUG
        .task { openDebugSheet() }
        #endif
        .focusedSceneValue(\.windowRouter, router)
        // Outermost, so sheets inherit them too.
        .environment(router)
        .environment(\.pausesDecorativeMotion, pausesMotion)
        #if HERMES_PUSH
        .pushPresentation()
        #endif
    }

    /// Decorative motion (faces, shimmer, auras) stops whenever nobody is looking at it: the app
    /// in the background, Low Power Mode, and on the Mac a window that isn't the key window
    /// (visible behind other apps, it kept animating all day).
    private var pausesMotion: Bool {
        #if os(macOS)
        if !appearsActive { return true }
        #endif
        return scenePhase != .active || PowerState.shared.isLowPower
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WindowSheet) -> some View {
        switch sheet {
        case .addGateway:
            NavigationStack {
                BotEditorView(mode: .add, onAdded: pairAfterAdding) { router.sheet = nil }
            }
            #if os(macOS)
            .frame(width: 520)
            .frame(minHeight: 420, idealHeight: 560)
            #endif
        case .editGateway(let bot):
            NavigationStack {
                BotEditorView(mode: .edit(bot)) { router.sheet = nil }
            }
            #if os(macOS)
            .frame(width: 520)
            .frame(minHeight: 420, idealHeight: 600)
            #endif
        case .settings:
            SettingsView()
        case .pairing(let botID):
            PairingSheet(botID: botID)
                #if os(macOS)
                .frame(width: 460)
                .frame(minHeight: 400, idealHeight: 620)
                #else
                .presentationDetents([.large])
                #endif
        case .connect(let link, let rightAway):
            PairingConnectView(link: link, connectsRightAway: rightAway)
                #if os(macOS)
                .frame(width: 440)
                .frame(minHeight: 380, idealHeight: 520)
                #else
                .presentationDetents([.medium, .large])
                #endif
        case .scanner:
            #if os(iOS)
            PairingScannerSheet()
            #else
            EmptyView()
            #endif
        case .quickOpen:
            if let workspace = app.currentWorkspace {
                QuickOpenView(workspace: workspace)
                    #if os(macOS)
                    .frame(width: 580, height: 440)
                    #else
                    .presentationDetents([.large])
                    #endif
            }
        }
    }

    /// A new gateway that other devices can reach goes straight to its pairing code on the Mac.
    private func pairAfterAdding(_ bot: BotConfiguration) {
        #if os(macOS)
        if app.pairingLink(for: bot.id)?.isReachableFromOtherDevices == true {
            router.sheet = .pairing(bot.id)
            return
        }
        #endif
        router.sheet = nil
    }

    #if DEBUG
    /// `-HERMES_SEND <text>` sends a message in a new chat once connected (turn screenshots and
    /// flow tests without driving the keyboard). Waits for Bot Mode so it runs over the socket.
    private func sendDebugMessage(in workspace: BotWorkspace) async {
        // `-HERMES_DRAFT <text>` opens a new chat with the text typed but not sent.
        if let typed = UserDefaults.standard.string(forKey: "HERMES_DRAFT"), !typed.isEmpty {
            for _ in 0..<40 where workspace.roster != nil && workspace.roster?.isConnected != true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            workspace.sidebarMode = .chats
            workspace.startNewChat()
            workspace.draft?.loadSlashCatalog()
            try? await Task.sleep(for: .milliseconds(800))
            // The roster's Bots name the `@handles` that become pills.
            for _ in 0..<40 where workspace.roster?.visibleBots.isEmpty == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let draft = workspace.draft else { return }
            // `-HERMES_DRAFT_SKILLS a,b` fills the tray; "/goal …" opens command mode; known
            // `@handles` and `@file:` paths become pills.
            if let skills = UserDefaults.standard.string(forKey: "HERMES_DRAFT_SKILLS") {
                draft.skills = skills.split(separator: ",").map(String.init)
            }
            if let command = SlashCommands.parse(typed), let info = SlashCommands.known(command.name), CommandMode.takesArgument(info) {
                draft.draftCommand = info.name
                draft.draft = command.argument ?? ""
            } else {
                draft.draftReferences = draft.referenceVocabulary.references(in: typed)
                draft.draft = typed
            }
            return
        }
        guard let text = UserDefaults.standard.string(forKey: "HERMES_SEND"), !text.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "HERMES_SEND")
        for _ in 0..<40 where workspace.roster != nil && workspace.roster?.isConnected != true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // `-HERMES_SEND_AFTER <seconds>` sends in the chat already open (`-HERMES_OPEN bot:<name>`,
        // `-HERMES_OPEN_SESSION <id>`) once it has loaded and settled, instead of a new chat.
        if let delay = UserDefaults.standard.string(forKey: "HERMES_SEND_AFTER").flatMap(Double.init) {
            try? await Task.sleep(for: .seconds(delay))
            let conversation = workspace.currentConversation
            conversation.draft = text
            conversation.send()
            await sendDebugFollowUp(in: conversation)
            return
        }
        workspace.sidebarMode = .chats
        workspace.startNewChat()
        guard let conversation = workspace.draft else { return }
        for _ in 0..<40 where workspace.roster?.visibleBots.isEmpty == true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        conversation.loadSlashCatalog()
        try? await Task.sleep(for: .milliseconds(600))
        conversation.draft = text
        conversation.send()
        // `-HERMES_FOLLOWUP <text>` types a follow-up while the turn runs (`-HERMES_FOLLOWUP_MODE
        // steer|redirect|sendNext|askAside|background` picks the mode, `-HERMES_FOLLOWUP_SEND YES`
        // sends it). Several follow-ups go one after another, separated by `|`.
        await sendDebugFollowUp(in: conversation)
    }

    /// `-HERMES_HELPERS team|helper:<n>|steer:<n>|stop:<n>` opens the chat's latest team, its helper
    /// n, a steer to it, or stops it, `-HERMES_HELPERS_AFTER <seconds>` after launch (helper screenshots).
    private func openDebugHelpers(in workspace: BotWorkspace) async {
        guard let action = UserDefaults.standard.string(forKey: "HERMES_HELPERS"), !action.isEmpty else { return }
        let delay = UserDefaults.standard.string(forKey: "HERMES_HELPERS_AFTER").flatMap(Double.init) ?? 6
        try? await Task.sleep(for: .seconds(delay))
        let conversation = workspace.currentConversation
        let store = conversation.helpers
        guard let team = store.teams.last else { return }
        let parts = action.split(separator: ":")
        let index = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let helper = team.topLevel.first { $0.taskIndex == index - 1 }
        store.shownTeam = team.id
        guard parts[0] != "team", let helper else { return }
        try? await Task.sleep(for: .milliseconds(700))
        store.shownHelper = helper.id
        if parts[0] == "stop" {
            try? await Task.sleep(for: .milliseconds(700))
            store.stop(helper)
        }
        if parts[0] == "steer" {
            try? await Task.sleep(for: .milliseconds(700))
            conversation.helperSteerTarget = HelperSteerTarget(helperID: helper.id, number: team.number(of: helper))
            // `-HERMES_HELPERS_NOTE <text>` sends it.
            if let note = UserDefaults.standard.string(forKey: "HERMES_HELPERS_NOTE"), !note.isEmpty {
                try? await Task.sleep(for: .milliseconds(600))
                conversation.draft = note
                conversation.send()
            }
        }
    }

    private func sendDebugFollowUp(in conversation: ConversationModel) async {
        guard let followUps = UserDefaults.standard.string(forKey: "HERMES_FOLLOWUP"), !followUps.isEmpty else { return }
        let delay = UserDefaults.standard.string(forKey: "HERMES_FOLLOWUP_AFTER").flatMap(Double.init) ?? 2
        try? await Task.sleep(for: .seconds(delay))
        let modes = (UserDefaults.standard.string(forKey: "HERMES_FOLLOWUP_MODE") ?? "").split(separator: "|").map(String.init)
        for (index, followUp) in followUps.split(separator: "|").map(String.init).enumerated() {
            if index > 0 { try? await Task.sleep(for: .seconds(1.2)) }
            let mode = modes.indices.contains(index) ? FollowUpMode(rawValue: modes[index]) : modes.last.flatMap(FollowUpMode.init(rawValue:))
            conversation.followUpPick = mode
            conversation.draft = followUp
            if UserDefaults.standard.bool(forKey: "HERMES_FOLLOWUP_SEND") {
                try? await Task.sleep(for: .milliseconds(600))
                conversation.send()
            }
        }
    }

    /// `-HERMES_PROJECT_SHEET new|edit:<id>|move:<session id>|runin` opens a projects sheet once
    /// the projects have loaded (screenshots).
    private func openProjectSheet(in workspace: BotWorkspace) async {
        guard let sheet = UserDefaults.standard.string(forKey: "HERMES_PROJECT_SHEET") else { return }
        for _ in 0..<40 where !workspace.projects.isAvailable {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(600))
        let projects = workspace.projects!
        switch sheet {
        case "new": projects.editing = .new(folder: nil)
        case let value where value.hasPrefix("edit:"): projects.editing = .edit(String(value.dropFirst(5)))
        case let value where value.hasPrefix("move:"):
            let id = String(value.dropFirst(5))
            projects.movingSession = workspace.session(forKey: id) ?? HermesSession(id: id)
        case "runin": projects.runInConversation = workspace.currentConversation
        default: break
        }
    }

    /// `-HERMES_OPEN_PAIRING YES|reveal` opens the current gateway's pairing code;
    /// `-HERMES_OPEN_LINK <url>` opens a pairing link; `-HERMES_OPEN_QUICK <query>` opens
    /// Quick Open (screenshot and flow tests).
    private func openDebugSheet() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "HERMES_OPEN_PAIRING") != nil, let botID = app.selectedBotID {
            router.sheet = .pairing(botID)
        } else if let link = defaults.string(forKey: "HERMES_OPEN_LINK").flatMap(URL.init(string:)) {
            router.open(link)
        } else if defaults.string(forKey: "HERMES_OPEN_QUICK") != nil, app.currentWorkspace != nil {
            router.sheet = .quickOpen
        } else if defaults.string(forKey: "HERMES_OPEN") == "settings" {
            router.sheet = .settings
        } else if defaults.string(forKey: "HERMES_OPEN") == "add-gateway" {
            router.sheet = .addGateway
        }
    }
    #endif
}

/// Split view on iPad and Mac, a Grok-style drawer on iPhone.
struct MainView: View {
    @Bindable var workspace: BotWorkspace

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isDrawerOpen = false

    var body: some View {
        layout
            .modifier(BotSheets(workspace: workspace))
            .modifier(ProjectSheets(workspace: workspace))
            // Another chat, Bot or page: the composer it typed into is gone.
            .onChange(of: workspace.selection) {
                Keyboard.dismiss()
                #if DEBUG && os(iOS)
                FrameMonitor.shared.mark("selection changed")
                #endif
            }
            #if DEBUG
            // `-HERMES_DRAWER YES` opens the iPhone drawer (screenshots).
            .task {
                if UserDefaults.standard.bool(forKey: "HERMES_DRAWER") {
                    try? await Task.sleep(for: .seconds(1.5))
                    isDrawerOpen = true
                }
            }
            #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        splitView
        #else
        if horizontalSizeClass == .compact {
            drawerLayout
        } else {
            splitView
        }
        #endif
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace, style: .split)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            NavigationStack {
                DetailView(workspace: workspace, onToggleSidebar: nil)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var drawerLayout: some View {
        DrawerContainer(isOpen: $isDrawerOpen) {
            SidebarView(workspace: workspace, style: .drawer) {
                // What was picked draws first, under the drawer, with its rows (the ones this
                // device kept arrive in a moment); then the drawer slides away with nothing left
                // to build. SwiftUI animates on the main thread: a chat built, or filled in,
                // during the slide made it jump.
                Task { @MainActor in
                    await workspace.currentConversation.firstRows(within: .milliseconds(250))
                    NextFrame.run { withAnimation(Theme.spring) { isDrawerOpen = false } }
                }
            }
        } content: {
            NavigationStack {
                DetailView(workspace: workspace) {
                    withAnimation(Theme.spring) { isDrawerOpen.toggle() }
                }
            }
        }
    }
}

/// New Bot, Edit Bot and Routines, presented for the whole window.
private struct BotSheets: ViewModifier {
    let workspace: BotWorkspace

    func body(content: Content) -> some View {
        if let roster = workspace.roster {
            content
                .onChange(of: roster.isCreatingBot || roster.isCreatingGroup || roster.editingBot != nil || roster.routinesBot != nil) { _, presenting in
                    if presenting { Keyboard.dismiss() }
                }
                .sheet(isPresented: Binding(get: { roster.isCreatingBot }, set: { roster.isCreatingBot = $0 })) {
                    BotSheet(roster: roster, mode: .create) { name in
                        roster.isCreatingBot = false
                        if let name {
                            workspace.sidebarMode = .bots
                            workspace.selection = .bot(name)
                        }
                    }
                    #if os(macOS)
                    .frame(width: 480).frame(minHeight: 420, idealHeight: 640)
                    #endif
                }
                .sheet(isPresented: Binding(get: { roster.isCreatingGroup }, set: { roster.isCreatingGroup = $0 })) {
                    NewGroupSheet(roster: roster) { room in
                        roster.isCreatingGroup = false
                        if let room {
                            workspace.sidebarMode = .bots
                            workspace.selection = .group(room.id)
                        }
                    }
                }
                .sheet(item: Binding(get: { roster.editingBot.map(BotSheetTarget.init) }, set: { roster.editingBot = $0?.name })) { target in
                    BotSheet(roster: roster, mode: .edit(target.name)) { _ in
                        roster.editingBot = nil
                    }
                    #if os(macOS)
                    .frame(width: 480).frame(minHeight: 420, idealHeight: 600)
                    #endif
                }
                .sheet(item: Binding(get: { roster.routinesBot.map(BotSheetTarget.init) }, set: { roster.routinesBot = $0?.name })) { target in
                    RoutinesView(roster: roster, botName: target.name) {
                        roster.routinesBot = nil
                    }
                    #if os(macOS)
                    .frame(width: 520).frame(minHeight: 420, idealHeight: 620)
                    #endif
                }
        } else {
            content
        }
    }
}

private struct BotSheetTarget: Identifiable {
    let name: String
    var id: String { name }
}

/// The main area for the current sidebar selection.
struct DetailView: View {
    @Bindable var workspace: BotWorkspace
    var onToggleSidebar: (() -> Void)?

    /// Bots mode with nothing picked shows all the Bots; Tasks, Skills and any chat or Bot
    /// show themselves whichever mode the sidebar is in.
    private var showsBotsHome: Bool {
        workspace.sidebarMode == .bots && workspace.roster != nil && workspace.selection == nil
    }

    var body: some View {
        Group {
            if showsBotsHome, let roster = workspace.roster {
                BotsHomeView(roster: roster, workspace: workspace, onToggleSidebar: onToggleSidebar)
            } else {
                selectionView
            }
        }
        .sheet(item: $workspace.openedFile) { file in
            GatewayFileSheet(file: file)
                .environment(\.references, ReferenceContext(workspace: workspace))
        }
    }

    @ViewBuilder
    private var selectionView: some View {
        switch workspace.selection {
        case .tasks:
            TasksView(workspace: workspace, onToggleSidebar: onToggleSidebar)
        case .skills:
            SkillsView(workspace: workspace, onToggleSidebar: onToggleSidebar)
        case .group(let id):
            if let rooms = workspace.roster?.groupRooms, let chat = rooms.chat(for: id) {
                GroupChatScreen(chat: chat, rooms: rooms, workspace: workspace, onToggleSidebar: onToggleSidebar)
                    .id(id)
            } else {
                StateMessage(symbol: "person.3", title: String(localized: "Group chat not found"), message: String(localized: "It may have been deleted on the gateway."))
            }
        case .project(let id):
            ProjectHomeView(workspace: workspace, projectID: id, onToggleSidebar: onToggleSidebar)
                .id(id)
        case .allProjects:
            AllProjectsView(workspace: workspace, onToggleSidebar: onToggleSidebar)
        case .session, .bot, nil:
            let conversation = workspace.currentConversation
            // One screen for every chat: opening another one swaps its data and its transcript,
            // not the toolbar, the composer and its text view (that cost a long frame per switch).
            ChatScreen(conversation: conversation, workspace: workspace, onToggleSidebar: onToggleSidebar)
        }
    }
}

/// A sidebar that slides in from the leading edge, pushing the content aside.
struct DrawerContainer<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let drawer: Drawer
    @ViewBuilder let content: Content

    /// How far the finger has moved the content. Reset in the same animation that opens or
    /// closes the drawer, so letting go carries on from where the finger left it.
    @State private var dragOffset: CGFloat = 0
    /// Decided once per drag: a drawer swipe, or something else (a scroll) to leave alone.
    @State private var dragIsDrawerSwipe: Bool?
    /// Notices drags the system takes over (a scroll, a sheet), which end without `onEnded`.
    @GestureState private var isDragging = false
    /// Where the drawer last came to rest. While `isOpen` differs from it, the drawer is sliding
    /// (`isSliding`), known in the very update that flips `isOpen`.
    @State private var restingOpen: Bool?
    /// The slide's spring hasn't settled yet (a quick open-and-close never rests in between).
    @State private var isSettling = false
    @State private var slideEnd: Task<Void, Never>?

    private var isSliding: Bool {
        isSettling || restingOpen.map { $0 != isOpen } ?? false
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.84, 360)
            let base = isOpen ? width : 0
            let offset = min(max(base + dragOffset, 0), width)
            let progress = offset / width

            ZStack(alignment: .leading) {
                drawer
                    .frame(width: width)
                    .offset(x: reduceMotion ? 0 : (progress - 1) * width * 0.25)
                    .opacity(reduceMotion ? (isOpen ? 1 : 0) : 1)
                    .accessibilityHidden(!isOpen)

                content
                    .frame(width: geometry.size.width)
                    .overlay {
                        Color.black
                            .opacity(0.32 * progress)
                            .ignoresSafeArea()
                            .allowsHitTesting(isOpen)
                            .onTapGesture { withAnimation(Theme.spring) { isOpen = false } }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Close sidebar")
                            .accessibilityHidden(!isOpen)
                    }
                    .background(Theme.canvas.ignoresSafeArea())
                    // The edge's shadow is a gradient strip: a blurred shadow of the whole chat had
                    // to be rendered again on every frame of the slide.
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.black.opacity(0.16 * progress), .clear], startPoint: .trailing, endPoint: .leading)
                            .frame(width: 18)
                            .offset(x: -18)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .offset(x: offset)
                    .environment(\.isSliding, isSliding)
                    .accessibilityHidden(isOpen)
            }
            .simultaneousGesture(dragGesture(width: width))
            // No implicit animation here: it animated everything that changed with the drawer,
            // the chat being opened included (old and new chats cross-faded, both rendered, for
            // the whole slide). Opening and closing animate explicitly.
            .onAppear { restingOpen = isOpen }
            .onChange(of: isOpen) { _, open in
                if open { Keyboard.dismiss() }
                #if DEBUG && os(iOS)
                FrameMonitor.shared.mark(open ? "drawer opening" : "drawer closing")
                #endif
                isSettling = true
                Settling.isSliding = true
                slideEnd?.cancel()
                slideEnd = Task {
                    // `Theme.spring` (response 0.38) has visibly settled by then.
                    try? await Task.sleep(for: .milliseconds(420))
                    guard !Task.isCancelled else { return }
                    restingOpen = open
                    isSettling = false
                    Settling.isSliding = false
                }
            }
            .onDisappear { Settling.isSliding = false }
            .onChange(of: isDragging) { _, dragging in
                guard !dragging, dragOffset != 0 || dragIsDrawerSwipe != nil else { return }
                dragIsDrawerSwipe = nil
                withAnimation(Theme.spring) { dragOffset = 0 }
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    /// Opening needs a swipe from the leading edge, so horizontal scrollers in the
    /// transcript (code blocks, tables, chips) keep their own swipes.
    private var edgeWidth: CGFloat { 32 }

    private func isDrawerSwipe(_ value: DragGesture.Value) -> Bool {
        // Only horizontal swipes; leave vertical scrolling alone.
        guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return false }
        return isOpen || value.startLocation.x <= edgeWidth
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if dragIsDrawerSwipe == nil {
                    dragIsDrawerSwipe = isDrawerSwipe(value)
                    // The drawer starts sliding in: the keyboard leaves with the chat, not after it.
                    if dragIsDrawerSwipe == true, !isOpen { Keyboard.dismiss() }
                }
                guard dragIsDrawerSwipe == true else { return }
                dragOffset = isOpen ? min(0, value.translation.width) : max(0, value.translation.width)
            }
            .onEnded { value in
                defer { dragIsDrawerSwipe = nil }
                guard dragIsDrawerSwipe == true else { return }
                let projected = value.predictedEndTranslation.width
                withAnimation(Theme.spring) {
                    if isOpen {
                        if projected < -width * 0.35 { isOpen = false }
                    } else if projected > width * 0.35 {
                        isOpen = true
                    }
                    dragOffset = 0
                }
            }
    }
}

/// Runs something once the frame being prepared now is on screen: after the work a change
/// causes, not in the middle of it.
@MainActor
enum NextFrame {
    static func run(_ action: @escaping @MainActor () -> Void) {
        #if os(iOS)
        let ticker = Ticker(action: action)
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        #else
        DispatchQueue.main.async { action() }
        #endif
    }

    #if os(iOS)
    private final class Ticker: NSObject {
        let action: @MainActor () -> Void
        private var ticks = 0
        init(action: @escaping @MainActor () -> Void) { self.action = action }

        /// The first tick can come before this frame's commit; the second is the next frame.
        @objc func tick(_ link: CADisplayLink) {
            ticks += 1
            guard ticks >= 2 else { return }
            link.invalidate()
            MainActor.assumeIsolated { action() }
        }
    }
    #endif
}

/// The software keyboard, put away when what it was typing into leaves the screen (another chat,
/// the drawer, a sheet). macOS has none to put away.
enum Keyboard {
    @MainActor static func dismiss() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
