import Foundation
import HermesKit
import Observation
import os

/// The app's own Hermes plugins on one gateway (`docs/plugins.md` §2, `pluginsAsk`): finds the
/// profiles where one is missing or older than the app needs, asks once, installs what the person
/// chose in the root and every Bot's profile, and from then on keeps them current by itself. A pin
/// that adds access waits for the person (`pluginUpdate`).
@MainActor
@Observable
final class AppPluginsModel {
    enum Phase: Equatable {
        case idle
        case checking
        /// `profile` is the one being installed into, as the app names it.
        case installing(profile: String, done: Int, total: Int)
        case restarting
    }

    /// The person's answer to the ask, per gateway, on this device.
    enum Consent: String {
        case install, declined
    }

    /// What the last install the person started did, for its result screen.
    struct Run: Equatable {
        /// The plugins it installed or turned on, by name.
        let plugins: [String]
        /// Profiles where a step didn't go through, in Hermes's words.
        let failures: [String: String]
        /// What Hermes said it activated, from the root's result.
        let results: [String: PluginActionResult]
    }

    private(set) var survey: AppPluginsSurvey?
    private(set) var checkedAt: Date?
    private(set) var phase: Phase = .idle
    /// The plugins an install under way is for: their rows keep a spinner.
    private(set) var installing: Set<String> = []
    private(set) var lastRun: Run?
    /// Installs that didn't go through, by profile, in Hermes's words.
    private(set) var failures: [String: String] = [:]
    /// The root got a plugin: the gateway starts its delivery and its watcher only when it starts.
    /// Kept per gateway, with the gateway's process id then, until a check sees a new process.
    private(set) var needsRestart: Bool
    private(set) var restartError: String?
    /// The ask (`pluginsAsk`) is up for this gateway.
    var isAsking = false

    @ObservationIgnored weak var workspace: BotWorkspace?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// When Bot Mode's connection last led to a check and its follow-up (the ask, or keeping current).
    @ObservationIgnored private var followedUpAt: Date?
    private let gatewayID: UUID
    private static let log = Logger(subsystem: "co.caffeinatedcode.hermes", category: "plugins")

    init(workspace: BotWorkspace) {
        self.workspace = workspace
        gatewayID = workspace.id
        needsRestart = UserDefaults.standard.object(forKey: "appPlugins.restartPID.\(workspace.id.uuidString)") != nil
        consented = UserDefaults.standard.dictionary(forKey: "appPlugins.consented.\(workspace.id.uuidString)") as? [String: String] ?? [:]
    }

    private var roster: BotRoster? { workspace?.roster }
    var needsBotMode: Bool { roster == nil }
    var isOnline: Bool { roster?.isConnected ?? false }
    var isBusy: Bool { phase != .idle }
    var gatewayName: String { workspace?.bot.name ?? "" }

    private var consentKey: String { "appPlugins.consent.\(gatewayID.uuidString)" }
    /// The gateway's process id when its root got a plugin (0 when it didn't say).
    private var restartPIDKey: String { "appPlugins.restartPID.\(gatewayID.uuidString)" }
    var consent: Consent? {
        get { UserDefaults.standard.string(forKey: consentKey).flatMap(Consent.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: consentKey) }
    }

    private var consentedKey: String { "appPlugins.consented.\(gatewayID.uuidString)" }
    /// The version of each plugin the person last said yes to on this gateway, on this device:
    /// the ask, a review's Install, or Allow on the consent card. Keeping current never goes
    /// past what it allows (`AppPluginsSurvey.held`).
    private(set) var consented: [String: String] {
        didSet { UserDefaults.standard.set(consented, forKey: consentedKey) }
    }

    /// The app's plugins the one ask lists: missing or older somewhere on this gateway.
    var askable: [AppPlugin] {
        survey?.missingOrOlder.filter { $0.moments.contains(.ask) } ?? []
    }

    /// App plugins whose pin adds access, waiting for the consent card, with what it adds.
    var heldUpdates: [AppPlugin: PluginCapabilities] {
        survey?.held(consented: consented) ?? [:]
    }

    // MARK: Moments

    /// Bot Mode came online: look at most hourly. With the person's yes, bring every profile up to
    /// date quietly; without an answer yet, ask.
    func connected() {
        // Its own clock: a check from a page (Settings, Setup) mustn't stand in for keeping current.
        guard work == nil, followedUpAt.map({ Date.now.timeIntervalSince($0) > 3600 }) ?? true else { return }
        work = Task { [weak self] in
            await self?.check()
            await self?.followUp()
            self?.followedUpAt = .now
            self?.work = nil
        }
    }

    /// A Bot was just made: a fresh profile has none of the root's plugins.
    func botCreated() {
        guard consent == .install || !consented.isEmpty else { return }
        checkedAt = nil
        work?.cancel()
        work = Task { [weak self] in
            await self?.check()
            await self?.followUp()
            self?.work = nil
        }
    }

