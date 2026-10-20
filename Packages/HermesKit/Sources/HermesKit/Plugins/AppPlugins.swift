import Foundation

/// A Hermes Agent plugin the app offers on its gateways (`docs/plugins.md` §3.1): one registry
/// entry each. The app installs it in the Hermes root and every Bot's profile with
/// `plugins.manage {action: install}`, pinned to the commit the app was built against, and keeps it
/// current. Adding a plugin is one entry here (with its words in `AppPluginRegistry.swift`) and a
/// What's New row.
public struct AppPlugin: Sendable, Hashable, Identifiable {
    /// Where the app may offer it, besides Apps and Tools → Plugins (`docs/plugins.md` §3.3).
    public enum Moment: String, Sendable, Hashable, CaseIterable {
        /// The one ask after Bot Mode first connects on a gateway (`pluginsAsk`).
        case ask
        /// Turn On Notifications, on a gateway without the plugin (`pushSetup`).
        case notificationsPrime
        /// What's New after an update that brings a feature it backs (`pluginWhatsNew`).
        case whatsNew
        /// The getting-started checklist (`pluginChecklist`).
        case checklist
    }

    /// One line of "What you get": a glyph and the words.
    public struct Benefit: Sendable, Hashable {
        public let symbol: String
        public let words: String
    }

    /// The offer card in context (`pluginOffer`): a title and a sentence for a gateway.
    public struct Offer: Sendable, Hashable {
        public let title: String
        public let body: String
    }

    /// The manifest's `name`: the key `plugins.manage list` reports it under.
    public let name: String
    /// The public repository Hermes clones (`owner/repo`).
    public let repo: String
    /// Its name in Hermes's catalog, once it's there (`docs/plugins.md` §13). Installs go by repo
    /// and ref until then.
    public let catalogName: String?
    /// The commit installs are pinned to (a full SHA: Hermes refuses anything shorter).
    public let ref: String
    /// The version that commit carries.
    public let version: String
    /// Installs older than this are replaced. Newer ones stay: another device may run a newer app.
    public let minimumVersion: String
    /// What each published version can do, from its `plugin.yaml` and `register()`. Moving a
    /// copy to a pin whose list adds access waits for the person (`docs/plugins.md` §7).
    public let capabilities: [String: PluginCapabilities]
    public let moments: Set<Moment>
    /// Its words, glyph and review (`AppPluginRegistry.swift`).
    public let words: Words

    public var id: String { name }

    public init(name: String, repo: String, catalogName: String? = nil, ref: String, version: String, minimumVersion: String,
                capabilities: [String: PluginCapabilities] = [:], moments: Set<Moment> = [], words: Words = Words()) {
        self.name = name
        self.repo = repo
        self.catalogName = catalogName
        self.ref = ref
        self.version = version
        self.minimumVersion = minimumVersion
        self.capabilities = capabilities
        self.moments = moments
        self.words = words
    }

    // Two entries are the same plugin at the same pin; the words don't make them different.
    public static func == (lhs: AppPlugin, rhs: AppPlugin) -> Bool {
        lhs.name == rhs.name && lhs.ref == rhs.ref && lhs.version == rhs.version && lhs.minimumVersion == rhs.minimumVersion
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(ref)
    }

    /// Every plugin the app offers, in the order it lists and installs them.
    public static let all: [AppPlugin] = [.push, .widgets]

    public static func named(_ name: String) -> AppPlugin? { all.first { $0.name == name } }

    /// The pinned version's capability list.
    public var pinnedCapabilities: PluginCapabilities { capabilities[version] ?? PluginCapabilities() }

    /// What moving a copy at `installedVersion` to the pin adds, or nil when it adds no access.
    /// A version the registry doesn't know (a copy installed by hand from an unpublished commit)
    /// can't be compared, so all of the pin's access counts as new: the person decides.
    public func widening(from installedVersion: String) -> PluginCapabilities? {
        let pinned = pinnedCapabilities
        let older = capabilities[installedVersion] ?? PluginCapabilities()
        return pinned.widens(older) ? pinned.additions(since: older) : nil
    }

    /// "github.com/vburojevic/hermes-app-push".
    public var source: String { "github.com/\(repo)" }

    /// Where this plugin stands in one profile, from that profile's `plugins.manage list`.
    public func state(in installed: [HermesPlugin]) -> AppPluginState {
        guard let row = installed.first(where: { $0.key == name || $0.name == name }) else { return .missing }
        if !Self.version(row.version, isAtLeast: minimumVersion) { return .outdated(version: row.version) }
        return row.isEnabled ? .current(version: row.version) : .off
    }

