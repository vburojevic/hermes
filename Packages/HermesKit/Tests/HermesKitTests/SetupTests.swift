import Foundation
import Testing
@testable import HermesKit

@Suite("Setup states")
struct SetupStatusTests {
    @Test func notSetUpComesFirstAndReadyLast() {
        let statuses = [
            SetupStatus(id: "a", state: .ready, title: "A"),
            SetupStatus(id: "b", state: .unknown, title: "B"),
            SetupStatus(id: "c", state: .notSetUp, title: "C"),
            SetupStatus(id: "d", state: .limited, title: "D"),
            SetupStatus(id: "e", state: .notSetUp, title: "E"),
        ]
        #expect(statuses.sortedForAttention.map(\.id) == ["c", "e", "d", "b", "a"])
        #expect(statuses.needingAttention == 3)
    }

    @Test func stepsShowUnlessChecking() {
        let steps = [SetupStep.updateHermes]
        #expect(SetupStatus(id: "x", state: .notSetUp, title: "X", steps: steps).showsSteps)
        #expect(SetupStatus(id: "x", state: .limited, title: "X", steps: steps).showsSteps)
        #expect(SetupStatus(id: "x", state: .unknown, title: "X", steps: steps).showsSteps)
        #expect(SetupStatus(id: "x", state: .ready, title: "X", steps: steps).showsSteps)
        #expect(!SetupStatus(id: "x", state: .checking, title: "X", steps: steps).showsSteps)
        #expect(!SetupStatus(id: "x", state: .notSetUp, title: "X").showsSteps)
    }

    @Test func docsPagesLiveUnderTheDocsRoot() {
        #expect(HermesDocs.page("user-guide/bot-mode").absoluteString
            == "https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode")
        #expect(HermesDocs.page("user-guide/features/kanban").absoluteString
            == "https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban")
    }
}