    /// After a check: the ask once, if this device hasn't answered and something is missing or
    /// older; otherwise keep what the person wanted current, quietly.
    private func followUp() async {
        guard let survey else { return }
        if consent == nil {
            if !askable.isEmpty {
                isAsking = true
            } else if survey.failures.isEmpty, !survey.entries.isEmpty {
                // Nothing to ask: every plugin is already here. Bots made later get them.
                consent = .install
            }
            return
        }
        guard consent == .install || !consented.isEmpty, !survey.plan(consented: consented).isEmpty else { return }
        await keepCurrent()
    }

    // MARK: Actions

    func check() async {
        guard let roster, roster.isConnected, phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        let profiles = Self.profiles(roster.profiles.map(\.name))
        let transport = Self.transport(roster)
        survey = await AppPluginsSurvey.read(profiles: profiles) { profile in
            try await ConnectionsClient(profile: profile, transport: transport).plugins()
        }
        checkedAt = .now
        if let survey, !survey.failures.isEmpty {
            Self.log.notice("plugins: \(survey.failures.count, privacy: .public) profiles couldn't be read")
        }
        if needsRestart { await clearRestartIfDone() }
    }

    /// A new gateway process means it restarted, however it did: by the app, by hand or by itself.
    private func clearRestartIfDone() async {
        let saved = UserDefaults.standard.integer(forKey: restartPIDKey)
        guard saved != 0, let pid = await gatewayPID(), pid != saved else { return }
        markRestarted()
    }

    private func gatewayPID() async -> Int? {
        try? await workspace?.client?.healthDetail().pid
    }

    private func markRestartNeeded(pid: Int?) {
        UserDefaults.standard.set(pid ?? 0, forKey: restartPIDKey)
        needsRestart = true
    }

    private func markRestarted() {
        UserDefaults.standard.removeObject(forKey: restartPIDKey)
        needsRestart = false
    }

    /// Keeping current (`docs/plugins.md` §7): the plan, never past what the person allowed,
    /// never turning a copy that's off back on.
    private func keepCurrent() async {
        guard let plan = survey?.plan(consented: consented), !plan.isEmpty else { return }
        await run(plan, recording: false)
    }

    /// The person's Install or Turn On (the ask, a review, Set Up Push, the per-Bot page): every
    /// profile where `only`'s plugins are missing, older or off, the root first, one profile at
    /// a time. It's their yes to each plugin's pinned version on this gateway.
    /// `profiles` limits it to some profiles (a row of the per-Bot page).
    func install(only names: Set<String>? = nil, profiles: Set<String>? = nil) async {
        guard let roster, roster.isConnected, !isBusy else { return }
        consent = .install
        if survey == nil { await check() }
        let chosen = names ?? Set(AppPlugin.all.map(\.name))
        for plugin in AppPlugin.all where chosen.contains(plugin.name) {
            consented[plugin.name] = plugin.version
        }
        guard let steps = survey?.fixes(only: chosen).filter({ profiles?.contains($0.profile) ?? true }), !steps.isEmpty else { return }
        await run(steps, recording: true)
    }

    /// Allow on the consent card: the person accepts what the new pin adds, then it installs.
    func acceptUpdate(_ plugin: AppPlugin) async {
        consented[plugin.name] = plugin.version
        await install(only: [plugin.name])
    }

    private func run(_ steps: [AppPluginsSurvey.Step], recording: Bool) async {
        // Only from idle: a check still running would set the phase back to idle mid-run.
        guard let roster, roster.isConnected, phase == .idle else { return }
        failures = [:]
        installing = Set(steps.map(\.plugin.name))
        defer { installing = [] }
        let transport = Self.transport(roster)
        var rootChanged = false
        var results: [String: PluginActionResult] = [:]
        // Progress counts profiles ("Installing in Scout… (4 of 5)"), whatever each one gets.
        let profiles = AppPluginsSurvey.profiles(of: steps)
        for step in steps {
            phase = .installing(profile: title(of: step.profile), done: profiles.firstIndex(of: step.profile) ?? 0, total: profiles.count)
            do {
                let result = try await ConnectionsClient(profile: step.profile, transport: transport).apply(step)
                if !result.ok {
                    failures[step.profile] = result.error ?? String(localized: "Hermes didn't install it.")
                } else {
                    if step.profile == "default" { results[step.plugin.name] = result }
                    if result.restartRequired || (step.profile == "default" && step.plugin.words.restartReason != nil) {
                        rootChanged = true
                    }
                }
            } catch {
                failures[step.profile] = error.localizedDescription
            }
        }
        if rootChanged { markRestartNeeded(pid: await gatewayPID()) }
        Self.log.notice("plugins: \(steps.count - self.failures.count, privacy: .public) of \(steps.count, privacy: .public) installs went through")
        if recording {
            var seen = Set<String>()
            lastRun = Run(plugins: steps.map(\.plugin.name).filter { seen.insert($0).inserted }, failures: failures, results: results)
        }
        phase = .idle
        await check()
        #if HERMES_PUSH
        await PushCenter.shared.recheck(gatewayID)
        #endif
    }