    /// Dotted version numbers, compared part by part ("1.10" is newer than "1.9"). A version
    /// that isn't one (empty, "dev") counts as older, so it gets replaced.
    public static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let core = text.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
            let numbers = core.split(separator: ".").map { Int($0) }
            return numbers.isEmpty || numbers.contains(nil) ? nil : numbers.compactMap { $0 }
        }
        guard let have = parts(version) else { return false }
        guard let need = parts(minimum) else { return true }
        for index in 0..<max(have.count, need.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < need.count ? need[index] : 0
            if a != b { return a > b }
        }
        return true
    }
}

public enum AppPluginState: Sendable, Hashable {
    case current(version: String)
    case missing
    /// Installed, but older than the app needs.
    case outdated(version: String)
    /// Installed and turned off. The app turns it back on only when the person asks (Install,
    /// Turn On); keeping current leaves it.
    case off

    public var isCurrent: Bool {
        if case .current = self { true } else { false }
    }

    public var needsInstall: Bool {
        switch self {
        case .missing, .outdated: true
        case .current, .off: false
        }
    }
}

/// What the app found on one gateway: each profile's state for each of the app's plugins.
public struct AppPluginsSurvey: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        /// The Hermes profile (`default` for the root).
        public let profile: String
        public let plugin: AppPlugin
        public let state: AppPluginState
        /// The copy there is turned on (an older copy can be off too).
        public let isOn: Bool

        public init(profile: String, plugin: AppPlugin, state: AppPluginState, isOn: Bool? = nil) {
            self.profile = profile
            self.plugin = plugin
            self.state = state
            self.isOn = isOn ?? (state != .off && state != .missing)
        }
    }

    /// One change to one profile: an install, a reinstall over an older copy (`force`), or turning
    /// a copy that's off back on (`toggle`).
    public struct Step: Sendable, Hashable {
        public enum Action: Sendable, Hashable {
            case install, replace, turnOn
        }

        public let profile: String
        public let plugin: AppPlugin
        public let action: Action
        /// An older copy that's turned off is replaced turned off.
        public var enable = true

        public var replaces: Bool { action == .replace }
    }

    public let entries: [Entry]
    /// Profiles whose plugins couldn't be read, with Hermes's message.
    public let failures: [String: String]

    public init(entries: [Entry], failures: [String: String] = [:]) {
        self.entries = entries
        self.failures = failures
    }

    /// Reads every profile's plugins; one profile failing doesn't stop the others.
    public static func read(
        profiles: [String], plugins: [AppPlugin] = AppPlugin.all,
        list: @Sendable (String) async throws -> [HermesPlugin]
    ) async -> AppPluginsSurvey {
        var entries: [Entry] = []
        var failures: [String: String] = [:]
        for profile in profiles {
            do {
                let installed = try await list(profile)
                entries += plugins.map { plugin in
                    let row = installed.first { $0.key == plugin.name || $0.name == plugin.name }
                    return Entry(profile: profile, plugin: plugin, state: plugin.state(in: installed), isOn: row?.isEnabled ?? false)
                }
            } catch {
                failures[profile] = error.localizedDescription
            }
        }
        return AppPluginsSurvey(entries: entries, failures: failures)
    }

    /// What keeping current does by itself (`docs/plugins.md` §7): installs and updates, the
    /// root's first, for the plugins this gateway already has or the person said yes to. A copy
    /// someone turned off stays off, and a plugin whose pin would widen its access waits (`held`).
    /// `consented`: the version the person last said yes to on this device, by plugin name.
    public func plan(consented: [String: String] = [:]) -> [Step] {
        // Wanted: said yes to on this device, or on somewhere on the gateway. Turned off
        // everywhere means it isn't, so a new Bot doesn't get it either.
        let wanted = Set(entries.compactMap { entry -> String? in
            consented[entry.plugin.name] != nil || entry.isOn ? entry.plugin.name : nil
        })
        let waiting = Set(held(consented: consented).keys.map(\.name))
        return steps(turningOn: false).filter { wanted.contains($0.plugin.name) && !waiting.contains($0.plugin.name) }
    }

    /// Plugins whose pinned version can do more than anything the person said yes to on this
    /// gateway, with what it adds: they wait for the consent card (`pluginUpdate`). The baseline
    /// is the newest of the versions on the gateway and the one the person last accepted.
    public func held(consented: [String: String] = [:]) -> [AppPlugin: PluginCapabilities] {
        var held: [AppPlugin: PluginCapabilities] = [:]
        for plugin in Set(entries.map(\.plugin)) {
            var versions = entries(for: plugin).compactMap { entry -> String? in
                switch entry.state {
                case .current(let version), .outdated(let version): version
                case .missing, .off: nil
                }
            }
            if let accepted = consented[plugin.name] { versions.append(accepted) }
            guard let baseline = versions.max(by: { !AppPlugin.version($0, isAtLeast: $1) }) else { continue }
            guard entries(for: plugin).contains(where: { $0.state.needsInstall }) else { continue }
            if let added = plugin.widening(from: baseline) { held[plugin] = added }
        }
        return held
    }

    /// What the person's Install or Turn On does: every install and update, plus turning copies
    /// that are off back on. `only` limits it to some plugins (the ask's switches).
    public func fixes(only names: Set<String>? = nil) -> [Step] {
        steps(turningOn: true).filter { names?.contains($0.plugin.name) ?? true }
    }

    public var fixes: [Step] { fixes() }

    public func steps(turningOn: Bool) -> [Step] {
        entries.compactMap { entry -> Step? in
            switch entry.state {
            case .missing: Step(profile: entry.profile, plugin: entry.plugin, action: .install)
            case .outdated:
                Step(profile: entry.profile, plugin: entry.plugin, action: .replace, enable: turningOn || entry.isOn)
            case .off: turningOn ? Step(profile: entry.profile, plugin: entry.plugin, action: .turnOn) : nil
            case .current: nil
            }
        }
        .sorted { ($0.profile == "default" ? 0 : 1) < ($1.profile == "default" ? 0 : 1) }
    }

    /// The app's plugins missing or older somewhere on this gateway: what the ask lists.
    public var missingOrOlder: [AppPlugin] {
        plugins.filter { plugin in entries(for: plugin).contains { $0.state.needsInstall } }
    }

    /// The plugins this survey looked for, in the registry's order.
    public var plugins: [AppPlugin] {
        var seen = Set<String>()
        return entries.map(\.plugin).filter { seen.insert($0.name).inserted }
    }

    public var isCurrent: Bool { fixes.isEmpty && failures.isEmpty }

    public func entries(for plugin: AppPlugin) -> [Entry] { entries.filter { $0.plugin == plugin } }

    /// Profiles where `plugin` is installed and on.
    public func profilesWith(_ plugin: AppPlugin) -> [String] {
        entries(for: plugin).filter { if case .current = $0.state { true } else { false } }.map(\.profile)
    }

    /// Profiles a step would install into or update.
    public var profilesNeedingWork: [String] { Self.profiles(of: plan()) }

    /// Profiles the person's Install or Turn On would change.
    public var profilesToFix: [String] { Self.profiles(of: fixes) }

    public static func profiles(of steps: [Step]) -> [String] {
        var seen = Set<String>()
        return steps.map(\.profile).filter { seen.insert($0).inserted }
    }
}