@Suite("Gateway setup checks")
struct GatewaySetupTests {
    private func facts(_ botMode: GatewaySetupFacts.BotMode = .online, config: JSONValue? = nil) -> GatewaySetupFacts {
        var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: botMode)
        facts.config = config
        facts.botCount = 3
        facts.version = "0.21.6"
        return facts
    }

    private func config(_ text: String) -> JSONValue {
        JSONValue.parse(Data(text.utf8))!
    }

    @Test func botModeStates() {
        #expect(GatewaySetup.botMode(facts(.notLinked)).state == .notSetUp)
        #expect(GatewaySetup.botMode(facts(.notLinked)).fix != nil)
        #expect(GatewaySetup.botMode(facts(.notLinked)).steps.first?.command == "hermes serve")
        #expect(GatewaySetup.botMode(facts(.signInNeeded)).fix?.title == "Sign In…")
        let offline = GatewaySetup.botMode(facts(.unreachable("Bots are offline")))
        #expect(offline.state == .unknown)
        #expect(offline.detail == "Bots are offline")
        #expect(GatewaySetup.botMode(facts()).state == .ready)
        #expect(GatewaySetup.botMode(facts()).detail == "Linked · 3 Bots")
    }

    @Test func botModeFeaturesSayWhatTheyNeed() {
        for check in [GatewaySetup.memory, GatewaySetup.board, GatewaySetup.projects, GatewaySetup.learned, GatewaySetup.groupChats] {
            let status = check(facts(.notLinked))
            #expect(status.state == .notSetUp)
            #expect(status.fix?.title == "Link Bot Mode…")
            #expect(check(facts(.connecting)).state == .checking)
            #expect(check(facts(.unreachable("x"))).state == .unknown)
        }
        let search = GatewaySetup.search(facts(.notLinked))
        #expect(search.state == .limited)
        #expect(search.fallback == "Search finds chats by their titles.")
    }

    @Test func hermesVersion() {
        var tooOld = facts()
        tooOld.gatewayTooOld = true
        #expect(GatewaySetup.hermes(tooOld).state == .notSetUp)
        #expect(GatewaySetup.hermes(tooOld).steps.map(\.command) == ["hermes update", "hermes gateway restart"])
        #expect(GatewaySetup.hermes(facts()).detail == "Version 0.21.6")
        var behind = facts()
        behind.update = .init(json: config(#"{"behind": 12, "can_apply": true, "update_command": "hermes update"}"#))
        let update = GatewaySetup.hermes(behind)
        #expect(update.state == .ready)
        #expect(update.showsSteps)
        #expect(update.detail == "Version 0.21.6 · an update is available")
        #expect(update.fix?.title == "Update Hermes…")
        #expect(update.steps.map(\.text) == ["Or on Studio Mac:"])
        var container = facts()
        container.update = .init(json: config(#"{"behind": -1, "can_apply": false, "update_command": "docker pull nousresearch/hermes-agent:latest"}"#))
        #expect(GatewaySetup.hermes(container).fix == nil)
        #expect(GatewaySetup.hermes(container).steps.map(\.command) == ["docker pull nousresearch/hermes-agent:latest"])
        var unknown = facts()
        unknown.version = nil
        #expect(GatewaySetup.hermes(unknown).state == .unknown)
    }

    @Test func hermesWhileTheAppUpdatesIt() {
        var run = facts()
        run.update = .init(json: config(#"{"behind": 12, "can_apply": true, "update_command": "hermes update"}"#))
        run.updateRun = .running
        let running = GatewaySetup.hermes(run)
        #expect(running.detail == "Version 0.21.6 · updating…")
        #expect(running.fallback == nil)
        #expect(running.fix == nil)
        run.updateRun = .finished(.updated(version: "0.22.0"))
        #expect(GatewaySetup.hermes(run).detail == "Version 0.22.0")
        run.updateRun = .finished(.owes(followups: "restart gateway (still draining)", userAction: nil))
        #expect(GatewaySetup.hermes(run).state == .limited)
        #expect(GatewaySetup.hermes(run).fix?.title == "Update Again…")
        run.updateRun = .finished(.owes(followups: "", userAction: "stash: run git stash pop in ~/.hermes/hermes-agent"))
        #expect(GatewaySetup.hermes(run).fix == nil)
        #expect(GatewaySetup.hermes(run).steps.map(\.text) == ["stash: run git stash pop in ~/.hermes/hermes-agent"])
        run.updateRun = .finished(.failed(exitCode: 1, lastLine: "error: Your local changes would be overwritten"))
        #expect(GatewaySetup.hermes(run).fallback == "error: Your local changes would be overwritten")
        #expect(GatewaySetup.hermes(run).fix?.title == "Try Again…")
        run.updateRun = .lostTouch
        #expect(GatewaySetup.hermes(run).state == .unknown)
        run.updateRun = .refused(message: "Hermes updates are managed outside this dashboard.", command: nil)
        #expect(GatewaySetup.hermes(run).fallback == "Hermes updates are managed outside this dashboard.")
        #expect(GatewaySetup.hermes(run).fix == nil)
    }

    @Test func models() {
        var none = facts()
        none.providerConfigured = false
        #expect(GatewaySetup.models(none).state == .notSetUp)
        #expect(GatewaySetup.models(none).fix != nil)
        var chatsOnly = facts(.notLinked)
        chatsOnly.usableProviders = 0
        #expect(GatewaySetup.models(chatsOnly).state == .notSetUp)
        #expect(GatewaySetup.models(chatsOnly).fix == nil)
        var ready = facts()
        ready.providerConfigured = true
        ready.defaultModel = "claude-opus-5-5"
        #expect(GatewaySetup.models(ready).detail == "Default: claude-opus-5-5")
        #expect(GatewaySetup.models(facts()).state == .unknown)
    }

    @Test func memoryProviderThatIsntSetUpFallsBackToBuiltIn() {
        var honcho = facts()
        honcho.memory = MemoryStatus(active: "honcho", providers: [MemoryProvider(name: "honcho", status: "needs_config")])
        let status = GatewaySetup.memory(honcho)
        #expect(status.state == .limited)
        #expect(status.steps.first?.command == "hermes memory setup honcho")
        var builtIn = facts()
        builtIn.memory = MemoryStatus()
        #expect(GatewaySetup.memory(builtIn).state == .ready)
        #expect(GatewaySetup.memory(builtIn).detail == "Built-in")
    }

    @Test func checkpoints() {
        #expect(GatewaySetup.checkpoints(facts(config: config(#"{"checkpoints": {"enabled": false}}"#))).state == .notSetUp)
        #expect(GatewaySetup.checkpoints(facts(config: config(#"{"checkpoints": {"enabled": false}}"#))).fix?.title == "Turn On")
        let docker = GatewaySetup.checkpoints(facts(config: config(#"{"checkpoints": {"enabled": true}, "terminal": {"backend": "docker"}}"#)))
        #expect(docker.state == .limited)
        #expect(docker.detail == "Hermes runs commands in docker, where it takes no checkpoints.")
        #expect(GatewaySetup.checkpoints(facts(config: config(#"{"checkpoints": {"enabled": true}, "terminal": {"backend": "ssh"}}"#))).state == .ready)
    }

    @Test func board() {
        var off = facts()
        off.board = .turnedOff
        #expect(GatewaySetup.board(off).fix?.title == "Turn On")
        #expect(GatewaySetup.board(off).steps.first?.command == "hermes plugins enable kanban")
        var missing = facts()
        missing.board = .missing
        #expect(GatewaySetup.board(missing).steps == [.updateHermes])
        var stopped = facts()
        stopped.board = .on
        stopped.gatewayRunning = false
        #expect(GatewaySetup.board(stopped).state == .limited)
        stopped.gatewayRunning = true
        #expect(GatewaySetup.board(stopped).state == .ready)
    }

    @Test func tidying() {
        var off = facts()
        off.curator = CuratorStatus(enabled: false)
        #expect(GatewaySetup.learned(off).state == .limited)
        #expect(GatewaySetup.learned(off).fix?.title == "Turn On")
        var paused = facts()
        paused.curator = CuratorStatus(paused: true)
        #expect(GatewaySetup.learned(paused).fix?.title == "Resume")
        var on = facts()
        on.curator = CuratorStatus()
        #expect(GatewaySetup.learned(on).state == .ready)
    }

    @Test func tasksNeedTheGatewayRunning() {
        var stopped = facts()
        stopped.gatewayRunning = false
        #expect(GatewaySetup.tasks(stopped).state == .notSetUp)
        #expect(GatewaySetup.tasks(stopped).steps.first?.command == "hermes gateway start")
        var running = facts()
        running.gatewayRunning = true
        #expect(GatewaySetup.tasks(running).state == .ready)
    }

    @Test func tasksSayWhenResultsDidntArrive() throws {
        let undelivered = try JSONDecoder().decode(CronJob.self, from: Data(#"{"id": "j1", "name": "Morning brief", "last_status": "delivery_failed", "last_delivery_error": "no home channel"}"#.utf8))
        let failed = try JSONDecoder().decode(CronJob.self, from: Data(#"{"id": "j2", "name": "Backup", "last_status": "error", "last_error": "refused"}"#.utf8))
        var one = facts()
        one.gatewayRunning = true
        one.taskProblems = [undelivered, failed]
        let status = GatewaySetup.tasks(one)
        #expect(status.state == .limited)
        #expect(status.detail == "Morning brief's results didn't arrive: no home channel")
        one.taskProblems = [failed]
        #expect(GatewaySetup.tasks(one).detail == "Backup's last run didn't work: refused")
    }

    @Test func groupChats() {
        let isolated = GatewaySetup.groupChats(facts(config: config(#"{"dashboard": {"turn_isolation": true}}"#)))
        #expect(isolated.state == .notSetUp)
        #expect(isolated.fix != nil)
        var noDriver = facts()
        noDriver.groupDriver = false
        #expect(GatewaySetup.groupChats(noDriver).state == .notSetUp)
        var oneBot = facts()
        oneBot.groupDriver = true
        oneBot.botCount = 1
        #expect(GatewaySetup.groupChats(oneBot).state == .limited)
        oneBot.botCount = 2
        #expect(GatewaySetup.groupChats(oneBot).state == .ready)
    }
}

@Suite("Scheduled task problems")
struct TaskProblemTests {
    private func job(_ fields: String) throws -> CronJob {
        try JSONDecoder().decode(CronJob.self, from: Data(#"{"id": "j1", "name": "Brief", \#(fields)}"#.utf8))
    }

    @Test func resultsThatDidntArriveAreNotASuccess() throws {
        let brief = try job(#""last_status": "delivery_failed", "last_delivery_error": "telegram: no home channel set", "last_error": null"#)
        #expect(!brief.hasFailed)
        #expect(brief.deliveryFailed)
        #expect(brief.problem == "telegram: no home channel set")
    }

    @Test func blockedConfigIsAFailure() throws {
        let blocked = try job(#""last_status": "blocked_config", "last_error": "[blocked_config] no API key for openai""#)
        #expect(blocked.hasFailed)
        #expect(!blocked.deliveryFailed)
    }

    @Test func aRunThatNeverStartedKeepsItsReason() throws {
        let missed = try job(#""last_status": "ok", "last_fire_error": {"at": "2026-10-18T07:30:01+02:00", "detail": "connection refused"}"#)
        #expect(missed.missedRun)
        #expect(missed.problem == "connection refused")
        #expect(!(try job(#""last_status": "ok", "last_fire_error": null, "last_delivery_error": """#)).missedRun)
        #expect(!(try job(#""last_status": "ok", "last_delivery_error": """#)).deliveryFailed)
    }

    @Test func routinesReadTheFireErrorsDetail() throws {
        let json = try #require(JSONValue.parse(Data(#"{"job_id": "r1", "name": "[bot:ops] Digest", "deliver": "bot-chat", "schedule": {"display": "every day"}, "enabled": true, "last_status": "blocked_config", "last_fire_error": {"detail": "runner down"}}"#.utf8)))
        let routine = try #require(BotRoutine(json: json))
        #expect(routine.hasFailed)
        #expect(routine.issue == "runner down")
    }
}

@Suite("Provider problems in a turn")
struct ProviderProblemTests {
    private func decode(_ type: String, _ payload: String) -> [TurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: 1, payload: JSONValue.parse(payload)!)).map(\.event)
    }

    @Test func aRefusedKeyComesWithTheProviderAndItsVariable() {
        let events = decode("message.complete", #"{"status": "error", "text": "", "error": "Provider authentication failed: 401", "error_surface": {"layer": "auth", "code": "auth", "provider": "anthropic", "provider_label": "Anthropic", "auth_kind": "api_key", "api_key_env": "ANTHROPIC_API_KEY"}}"#)
        #expect(events == [
            .finalText(""),
            .providerProblem(ProviderProblem(kind: .key(envVar: "ANTHROPIC_API_KEY"), provider: "anthropic", providerLabel: "Anthropic")),
            .failed("Provider authentication failed: 401"),
        ])
    }

    @Test func otherFailuresCarryNoProblem() {
        let events = decode("message.complete", #"{"status": "error", "text": "", "error": "529 overloaded", "error_surface": {"layer": "provider", "code": "overloaded"}}"#)
        #expect(events == [.finalText(""), .failed("529 overloaded")])
    }

    @Test func noProviderIsSaidByItsCode() {
        let events = decode("error", #"{"message": "No inference provider configured.", "code": "provider_not_configured"}"#)
        #expect(events == [.providerProblem(ProviderProblem(kind: .notConfigured)), .failed("No inference provider configured.")])
    }

    @Test func aSignInComesFromOAuth() {
        let problem = ProviderProblem.from(surface: JSONValue.parse(#"{"layer": "auth", "provider": "openai-codex", "provider_label": "OpenAI Codex", "auth_kind": "oauth"}"#))
        #expect(problem?.kind == .signIn)
        let status = problem?.status(gatewayName: "Studio Mac")
        #expect(status?.fix?.title == "Sign In…")
        #expect(status?.steps.first?.command == "hermes auth add openai-codex --type oauth")
        // Anthropic's sign-in goes through its own CLI: steps only.
        let anthropic = ProviderProblem(kind: .signIn, provider: "anthropic", providerLabel: "Anthropic")
        #expect(!anthropic.signsInFromApp)
        #expect(anthropic.status(gatewayName: "Studio Mac").fix == nil)
    }

    @Test func theAPIServerSaysSoInWords() {
        #expect(ProviderProblem.from(message: "⚠️ Provider authentication failed: invalid key")?.kind == .key(envVar: nil))
        #expect(ProviderProblem.from(message: "Provider returned 500") == nil)
        var live = LiveTurn(id: "t", sessionID: nil)
        live.apply(SequencedTurnEvent(seq: 1, event: .failed("⚠️ Provider authentication failed: invalid key")))
        #expect(live.turn.providerProblem?.kind == .key(envVar: nil))
    }

    @Test func aRefusedKeyOffersAddKey() {
        let status = ProviderProblem(kind: .key(envVar: "ANTHROPIC_API_KEY"), provider: "anthropic", providerLabel: "Anthropic").status(gatewayName: "Studio Mac")
        #expect(status.detail == "Anthropic refused Hermes's key.")
        #expect(status.fix?.title == "Add Key…")
        #expect(status.steps.map(\.command) == ["hermes auth add anthropic --type api-key", nil])
    }
}

@Suite("Toolset keys")
struct ToolsetKeysTests {
    @Test func keysAreReadWithoutValuesAndManagedRowsAreLeftOut() throws {
        let json = try #require(JSONValue.parse(Data(#"""
        {"name": "web", "providers": [
          {"name": "Nous Subscription", "env_vars": [], "requires_nous_auth": true, "managed_nous_feature": "web", "status": "needs_auth"},
          {"name": "Exa", "badge": "paid", "env_vars": [{"key": "EXA_API_KEY", "prompt": "Exa API key", "url": "https://exa.ai", "is_set": false}], "status": "needs_keys", "is_active": false},
          {"name": "DuckDuckGo", "env_vars": [], "status": "ready", "is_active": true}
        ]}
        """#.utf8)))
        let keys = ToolsetKeys(json: json)
        #expect(keys.providers.map(\.name) == ["Exa", "DuckDuckGo"])
        #expect(keys.takingKeys.map(\.name) == ["Exa"])
        #expect(keys.takingKeys.first?.keys.first == .init(name: "EXA_API_KEY", prompt: "Exa API key", url: URL(string: "https://exa.ai"), isSet: false))
    }
}

@Suite("Updating Hermes")
struct HermesUpdateTests {
    private func json(_ text: String) -> JSONValue {
        JSONValue.parse(Data(text.utf8))!
    }

    @Test func startIsRunningOrRefused() {
        #expect(HermesUpdateStart(json: json(#"{"ok": true, "pid": 4120, "name": "hermes-update", "action_id": "a1"}"#)) == .started(actionID: "a1"))
        #expect(HermesUpdateStart(json: json(#"{"ok": true, "pid": 4120, "already_running": true}"#)) == .started(actionID: nil))
        let refused = HermesUpdateStart(json: json(#"{"ok": false, "error": "nix_update_unsupported", "message": "Managed by Nix.", "update_command": ""}"#))
        #expect(refused == .refused(message: "Managed by Nix.", command: nil))
        let desktop = HermesUpdateStart(json: json(#"{"ok": false, "error": "update_not_in_place", "message": "✗ This Hermes runs from inside the desktop app bundle.\n\nManage updates from within the desktop app.\nSee:\n  https://hermes-agent.nousresearch.com/docs/user-guide/switching-to-source", "update_command": "Manage updates from within the desktop app"}"#))
        #expect(desktop == .refused(message: "This Hermes runs from inside the desktop app bundle.\n\nManage updates from within the desktop app.\nSee:\nhttps://hermes-agent.nousresearch.com/docs/user-guide/switching-to-source", command: nil))
        let docker = HermesUpdateStart(json: json(#"{"ok": false, "message": "Pull a fresh image.", "update_command": "docker pull nousresearch/hermes-agent:latest"}"#))
        #expect(docker == .refused(message: "Pull a fresh image.", command: "docker pull nousresearch/hermes-agent:latest"))
    }

    @Test func runningHasNoOutcomeAndShowsItsLastLine() {
        let status = HermesUpdateStatus(json: json(#"{"name": "hermes-update", "running": true, "exit_code": null, "lines": ["=== hermes-update started 2026-10-18 a1 ===", "Fetching updates…", "  "]}"#))
        #expect(status.outcome(actionID: "a1") == nil)
        #expect(status.lastLine == "Fetching updates…")
    }

    @Test func ownReceiptNamesTheVersionAndWhatIsOwed() {
        let done = HermesUpdateStatus(json: json(#"{"running": false, "exit_code": 0, "lines": [], "receipt": {"outcome": "success", "action_id": "a1", "post_version": "0.22.0", "followups": []}}"#))
        #expect(done.outcome(actionID: "a1") == .updated(version: "0.22.0"))
        let owed = HermesUpdateStatus(json: json(#"{"running": false, "exit_code": 1, "lines": [], "receipt": {"outcome": "partial", "action_id": "a1", "followups": [{"step": "restart gateway", "reason": "still draining"}, {"step": "plugins"}], "user_action": {"step": "stash", "reason": "run git stash pop"}}}"#))
        #expect(owed.outcome(actionID: "a1") == .owes(followups: "restart gateway (still draining); plugins", userAction: "stash: run git stash pop"))
    }

    @Test func anotherRunsReceiptDoesNotCount() {
        let status = HermesUpdateStatus(json: json(#"{"running": false, "exit_code": 1, "lines": ["error: merge conflict", "=== hermes-update completed ==="], "receipt": {"outcome": "partial", "action_id": "b2", "followups": [{"step": "plugins"}]}}"#))
        #expect(status.outcome(actionID: "a1") == .failed(exitCode: 1, lastLine: "error: merge conflict"))
        #expect(status.outcome(actionID: nil) == .failed(exitCode: 1, lastLine: "error: merge conflict"))
    }

    @Test func noExitCodeAfterARestartIsUnknown() {
        #expect(HermesUpdateStatus(json: json(#"{"running": false, "exit_code": null, "lines": []}"#)).outcome(actionID: "a1") == .unknown)
    }
}

@Suite("Features an older Hermes lacks")
struct HermesVersionGapTests {
    @Test func unknownMethodsAndMissingRoutesSayToUpdate() {
        let method = GatewayRPCError(code: -32601, message: "unknown method: board.list — the client and the Hermes backend are out of sync (different versions); run `hermes update` and restart both")
        let route = BackendClient.Failure.http(404, "No such API endpoint: /api/hermes/update")
        #expect(HermesVersionGap.isMissing(method))
        #expect(HermesVersionGap.isMissing(route))
        #expect(method.errorDescription == HermesVersionGap.message)
        #expect(route.errorDescription == HermesVersionGap.message)
    }

    @Test func otherNotFoundsKeepTheirWords() {
        let plugin = BackendClient.Failure.http(404, "Plugin not found")
        #expect(!HermesVersionGap.isMissing(plugin))
        #expect(plugin.errorDescription == "Plugin not found")
        #expect(!HermesVersionGap.isMissing(GatewayRPCError(code: 4001, message: "session not found")))
    }
}

@Suite("Connected apps setup")
struct ConnectedAppsSetupTests {
    private func json(_ text: String) throws -> JSONValue {
        try #require(JSONValue.parse(Data(text.utf8)))
    }

    @Test func appsAreOnUnlessTheSwitchSaysOff() throws {
        #expect(GatewaySetup.appsTurnedOn(config: try json(#"{"model": {"default": "x"}}"#)))
        #expect(GatewaySetup.appsTurnedOn(config: try json(#"{"tools": {"connectors": {"enabled": true}}}"#)))
        #expect(!GatewaySetup.appsTurnedOn(config: try json(#"{"tools": {"connectors": false}}"#)))
        #expect(!GatewaySetup.appsTurnedOn(config: try json(#"{"tools": {"connectors": {"enabled": false}}}"#)))
    }

    @Test func nousSignInIsReadFromItsOwnRow() throws {
        let signedIn = try json(#"{"providers": [{"id": "openai-codex", "status": {"logged_in": true}}, {"id": "nous", "status": {"logged_in": true}}]}"#)
        let signedOut = try json(#"{"providers": [{"id": "openai-codex", "status": {"logged_in": true}}, {"id": "nous", "status": {"logged_in": false}}]}"#)
        #expect(GatewaySetup.signedInToNous(oauthProviders: signedIn))
        #expect(!GatewaySetup.signedInToNous(oauthProviders: signedOut))
        #expect(!GatewaySetup.signedInToNous(oauthProviders: try json(#"{"providers": []}"#)))
    }
}

@Suite("Memory provider setup")
struct MemoryProviderFormTests {
    private let form = MemoryProviderForm(json: JSONValue.parse(Data(#"""
    {"name": "mem0", "label": "Mem0", "fields": [
      {"key": "api_key", "label": "API key", "kind": "secret", "required": true, "value": "", "is_set": false, "options": [], "url": "https://app.mem0.ai"},
      {"key": "mode", "label": "Mode", "kind": "select", "required": false, "value": "cloud", "is_set": true, "options": [{"value": "cloud", "label": "Cloud"}, {"value": "local", "label": "Local"}]},
      {"key": "host", "label": "Host", "kind": "text", "required": true, "value": "", "is_set": false, "options": [], "when": {"mode": "local"}}
    ]}
    """#.utf8))!)

    @Test func setupListsWhatInstallingRuns() throws {
        let json = try #require(JSONValue.parse(Data(#"""
        {"name": "hindsight", "label": "Hindsight", "fields": [], "setup": {
          "pip_dependencies": ["hindsight-client>=0.4"], "python_dependencies_declared": true,
          "external_dependencies": [{"name": "hindsight-api", "install": "uv tool install hindsight-api", "check": "hindsight-api --version"},
                                    {"name": "docs only", "install": "", "check": "true"}],
          "required_env": [], "dependencies_installed": false}}
        """#.utf8)))
        let setup = try #require(MemoryProviderForm(json: json).setup)
        #expect(setup.packages == ["hindsight-client>=0.4"])
        #expect(setup.commands == [.init(name: "hindsight-api", install: "uv tool install hindsight-api")])
        #expect(!setup.installed)
        #expect(setup.hasSteps)
        #expect(form.setup == nil)
    }

    @Test func installReportsEachStep() throws {
        let json = try #require(JSONValue.parse(Data(#"""
        {"ok": false, "provider": "hindsight", "status": {"name": "hindsight", "status": "unavailable"}, "results": [
          {"kind": "pip", "name": "hindsight", "status": "installed", "command": "hermes pm install", "returncode": null, "stdout": "", "stderr": ""},
          {"kind": "external_install", "name": "hindsight-api", "status": "failed", "command": "uv tool install hindsight-api", "returncode": 127, "stdout": "", "stderr": "bash: uv: command not found\n"}
        ]}
        """#.utf8)))
        let install = MemoryProviderInstall(json: json)
        #expect(!install.ok)
        #expect(install.providerStatus == "unavailable")
        #expect(install.steps.filter(\.failed).map(\.output) == ["bash: uv: command not found"])
    }

    @Test func fieldsFollowWhen() {
        #expect(form.visibleFields(edits: [:]).map(\.key) == ["api_key", "mode"])
        #expect(form.visibleFields(edits: ["mode": "local"]).map(\.key) == ["api_key", "mode", "host"])
    }

    @Test func requiredFieldsMustBeFilled() {
        #expect(!form.isComplete(edits: [:]))
        #expect(form.isComplete(edits: ["api_key": "m0-key"]))
        #expect(!form.isComplete(edits: ["api_key": "m0-key", "mode": "local"]))
    }

    @Test func onlyChangesAreSentAndEmptySecretsAreLeft() {
        #expect(form.changes(["api_key": "m0-key", "mode": "cloud"]) == ["api_key": .string("m0-key")])
        #expect(form.changes(["api_key": ""]).isEmpty)
        #expect(form.changes(["mode": "local", "host": "http://nas:8000"]) == ["mode": .string("local"), "host": .string("http://nas:8000")])
    }
}

@Suite("Gateway priority")
struct GatewayPriorityTests {
    private let report = GatewayHostReport(json: JSONValue.parse(Data(#"""
    {"os": "darwin", "machine_id": "666ff6ccaa5b3c07", "jobs": [
      {"label": "ai.hermes.gateway", "role": "gateway", "plist": "/Users/sam/Library/LaunchAgents/ai.hermes.gateway.plist", "process_type": null, "spawn_type": "background", "pid": 40, "priority": 20},
      {"label": "ai.hermes.dashboard", "role": "dashboard", "plist": "/Users/sam/Library/LaunchAgents/ai.hermes.dashboard.plist", "process_type": "Interactive", "spawn_type": "interactive", "pid": 41, "priority": 31},
      {"label": "ai.hermes.dashboard-proxy", "role": "dashboard", "plist": "/Users/sam/Library/LaunchAgents/ai.hermes.dashboard-proxy.plist", "process_type": "Interactive", "spawn_type": "background", "pid": 42, "priority": 20},
      {"label": "ai.hermes.odd", "role": "nonsense", "plist": "/x"}
    ]}
    """#.utf8))!)

    private func facts(_ priority: GatewaySetupFacts.HostPriority?, thisMac: Bool = false) -> GatewaySetupFacts {
        var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: .online)
        facts.hostPriority = priority
        facts.hostIsThisMac = thisMac
        return facts
    }

    @Test func readsTheJobsAndWhichAreThrottled() {
        #expect(report.jobs.map(\.label) == ["ai.hermes.gateway", "ai.hermes.dashboard", "ai.hermes.dashboard-proxy"])
        #expect(report.throttled.map(\.label) == ["ai.hermes.gateway", "ai.hermes.dashboard-proxy"])
        #expect(report.jobs[2].needsReload)
        #expect(!report.jobs[0].needsReload)
        #expect(GatewayHostReport.machineID(hardwareUUID: "11111111-2222-3333-4444-555555555555") == "666ff6ccaa5b3c07")
        let unloaded = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "", processType: "Interactive")
        #expect(!unloaded.isThrottled)
    }

    @Test func onlyHermesJobsInTheAgentsFolderMayBeChanged() {
        let folder = "/Users/sam/Library/LaunchAgents"
        #expect(report.jobs.allSatisfy { $0.isSafeToChange(agentsFolder: folder) })
        let elsewhere = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "/tmp/ai.hermes.gateway.plist")
        let notHermes = GatewayHostReport.Job(label: "com.apple.something", role: .own, plistPath: folder + "/com.apple.something.plist")
        let sneaky = GatewayHostReport.Job(label: "ai.hermes../../x", role: .gateway, plistPath: folder + "/ai.hermes../../x.plist")
        #expect(!elsewhere.isSafeToChange(agentsFolder: folder))
        #expect(!notHermes.isSafeToChange(agentsFolder: folder))
        #expect(!sneaky.isSafeToChange(agentsFolder: folder))
    }

    @Test func throttledOffersTheFixOnlyOnThisMac() {
        let remote = GatewaySetup.priority(facts(.report(report)))
        #expect(remote.state == .limited)
        #expect(remote.fix == nil)
        #expect(remote.steps.compactMap(\.command).count == 2)
        #expect(remote.steps.first?.text == "For ai.hermes.gateway, in Terminal on Studio Mac:")
        #expect(remote.steps.last?.text.contains("hermes update") == true)
        #expect(GatewaySetup.priority(facts(.report(report), thisMac: true)).fix?.title == "Run at Full Priority…")
    }

    @Test func readyOtherSystemsAndOlderPlugins() {
        let fine = GatewayHostReport(os: "darwin", jobs: [report.jobs[1]])
        #expect(GatewaySetup.priority(facts(.report(fine))).state == .ready)
        #expect(GatewaySetup.priority(facts(.report(GatewayHostReport(os: "linux")))).state == .ready)
        #expect(GatewaySetup.priority(facts(.pluginTooOld)).state == .unknown)
        #expect(GatewaySetup.priority(facts(.noPlugin)).state == .unknown)
        #expect(GatewaySetup.priority(facts(nil)).state == .checking)
        var linked = facts(nil)
        linked.botMode = .notLinked
        #expect(GatewaySetup.priority(linked).state == .notSetUp)
    }

    @Test func theStepIsOneCommandPerJob() {
        let job = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "/Users/sam/Library/LaunchAgents/ai.hermes.gateway.plist")
        #expect(GatewayHostReport.command(for: job) == "plutil -replace ProcessType -string Interactive ~/Library/LaunchAgents/ai.hermes.gateway.plist && launchctl bootout gui/$(id -u)/ai.hermes.gateway; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.hermes.gateway.plist")
    }

    /// Right after `hermes update` the gateway still runs as launchd loaded it, while its plist no
    /// longer says Interactive: throttled from its next start, and the plist alone fixes it.
    @Test func aRewrittenPlistCountsBeforeTheReload() {
        let rewritten = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "/Users/sam/Library/LaunchAgents/ai.hermes.gateway.plist",
                                              processType: nil, spawnType: "interactive", pid: 50, priority: 31)
        #expect(rewritten.isThrottled)
        #expect(rewritten.losesPriorityAtNextStart)
        #expect(!rewritten.needsReload)
        #expect(GatewayHostReport.command(for: rewritten) == "plutil -replace ProcessType -string Interactive ~/Library/LaunchAgents/ai.hermes.gateway.plist")
        let status = GatewaySetup.priority(facts(.report(GatewayHostReport(os: "darwin", jobs: [rewritten, report.jobs[1]]))))
        #expect(status.state == .limited)
        #expect(status.detail == "From its next start, macOS runs Hermes on Studio Mac as a background job, so when the Mac is busy it will answer late or not at all.")
        #expect(status.fallback == "It runs at full priority until then.")
        // launchd says "daemon" for a LaunchAgent without ProcessType.
        let daemon = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "", spawnType: "daemon")
        #expect(daemon.isThrottled && !daemon.losesPriorityAtNextStart)
        let full = GatewayHostReport.Job(label: "ai.hermes.gateway", role: .gateway, plistPath: "", processType: "Interactive", spawnType: "interactive")
        #expect(!full.isThrottled)
    }

    @Test func anUpdateThatResetsPrioritySaysSoWithTheFixOrTheSteps() throws {
        let here = try #require(GatewaySetup.priorityReset(facts(.report(report), thisMac: true), after: .update, wasThrottled: false))
        #expect(here.headline == "Updating reset Hermes to background priority")
        #expect(here.detail == "macOS runs Hermes on this Mac as a background job, so when the Mac is busy it answers late or not at all.")
        #expect(here.canFixHere)
        #expect(here.steps.isEmpty)
        let elsewhere = try #require(GatewaySetup.priorityReset(facts(.report(report)), after: .restart, wasThrottled: false))
        #expect(elsewhere.headline == "Restarting reset Hermes to background priority")
        #expect(!elsewhere.canFixHere)
        #expect(elsewhere.steps.map(\.text) == ["For ai.hermes.gateway, in Terminal on Studio Mac:", "For ai.hermes.dashboard-proxy, in Terminal on Studio Mac:"])
        #expect(elsewhere.steps.allSatisfy { $0.command?.hasPrefix("plutil -replace ProcessType -string Interactive") == true })
        #expect(GatewaySetup.priorityReset(facts(.report(report)), after: .update, wasThrottled: true)?.headline == "Hermes still runs at background priority")
        // Nothing to say at full priority, about dashboards alone (updating doesn't touch theirs), or off a Mac.
        let dashboards = GatewayHostReport(os: "darwin", jobs: [report.jobs[1], report.jobs[2]])
        #expect(GatewaySetup.priorityReset(facts(.report(dashboards)), after: .update, wasThrottled: false) == nil)
        #expect(GatewaySetup.priorityReset(facts(.report(GatewayHostReport(os: "linux"))), after: .update, wasThrottled: false) == nil)
        #expect(GatewaySetup.priorityReset(facts(.failed), after: .update, wasThrottled: false) == nil)
    }

    @Test func theMacsNoticeAndTheUpdateConfirmation() throws {
        let notice = try #require(GatewaySetup.priorityNotice(facts(.report(report), thisMac: true)))
        #expect(notice.headline == "Hermes runs at background priority")
        #expect(notice.detail == "When this Mac is busy, Hermes answers late or not at all.")
        #expect(GatewaySetup.priorityNotice(facts(.report(report)))?.detail == "When Studio Mac is busy, Hermes answers late or not at all.")
        #expect(notice.canFixHere)
        #expect(GatewaySetup.priorityNotice(facts(.report(report)))?.steps.count == 2)
        var connecting = facts(.report(report), thisMac: true)
        connecting.botMode = .connecting
        #expect(GatewaySetup.priorityNotice(connecting) == nil)
        #expect(GatewaySetup.priorityNotice(facts(.report(GatewayHostReport(os: "darwin", jobs: [report.jobs[1]])))) == nil)

        let plain = "Hermes updates itself, then restarts once running chats and tasks finish. The app reconnects by itself."
        #expect(GatewaySetup.updateConfirmation(facts(.report(report))) == plain + "\n\nUpdating resets Hermes to background priority on Studio Mac. The app offers to restore it when it's done.")
        #expect(GatewaySetup.updateConfirmation(facts(.report(report), thisMac: true)).hasSuffix("on this Mac. The app offers to restore it when it's done."))
        #expect(GatewaySetup.updateConfirmation(facts(.report(GatewayHostReport(os: "linux")))) == plain)
        #expect(GatewaySetup.updateConfirmation(facts(nil)) == plain)
    }
}

@Suite("Bot-to-Bot replies")
struct BotRepliesSetupTests {
    private func facts(_ record: DeliveryProtection?, canApply: Bool = true) -> GatewaySetupFacts {
        var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: .online)
        facts.deliveryProtection = record
        facts.update = .init(behind: 3, canApply: canApply, updateCommand: "hermes update")
        return facts
    }

    @Test func hiddenUntilADeliveryIsSeen() {
        #expect(GatewaySetup.botReplies(facts(nil)) == nil)
    }

    @Test func protectedIsReady() {
        let status = GatewaySetup.botReplies(facts(DeliveryProtection(version: "0.22.2", protected: true)))
        #expect(status?.state == .ready)
        #expect(status?.fix == nil)
    }

    @Test func unprotectedWarnsAndOffersTheUpdateOnlyOnceAFixShips() {
        let lost = DeliveryProtection(version: "0.22.2", protected: false)
        let unfixed = GatewaySetup.botReplies(facts(lost), fixedIn: nil)
        #expect(unfixed?.state == .limited)
        #expect(unfixed?.fix == nil)
        #expect(unfixed?.steps.isEmpty == true)
        #expect(unfixed?.fallback == "Keeping the app open while Bots reply to each other avoids it.")
        #expect(unfixed?.docs?.absoluteString.hasSuffix("/pull/136220") == true)
        let fixed = GatewaySetup.botReplies(facts(lost), fixedIn: "0.22.4")
        #expect(fixed?.fix?.title == "Update Hermes…")
        #expect(fixed?.steps.first?.command == "hermes update")
        #expect(GatewaySetup.botReplies(facts(lost, canApply: false), fixedIn: "0.22.4")?.fix == nil)
        // Already on the fixed version or newer: unprotected there is something else, so no update.
        #expect(GatewaySetup.botReplies(facts(DeliveryProtection(version: "0.23.0", protected: false)), fixedIn: "0.22.4")?.fix == nil)
    }
}
