import Foundation
import Testing
@testable import HermesKit

@Suite("Bot Screen")
struct BotScreenTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// `display.status` as Hermes answers it on a Linux host with the screen running.
    private let runningJSON = #"""
    {"profile": "research", "supported": true, "installed": true, "missing": [], "running": true, "pid": 4242,
     "display": ":20", "socket": "/tmp/x", "geometry": "1440x900", "install_command": null, "browser": "chromium",
     "blocker": null, "placement": "gateway", "profile_key": "k",
     "lease": {"holder": "human", "viewer_id": null, "reason": "Taken from the Hermes app", "epoch": 3, "since": 1, "viewer_hash": "abc123"}}
    """#

    @Test func readsDisplayStatus() throws {
        let status = BotScreenStatus(json: try json(runningJSON))
        #expect(status.supported && status.installed && status.running)
        #expect(status.geometry == "1440x900" && status.installCommand == nil && status.blocker == nil)
        #expect(status.holder == "human" && status.viewerHash == "abc123" && status.reason == "Taken from the Hermes app")

        let missing = BotScreenStatus(json: try json(#"""
        {"supported": true, "installed": false, "missing": ["Xvnc", "xfwm4"], "running": false,
         "install_command": "sudo apt-get install -y --no-install-recommends tigervnc-standalone-server", "lease": {"holder": "agent"}}
        """#))
        #expect(!missing.installed && missing.missing == ["Xvnc", "xfwm4"] && missing.installCommand?.hasPrefix("sudo apt-get") == true)
        #expect(missing.holder == "agent" && missing.viewerHash == nil)
    }

    @Test func leaseMovesWithTheBroadcast() throws {
        var status = BotScreenStatus(json: try json(runningJSON))
        status.apply(lease: try json(#"{"profile_key": "k", "lease": {"holder": "agent", "viewer_hash": null}}"#))
        #expect(status.holder == "agent" && status.viewerHash == nil)
        status.apply(lease: try json(#"{"profile_key": "k"}"#))
        #expect(status.holder == "agent")
    }

    @Test func openScreenShowsWhereTheHostCanHaveOne() {
        // Running: the issue's case, a chat with no Inspector tabs.
        #expect(BotScreenStatus.offersOpenScreen(BotScreenStatus(supported: true, installed: true, running: true)))
        // Stopped or not installed: it opens on the Screen's setup, with Start or the install steps.
        #expect(BotScreenStatus.offersOpenScreen(BotScreenStatus(supported: true, installed: true, running: false)))
        #expect(BotScreenStatus.offersOpenScreen(BotScreenStatus(supported: true, installed: false, running: false)))
        // A Mac or Windows gateway has no Bot Screen; an older Hermes or no answer says nothing.
        #expect(!BotScreenStatus.offersOpenScreen(BotScreenStatus(supported: false, installed: false, running: false)))
        #expect(!BotScreenStatus.offersOpenScreen(nil))
    }

    // MARK: Setup

    @Test func screenTabSaysWhatsMissing() throws {
        let running = BotScreenStatus(supported: true, installed: true, running: true)
        #expect(GatewaySetup.screen(running, profile: "research", gatewayName: "Lab") == nil)

        let stopped = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: true, installed: true, running: false), profile: "research", gatewayName: "Lab"))
        #expect(stopped.state == .notSetUp && stopped.fix?.title == "Start Screen")
        #expect(stopped.steps.map(\.command) == ["hermes -p research computer-use screen start"])

        let defaultBot = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: true, installed: true, running: false), profile: "default", gatewayName: "Lab"))
        #expect(defaultBot.steps.map(\.command) == ["hermes computer-use screen start"])

        let missing = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: true, installed: false, running: false, installCommand: "sudo pacman -S --needed tigervnc"),
            profile: nil, gatewayName: "Lab"))
        #expect(missing.state == .notSetUp && missing.fix == nil)
        #expect(missing.steps.map(\.command) == ["sudo pacman -S --needed tigervnc", "hermes computer-use screen start"])

        // No package manager Hermes knows: its own installer says what to do.
        let noManager = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: true, installed: false, running: false), profile: nil, gatewayName: "Lab"))
        #expect(noManager.steps.first?.command == "hermes computer-use screen install")

        let blocked = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: true, installed: true, running: false, blocker: "Only 300 MB of memory is free."),
            profile: nil, gatewayName: "Lab"))
        #expect(blocked.fix == nil && blocked.detail == "Only 300 MB of memory is free.")

        let mac = try #require(GatewaySetup.screen(
            BotScreenStatus(supported: false, installed: false, running: false), profile: nil, gatewayName: "Studio Mac"))
        #expect(mac.fix == nil && mac.steps.isEmpty)
    }

    @Test func setupRowFollowsTheHost() {
        var facts = GatewaySetupFacts(gatewayName: "Lab", gatewayOnline: true, botMode: .online)
        #expect(GatewaySetup.botScreen(facts) == nil)
        facts.botScreen = BotScreenStatus(supported: false, installed: false, running: false)
        #expect(GatewaySetup.botScreen(facts) == nil)
        // Ready once the packages are there, whether or not a Bot's screen runs.
        facts.botScreen = BotScreenStatus(supported: true, installed: true, running: false)
        #expect(GatewaySetup.botScreen(facts)?.state == .ready)
        facts.botScreen = BotScreenStatus(supported: true, installed: false, running: false, installCommand: "sudo dnf install -y tigervnc-x11-server")
        let missing = GatewaySetup.botScreen(facts)
        #expect(missing?.state == .notSetUp && missing?.steps.first?.command == "sudo dnf install -y tigervnc-x11-server")
        #expect(missing?.docs == GatewaySetup.Docs.botScreen)
    }
}
