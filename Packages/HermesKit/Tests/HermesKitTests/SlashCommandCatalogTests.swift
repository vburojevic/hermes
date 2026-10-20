import Foundation
import Testing
@testable import HermesKit

@Suite("The \"/\" menu's catalog from commands.catalog")
struct SlashCommandCatalogTests {
    /// Shaped like Hermes's `commands.catalog`: registry pairs with their `desktop` dispositions,
    /// a quick command, a plugin command, and a skill both in `pairs` and in `skills` (keys with "/").
    private let catalog = JSONValue.parse("""
    {
      "pairs": [["/new", "Start a new session"], ["/goal", "Set a standing goal"], ["/update", "Update Hermes Agent to the latest version"],
                ["/copy", "Copy the last assistant response to clipboard"], ["/model", "Switch model"],
                ["/voice", "Toggle voice mode"], ["/login", "Sign in to a provider"], ["/reload-mcp", "Reload MCP servers"],
                ["/deploy", "exec: ./deploy.sh"], ["/app-push", "Push notices"], ["/github-pr", "Pull request workflow"],
                ["/reset", "Start a new session"]],
      "commands": {"/new": {"argument_mode": "text", "desktop": null}, "/goal": {"argument_mode": "text", "desktop": null},
                   "/update": {"argument_mode": null, "desktop": "terminal"}, "/copy": {"argument_mode": "text", "desktop": "terminal"},
                   "/model": {"argument_mode": "options", "desktop": "hidden"}, "/voice": {"argument_mode": "options", "desktop": "composer-voice"},
                   "/login": {"argument_mode": null, "desktop": "settings"}, "/reload-mcp": {"argument_mode": null, "desktop": "advanced"},
                   "/deploy": {"argument_mode": null, "desktop": null}},
      "categories": [{"name": "Session", "pairs": [["/new", "Start a new session"]]},
                     {"name": "Configuration", "pairs": [["/reload-mcp", "Reload MCP servers"], ["/login", "Sign in to a provider"]]},
                     {"name": "User commands", "pairs": [["/deploy", "exec: ./deploy.sh"]]}],
      "skills": {"/github-pr": {"usage": 4, "origin": "hermes-skills"}},
      "skill_count": 1, "warning": ""
    }
    """)!

    private func parse(appRuns: Set<String> = ["new", "model", "update", "restart"]) -> SlashCommandCatalog {
        SlashCommandCatalog.parse(catalog, descriptions: ["github-pr": "Open and land pull requests"], hidden: ["app-push"], appRuns: appRuns)
    }

    @Test func skillsLoseTheirSlashAndAreNotCommands() {
        let parsed = parse()
        #expect(parsed.skills == [.init(name: "github-pr", summary: "Open and land pull requests", category: "hermes-skills")])
        #expect(!parsed.commands.contains { $0.name == "github-pr" })
    }

    @Test func updateIsListedEvenThoughHermesMarksItForTheTerminal() {
        let update = parse().commands.first { $0.name == "update" }
        #expect(update?.unavailable == nil)
        #expect(update?.info.title == "Update Hermes")
        #expect(update?.info.confirmsOnSend == true)
        // Without the app running it, it would say why it can't run here.
        #expect(parse(appRuns: []).commands.first { $0.name == "update" }?.unavailable == "Runs only in Hermes in a terminal")
    }

    @Test func commandsThatCantRunHereSayWhyInsteadOfHiding() {
        let commands = parse().commands
        #expect(commands.first { $0.name == "copy" }?.unavailable == "Runs only in Hermes in a terminal")
        #expect(commands.first { $0.name == "voice" }?.unavailable == "Use the microphone in the composer")
        #expect(commands.first { $0.name == "login" }?.unavailable == "Set this up in Settings")
        // "advanced" runs in the app.
        #expect(commands.first { $0.name == "reload-mcp" }?.unavailable == nil)
    }

    @Test func hiddenAndPlumbingStayOutButTheAppsOwnStayIn() {
        let names = parse().commands.map(\.name)
        #expect(!names.contains("app-push"))
        // Hermes hides /model from its own popover; the app runs it with a picker, so it's listed.
        #expect(names.contains("model"))
        #expect(!parse(appRuns: []).commands.map(\.name).contains("model"))
        // An alias of a listed command isn't listed twice.
        #expect(names.filter { $0 == "new" }.count == 1)
        #expect(!names.contains("reset"))
    }

    @Test func unknownCommandsKeepHermesWordsInTheNearestGroup() {
        let commands = parse().commands
        let deploy = commands.first { $0.name == "deploy" }
        #expect(deploy?.info.summary == "exec: ./deploy.sh")
        #expect(deploy?.info.symbol == SlashCommands.fallbackSymbol)
        #expect(deploy?.info.group == .more)
        #expect(commands.first { $0.name == "reload-mcp" }?.info.group == .settings)
        // Groups come in the menu's order: Session first, More last.
        #expect(commands.first?.info.group == .session)
        #expect(commands.last?.info.group == .more)
    }

    @Test func confirmingCommandsDontRunOnTap() {
        #expect(SlashCommands.known("update")?.runsImmediately == false)
        #expect(SlashCommands.known("restart")?.runsImmediately == false)
        #expect(SlashCommands.known("usage")?.runsImmediately == true)
    }
}
