import Foundation
import Testing
@testable import HermesKit

@Suite("Browser settings")
struct BrowserSettingsTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func readsHermesDefaults() throws {
        // GET /api/config with defaults filled in: no cloud_provider until one is chosen.
        let settings = BrowserSettings(config: try json("""
        {"browser": {"backend": "", "engine": "auto", "use_real_profile": false, "record_sessions": false,
          "auto_local_for_private_urls": true, "extension_control": {"enabled": false, "developer_mode": false}},
         "security": {"website_blocklist": {"enabled": false, "domains": [], "shared_files": []}}}
        """))
        #expect(settings.cloudProvider == nil)
        #expect(settings.cloud == nil)
        #expect(!settings.fastTextOnly)
        #expect(settings.localForPrivateAddresses)
        #expect(BrowserPlace.current(settings, BrowserConnection()) == .cleanBrowser)
    }

    @Test func placesFollowHermesOrder() throws {
        var settings = BrowserSettings()
        settings.useRealProfile = true
        #expect(BrowserPlace.current(settings, nil) == .withYourLogins)
        settings.cloudProvider = "browserbase"
        #expect(BrowserPlace.current(settings, nil) == .cloud)
        #expect(BrowserPlace.current(settings, BrowserConnection(connected: true, url: "http://127.0.0.1:9222")) == .window)
        settings.cloudProvider = "local"
        #expect(settings.cloud == nil)
        #expect(BrowserPlace.current(settings, nil) == .withYourLogins)
    }

    @Test func patchesWriteOnlyWhatChanges() {
        #expect(BrowserSettings.cleanBrowserPatch == .object(["browser": .object(["cloud_provider": .string("local"), "use_real_profile": .bool(false)])]))
        #expect(BrowserSettings.fastTextOnlyPatch(true) == .object(["browser": .object(["engine": .string("lightpanda")])]))
        #expect(BrowserSettings.fastTextOnlyPatch(false) == .object(["browser": .object(["engine": .string("auto")])]))
        // A list replaces the one in config, so the whole blocklist goes every time.
        #expect(BrowserSettings.blocklistPatch(enabled: true, domains: ["example.com"]) == .object(["security": .object([
            "website_blocklist": .object(["enabled": .bool(true), "domains": .array([.string("example.com")])]),
        ])]))
    }

    @Test func blockedSitesAreHostsLikeHermesKeepsThem() {
        #expect(BrowserSettings.blockedDomain("https://www.Example.com/path") == "example.com")
        #expect(BrowserSettings.blockedDomain("ads.example.com") == "ads.example.com")
        #expect(BrowserSettings.blockedDomain("*.tracker.example.net") == "*.tracker.example.net")
        #expect(BrowserSettings.blockedDomain("not a site") == nil)
        #expect(BrowserSettings.blockedDomain("nodot") == nil)
    }

    @Test func readsBrowserManageStatus() throws {
        let connection = BrowserConnection(json: try json(#"{"connected": true, "url": "http://127.0.0.1:9222", "browser_use": false}"#))
        #expect(connection.connected)
        #expect(connection.address == "127.0.0.1:9222")
        #expect(connection.browserUse == false)
        #expect(BrowserConnection(json: try json(#"{"connected": false, "url": ""}"#)).url == nil)
    }

    @Test func setupNamesThePlace() {
        var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: .online)
        facts.config = .object(["browser": .object(["cloud_provider": .string("nous")])])
        #expect(GatewaySetup.browser(facts).detail == "In the cloud · Browser Use with your Nous plan")
        facts.botMode = .notLinked
        #expect(GatewaySetup.browser(facts).state == .notSetUp)
    }
}
