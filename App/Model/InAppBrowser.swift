import Foundation
import HermesKit
import Observation

/// Whether this app is Hermes's browser on a gateway (`docs/web.md` §6): In this app
/// (`browser.extension_control.enabled`) as each profile's config says it (Hermes routes a chat's
/// browser steps by its own profile's switch), and what Hermes said the last time a chat
/// registered the app's browser.
@MainActor
@Observable
final class InAppBrowser {
    /// The switch per profile ("" is the gateway's own, which the Browser page sets).
    private(set) var flags: [String: Bool] = [:]
    /// Why the last registration failed, until one works or the place changes.
    var refusal: BrowserControlRefusal?

    @ObservationIgnored private weak var workspace: BotWorkspace?
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var refreshing: Set<String> = []

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    /// The Browser page's profile.
    private var ownProfile: String? { workspace?.bot.profileName }

    private func key(_ profile: String?) -> String { profile ?? ownProfile ?? "" }

    /// In this app, for the gateway's own profile: what the Browser page and Setup show.
    var isOn: Bool { isOn(profile: nil) }

    func isOn(profile: String?) -> Bool { flags[key(profile)] ?? false }

    /// What a config read said, for `profile` (the gateway's own by default).
    func read(_ settings: BrowserSettings, profile: String? = nil) {
        flags[key(profile)] = settings.extensionControl
        readAt[key(profile)] = .now
    }

    /// The Browser page chose In this app: other profiles' switches are read again before their next turn.
    func turnedOn() {
        flags[key(nil)] = true
        readAt = [key(nil): .now]
        refusal = nil
    }

    /// Another place: every chat on this gateway gives the app's browser back (a Bot whose own
    /// profile still says In this app registers again with its next turn).
    func turnedOff() {
        flags[key(nil)] = false
        readAt = [key(nil): .now]
        refusal = nil
        if let id = workspace?.id { BrowserController.detachAll(gateway: id) }
    }

    /// Before a turn: the profile's switch as last read (Setup and the Browser page read the
    /// gateway's own too). A read older than five minutes is refreshed in the background; with none
    /// yet, the turn waits for one at most three seconds, so a slow gateway never holds a message up.
    func prepare(profile: String?) async {
        if let readAt = readAt[key(profile)] {
            if Date.now.timeIntervalSince(readAt) >= 300 { Task { await refresh(profile: profile) } }
            return
        }
        let reading = Task { await refresh(profile: profile) }
        let cap = Task {
            try? await Task.sleep(for: .seconds(3))
            reading.cancel()
        }
        await reading.value
        cap.cancel()
    }

    /// Without Bot Mode there's no config to read, so the switch stays as it was.
    private func refresh(profile: String?) async {
        let key = key(profile)
        guard !refreshing.contains(key), let workspace, let roster = workspace.roster, roster.isConnected else { return }
        refreshing.insert(key)
        defer { refreshing.remove(key) }
        guard let config = try? await roster.backendClient.config(profile: profile ?? ownProfile) else { return }
        read(BrowserSettings(config: config), profile: profile)
    }
}
