import Foundation
import Testing
@testable import HermesKit

private func row(_ name: String, version: String, status: String = "enabled") -> HermesPlugin {
    HermesPlugin(json: .object(["name": .string(name), "key": .string(name), "version": .string(version),
                                "source": .string("git"), "status": .string(status)]))!
}

/// A list from a `plugin.yaml` in `Tools/`: the strings under `key:`, one `- name` a line.
private func manifestList(_ plugin: String, _ key: String) throws -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Tools/\(plugin)/plugin.yaml")
    let text = try String(contentsOf: root.standardizedFileURL, encoding: .utf8)
    var values: [String] = []
    var inside = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("\(key):") {
            inside = true
        } else if inside, line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
            values.append(line.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces))
        } else if inside {
            inside = false
        }
    }
    return values
}

@Suite("The plugin registry")
struct PluginRegistryTests {
    /// The registry's list for each pin is the manifest's: a plugin change that adds a hook or a
    /// tool must add it here too, or the consent card would miss it.
    @Test func pinnedCapabilitiesMatchTheManifests() throws {
        for plugin in AppPlugin.all {
            let pinned = plugin.pinnedCapabilities
            #expect(Set(pinned.hooks) == Set(try manifestList(plugin.name, "provides_hooks")), "\(plugin.name)")
            #expect(Set(pinned.tools) == Set(try manifestList(plugin.name, "provides_tools")), "\(plugin.name)")
            #expect(plugin.capabilities[plugin.minimumVersion] != nil, "the minimum version has a capability list")
        }
    }