/// One plugin on one gateway, as Settings and Settings → Setup show it (`docs/plugins.md` §2.1,
/// `docs/setup.md`). Profiles are Hermes profile names (`default` for the root).
public enum AppPluginStatus: Sendable, Hashable {
    case needsBotMode
    case offline
    case checking
    /// On and current in these profiles, every profile there is.
    case current(profiles: [String])
    case missing(profiles: [String])
    case outdated(profiles: [String])
    case off(profiles: [String])
    /// Installed everywhere; the gateway hasn't restarted since the root got it.
    case restartPending
    /// Hermes's words: a profile that couldn't be read, or an install that didn't go through.
    case failed(String)

    public var isReady: Bool {
        if case .current = self { true } else { false }
    }

    /// From what the last check found. Missing comes first, then older copies, then copies turned
    /// off, then a pending restart: each is what the person would fix next.
    public static func of(_ plugin: AppPlugin, in survey: AppPluginsSurvey, restartPending: Bool,
                          installFailures: [String: String] = [:]) -> AppPluginStatus {
        if let failure = installFailures.merging(survey.failures, uniquingKeysWith: { first, _ in first })
            .sorted(by: { $0.key < $1.key }).first {
            return .failed(failure.value)
        }
        let entries = survey.entries(for: plugin)
        func profiles(_ match: (AppPluginState) -> Bool) -> [String] { entries.filter { match($0.state) }.map(\.profile) }
        let missing = profiles { $0 == .missing }
        if !missing.isEmpty { return .missing(profiles: missing) }
        let outdated = profiles { if case .outdated = $0 { true } else { false } }
        if !outdated.isEmpty { return .outdated(profiles: outdated) }
        let off = profiles { $0 == .off }
        if !off.isEmpty { return .off(profiles: off) }
        if restartPending { return .restartPending }
        return .current(profiles: entries.map(\.profile))
    }
}

extension ConnectionsClient {
    /// Installs one of the app's plugins in this client's profile, pinned to the app's commit.
    /// `replacing` reinstalls over an older copy: Hermes's `update` only moves catalog installs.
    public func install(_ plugin: AppPlugin, replacing: Bool, enable: Bool = true) async throws -> PluginActionResult {
        try await installPlugin(repo: plugin.repo, ref: plugin.ref, force: replacing, enable: enable)
    }

    /// One step of a survey's plan or fixes, in this client's profile.
    public func apply(_ step: AppPluginsSurvey.Step) async throws -> PluginActionResult {
        switch step.action {
        case .install: try await install(step.plugin, replacing: false)
        case .replace: try await install(step.plugin, replacing: true, enable: step.enable)
        case .turnOn: try await togglePlugin(step.plugin.name, enable: true)
        }
    }
}
