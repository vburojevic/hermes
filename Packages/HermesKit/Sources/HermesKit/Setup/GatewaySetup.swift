import Foundation

/// What the app knows about one gateway's setup, read for Settings → Setup (`docs/setup.md` §4).
/// Missing values weren't read (no Bot Mode, offline, an older Hermes): the checks say so rather
/// than guess.
public struct GatewaySetupFacts: Sendable, Equatable {
    /// Bot Mode's link to the gateway's backend (`hermes serve`).
    public enum BotMode: Sendable, Equatable {
        /// No backend linked: chats only.
        case notLinked
        case connecting
        /// Linked, but the backend wants a (fresh) sign-in.
        case signInNeeded
        /// Linked, and it isn't answering; the reason as the roster has it.
        case unreachable(String)
        case online
    }

    /// `GET /api/hermes/update/check`.
    public struct UpdateCheck: Sendable, Equatable {
        /// Commits behind: 0 up to date, -1 an unknown number, nil when the check couldn't run.
        public var behind: Int?
        public var canApply: Bool
        public var updateCommand: String?
        public var message: String?

        public init(behind: Int?, canApply: Bool = false, updateCommand: String? = nil, message: String? = nil) {
            self.behind = behind
            self.canApply = canApply
            self.updateCommand = updateCommand
            self.message = message
        }

        public init(json: JSONValue) {
            behind = json["behind"]?.truncatedIntValue
            canApply = json["can_apply"]?.boolValue ?? false
            updateCommand = json["update_command"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            message = json["message"]?.stringValue
        }
    }

    /// Whether the Board's kanban plugin answers.
    public enum Board: Sendable, Equatable {
        case on
        /// In `plugins.disabled`: Hermes answers 404 "Plugin not found".
        case turnedOff
        /// No such route: an older Hermes.
        case missing
    }

    public var gatewayName: String
    /// The API server answers.
    public var gatewayOnline: Bool
    /// The API server is too old for the app (`supportsNativeClient`).
    public var gatewayTooOld = false
    public var botMode: BotMode
    /// Hermes's version, from the backend or the API server.
    public var version: String?
    public var update: UpdateCheck?
    /// How the gateway's Mac schedules Hermes (`/app-push host`).
    public var hostPriority: HostPriority?
    /// What the app saw of Bot-to-Bot deliveries on this Hermes (`DeliveryProtection`).
    public var deliveryProtection: DeliveryProtection?
    /// The gateway runs on this Mac, so the app can change its launchd jobs.
    public var hostIsThisMac = false
    /// An update the person started from the app.
    public var updateRun: HermesUpdateRun?
    /// The gateway's own `config.yaml`, defaults filled in (`GET /api/config`).
    public var config: JSONValue?
    /// `/api/status`: whether the messaging gateway (which runs scheduled tasks) is running.
    public var gatewayRunning: Bool?
    /// `/api/status.fts_rebuild`: Hermes is rebuilding its search index.
    public var searchIndexRebuilding = false
    /// `setup.status.provider_configured`.
    public var providerConfigured: Bool?
    /// The default model's name, when there is one.
    public var defaultModel: String?
    /// Providers the model picker can use (`/api/model/options`).
    public var usableProviders: Int?
    public var memory: MemoryStatus?
    public var curator: CuratorStatus?
    /// `groups.capabilities.driver`.
    public var groupDriver: Bool?
    public var botCount = 0
    public var board: Board?
    /// `projects.list` answered "unknown method" (an older Hermes).
    public var projectsMissing = false
    /// Scheduled tasks whose last run failed, didn't start, or whose results didn't arrive.
    public var taskProblems: [CronJob] = []
    /// `vault.sources`: where Hermes finds logins (`docs/web.md` §3).
    public var vaultSources: [VaultSource]?
    /// `vault.sources` answered "unknown method" (a Hermes from before Passwords).
    public var vaultMissing = false
    /// Why a chat couldn't make this app Hermes's browser, last time it tried (`docs/web.md` §6).
    public var inAppBrowserRefusal: BrowserControlRefusal?