    /// The version in `Tools/` has its list before it's published and pinned: a copy someone
    /// installed by hand, or the next pin, is compared with what it really asks for.
    @Test func theManifestsVersionHasACapabilityList() throws {
        for plugin in AppPlugin.all {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "../../../../Tools/\(plugin.name)/plugin.yaml")
            let text = try String(contentsOf: root.standardizedFileURL, encoding: .utf8)
            let version = text.split(separator: "\n").first { $0.hasPrefix("version:") }
                .map { $0.dropFirst("version:".count).trimmingCharacters(in: .whitespaces) } ?? ""
            #expect(plugin.capabilities[version] != nil, "\(plugin.name) \(version) has no capability list")
        }
    }

    /// `docs/plugins.md` §12: every hook in a manifest is on the review.
    @Test func everyHookIsOnTheReview() {
        for plugin in AppPlugin.all {
            let named = Set(plugin.words.review("Studio Mac").flatMap(\.names))
            for hook in plugin.pinnedCapabilities.hooks {
                #expect(named.contains(hook), "\(plugin.name) doesn't name \(hook) on its review")
            }
            for tool in plugin.pinnedCapabilities.tools {
                #expect(named.contains(tool), "\(plugin.name) doesn't name \(tool) on its review")
            }
            for command in plugin.pinnedCapabilities.commands {
                #expect(named.contains("command \(command)"))
            }
        }
    }

    @Test func everyEntryHasItsWords() {
        for plugin in AppPlugin.all {
            let words = plugin.words
            #expect(!words.title.isEmpty && !words.feature.isEmpty && !words.summary.isEmpty && !words.askLine.isEmpty)
            #expect(words.benefits.count >= 2)
            #expect(!words.promise("Studio Mac").isEmpty)
            #expect(!words.offer("Studio Mac").title.isEmpty && !words.offerOff("Studio Mac").title.isEmpty)
            #expect(plugin.moments.contains(.ask), "every app plugin is in the one ask")
        }
        #expect(!AppPlugin.widgets.words.checklist("Studio Mac").title.isEmpty, "the checklist offers widgets")
    }

    @Test func hooksReadAsPlainWords() {
        let lines = CapabilityWords.hookLines(["pre_llm_call", "post_llm_call", "transform_llm_output", "pre_tool_call",
                                               "post_tool_call", "on_human_input_request", "made_up_hook"])
        #expect(lines.map(\.words) == [
            "Can change Hermes’s replies before they’re saved",
            "Sees tool calls and can block one",
            "Sees tool calls and results",
            "Sees what’s sent to the model and what comes back",
            "Sees questions and when they’re answered",
            "Uses the made_up_hook hook",
        ])
        #expect(lines.first { $0.words.hasPrefix("Sees what") }?.names == ["pre_llm_call", "post_llm_call"])
        #expect(lines.filter { $0.kind == .reaches }.count == 3, "transform, pre_tool_call and the unknown hook reach")
        #expect(lines.last?.kind == .reaches)
    }

    @Test func aWholeListReadsTopToBottom() {
        let capabilities = PluginCapabilities(hooks: ["on_session_start"], tools: ["a", "b"], middleware: ["mw"],
                                              networkHosts: ["api.example.com"], env: ["KEY_ONE", "KEY_TWO"])
        let lines = CapabilityWords.lines(for: capabilities, gateway: "Studio Mac")
        #expect(lines.map(\.kind) == [.sees, .reaches, .tools, .network, .keys])
        #expect(lines[2].words == "Adds 2 tools Hermes can call")
        #expect(lines[4].words == "Needs 2 keys, added after it installs")
        let quiet = CapabilityWords.lines(for: PluginCapabilities(tools: ["one"]), gateway: "Studio Mac")
        #expect(quiet.last == CapabilityLine(.safe, "Needs no keys and sends nothing off Studio Mac", names: ["no network", "no keys"]))
    }

    @Test func monoNamesFoldSiblingHooks() {
        let line = CapabilityLine(.sees, "", names: ["pre_approval_request", "post_approval_response",
                                                     "on_human_input_request", "on_human_input_resolved"])
        #expect(line.mono == "pre_approval_request · post_approval_response · on_human_input_*")
        #expect(CapabilityLine(.sees, "", names: ["pre_llm_call", "pre_tool_call"]).mono == "pre_llm_call · pre_tool_call")
        #expect(CapabilityLine(.sees, "", names: ["kanban_task_completed", "kanban_task_blocked"]).mono == "kanban_task_*")
    }

    // MARK: Pins

    @Test func aPinThatAddsAHookWidens() {
        let widgets = AppPlugin.widgets
        #expect(widgets.widening(from: "1.1.0")?.hooks == ["pre_llm_call"], "1.1.1 added pre_llm_call")
        #expect(widgets.widening(from: "1.1.1") == nil)
        #expect(AppPlugin.push.widening(from: "1.0.0") == nil, "push kept the same access")
        let unknown = AppPlugin.push.widening(from: "0.9.0")
        #expect(unknown?.hooks.count == AppPlugin.push.pinnedCapabilities.hooks.count, "an unknown version can't be compared")
        let lines = CapabilityWords.consentLines(for: widgets.widening(from: "1.1.0")!, gateway: "Studio Mac")
        #expect(lines.map(\.words) == ["Sees what’s sent to the model and what comes back"])
    }

    @Test func capabilityDiffs() {
        let old = PluginCapabilities(hooks: ["a"], tools: ["t"], networkHosts: [])
        let new = PluginCapabilities(hooks: ["a", "b"], tools: ["t"], networkHosts: ["x.example"], env: ["K"])
        #expect(new.additions(since: old) == PluginCapabilities(hooks: ["b"], networkHosts: ["x.example"], env: ["K"]))
        #expect(new.widens(old))
        #expect(!old.widens(new))
        #expect(!PluginCapabilities(hooks: ["a"], env: ["K"]).widens(old), "a key alone isn't more access")
        #expect(PluginCapabilities(commands: ["c"]).widens(PluginCapabilities()))
    }

    // MARK: Keeping current

    private func survey(_ rows: [String: [HermesPlugin]], plugins: [AppPlugin] = [.widgets]) async -> AppPluginsSurvey {
        await AppPluginsSurvey.read(profiles: ["default", "ada", "ops"], plugins: plugins) { rows[$0] ?? [] }
    }

    @Test func aWideningPinWaitsForTheConsentCard() async {
        let survey = await survey(["default": [row("hermes-app-widgets", version: "1.1.0")],
                                   "ada": [row("hermes-app-widgets", version: "1.1.0")]])
        #expect(survey.plan().isEmpty, "nothing moves to more access by itself, not even into a Bot that lacks it")
        #expect(survey.held()[.widgets]?.hooks == ["pre_llm_call"])
        let accepted = survey.plan(consented: ["hermes-app-widgets": "1.2.0"])
        #expect(accepted.map(\.profile) == ["default", "ada", "ops"])
        #expect(accepted.map(\.action) == [.replace, .replace, .install])
    }

    @Test func theSameAccessMovesQuietly() async {
        let survey = await survey(["default": [row("hermes-app-push", version: "1.1.0")]], plugins: [.push])
        #expect(survey.held().isEmpty)
        #expect(survey.plan().map(\.profile) == ["default", "ada", "ops"], "older copies update and new Bots get it")
    }

    @Test func onlyWantedPluginsKeepCurrent() async {
        let nothing = await survey([:])
        #expect(nothing.plan().isEmpty, "a plugin nobody said yes to stays in Suggested")
        #expect(nothing.plan(consented: ["hermes-app-widgets": "1.2.0"]).count == 3)
        let off = await survey(["default": [row("hermes-app-widgets", version: AppPlugin.widgets.version, status: "not enabled")]])
        #expect(off.plan().isEmpty, "turned off everywhere: a new Bot doesn't get it either")
        #expect(off.fixes.map(\.action) == [.turnOn, .install, .install])
    }

    /// A Bot Chat is marked for widgets through its own Bot's profile, whatever Hermes itself has.
    @Test func whereWidgetsRunIsReadPerProfile() async {
        let survey = await survey(["default": [row("hermes-app-widgets", version: AppPlugin.widgets.version)],
                                   "ada": [row("hermes-app-widgets", version: "1.1.1")],
                                   "ops": [row("hermes-app-widgets", version: AppPlugin.widgets.version, status: "not enabled")]])
        #expect(survey.runs(.widgets, in: "default") == true)
        #expect(survey.runs(.widgets, in: "ada") == true, "an older copy still runs")
        #expect(survey.runs(.widgets, in: "ops") == false, "turned off")
        #expect(survey.runs(.widgets, in: "core") == nil, "a profile the survey didn't read")
        let missing = await self.survey([:])
        #expect(missing.runs(.widgets, in: "ada") == false)
        #expect(survey.profilesRunning(.widgets) == ["default", "ada"])
        #expect(survey.commandProfile(for: .widgets) == "default", "Hermes itself first")
        #expect(missing.commandProfile(for: .widgets) == nil)
    }

    /// Only a Bot has the plugin (an older copy counts): its commands go through that Bot.
    @Test func aBotOnlyPluginIsReachedThroughTheBot() async {
        let survey = await survey(["ada": [row("hermes-app-widgets", version: "1.2.1")],
                                   "ops": [row("hermes-app-widgets", version: AppPlugin.widgets.version, status: "not enabled")]])
        #expect(survey.profilesRunning(.widgets) == ["ada"])
        #expect(survey.commandProfile(for: .widgets) == "ada")
    }

    /// Several Bots have it and Hermes doesn't: the one whose chat is open is the way in.
    @Test func aBotWithAnOpenChatIsPreferred() async {
        let survey = await survey(["ada": [row("hermes-app-widgets", version: AppPlugin.widgets.version)],
                                   "ops": [row("hermes-app-widgets", version: AppPlugin.widgets.version)]])
        #expect(survey.commandProfile(for: .widgets) == "ada")
        #expect(survey.commandProfile(for: .widgets, open: ["ops"]) == "ops")
        #expect(survey.commandProfile(for: .widgets, open: ["scout"]) == "ada", "a chat without the plugin doesn't count")
        let rooted = await self.survey(["default": [row("hermes-app-widgets", version: AppPlugin.widgets.version)],
                                        "ops": [row("hermes-app-widgets", version: AppPlugin.widgets.version)]])
        #expect(rooted.commandProfile(for: .widgets, open: ["ops"]) == "default", "Hermes itself needs no open chat")
    }

    @Test func the130PluginAsksForNoMoreAccess() {
        let widgets = AppPlugin.widgets
        #expect(widgets.capabilities["1.3.0"] == widgets.capabilities["1.2.2"], "a published 1.3.0 updates quietly")
    }

    @Test func anOlderCopyThatsOffIsReplacedOff() async {
        let survey = await survey(["default": [row("hermes-app-widgets", version: AppPlugin.widgets.version)],
                                   "ada": [row("hermes-app-widgets", version: "1.1.1", status: "not enabled")]])
        let replace = survey.plan().first { $0.profile == "ada" }
        #expect(replace?.action == .replace)
        #expect(replace?.enable == false)
        #expect(survey.fixes.first { $0.profile == "ada" }?.enable == true, "Install or Turn On turns it on")
    }

    @Test func theAskListsWhatsMissingOrOlder() async {
        let survey = await survey(["default": [row("hermes-app-push", version: "1.2.0"), row("hermes-app-widgets", version: "1.1.0")]],
                                  plugins: AppPlugin.all)
        #expect(survey.missingOrOlder.map(\.name) == ["hermes-app-push", "hermes-app-widgets"], "push is missing in Ada and Ops")
        #expect(Set(survey.fixes(only: ["hermes-app-widgets"]).map(\.plugin.name)) == ["hermes-app-widgets"])
    }

    // MARK: Failures

    @Test func installFailuresInWords() {
        let clone = PluginInstallFailure(message: "Could not download the plugin from https://github.com/x/y.git. Check the address.\nDetails: git clone failed: Could not resolve host: github.com")
        #expect(clone.reason == .unreachable)
        #expect(clone.detail == "git clone failed: Could not resolve host: github.com")
        #expect(clone.words(gateway: "Studio Mac") == "Studio Mac couldn’t download it from GitHub. Check that it’s online, then try again.")
        let pulled = PluginInstallFailure(message: "Plugin 'agent-ledger' was removed from the Hermes plugin catalog and is blocked from installation: It sent commands away. (removed 2026-10-02)")
        #expect(pulled.reason == .pulled(reason: "It sent commands away."))
        let os = PluginInstallFailure(message: "Plugin 'nvidia-app' is unavailable on darwin; supported platforms: windows.")
        #expect(os.reason == .platform(supported: "Windows"))
        let version = PluginInstallFailure(message: "Plugin 'memory-palace' requires hermes >=0.30.0, running 0.22.2 Run hermes update to update Hermes.")
        #expect(version.reason == .hermesVersion(spec: ">=0.30.0"))
        #expect(PluginInstallFailure(message: "Plugin 'x' was not published: Reinstall declined: dependency install skipped (non-interactive).").reason == .dependencies)
        #expect(PluginInstallFailure(message: "boom").reason == .other)
        // A pin to a commit the repository no longer has (a build from before a history rewrite).
        let gone = PluginInstallFailure(message: "Git commit '27a6d5c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f70' could not be fetched:\nfatal: remote error: upload-pack: not our ref 27a6d5c0e1f2a3b4c5d6e7f8091a2b3c4d5e6f70")
        #expect(gone.reason == .revisionGone)
        #expect(gone.words(gateway: "Studio Mac").hasPrefix("This version of the plugin is no longer on GitHub."))
        let offline = PluginInstallFailure(message: "Git commit 'abc' could not be fetched:\nfatal: unable to access 'https://github.com/x/y.git/': Could not resolve host: github.com")
        #expect(offline.reason == .unreachable, "no network is still no network")
    }
}
