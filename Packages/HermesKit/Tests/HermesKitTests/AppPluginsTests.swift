import Foundation
import Testing
@testable import HermesKit

private func row(_ name: String, version: String, status: String = "enabled") -> HermesPlugin {
    HermesPlugin(json: .object(["name": .string(name), "key": .string(name), "version": .string(version),
                                "source": .string("git"), "status": .string(status)]))!
}

private actor Calls {
    var list: [(method: String, params: [String: JSONValue])] = []
    func add(_ method: String, _ params: [String: JSONValue]) { list.append((method, params)) }
}

@Suite("The app's Hermes plugins")
struct AppPluginsTests {
    private let push = AppPlugin.push

    @Test func everyPluginIsPinnedToAFullCommit() {
        for plugin in AppPlugin.all {
            #expect(plugin.ref.count == 40 && plugin.ref.allSatisfy(\.isHexDigit), "Hermes refuses a ref that isn't a full SHA")
            #expect(AppPlugin.version(plugin.version, isAtLeast: plugin.minimumVersion), "the pinned commit must satisfy its own minimum")
            #expect(plugin.repo.split(separator: "/").count == 2)
        }
    }

    @Test func versionsCompareByNumber() {
        #expect(AppPlugin.version("1.0.0", isAtLeast: "1.0.0"))
        #expect(AppPlugin.version("1.10.0", isAtLeast: "1.9.2"))
        #expect(AppPlugin.version("2", isAtLeast: "1.9"))
        #expect(AppPlugin.version("1.0", isAtLeast: "1.0.0"))
        #expect(!AppPlugin.version("1.0.0", isAtLeast: "1.0.1"))
        #expect(AppPlugin.version("1.1.0-beta", isAtLeast: "1.1.0"))
        #expect(!AppPlugin.version("", isAtLeast: "1.0.0"))
        #expect(!AppPlugin.version("dev", isAtLeast: "1.0.0"))
    }

    /// Missing or older is installed; newer (another device's app) and turned off are left alone.
    @Test func eachProfileGetsAState() {
        #expect(push.state(in: []) == .missing)
        #expect(push.state(in: [row("other", version: "9")]) == .missing)
        #expect(push.state(in: [row("hermes-app-push", version: push.version)]) == .current(version: push.version))
        #expect(push.state(in: [row("hermes-app-push", version: "1.0.0")]) == .outdated(version: "1.0.0"))
        #expect(push.state(in: [row("hermes-app-push", version: "3.0.0")]) == .current(version: "3.0.0"))
        #expect(push.state(in: [row("hermes-app-push", version: push.version, status: "not enabled")]) == .off)
        let old = AppPlugin(name: "hermes-app-push", repo: push.repo, ref: push.ref, version: "1.2.0", minimumVersion: "1.2.0")
        #expect(old.state(in: [row("hermes-app-push", version: "1.0.0")]) == .outdated(version: "1.0.0"))
        #expect(old.state(in: [row("hermes-app-push", version: "1.0.0", status: "not enabled")]) == .outdated(version: "1.0.0"))
    }

    @Test func thePlanInstallsTheRootFirstAndReplacesOlderCopies() async {
        let newer = AppPlugin(name: "hermes-app-push", repo: push.repo, ref: push.ref, version: "1.1.0", minimumVersion: "1.1.0")
        let installed: [String: [HermesPlugin]] = [
            "ops": [row("hermes-app-push", version: "1.0.0")],
            "writer": [row("hermes-app-push", version: "1.1.0")],
            "default": [],
        ]
        let survey = await AppPluginsSurvey.read(profiles: ["ops", "writer", "default", "scout"], plugins: [newer]) { profile in
            if profile == "scout" { throw GatewayRPCError(code: 4064, message: "profile 'scout' not found") }
            return installed[profile] ?? []
        }
        #expect(survey.plan().map(\.profile) == ["default", "ops"])
        #expect(survey.plan().map(\.replaces) == [false, true])
        #expect(survey.failures.keys.sorted() == ["scout"])
        #expect(survey.profilesWith(newer) == ["writer"])
        #expect(!survey.isCurrent)

        let done = await AppPluginsSurvey.read(profiles: ["default"], plugins: [newer]) { _ in [row("hermes-app-push", version: "1.1.0")] }
        #expect(done.isCurrent && done.plan().isEmpty)
    }

