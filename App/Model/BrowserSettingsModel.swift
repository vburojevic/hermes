import Foundation
import HermesKit
import Observation

/// Settings → Hermes on <gateway> → Browser (`docs/web.md` §5): where Hermes browses for new chats,
/// the engine, and the advanced switches. Everything is read and written through Bot Mode's backend
/// (`GET`/`PUT /api/config`, `browser.manage`), so the page needs it.
@MainActor
@Observable
final class BrowserSettingsModel {
    let workspace: BotWorkspace

    private(set) var settings: BrowserSettings?
    private(set) var connection: BrowserConnection?
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// What's being changed, for its row's spinner: a place's id, "engine", "fast", "private",
    /// "record", "blocklist".
    private(set) var busy: Set<String> = []
    /// A change that didn't take, in words.
    var message: String?
    /// What Hermes said while it looked for a window to attach to.
    private(set) var connectNotes: [String] = []
    /// Set after a change: open chats keep the browser they started with.
    private(set) var changedThisVisit = false

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    private var roster: BotRoster? { workspace.roster }
    var isOnline: Bool { roster?.isConnected ?? false }
    var needsBotMode: Bool { roster == nil }
    var gatewayName: String { workspace.bot.name }
    private var profile: String? { workspace.bot.profileName }

    var place: BrowserPlace? { settings.map { BrowserPlace.current($0, connection) } }

    /// "A clean browser on Studio Mac": the Settings row and the Built-in row.
    var summary: String {
        guard !needsBotMode else { return String(localized: "Needs Bot Mode") }
        guard let place, let settings else { return String(localized: "Where Hermes browses") }
        return BrowserCopy.summary(place, settings: settings, gateway: gatewayName)
    }

    // MARK: Loading

    func load() async {
        guard let roster, roster.isConnected else { return }
        let client = roster.backendClient
        let profile = profile
        async let config = client.config(profile: profile)
        async let status = manage(["action": .string("status")], timeout: .seconds(20))
        do {
            let settings = BrowserSettings(config: try await config)
            self.settings = settings
            workspace.inAppBrowser.read(settings)
            loadError = nil
            hasLoaded = true
        } catch {
            loadError = String(localized: "Couldn't read the browser settings from \(gatewayName).")
        }
        connection = (try? await status).map(BrowserConnection.init(json:))
    }

    private func manage(_ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        guard let roster else { throw GatewaySocket.Failure.notConnected }
        var params = params
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return try await roster.request("browser.manage", params, timeout: timeout)
    }

    // MARK: Places

    /// Whether choosing `place` needs the profile consent first (`browserProfileConsent`): asked
    /// once per gateway on this device.
    func needsConsent(for place: BrowserPlace) -> Bool {
        place == .withYourLogins && !UserDefaults.standard.bool(forKey: consentKey)
    }

    func recordConsent() {
        UserDefaults.standard.set(true, forKey: consentKey)
    }

    private var consentKey: String { "browser.profileConsent.\(workspace.bot.id)" }

    /// Makes `place` the one new chats use. The cloud is chosen through its provider sheet, which
    /// calls `choseCloud()` once a provider is saved.
    func choose(_ place: BrowserPlace) async {
        guard place != self.place else { return }
        busy.insert(place.id)
        defer { busy.remove(place.id) }
        do {
            switch place {
            case .inThisApp:
                try await leaveWindow()
                try await write(BrowserSettings.inThisAppPatch)
                // Hermes checks a registration against the profile it was started with: that one
                // lets controllers register too (it changes nothing for its own chats by itself).
                if let profile, !profile.isEmpty, let roster {
                    try await roster.backendClient.updateConfig(BrowserSettings.controllersAllowedPatch, profile: nil)
                }
                workspace.inAppBrowser.turnedOn()
            case .window:
                connectNotes = []
                let result = try await manage(["action": .string("connect")], timeout: .seconds(60))
                if result["connected"]?.boolValue != true {
                    connectNotes = BrowserCopy.connectNotes(result)
                    message = String(localized: "Hermes couldn't open a window on \(gatewayName).")
                    await load()
                    return
                }
                try await write(BrowserSettings.windowPatch)
                workspace.inAppBrowser.turnedOff()
            case .cleanBrowser, .withYourLogins:
                try await leaveWindow()
                try await write(place == .cleanBrowser ? BrowserSettings.cleanBrowserPatch : BrowserSettings.withYourLoginsPatch)
                workspace.inAppBrowser.turnedOff()
            case .cloud:
                return
            }
            changedThisVisit = true
        } catch {
            message = BrowserCopy.failure(error, gateway: gatewayName)
        }
        await load()
    }

    /// A cloud provider was saved with its keys (`ToolsetKeySheet`): the copied profile goes and
    /// a window Hermes was attached to is let go, so the cloud is what new chats use.
    func choseCloud() async {
        busy.insert(BrowserPlace.cloud.id)
        defer { busy.remove(BrowserPlace.cloud.id) }
        do {
            try await leaveWindow()
            try await write(BrowserSettings.cloudPatch)
            workspace.inAppBrowser.turnedOff()
            changedThisVisit = true
        } catch {
            message = BrowserCopy.failure(error, gateway: gatewayName)
        }
        await load()
    }