    public init(gatewayName: String, gatewayOnline: Bool, botMode: BotMode) {
        self.gatewayName = gatewayName
        self.gatewayOnline = gatewayOnline
        self.botMode = botMode
    }

    var botModeOnline: Bool { botMode == .online }
}

/// Every gateway feature's status from what was read (`docs/setup.md` §4). Pure, so each state
/// is tested; the app adds the actions.
public enum GatewaySetup {
    public enum ID {
        public static let botMode = "botMode"
        public static let hermes = "hermes"
        public static let models = "models"
        public static let memory = "memory"
        public static let checkpoints = "checkpoints"
        public static let search = "search"
        public static let board = "board"
        public static let projects = "projects"
        public static let learned = "learned"
        public static let tasks = "tasks"
        public static let groupChats = "groupChats"
        public static let priority = "priority"
        public static let botReplies = "botReplies"
    }

    public enum Docs {
        public static let botMode = HermesDocs.page("user-guide/bot-mode")
        public static let remoteBackend = HermesDocs.page("user-guide/features/web-dashboard")
        public static let updating = HermesDocs.page("getting-started/updating")
        public static let providers = HermesDocs.page("integrations/providers")
        public static let memoryProviders = HermesDocs.page("user-guide/features/memory-providers")
        public static let checkpoints = HermesDocs.page("user-guide/checkpoints-and-rollback")
        public static let sessions = HermesDocs.page("user-guide/sessions")
        public static let kanban = HermesDocs.page("user-guide/features/kanban")
        public static let curator = HermesDocs.page("user-guide/features/curator")
        public static let cron = HermesDocs.page("user-guide/features/cron")
        public static let cronDelivery = URL(string: "https://hermes-agent.nousresearch.com/docs/user-guide/features/cron#delivery-options")!
        public static let desktop = HermesDocs.page("user-guide/desktop")
        /// Hermes's fix for deliveries dying with the sender's chat (upstream, not merged yet).
        public static let botDeliveryFix = URL(string: "https://github.com/NousResearch/hermes-agent/pull/136220")!
    }

    // MARK: Bot Mode and Hermes

    /// Steps that give a gateway Bot Mode: the backend, and from another device a password.
    public static func botModeSteps(_ facts: GatewaySetupFacts) -> [SetupStep] {
        [
            SetupStep(String(localized: "On \(facts.gatewayName), start Hermes's backend (Hermes Desktop starts it for you):"), command: "hermes serve"),
            SetupStep(String(localized: "To link it from another device, give it a sign-in: add these to ~/.hermes/.env on \(facts.gatewayName):"),
                      command: "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=…\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=…\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=…"),
            SetupStep(String(localized: "Then serve it on the network, and link it here with its address, username and password:"), command: "hermes serve --host 0.0.0.0"),
        ]
    }

    public static func botMode(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Bot Mode")
        switch facts.botMode {
        case .notLinked:
            return SetupStatus(
                id: ID.botMode, state: .notSetUp, title: title,
                detail: String(localized: "Bots, projects, the Board, memory, Apps and Tools and searching what was said need Bot Mode. Chats work without it."),
                fix: .linkBotMode,
                steps: botModeSteps(facts), docs: Docs.botMode
            )
        case .connecting:
            return .checking(id: ID.botMode, title: title)
        case .signInNeeded:
            return SetupStatus(
                id: ID.botMode, state: .notSetUp, title: title,
                detail: String(localized: "Bot Mode on \(facts.gatewayName) needs you to sign in again."),
                fix: .signIn,
                docs: Docs.remoteBackend
            )
        case .unreachable(let reason):
            return SetupStatus(
                id: ID.botMode, state: .unknown, title: title,
                detail: reason,
                fallback: String(localized: "Chats still work."),
                fix: SetupFix(title: String(localized: "Edit Gateway…"), action: .linkBotMode),
                steps: [SetupStep(String(localized: "Check that Hermes's backend is running on \(facts.gatewayName):"), command: "hermes serve")],
                docs: Docs.botMode
            )
        case .online:
            return SetupStatus(
                id: ID.botMode, state: .ready, title: title,
                detail: facts.botCount == 1 ? String(localized: "Linked · 1 Bot") : String(localized: "Linked · \(facts.botCount) Bots")
            )
        }
    }