    /// Keeping current leaves a copy someone turned off; the person's Install or Turn On turns it on.
    @Test func aCopyTurnedOffIsTurnedOnOnlyWhenAsked() async {
        let survey = await AppPluginsSurvey.read(profiles: ["default", "ops"], plugins: [push]) { profile in
            [row("hermes-app-push", version: push.version, status: profile == "default" ? "not enabled" : "enabled")]
        }
        #expect(survey.plan().isEmpty)
        #expect(survey.fixes.map(\.action) == [.turnOn])
        #expect(survey.profilesToFix == ["default"])
        #expect(!survey.isCurrent)
    }

    /// Settings → Setup shows the first thing to fix: missing, then older, then off, then the restart.
    @Test func statusNamesWhatToFixFirst() {
        func survey(_ states: [String: AppPluginState]) -> AppPluginsSurvey {
            AppPluginsSurvey(entries: states.sorted { $0.key < $1.key }.map { .init(profile: $0.key, plugin: push, state: $0.value) })
        }
        let current = AppPluginState.current(version: push.version)
        #expect(AppPluginStatus.of(push, in: survey(["default": current, "ops": .missing, "writer": .off]), restartPending: true)
                == .missing(profiles: ["ops"]))
        #expect(AppPluginStatus.of(push, in: survey(["default": .off, "ops": .outdated(version: "1.0.0")]), restartPending: false)
                == .outdated(profiles: ["ops"]))
        #expect(AppPluginStatus.of(push, in: survey(["default": .off, "ops": current]), restartPending: true) == .off(profiles: ["default"]))
        #expect(AppPluginStatus.of(push, in: survey(["default": current]), restartPending: true) == .restartPending)
        let ready = AppPluginStatus.of(push, in: survey(["default": current, "ops": current]), restartPending: false)
        #expect(ready == .current(profiles: ["default", "ops"]) && ready.isReady)
        #expect(AppPluginStatus.of(push, in: survey(["default": current]), restartPending: false,
                                   installFailures: ["ops": "already exists"]) == .failed("already exists"))
        let unread = AppPluginsSurvey(entries: [], failures: ["scout": "profile 'scout' not found"])
        #expect(AppPluginStatus.of(push, in: unread, restartPending: false) == .failed("profile 'scout' not found"))
    }

    /// Turning on is plugins.manage toggle in that profile, not a reinstall.
    @Test func turningOnTogglesInTheProfile() async throws {
        let calls = Calls()
        let client = ConnectionsClient(profile: "default") { method, params in
            await calls.add(method, params)
            return .object(["ok": .bool(true), "name": .string(AppPlugin.push.name)])
        }
        _ = try await client.apply(AppPluginsSurvey.Step(profile: "default", plugin: push, action: .turnOn))
        let sent = await calls.list
        #expect(sent.count == 1)
        #expect(sent[0].params["action"]?.stringValue == "toggle")
        #expect(sent[0].params["key"]?.stringValue == "hermes-app-push")
        #expect(sent[0].params["enable"]?.boolValue == true)
        #expect(sent[0].params["profile"]?.stringValue == "default")
    }

    /// The install is pinned, scoped to the profile, and forced only over an older copy.
    @Test func installSendsTheRepoPinAndProfile() async throws {
        let calls = Calls()
        let client = ConnectionsClient(profile: "ops") { method, params in
            await calls.add(method, params)
            return .object(["ok": .bool(true), "restart_required": .bool(false), "name": .string("hermes-app-push")])
        }
        _ = try await client.install(push, replacing: false)
        _ = try await client.install(push, replacing: true)
        let sent = await calls.list
        #expect(sent.map(\.method) == ["plugins.manage", "plugins.manage"])
        let first = sent[0].params
        #expect(first["action"]?.stringValue == "install")
        #expect(first["repo"]?.stringValue == "vburojevic/hermes-app-push")
        #expect(first["ref"]?.stringValue == push.ref)
        #expect(first["profile"]?.stringValue == "ops")
        #expect(first["enable"]?.boolValue == true)
        #expect(first["force"] == nil)
        #expect(sent[1].params["force"]?.boolValue == true)
    }
}