    private func leaveWindow() async throws {
        guard connection?.connected == true else { return }
        _ = try await manage(["action": .string("disconnect")], timeout: .seconds(30))
    }

    private func write(_ patch: JSONValue) async throws {
        guard let roster else { throw GatewaySocket.Failure.notConnected }
        try await roster.backendClient.updateConfig(patch, profile: profile)
    }

    // MARK: Engine and switches

    /// Browser Use (one `browser_exec` tool) or Hermes's built-in browser tools, for new chats.
    func setBrowserUse(_ on: Bool) async {
        await change("engine") { _ = try await self.manage(["action": .string("use"), "enabled": .bool(on)], timeout: .seconds(20)) }
    }

    func setFastTextOnly(_ on: Bool) async {
        await change("fast") { try await self.write(BrowserSettings.fastTextOnlyPatch(on)) }
    }

    func setLocalForPrivateAddresses(_ on: Bool) async {
        await change("private") { try await self.write(BrowserSettings.localForPrivateAddressesPatch(on)) }
    }

    func setRecordSessions(_ on: Bool) async {
        await change("record") { try await self.write(BrowserSettings.recordSessionsPatch(on)) }
    }

    func setBlocklist(enabled: Bool, domains: [String]) async {
        await change("blocklist") { try await self.write(BrowserSettings.blocklistPatch(enabled: enabled, domains: domains)) }
    }

    private func change(_ id: String, _ work: () async throws -> Void) async {
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await work()
            changedThisVisit = true
        } catch {
            message = BrowserCopy.failure(error, gateway: gatewayName)
        }
        await load()
    }
}

/// The Browser page's words (`docs/web.md` §5, §7): places said as places.
enum BrowserCopy {
    static func title(_ place: BrowserPlace, gateway: String) -> String {
        switch place {
        case .inThisApp: String(localized: "In this app")
        case .cleanBrowser: String(localized: "A clean browser on \(gateway)")
        case .withYourLogins: String(localized: "With your logins on \(gateway)")
        case .window: String(localized: "A window on \(gateway)")
        case .cloud: String(localized: "In the cloud")
        }
    }

    static func detail(_ place: BrowserPlace, gateway: String) -> String {
        switch place {
        case .inThisApp: String(localized: "Watch it live and take over any time. On a sign-in page, you sign in with your Passwords; Hermes waits.")
        case .cleanBrowser: String(localized: "Starts fresh every time. Signs in with the logins in Passwords.")
        case .withYourLogins: String(localized: "A copy of your Chrome profile, with its cookies and logins. Your own profile is never opened.")
        case .window: String(localized: "A Chrome window you can watch on \(gateway). What you sign in to there stays.")
        case .cloud: String(localized: "For sites that block automation: Browser Use with your Nous plan, Browserbase or Firecrawl.")
        }
    }

    static func tags(_ place: BrowserPlace, gateway: String) -> [String] {
        switch place {
        case .inThisApp:
            #if os(macOS)
            [String(localized: "Live"), String(localized: "Take over"), String(localized: "While Hermes is open")]
            #else
            [String(localized: "Live"), String(localized: "Take over"), String(localized: "While the app is open")]
            #endif
        case .cleanBrowser: [String(localized: "Default"), String(localized: "Free"), String(localized: "Not visible")]
        case .withYourLogins: [String(localized: "Your logins"), String(localized: "Chrome, Edge or Brave")]
        case .window: [String(localized: "Visible on \(gateway)")]
        case .cloud: [String(localized: "Needs a plan or key")]
        }
    }

    static func symbol(_ place: BrowserPlace) -> String {
        switch place {
        case .inThisApp:
            #if os(macOS)
            "macwindow"
            #else
            "iphone"
            #endif
        case .cleanBrowser: "desktopcomputer"
        case .withYourLogins: "person.badge.key"
        case .window: "rectangle.on.rectangle"
        case .cloud: "cloud"
        }
    }

    /// "A clean browser on Studio Mac", "In the cloud · Browserbase".
    static func summary(_ place: BrowserPlace, settings: BrowserSettings, gateway: String) -> String {
        if place == .cloud, let provider = settings.cloud {
            return String(localized: "In the cloud · \(BrowserSettings.cloudName(provider))")
        }
        return title(place, gateway: gateway)
    }

    /// What a failed connect said, without its command lines.
    static func connectNotes(_ result: JSONValue) -> [String] {
        guard case .array(let lines)? = result["messages"] else { return [] }
        return lines.compactMap(\.stringValue).filter { !$0.isEmpty }
    }

    static func failure(_ error: any Error, gateway: String) -> String {
        if HermesVersionGap.isMissing(error) { return HermesVersionGap.message }
        if let error = error as? GatewayRPCError {
            if error.code == 5031 { return String(localized: "Hermes couldn't reach a browser window on \(gateway).") }
            return String(localized: "Hermes didn't change it: \(error.message)")
        }
        return String(localized: "Couldn't reach \(gateway). Nothing changed.")
    }
}