    public static func hermes(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Hermes Agent")
        if facts.gatewayTooOld {
            return SetupStatus(
                id: ID.hermes, state: .notSetUp, title: title,
                detail: String(localized: "This gateway's Hermes Agent is too old for the app."),
                steps: [.updateHermes, .restartGateway], docs: Docs.updating
            )
        }
        guard let version = facts.version else {
            return .unknown(id: ID.hermes, title: title, reason: String(localized: "Can't reach \(facts.gatewayName) to ask."))
        }
        let detail = String(localized: "Version \(version)")
        let command = facts.update?.updateCommand ?? "hermes update"
        let updateSteps = [SetupStep(String(localized: "To update, on \(facts.gatewayName):"), command: command)]
        switch facts.updateRun {
        case .starting?, .running?:
            // The page shows the run under the section (`GatewayJob`): its step, lines and when
            // Hermes restarts.
            return SetupStatus(id: ID.hermes, state: .ready, title: title, detail: detail + " · " + String(localized: "updating…"))
        case .finished(.updated(let newVersion))?:
            return SetupStatus(
                id: ID.hermes, state: .ready, title: title,
                detail: String(localized: "Version \(newVersion ?? version)"),
                fallback: String(localized: "Updated.")
            )
        case .finished(.owes(let followups, let userAction))?:
            var steps: [SetupStep] = []
            if !followups.isEmpty {
                steps.append(SetupStep(String(localized: "To finish, update again here or on \(facts.gatewayName):"), command: "hermes update"))
            }
            if let userAction {
                steps.append(SetupStep(userAction))
            }
            return SetupStatus(
                id: ID.hermes, state: .limited, title: title,
                detail: followups.isEmpty
                    ? String(localized: "Updated, but Hermes needs something from you.")
                    : String(localized: "Updated, but Hermes still has steps to finish: \(followups)."),
                fix: followups.isEmpty ? nil : SetupFix(title: String(localized: "Update Again…")),
                steps: steps, docs: Docs.updating
            )
        case .finished(.failed(let code, let line))?:
            return SetupStatus(
                id: ID.hermes, state: .limited, title: title,
                detail: String(localized: "The update stopped before it finished (exit \(code))."),
                fallback: line,
                fix: SetupFix(title: String(localized: "Try Again…")),
                steps: [SetupStep(String(localized: "To see why, update on \(facts.gatewayName):"), command: command)],
                docs: Docs.updating
            )
        case .finished(.unknown)?, .lostTouch?:
            return SetupStatus(
                id: ID.hermes, state: .unknown, title: title,
                detail: String(localized: "\(facts.gatewayName) stopped answering while Hermes updated, so the app can't tell how it went."),
                fallback: String(localized: "Check Again in a minute to see its version."),
                steps: updateSteps, docs: Docs.updating
            )
        case .refused(let message, let command)?:
            return SetupStatus(
                id: ID.hermes, state: .ready, title: title,
                detail: detail + " · " + String(localized: "an update is available"),
                fallback: message,
                steps: command.map { [SetupStep(String(localized: "To update, on \(facts.gatewayName):"), command: $0)] } ?? [],
                docs: Docs.updating
            )
        case nil, .couldNotStart?:
            break
        }
        if let update = facts.update, let behind = update.behind, behind != 0 {
            // Up to date isn't a setup matter: still ready, with the way to update. Hermes
            // updates itself only from a git checkout (`can_apply`); its message says when an
            // update would move back to a stable release.
            return SetupStatus(
                id: ID.hermes, state: .ready, title: title,
                detail: detail + " · " + String(localized: "an update is available"),
                fallback: update.canApply ? update.message : nil,
                fix: update.canApply ? SetupFix(title: String(localized: "Update Hermes…")) : nil,
                steps: update.canApply ? [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: command)] : updateSteps,
                docs: Docs.updating
            )
        }
        return SetupStatus(id: ID.hermes, state: .ready, title: title, detail: detail)
    }

    // MARK: Hermes's settings

