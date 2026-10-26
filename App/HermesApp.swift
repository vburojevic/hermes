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
                            #if os(iOS)
                            FrameMonitor.shared.startIfRequested()
                            #endif
                            ScrollRun.shared.startIfRequested()
                        }
                }
                #else
                RootView()
                #endif
            }
                .environment(model)
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 520)
                #endif
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(AppModel.refreshTask)) { [model] in
            await model.refreshInBackground()
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
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
            SidebarCommands()
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

        MenuBarExtra(isInserted: Binding(get: { TalkCenter.shared.isActive }, set: { if !$0 { TalkCenter.shared.end() } })) {
            TalkMenuBar()
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
    @Environment(\.openWindow) private var openWindow

    /// The open chat was marked unread (⇧⌘U flips it back).
    private var openChatIsUnread: Bool {
        guard let workspace = model.currentWorkspace, let key = workspace.unread.openKey else { return false }
        return workspace.unread.readMark(for: key) == .markedUnread
    }

    var body: some Commands {
        // File (Elyx macMenuFile): New Chat, New Bot…, New Window; Pair a Device…; Close Window.
        CommandGroup(replacing: .newItem) {
            // On a Board, ⌘N adds a card (`docs/board.md` §2).
            if let board = model.currentWorkspace?.shownBoard {
                Button("New Card") {
                    board.newCard = BoardModel.NewCardTarget()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!board.isOnline || board.workflow == nil)
            } else {
                Button("New Chat") {
                    guard let workspace = model.currentWorkspace else { return }
                    workspace.sidebarMode = .chats
                    workspace.startNewChat()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.currentWorkspace == nil)
            }
            Button("New Bot…") {
                guard let workspace = model.currentWorkspace, let roster = workspace.roster else { return }
                workspace.sidebarMode = .bots
                roster.isCreatingBot = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(model.currentWorkspace?.roster == nil)
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
            .disabled(model.currentWorkspace == nil || router == nil)
            Button("Pair a Device…") {
                if let botID = model.selectedBotID { router?.sheet = .pairing(botID) }
            }
            .disabled(model.selectedBotID == nil || router == nil)
        }
        // View (macMenuView): Chats, Bots; Tasks, Skills; then the system's sidebar items.
        CommandGroup(before: .sidebar) {
            Button("Chats") { model.currentWorkspace?.sidebarMode = .chats }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(model.currentWorkspace?.roster == nil)
            Button("Bots") { model.currentWorkspace?.sidebarMode = .bots }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model.currentWorkspace?.roster == nil)
            Divider()
            Button("Tasks") {
                model.currentWorkspace?.selection = .tasks
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            .disabled(model.currentWorkspace == nil)
            Button("Skills") {
                model.currentWorkspace?.selection = .skills
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .disabled(model.currentWorkspace == nil)
            // The project's Board: from its home, one of its chats, or the Board itself (back home).
            Button("Board") {
                guard let workspace = model.currentWorkspace, let projectID = workspace.currentProjectID else { return }
                workspace.sidebarMode = .chats
                if case .board = workspace.selection {
                    workspace.selection = .project(projectID)
                } else {
                    workspace.selection = .board(projectID)
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(model.currentWorkspace?.currentProjectID == nil || model.currentWorkspace?.roster == nil)
            // Drag and drop's keyboard path (`docs/board.md` §6): the selected card to the next
            // column it may go to. Off while typing in the card, where ⌘→ moves the cursor.
            let board = model.currentWorkspace?.shownBoard
            let canMove = board.map { $0.openCardID != nil && !$0.isTyping } ?? false
            Button("Move Card Right") { Task { await board?.moveOpenCard(forward: true) } }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!canMove)
            Button("Move Card Left") { Task { await board?.moveOpenCard(forward: false) } }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!canMove)
            Divider()
        }
        // Chat (macMenuChat): the turn, the conversation, then the gateways.
        CommandMenu("Chat") {
            // ⌘. stops the turn; with none running, the process the Terminal shows (after a
            // confirmation). One command: UIKit refuses two with the same keys.
            let current = model.currentWorkspace?.currentConversation
            let stopsProcess = current?.isWorking != true && current?.inspector.selectedProcessID != nil
            Button(stopsProcess ? "Stop Process…" : "Stop Responding") {
                if stopsProcess {
                    current?.inspector.confirmingStop = current?.inspector.selectedProcessID
                } else {
                    current?.stop()
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(current?.isWorking ?? false) && !stopsProcess)

            Button("Routines…") {
                guard let workspace = model.currentWorkspace, case .bot(let name) = workspace.selection else { return }
                workspace.roster?.routinesBot = name
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!model.isShowingBotChat)

            Button("Reload Conversation") {
                model.currentWorkspace?.currentConversation.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.currentWorkspace?.currentConversation.sessionID == nil && !model.isShowingBotChat)

            // The chat's helpers (`docs/helpers.md`): the Team inspector, or the Team page.
            let helpers = model.currentWorkspace?.currentConversation.helpers
            Button(helpers?.shownTeam == nil ? "Show Team" : "Hide Team") {
                helpers?.toggleTeam()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(helpers?.latestTeamID == nil)

            Button(TalkCenter.shared.isActive ? "End Call" : "Talk") {
                if TalkCenter.shared.isActive {
                    TalkCenter.shared.end()
                } else {
                    model.currentWorkspace?.voiceToggleRequests += 1
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(model.currentWorkspace == nil && !TalkCenter.shared.isActive)

            // The Inspector (`docs/inspector.md` §1): show or hide it, open an address, switch tabs.
            let inspector = model.currentWorkspace?.currentConversation.inspector
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
                if let conversation = model.currentWorkspace?.currentConversation { conversation.find(conversation.findText ?? "") }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.currentWorkspace?.currentConversation.isEmpty ?? true)
            Button("Search Chats") {
                model.currentWorkspace?.sidebarMode = .chats
                router?.focusSidebarSearch()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(model.currentWorkspace == nil || router == nil)

            // Checkpoints (`docs/checkpoints.md`): the sheet, and Undo for the newest reply that
            // changed files.
            let conversation = model.currentWorkspace?.currentConversation
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

            // Unread (`docs/inbox.md` §4, §5).
            Button("Jump to Latest") {
                model.currentWorkspace?.currentConversation.jumpToLatestRequests += 1
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(model.currentWorkspace?.currentConversation.isReadingBack != true)
            Button("Next Unread Chat") {
                model.currentWorkspace?.selectAdjacentUnread(1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(model.currentWorkspace == nil)
            Button("Previous Unread Chat") {
                model.currentWorkspace?.selectAdjacentUnread(-1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(model.currentWorkspace == nil)
            Button(openChatIsUnread ? "Mark as Read" : "Mark as Unread") {
                model.currentWorkspace?.toggleOpenChatRead()
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(model.currentWorkspace?.unread.openKey == nil)

            Button("Next Conversation") {
                model.currentWorkspace?.selectAdjacent(1)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(model.currentWorkspace == nil)
            Button("Previous Conversation") {
                model.currentWorkspace?.selectAdjacent(-1)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(model.currentWorkspace == nil)

            Divider()

            Button("Add Gateway…") {
                router?.sheet = .addGateway
            }
            .disabled(router == nil)
            ForEach(Array(model.bots.enumerated()), id: \.element.id) { index, bot in
                Toggle(bot.name, isOn: Binding(get: { bot.id == model.selectedBotID }, set: { if $0 { model.select(bot.id) } }))
                    .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control]) : nil)
            }
        }
    }
}
