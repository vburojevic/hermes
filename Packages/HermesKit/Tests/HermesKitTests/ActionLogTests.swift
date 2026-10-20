import Foundation
import Testing
@testable import HermesKit

@Suite("Gateway job logs")
struct ActionLogTests {
    private let earlier = [
        "=== hermes-update started 2026-10-19 21:04:10 aaaa ===",
        "→ Fetching updates…",
        "✓ Already up to date.",
    ]

    @Test func onlyThisRunsLinesCount() {
        let tail = earlier + [
            "",
            "=== hermes-update started 2026-10-20 08:00:00 bbbb ===",
            "→ Fetching updates…",
            "→ Pulling 12 commits from origin/main",
            "  → ai.hermes.gateway: draining (up to 600s)...",
        ]
        let log = ActionLog(tail: tail, name: "hermes-update", actionID: "bbbb")
        #expect(log.lines.map(\.text) == ["→ Fetching updates…", "→ Pulling 12 commits from origin/main",
                                          "  → ai.hermes.gateway: draining (up to 600s)..."])
        #expect(log.currentStep == "ai.hermes.gateway: draining (up to 600s)...")
        #expect(log.lines[2].isDetail)
        #expect(!log.lines[1].isDetail)
        // Another run's header with the id asked for wins over a newer one.
        #expect(ActionLog(tail: tail, name: "hermes-update", actionID: "aaaa").lines.map(\.words) == ["Fetching updates…", "Already up to date."])
    }

    @Test func marksSayWhatALineIs() {
        let kinds = ["→ a", "↻ b", "☤ c", "✓ d", "✅ e", "⚠ f", "⚠️ g", "✗ h", "❌ i", "plain j"].map { ActionLog.Line($0).kind }
        #expect(kinds == [.step, .step, .step, .done, .done, .warning, .warning, .failure, .failure, .plain])
        #expect(ActionLog.Line("⚠️ Gateway still draining").words == "Gateway still draining")
    }

    @Test func theStepIsTheNewestStepLine() {
        let log = ActionLog(tail: ["=== gateway-restart started 2026-10-20 08:00:00 ===", "→ Draining 1 running chat",
                                   "  ✓ Stopped ai.hermes.gateway"], name: "gateway-restart")
        #expect(log.currentStep == "Draining 1 running chat")
        #expect(log.lastLine == "Stopped ai.hermes.gateway")
        // No step yet: the newest line.
        #expect(ActionLog(tail: ["=== x started 1 ===", "Resolving dependencies"], name: "x").currentStep == "Resolving dependencies")
        #expect(ActionLog(tail: ["=== x started 1 ==="], name: "x").currentStep == nil)
    }

    @Test func colourAndProgressBarsAreCleanedAway() {
        #expect(ActionLog.clean("\u{1B}[32m✓\u{1B}[0m Installed") == "✓ Installed")
        #expect(ActionLog.clean("Downloading  10%\rDownloading  60%\rDownloading 100%  ") == "Downloading 100%")
        #expect(ActionLog.clean("\u{1B}]8;;https://x.dev\u{07}link\u{1B}]8;;\u{07}") == "link")
        #expect(ActionLog.clean("\r") == "")
    }

    @Test func aLongRunContinuesOnceItsHeaderScrollsOut() {
        var log = ActionLog(tail: ["=== hermes-update started 1 bbbb ===", "→ one", "→ two", "→ three"],
                            name: "hermes-update", actionID: "bbbb")
        // The next tail no longer has the header: it overlaps the last poll by two lines.
        log.merge(tail: ["→ two", "→ three", "→ four", "→ five"], name: "hermes-update", actionID: "bbbb")
        #expect(log.lines.map(\.words) == ["one", "two", "three", "four", "five"])
        // More arrived than one tail holds: no overlap, so the new lines follow on.
        log.merge(tail: ["→ nine", "→ ten"], name: "hermes-update", actionID: "bbbb")
        #expect(log.lines.map(\.words) == ["one", "two", "three", "four", "five", "nine", "ten"])
        // The route's completion marker isn't output.
        log.merge(tail: ["→ ten", "=== hermes-update completed bbbb ==="], name: "hermes-update", actionID: "bbbb")
        #expect(log.lines.last?.words == "ten")
    }

    @Test func statusReadsTheTail() {
        let json = JSONValue.parse(Data(#"{"name": "gateway-restart", "running": false, "exit_code": 0, "pid": 7, "lines": ["=== gateway-restart started 1 ===", "✓ Restarted"]}"#.utf8))!
        let status = ActionStatus(json: json)
        #expect(!status.running)
        #expect(status.exitCode == 0)
        #expect(status.lines.count == 2)
    }
}

@Suite("Gateway jobs")
struct GatewayJobTests {
    private let log = ActionLog(tail: ["=== hermes-update started 1 ===", "→ Pulling 12 commits from origin/main"], name: "hermes-update")

    @Test func anUpdateShowsItsStepThenHowItEnded() {
        let running = GatewayJob.update(.running, log: log, started: .now, gatewayName: "Studio")
        #expect(running.isRunning)
        #expect(running.headline == "Pulling 12 commits from origin/main")
        #expect(GatewayJob.update(.running, log: ActionLog(), started: .now, gatewayName: "Studio").headline == "Updating Hermes…")
        #expect(GatewayJob.update(.starting, log: ActionLog(), started: .now, gatewayName: "Studio").isRunning)

        let updated = GatewayJob.update(.finished(.updated(version: "0.23.1")), log: log, started: .now, gatewayName: "Studio")
        #expect(updated.tone == .done)
        #expect(updated.headline == "Updated to 0.23.1")
        #expect(updated.log == log)

        let owes = GatewayJob.update(.finished(.owes(followups: "restart gateway", userAction: "Run git stash pop")), log: log, started: .now, gatewayName: "Studio")
        #expect(owes.tone == .attention)
        #expect(owes.detail == "restart gateway\nRun git stash pop")

        let failed = GatewayJob.update(.finished(.failed(exitCode: 1, lastLine: "error")), log: log, started: .now, gatewayName: "Studio")
        #expect(failed.tone == .failed)
        #expect(failed.headline == "The update stopped (exit 1)")

        let refused = GatewayJob.update(.refused(message: "This Hermes runs in Docker.", command: "docker pull nousresearch/hermes"), log: ActionLog(), started: .now, gatewayName: "Studio")
        #expect(refused.tone == .attention)
        #expect(refused.command == "docker pull nousresearch/hermes")

        #expect(GatewayJob.update(.lostTouch, log: log, started: .now, gatewayName: "Studio").headline == "Studio stopped answering while Hermes updated")
        #expect(GatewayJob.update(.couldNotStart(message: "Offline"), log: ActionLog(), started: .now, gatewayName: "Studio").tone == .failed)
    }

    @Test func aRestartSaysWhatToRunWhenItFails() {
        let restart = ActionLog(tail: ["=== gateway-restart started 1 ===", "→ Draining 1 running chat"], name: "gateway-restart")
        #expect(GatewayJob.restart(.running, log: restart, started: .now, gatewayName: "Studio").headline == "Draining 1 running chat")
        #expect(GatewayJob.restart(.succeeded, log: restart, started: .now, gatewayName: "Studio").tone == .done)
        let failed = GatewayJob.restart(.failed(exitCode: 78), log: restart, started: .now, gatewayName: "Studio")
        #expect(failed.headline == "The restart stopped (exit 78)")
        #expect(failed.command == "hermes gateway restart")
    }
}