    public static func models(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Models")
        let steps = [SetupStep(String(localized: "On \(facts.gatewayName), choose a provider and a model:"), command: "hermes model")]
        if facts.providerConfigured == false || facts.usableProviders == 0 {
            return SetupStatus(
                id: ID.models, state: .notSetUp, title: title,
                detail: String(localized: "Hermes on \(facts.gatewayName) has no model provider, so chats get no answers."),
                fix: facts.botModeOnline ? SetupFix(title: String(localized: "Choose a Provider…")) : nil,
                steps: steps, docs: Docs.providers
            )
        }
        guard facts.providerConfigured != nil || facts.usableProviders != nil else {
            return .unknown(id: ID.models, title: title, reason: String(localized: "Can't reach \(facts.gatewayName) to ask."))
        }
        return SetupStatus(id: ID.models, state: .ready, title: title, detail: facts.defaultModel.map { String(localized: "Default: \($0)") })
    }

    public static func memory(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Memory")
        guard facts.botModeOnline else { return needsBotMode(id: ID.memory, title: title, facts) }
        guard let memory = facts.memory else {
            return .unknown(id: ID.memory, title: title, reason: String(localized: "Hermes didn't say which memory it uses."))
        }
        if let provider = memory.providers.first(where: { $0.name == memory.active }), !provider.isReady {
            return SetupStatus(
                id: ID.memory, state: .limited, title: title,
                detail: String(localized: "\(provider.title) isn't set up on \(facts.gatewayName)."),
                fallback: String(localized: "Hermes remembers with its built-in memory until it is."),
                steps: [SetupStep(String(localized: "On \(facts.gatewayName), set it up:"), command: "hermes memory setup \(provider.name)")],
                docs: Docs.memoryProviders
            )
        }
        return SetupStatus(id: ID.memory, state: .ready, title: title, detail: memory.activeTitle)
    }

