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

    var body: some Scene {
        WindowGroup(id: Self.mainWindow) {
            Group {
                #if DEBUG
                if let page = UserDefaults.standard.string(forKey: "HERMES_GALLERY") {
                    DesignGallery(page: page)
                } else {
                    RootView()
                        #if os(iOS)
                        .onAppear { FrameMonitor.shared.startIfRequested() }
                        #endif
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

    var body: some Commands {
        // File (Elyx macMenuFile): New Chat, New Bot…, New Window; Pair a Device…; Close Window.
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                guard let workspace = model.currentWorkspace else { return }
                workspace.sidebarMode = .chats
                workspace.startNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.currentWorkspace == nil)
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
                router?.toggleQuickOpen()
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
            Divider()
        }
        // Chat (macMenuChat): the turn, the conversation, then the gateways.
        CommandMenu("Chat") {
            Button("Stop Responding") {
                model.currentWorkspace?.currentConversation.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(model.currentWorkspace?.currentConversation.isWorking ?? false))

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
