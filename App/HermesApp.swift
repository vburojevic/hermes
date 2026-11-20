import HermesKit
import SwiftUI
#if os(macOS)
import HermesMacSupport
#endif

@main
struct HermesApp: App {
    static let mainWindow = "main"
    @State private var model = AppModel()
    /// The app-wide phase: active while any window is.
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @State private var updater = Updater()
    #endif
    #if HERMES_PUSH
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #else
    @NSApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif
    #endif

    #if DEBUG
    init() {
        // Debug logs (`-HERMES_SCROLL_LOG` and the like) reach a file a line at a time: written to
        // a file, stdout otherwise holds 4 KB, and loses it when the app is stopped.
        setvbuf(stdout, nil, _IOLBF, 0)
        LaunchTrace.mark("app init")
        #if os(macOS)
        // The first view's `onAppear` comes before its first frame is drawn; the window turning
        // visible is when the person sees it.
        if LaunchTrace.enabled {
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    if window.occlusionState.contains(.visible) { LaunchTrace.mark("window on screen") }
                }
            }
        }
        #endif
        // `-HERMES_VOICE_INPUT /path/clip.m4a@1.5,/path/stop.m4a@9`: spoken clips heard as if by
        // the microphone, at their second from when listening starts (`docs/voice.md` §12).
        if let spec = UserDefaults.standard.string(forKey: "HERMES_VOICE_INPUT") {
            AudioGraph.simulatedInput = spec.split(separator: ",").compactMap { part in
                let pieces = part.split(separator: "@", maxSplits: 1)
                guard let path = pieces.first else { return nil }
                return (URL(fileURLWithPath: String(path)), pieces.count > 1 ? Double(pieces[1]) ?? 0 : 0)
            }
        }
        // `-HERMES_ENGINE_START_DELAY 12`: the audio engine's first start takes that much longer, as
        // on a busy Mac.
        AudioGraph.engineStartDelay = UserDefaults.standard.double(forKey: "HERMES_ENGINE_START_DELAY")
        // `-HERMES_SPEAKER_ECHO 25`: with the simulated microphone, what plays comes back that
        // many dB quieter, its words heard, as a loudspeaker's echo past the echo canceller.
        if UserDefaults.standard.object(forKey: "HERMES_SPEAKER_ECHO") != nil {
            AudioGraph.simulatedEcho = UserDefaults.standard.float(forKey: "HERMES_SPEAKER_ECHO")
        }
        #if os(macOS)
        // `-HERMES_QUIT_AFTER 90`: Hermes Dev quits itself that many seconds after launch, so a Mac
        // run ends without signalling anything: every Debug build shares one bundle id.
        let quitAfter = UserDefaults.standard.double(forKey: "HERMES_QUIT_AFTER")
        if quitAfter > 0 {
            Task {
                try? await Task.sleep(for: .seconds(quitAfter))
                NSApplication.shared.terminate(nil)
            }
        }
        #endif
    }
    #endif

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            Group {
                #if DEBUG
                if let page = UserDefaults.standard.string(forKey: "HERMES_GALLERY") {
                    DesignGallery(page: page)
                } else {
                    RootView()
                        .onAppear {
                            LaunchTrace.mark("first view on screen")
                            FrameMonitor.shared.startIfRequested()
                            ScrollRun.shared.startIfRequested()
                        }
                }
                #else
                RootView()
                #endif
            }
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(AppModel.refreshTask)) { [model] in
            await model.refreshInBackground()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
            if phase == .active { PluginHubModel.syncHidden() }
            #if HERMES_PUSH
            if phase == .active { PushCenter.shared.sceneDidBecomeActive() }
            if phase == .inactive { PushCenter.shared.sceneWillResignActive() }
            if phase == .background { PushCenter.shared.sceneDidEnterBackground() }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
        .commands {
            #if os(iOS)
            SidebarCommands()
            #endif
            HermesCommands(model: model)
            #if os(macOS)
            if updater.isAvailable {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            #endif
        }

        #if os(macOS)
        Settings {
            MacSettingsView(updater: updater)
                .environment(model)
                .pausesMotionWhenAway()
        }

        // An Inspector tab dragged out into its own window (`docs/inspector.md` §1).
        WindowGroup("Inspector", for: InspectorWindowRef.self) { $ref in
            if let ref {
                InspectorTabWindow(ref: ref)
                    .environment(model)
                    .pausesMotionWhenAway()
            }
        }
        .defaultSize(width: 760, height: 680)
        .windowToolbarStyle(.unified(showsTitle: true))

        // A call (`macTalk`, `docs/voice.md` §4.5): its own small window, over every app.
        Window("Talk", id: TalkCenter.windowID) {
            TalkWindowContent()
                .environment(model)
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        // Also while a call from outside the app waits to start.
        MenuBarExtra(isInserted: Binding(
            get: { TalkCenter.shared.isActive || TalkCenter.shared.pendingCall != nil },
            set: { if !$0 { TalkCenter.shared.end(); TalkCenter.shared.cancelPending() } }
        )) {
            TalkMenuBar()
                .environment(model)
        } label: {
            Label("Hermes Call", systemImage: "waveform")
        }
        #endif
    }
}

/// Menu bar and hardware-keyboard commands.
struct HermesCommands: Commands {
    let model: AppModel
    /// The key window's sheets.
    @FocusedValue(\.windowRouter) private var router
    /// A failed read's Try Again in the key window, which ⌘R runs in place of Reload Conversation.
    @FocusedValue(\.tryAgain) private var tryAgain
    @Environment(\.openWindow) private var openWindow

    /// The key window's gateway; with no window in front, the last-used one
    /// (`docs/connecting-and-voice.md` §8).
    private var workspace: BotWorkspace? {
        router.flatMap { model.workspace(in: $0.windowID) } ?? model.currentWorkspace
    }

    /// A Bot Chat is on screen in the key window.
    private var isShowingBotChat: Bool {
        if case .bot? = workspace?.selection { return true }
        return false
    }

    /// Settings is up in the key window on iPhone or iPad, where ⌘. closes it
    /// (`docs/setup.md` §3).
    private var isShowingSettings: Bool {
        #if os(iOS)
        if case .settings? = router?.sheet { return true }
        #endif
        return false
    }

    /// The open chat was marked unread (⇧⌘U flips it back).
    private var openChatIsUnread: Bool {
        guard let workspace, let key = workspace.unread.openKey else { return false }
        return workspace.unread.readMark(for: key) == .markedUnread
    }

    /// The View menu's own items (macMenuView): Chats, Bots; Tasks, Skills, Board, the card moves
    /// and Filter.
    @ViewBuilder private var viewItems: some View {
        Button("Chats") { workspace?.sidebarMode = .chats }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(workspace?.roster == nil)
        Button("Bots") { workspace?.sidebarMode = .bots }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(workspace?.roster == nil)
        Divider()
        Button("Tasks") {
            workspace?.selection = .tasks
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .disabled(workspace == nil)
        Button("Skills") {
            workspace?.selection = .skills
        }
        .keyboardShortcut("2", modifiers: [.command, .shift])
        .disabled(workspace == nil)
        // The project's Board: from its home, one of its chats, or the Board itself (back home).
        Button("Board") {
            guard let workspace, let projectID = workspace.currentProjectID else { return }
            workspace.sidebarMode = .chats
            if case .board = workspace.selection {
                workspace.selection = .project(projectID)
            } else {
                workspace.selection = .board(projectID)
            }
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(workspace?.currentProjectID == nil || workspace?.roster == nil)
        // Drag and drop's keyboard path (`docs/board.md` §6): the selected card to the next
        // column it may go to. Off while typing in the card, where ⌘→ moves the cursor.
        let board = workspace?.shownBoard
        let canMove = board.map { $0.openCardID != nil && !$0.isTyping } ?? false
        Button("Move Card Right") { Task { await board?.moveOpenCard(forward: true) } }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!canMove)
        Button("Move Card Left") { Task { await board?.moveOpenCard(forward: false) } }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!canMove)
        // The chat list's filter, as the sidebar's filter button has it (`docs/inbox.md` §5).
        if let workspace {
            Menu("Filter") { InboxFilterMenuContent(workspace: workspace) }
        } else {
            Menu("Filter") {}.disabled(true)
        }
        Divider()
    }

    var body: some Commands {
        // File (Elyx macMenuFile): New Chat, New Bot…, New Window; Pair a Device…; Close Window.
        #if os(iOS)
        // ⌘, opens Settings over the key window (`ipadSettings`); the Mac has its Settings scene.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router?.sheet = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(router == nil || router?.sheet != nil)
        }
        #endif
        CommandGroup(replacing: .newItem) {
            // On a Board, ⌘N adds a card (`docs/board.md` §2).
            if let board = workspace?.shownBoard {
                Button("New Card") {
                    board.newCard = BoardModel.NewCardTarget()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!board.isOnline || board.workflow == nil)
            } else if let workspace, workspace.detailRoute(compact: false) == .tasks {
                // In Tasks, ⌘N opens New Task, as + does (`docs/tasks.md` §4).
                Button("New Task") {
                    workspace.pendingNewTask = .empty
                }
                .keyboardShortcut("n", modifiers: .command)
            } else {
                Button("New Chat") {
                    guard let workspace else { return }
                    workspace.sidebarMode = .chats
                    // On a project home ⌘N starts the chat in that project, as its New Chat button
                    // does (`docs/projects.md` §3).
                    if case .project(let projectID) = workspace.selection {
                        workspace.startNewChat(inProject: projectID, fromHome: true)
                    } else {
                        workspace.startNewChat()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(workspace == nil)
            }
            Button("New Bot…") {
                guard let workspace, let roster = workspace.roster else { return }
                workspace.sidebarMode = .bots
                roster.isCreatingBot = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(workspace?.roster == nil)
            Button("New Window") {
                openWindow(id: HermesApp.mainWindow)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open Quickly…") {
                #if os(macOS)
                // The search palette (`macSearch`).
                router?.showsSearchPalette.toggle()
                #else
                router?.toggleQuickOpen()
                #endif
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(workspace == nil || router == nil)
            Button("Pair a Device…") {
                if let botID = workspace?.id { router?.sheet = .pairing(botID) }
            }
            .disabled(workspace == nil || router == nil)
        }
        // View (macMenuView): Chats, Bots; Tasks, Skills, Board, Filter; then the sidebar items.
        #if os(macOS)
        // The system's Show Sidebar would dock the sidebar in a narrow window and squeeze the chat;
        // this one brings it over the chat there (`docs/chat.md` §4). Replacing the sidebar group
        // also drops whatever is placed before it, so the View items live in the same group.
        CommandGroup(replacing: .sidebar) {
            viewItems
            Button(router?.layout.showsSidebar == false ? "Show Sidebar" : "Hide Sidebar") {
                router?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(router == nil)
        }
        #else
        CommandGroup(before: .sidebar) {
            viewItems
        }
        #endif
        // Chat (macMenuChat): the turn, the conversation, then the gateways.
        CommandMenu("Chat") {
            // ⌘. stops the turn; with none running, the process the Terminal shows (after a
            // confirmation); over Settings on iPhone and iPad, it closes Settings. One command:
            // UIKit refuses two with the same keys.
            let current = workspace?.currentConversation
            let closesSettings = isShowingSettings
            let stopsProcess = !closesSettings && current?.isWorking != true && current?.inspector.selectedProcessID != nil
            Button(closesSettings ? "Close Settings" : stopsProcess ? "Stop Process…" : "Stop Responding") {
                if closesSettings {
                    router?.sheet = nil
                } else if stopsProcess {
                    current?.inspector.confirmingStop = current?.inspector.selectedProcessID
                } else {
                    current?.stop()
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!closesSettings && !(current?.isWorking ?? false) && !stopsProcess)

            Button("Routines…") {
                guard let workspace, case .bot(let name) = workspace.selection else { return }
                workspace.roster?.routinesBot = name
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!isShowingBotChat)

            Button(tryAgain == nil ? "Reload Conversation" : "Try Again") {
                if let tryAgain {
                    tryAgain.run()
                } else {
                    workspace?.currentConversation.reload()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(tryAgain == nil && workspace?.currentConversation.sessionID == nil && !isShowingBotChat)

            // The chat's helpers (`docs/helpers.md`): the Team inspector, or the Team page.
            let helpers = workspace?.currentConversation.helpers
            Button(helpers?.shownTeam == nil ? "Show Team" : "Hide Team") {
                helpers?.toggleTeam()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(helpers?.latestTeamID == nil)

            Button(TalkCenter.shared.isActive ? "End Call" : "Talk") {
                if TalkCenter.shared.isActive {
                    TalkCenter.shared.end()
                } else {
                    workspace?.voiceToggleRequests += 1
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(workspace == nil && !TalkCenter.shared.isActive)

            // The Inspector (`docs/inspector.md` §1): show or hide it, open an address, switch tabs.
            let inspector = workspace?.currentConversation.inspector
            Button(inspector?.isPresented == true ? "Hide Inspector" : "Show Inspector") {
                inspector?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspector == nil)
            Button("Open Address…") {
                inspector?.showsAddressPrompt = true
                if inspector?.isPresented == false { inspector?.toggle() }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(inspector == nil)
            // Background processes (`docs/background-processes.md` §6): the Terminal, and Stop for
            // the one it shows (⌘., under Chat, when no turn runs).
            Button("Show Terminal") {
                inspector?.openTerminal()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(inspector == nil)

            if let inspector, !inspector.tabs.isEmpty {
                Menu("Inspector Tabs") {
                    ForEach(Array(inspector.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                        Button(tab.title) {
                            inspector.select(tab.id)
                            if !inspector.isPresented { inspector.toggle() }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    }
                }
            }

            // Search (`docs/search.md`): find in this chat, or search every chat in the sidebar.
            Button("Find in Chat…") {
                if let conversation = workspace?.currentConversation { conversation.find(conversation.findText ?? "") }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(workspace?.currentConversation.isEmpty ?? true)
            Button("Search Chats") {
                workspace?.sidebarMode = .chats
                router?.focusSidebarSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(workspace == nil || router == nil)

            // Checkpoints (`docs/checkpoints.md`): the sheet, and Undo for the newest reply that
            // changed files.
            let conversation = workspace?.currentConversation
            Button("Checkpoints…") {
                conversation?.checkpoints.showTimeline()
            }
            .disabled(conversation?.usesGateway != true || conversation?.sessionID == nil)
            Button("Undo File Changes…") {
                if let checkpoints = conversation?.checkpoints, let turnID = checkpoints.latestEditingTurnID {
                    checkpoints.undo(turnID: turnID)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(conversation?.usesGateway != true || conversation?.checkpoints.latestEditingTurnID == nil)

            #if os(macOS)
            // Words selected in a finished reply quote into the composer (`docs/inbox.md` §4).
            Button("Reply to Selection") {
                conversation?.selectedWords.reply()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(conversation?.selectedWords.canReply != true)
            #endif

            // Unread (`docs/inbox.md` §4, §5).
            Button("Jump to Latest") {
                workspace?.currentConversation.jumpToLatestRequests += 1
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(workspace?.currentConversation.isReadingBack != true)
            Button("Next Unread Chat") {
                workspace?.selectAdjacentUnread(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(workspace == nil)
            Button("Previous Unread Chat") {
                workspace?.selectAdjacentUnread(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(workspace == nil)
            Button(openChatIsUnread ? "Mark as Read" : "Mark as Unread") {
                workspace?.toggleOpenChatRead()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(workspace?.unread.openKey == nil)

            Button("Next Conversation") {
                workspace?.selectAdjacent(1)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(workspace == nil)
            Button("Previous Conversation") {
                workspace?.selectAdjacent(-1)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(workspace == nil)

            Divider()

            Button("Add Gateway…") {
                router?.sheet = .addGateway
            }
            .disabled(router == nil)
            ForEach(Array(model.bots.enumerated()), id: \.element.id) { index, bot in
                Toggle(bot.name, isOn: Binding(get: { bot.id == workspace?.id }, set: { if $0 { model.select(bot.id, in: router?.windowID) } }))
                    .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control]) : nil)
            }
        }
    }
}