    public static func checkpoints(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Undo for Files")
        guard let config = facts.config else {
            return facts.botModeOnline
                ? .unknown(id: ID.checkpoints, title: title, reason: String(localized: "Hermes didn't send its settings."))
                : needsBotMode(id: ID.checkpoints, title: title, facts)
        }
        let backend = config["terminal"]?["backend"]?.stringValue ?? "local"
        if config["checkpoints"]?["enabled"]?.boolValue != true {
            return SetupStatus(
                id: ID.checkpoints, state: .notSetUp, title: title,
                detail: String(localized: "Hermes doesn't save a chat's folder before it edits files, so there's nothing to undo."),
                fix: SetupFix(title: String(localized: "Turn On")),
                steps: [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: "hermes config set checkpoints.enabled true")],
                docs: Docs.checkpoints
            )
        }
        if backend != "local", backend != "ssh" {
            return SetupStatus(
                id: ID.checkpoints, state: .limited, title: title,
                detail: String(localized: "Hermes runs commands in \(backend), where it takes no checkpoints."),
                fallback: String(localized: "Chats show what changed, without undo."),
                steps: [SetupStep(String(localized: "To use undo, run commands on \(facts.gatewayName) itself:"), command: "hermes config set terminal.backend local")],
                docs: Docs.checkpoints
            )
        }
        return SetupStatus(id: ID.checkpoints, state: .ready, title: title, detail: String(localized: "Hermes saves the folder before each turn that edits files."))
    }

    public static func search(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Search")
        switch facts.botMode {
        case .online:
            if facts.searchIndexRebuilding {
                return SetupStatus(
                    id: ID.search, state: .limited, title: title,
                    detail: String(localized: "Hermes is rebuilding its search index."),
                    fallback: String(localized: "Results may be missing chats until it's done.")
                )
            }
            return SetupStatus(id: ID.search, state: .ready, title: title, detail: String(localized: "Searches what was said in every chat."))
        case .connecting:
            return .checking(id: ID.search, title: title)
        default:
            return SetupStatus(
                id: ID.search, state: .limited, title: title,
                detail: String(localized: "Searching what was said needs Bot Mode."),
                fallback: String(localized: "Search finds chats by their titles."),
                fix: botModeFix(facts), docs: Docs.sessions
            )
        }
    }

    public static func board(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Board")
        guard facts.botModeOnline else { return needsBotMode(id: ID.board, title: title, facts) }
        switch facts.board {
        case .turnedOff:
            return SetupStatus(
                id: ID.board, state: .notSetUp, title: title,
                detail: String(localized: "The Board is turned off on \(facts.gatewayName)."),
                fix: SetupFix(title: String(localized: "Turn On")),
                steps: [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: "hermes plugins enable kanban")],
                docs: Docs.kanban
            )
        case .missing:
            return SetupStatus(
                id: ID.board, state: .notSetUp, title: title,
                detail: String(localized: "This version of Hermes has no Board."),
                steps: [.updateHermes], docs: Docs.kanban
            )
        case .on:
            if facts.gatewayRunning == false {
                return SetupStatus(
                    id: ID.board, state: .limited, title: title,
                    detail: String(localized: "Cards wait in Ready: the gateway that hands them to Hermes isn't running."),
                    fallback: String(localized: "You can still add and move cards."),
                    steps: [SetupStep(String(localized: "On \(facts.gatewayName), start the gateway:"), command: "hermes gateway start")],
                    docs: Docs.kanban
                )
            }
            return SetupStatus(id: ID.board, state: .ready, title: title, detail: String(localized: "Hermes and your Bots work through cards as they're ready."))
        case nil:
            return .unknown(id: ID.board, title: title, reason: String(localized: "Hermes didn't answer about the Board."))
        }
    }

    public static func projects(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Projects")
        guard facts.botModeOnline else { return needsBotMode(id: ID.projects, title: title, facts) }
        if facts.projectsMissing {
            return SetupStatus(
                id: ID.projects, state: .notSetUp, title: title,
                detail: String(localized: "This version of Hermes has no projects."),
                steps: [.updateHermes], docs: Docs.desktop
            )
        }
        return SetupStatus(id: ID.projects, state: .ready, title: title, detail: String(localized: "Chats can belong to a project, in lanes by branch."))
    }

    public static func learned(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Tidying")
        guard facts.botModeOnline else { return needsBotMode(id: ID.learned, title: title, facts) }
        guard let curator = facts.curator else {
            return .unknown(id: ID.learned, title: title, reason: String(localized: "Hermes didn't answer about tidying."))
        }
        if !curator.enabled {
            return SetupStatus(
                id: ID.learned, state: .limited, title: title,
                detail: String(localized: "Tidying is turned off on \(facts.gatewayName)."),
                fallback: String(localized: "Hermes still learns skills; nothing merges or archives them."),
                fix: SetupFix(title: String(localized: "Turn On")),
                steps: [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: "hermes config set curator.enabled true")],
                docs: Docs.curator
            )
        }
        if curator.paused {
            return SetupStatus(
                id: ID.learned, state: .limited, title: title,
                detail: String(localized: "Tidying is paused."),
                fallback: String(localized: "Hermes still learns skills; nothing merges or archives them."),
                fix: SetupFix(title: String(localized: "Resume")),
                steps: [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: "hermes curator resume")],
                docs: Docs.curator
            )
        }
        return SetupStatus(id: ID.learned, state: .ready, title: title, detail: String(localized: "Hermes tidies what it learned by itself."))
    }

    public static func tasks(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Scheduled Tasks")
        switch facts.gatewayRunning {
        case false?:
            return SetupStatus(
                id: ID.tasks, state: .notSetUp, title: title,
                detail: String(localized: "Tasks don't run while the gateway on \(facts.gatewayName) is stopped."),
                steps: [
                    SetupStep(String(localized: "On \(facts.gatewayName), start the gateway:"), command: "hermes gateway start"),
                    SetupStep(String(localized: "To keep it running after a restart, install it as a service:"), command: "hermes gateway install"),
                ],
                docs: Docs.cron
            )
        case nil where !facts.gatewayOnline:
            return .unknown(id: ID.tasks, title: title, reason: String(localized: "Can't reach \(facts.gatewayName) to ask."))
        default:
            break
        }
        let undelivered = facts.taskProblems.filter(\.deliveryFailed)
        if let first = undelivered.first {
            return SetupStatus(
                id: ID.tasks, state: .limited, title: title,
                detail: undelivered.count == 1
                    ? String(localized: "\(first.name)'s results didn't arrive: \(first.problem ?? "")")
                    : String(localized: "\(undelivered.count) tasks' results didn't arrive."),
                fallback: String(localized: "The tasks run; their results are in each task's runs."),
                steps: [SetupStep(String(localized: "Set up where they deliver on \(facts.gatewayName) (for a chat app, its home channel), or change the task to deliver somewhere else:"),
                                  command: "hermes gateway setup")],
                docs: Docs.cronDelivery
            )
        }
        if let failed = facts.taskProblems.first(where: { $0.hasFailed || $0.missedRun }) {
            let count = facts.taskProblems.filter { $0.hasFailed || $0.missedRun }.count
            return SetupStatus(
                id: ID.tasks, state: .limited, title: title,
                detail: count == 1
                    ? String(localized: "\(failed.name)'s last run didn't work: \(failed.problem ?? "")")
                    : String(localized: "\(count) tasks' last runs didn't work."),
                fallback: String(localized: "Each task tries again at its next run."),
                docs: Docs.cron
            )
        }
        return SetupStatus(id: ID.tasks, state: .ready, title: title, detail: String(localized: "The gateway runs them on schedule."))
    }

    public static func groupChats(_ facts: GatewaySetupFacts) -> SetupStatus {
        let title = String(localized: "Group Chats")
        guard facts.botModeOnline else { return needsBotMode(id: ID.groupChats, title: title, facts) }
        if facts.config?["dashboard"]?["turn_isolation"]?.boolValue == true {
            return SetupStatus(
                id: ID.groupChats, state: .notSetUp, title: title,
                detail: String(localized: "Bots can't reply in group chats while turn isolation is on: their turns wait forever."),
                fix: SetupFix(title: String(localized: "Turn Off Turn Isolation")),
                steps: [SetupStep(String(localized: "Or on \(facts.gatewayName):"), command: "hermes config set dashboard.turn_isolation false")],
                docs: Docs.botMode
            )
        }
        if facts.groupDriver == false {
            return SetupStatus(
                id: ID.groupChats, state: .notSetUp, title: title,
                detail: String(localized: "Group chats aren't running on \(facts.gatewayName)."),
                steps: [SetupStep(String(localized: "On \(facts.gatewayName), restart Hermes's backend (or quit and reopen Hermes Desktop):"), command: "hermes serve")],
                docs: Docs.botMode
            )
        }
        if facts.botCount < 2 {
            return SetupStatus(
                id: ID.groupChats, state: .limited, title: title,
                detail: String(localized: "A group chat needs two Bots."),
                fallback: String(localized: "Your Bot can still chat with you on its own."),
                steps: [SetupStep(String(localized: "In Bots, choose New Bot to make another."))],
                docs: Docs.botMode
            )
        }
        return SetupStatus(id: ID.groupChats, state: .ready, title: title, detail: String(localized: "Your Bots can talk together in group chats."))
    }

    // MARK: Helpers

    /// A feature that runs on Bot Mode, on a gateway without it working.
    public static func needsBotMode(id: String, title: String, _ facts: GatewaySetupFacts) -> SetupStatus {
        switch facts.botMode {
        case .connecting:
            return .checking(id: id, title: title)
        case .unreachable:
            return .unknown(id: id, title: title, reason: String(localized: "Bot Mode on \(facts.gatewayName) isn't answering."))
        case .signInNeeded:
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "Needs Bot Mode, which needs you to sign in again."),
                fix: .signIn, docs: Docs.botMode
            )
        case .notLinked, .online:
            return SetupStatus(
                id: id, state: .notSetUp, title: title,
                detail: String(localized: "Needs Bot Mode, which isn't linked for \(facts.gatewayName)."),
                fix: .linkBotMode,
                steps: botModeSteps(facts), docs: Docs.botMode
            )
        }
    }

    static func botModeFix(_ facts: GatewaySetupFacts) -> SetupFix? {
        switch facts.botMode {
        case .notLinked: .linkBotMode
        case .signInNeeded: .signIn
        default: nil
        }
    }
}