    /// Turn Off in Hermes and All Bots: the plugin stays installed, off everywhere, and keeping
    /// current leaves it (nothing is on and the person's yes is withdrawn).
    func turnOff(_ plugin: AppPlugin) async {
        consented[plugin.name] = nil
        let profiles = survey?.entries(for: plugin).filter(\.isOn).map(\.profile) ?? []
        await each(profiles, of: plugin) { client in try await client.togglePlugin(plugin.name, enable: false) }
    }

    /// Remove from <gateway>: out of every profile. It goes back to Suggested.
    func remove(_ plugin: AppPlugin) async {
        consented[plugin.name] = nil
        let profiles = survey?.entries(for: plugin).filter { $0.state != .missing }.map(\.profile) ?? []
        await each(profiles, of: plugin) { client in try await client.removePlugin(plugin.name) }
    }

    private func each(_ profiles: [String], of plugin: AppPlugin,
                      _ action: @escaping (ConnectionsClient) async throws -> PluginActionResult) async {
        guard let roster, roster.isConnected, !isBusy, !profiles.isEmpty else { return }
        failures = [:]
        installing = [plugin.name]
        defer { installing = [] }
        let transport = Self.transport(roster)
        for (index, profile) in profiles.enumerated() {
            phase = .installing(profile: title(of: profile), done: index, total: profiles.count)
            do {
                let result = try await action(ConnectionsClient(profile: profile, transport: transport))
                if !result.ok { failures[profile] = result.error ?? String(localized: "Hermes didn't change it.") }
            } catch {
                failures[profile] = error.localizedDescription
            }
        }
        phase = .idle
        await check()
        #if HERMES_PUSH
        await PushCenter.shared.recheck(gatewayID)
        #endif
    }

    /// `hermes gateway restart`, through the backend. Running replies finish first.
    func restartGateway() async {
        guard let roster, !isBusy else { return }
        phase = .restarting
        restartError = nil
        do {
            try await roster.restartGateway()
            markRestarted()
        } catch {
            restartError = error.localizedDescription
        }
        phase = .idle
    }

    /// Not Now: never asked again for this gateway on this device. Suggested still offers them.
    func decline() {
        consent = .declined
        isAsking = false
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: restartPIDKey)
        consented = [:]
        UserDefaults.standard.removeObject(forKey: consentedKey)
    }

    func tearDown() {
        work?.cancel()
        work = nil
    }

    // MARK: Reading it

    /// "Hermes" for the root, else the Bot's name.
    func title(of profile: String) -> String {
        if profile == "default" { return String(localized: "Hermes") }
        return roster?.bot(named: profile)?.title ?? profile
    }

    /// Where `plugin` is on: "Hermes and 4 Bots", "Hermes", "Ada and Ops".
    func placesWith(_ plugin: AppPlugin) -> String {
        guard let survey else { return "" }
        return Self.places(survey.profilesWith(plugin), title: title(of:))
    }

    /// Where one plugin stands on this gateway (Settings → Setup reads it, `docs/setup.md`).
    func status(for plugin: AppPlugin) -> AppPluginStatus {
        if needsBotMode { return .needsBotMode }
        guard let survey else { return isOnline ? .checking : .offline }
        return .of(plugin, in: survey, restartPending: needsRestart && plugin.words.restartReason != nil, installFailures: failures)
    }

    static func line(for status: AppPluginStatus, title: (String) -> String) -> String {
        switch status {
        case .needsBotMode: String(localized: "Needs Bot Mode")
        case .offline: String(localized: "Offline")
        case .checking: String(localized: "Checking…")
        case .current(let profiles): String(localized: "Installed in \(places(profiles, title: title))")
        case .missing(let profiles): String(localized: "Missing in \(places(profiles, title: title))")
        case .outdated(let profiles): String(localized: "Needs an update in \(places(profiles, title: title))")
        case .off(let profiles): String(localized: "Turned off in \(places(profiles, title: title))")
        case .restartPending: String(localized: "Restart the gateway to finish")
        case .failed(let message): message
        }
    }

    static func places(_ profiles: [String], title: (String) -> String) -> String {
        let bots = profiles.filter { $0 != "default" }
        let hasRoot = profiles.contains("default")
        switch (hasRoot, bots.count) {
        case (_, 0): return hasRoot ? String(localized: "Hermes") : ""
        case (true, 1): return String(localized: "Hermes and 1 Bot")
        case (true, let count): return String(localized: "Hermes and \(count) Bots")
        case (false, 1): return title(bots[0])
        case (false, 2): return String(localized: "\(title(bots[0])) and \(title(bots[1]))")
        case (false, let count): return String(localized: "\(count) Bots")
        }
    }

    /// Every profile, the root once and first, even before the roster lists it.
    static func profiles(_ names: [String]) -> [String] {
        ["default"] + names.filter { $0 != "default" }.uniqued()
    }

    private static func transport(_ roster: BotRoster) -> ConnectionsClient.Transport {
        // A clone and a scan can take a while on a busy Mac.
        { [weak roster] method, params in
            guard let roster else { throw GatewaySocket.Failure.notConnected }
            return try await roster.request(method, params, timeout: .seconds(180))
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
