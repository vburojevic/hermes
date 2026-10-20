import XCTest

/// The app's own plugins against the mock (`docs/plugins.md` §12): the one ask, installing in
/// Hermes and every Bot, a pin that adds access, a failed install and the Bot Mode gate. Start the
/// mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
/// Elsewhere: pass `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild.
final class PluginsUITests: XCTestCase {
    private let mock = PluginsMock()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        try await mock.set("current")
    }

    @MainActor
    private func launch(_ extra: [String] = [], botMode: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
                         "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO"]
        arguments += ["-HERMES_BOOTSTRAP_BACKEND", botMode ? mock.backend.absoluteString : "none"]
        app.launchArguments = arguments + extra
        app.launch()
        return app
    }

    /// The header reads as one element: title, then the sentence.
    private static var askTitle: NSPredicate { NSPredicate(format: "label CONTAINS ' for This App'") }

    /// The ask comes once per gateway on this device: Not Now is the answer, and it doesn't come
    /// back on the next launch.
    @MainActor
    func testTheAskComesOncePerGateway() async throws {
        try await mock.set("missing")
        var app = launch(["-HERMES_PLUGINS_FORGET", "YES"])
        let title = app.staticTexts.matching(Self.askTitle).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 40), "no ask after Bot Mode connected")
        XCTAssertTrue(app.staticTexts["Plugins for this app · 2"].exists, "the ask doesn't list both plugins")
        app.buttons["Not Now"].firstMatch.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        app.terminate()
        app = launch()
        XCTAssertFalse(app.staticTexts.matching(Self.askTitle).firstMatch.waitForExistence(timeout: 25), "asked twice")
    }

    /// Install goes into Hermes and each of the 4 Bots, a profile at a time, then says where
    /// they're on and offers the restart push needs.
    @MainActor
    func testInstallReachesHermesAndEveryBot() async throws {
        try await mock.set("missing")
        let app = launch(["-HERMES_PLUGINS_FORGET", "YES"])
        let install = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Install on '")).firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 40), "no ask")
        install.tap()
        let progress = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'Installing in .*\\\\(\\\\d of 5\\\\)'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "no per-profile progress out of 5")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Both plugins are on in Hermes and 4 Bots.'")).firstMatch
            .waitForExistence(timeout: 60), "not on everywhere")
        XCTAssertTrue(app.buttons["Restart Gateway"].exists, "push in the root needs a restart")
        app.buttons["Later"].tap()
    }

    /// A pin that adds a hook waits: keeping current leaves the older copy until the person
    /// allows it on the consent card.
    @MainActor
    func testAWideningUpdateWaitsForConsent() async throws {
        try await mock.set("widened")
        let app = launch(["-HERMES_PLUGINS_ASKED", "YES", "-HERMES_OPEN", "settings", "-HERMES_SETTINGS_SETUP", "widgets"])
        let card = app.staticTexts["This update asks for more access"]
        XCTAssertTrue(card.waitForExistence(timeout: 40), "no consent card")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Sees what’s sent to the model'")).firstMatch.exists,
                      "the addition isn't in words")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Older (1.1.0)'")).firstMatch.exists,
                      "it moved before the person allowed it")
        app.buttons["Allow and Update"].tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 60), "Allow and Update didn't update")
    }

    /// An install that can't reach GitHub says so in words, with Hermes's own message, Try Again
    /// and the Terminal way round.
    @MainActor
    func testAFailedInstallSaysWhy() async throws {
        try await mock.set("failing")
        let app = launch(["-HERMES_PLUGINS_FORGET", "YES"])
        let install = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Install on '")).firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 40), "no ask")
        install.tap()
        let words = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'couldn’t download it from GitHub'")).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 60), "the failure isn't in words")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Could not resolve host'")).firstMatch.exists, "Hermes's message is missing")
        XCTAssertTrue(app.buttons["Try Again"].exists)
        XCTAssertTrue(app.staticTexts["hermes plugins install vburojevic/hermes-app-push --enable"].exists, "no Terminal commands")
    }

    /// Apps and Tools → Plugins without Bot Mode (`pluginsNeedsBotMode`): the card, and the app's
    /// plugins dimmed with "Needs Bot Mode", nothing to install.
    @MainActor
    func testTheHubWithoutBotModeOffersNothingToInstall() async throws {
        let app = launch(["-HERMES_OPEN", "settings", "-HERMES_APPS_TOOLS", "plugins",
                          "-HERMES_PLUGIN_CATALOG_URL", mock.feed.absoluteString], botMode: false)
        XCTAssertTrue(app.staticTexts["Plugins need Bot Mode"].waitForExistence(timeout: 30), "no Bot Mode card")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Needs Bot Mode'")).firstMatch.exists, "suggestions aren't dimmed")
        XCTAssertFalse(app.buttons["Install"].exists, "something offers Install without Bot Mode")
    }

    /// Nothing offered is lost: Don't Suggest Again moves a suggestion to Hidden Suggestions, and
    /// Show Again brings it back.
    @MainActor
    func testHiddenSuggestionsComeBackWithShowAgain() async throws {
        try await mock.set("current")
        let app = launch(["-HERMES_OPEN", "settings", "-HERMES_APPS_TOOLS", "plugins", "-HERMES_PLUGINS_FORGET", "YES",
                          "-HERMES_PLUGIN_CATALOG_URL", mock.feed.absoluteString])
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'TouchDesigner'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40), "TouchDesigner isn't suggested")
        row.press(forDuration: 1.2)
        let hide = app.buttons["Don’t Suggest Again"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "still suggested")
        // At the foot of the hub: off screen until it scrolls there.
        let hidden = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hidden Suggestions'")).firstMatch
        for _ in 0..<6 where !hidden.exists { app.swipeUp() }
        XCTAssertTrue(hidden.waitForExistence(timeout: 5), "no Hidden Suggestions")
        hidden.tap()
        let showAgain = app.buttons["Show Again"]
        XCTAssertTrue(showAgain.waitForExistence(timeout: 5))
        showAgain.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<6 where !row.exists { app.swipeDown() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Show Again didn't bring it back")
    }

    /// A catalog plugin installs by its catalog name from its review, then asks for the key its
    /// manifest needs, in a secure field, and turns on.
    @MainActor
    func testACatalogInstallAsksForItsKey() async throws {
        try await mock.resetHub()
        let app = launch(["-HERMES_OPEN", "settings", "-HERMES_APPS_TOOLS", "plugins:review:spotify",
                          "-HERMES_PLUGIN_CATALOG_URL", mock.feed.absoluteString])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'THE CATALOG’S DISCLOSURE' OR label CONTAINS 'controls playback'")).firstMatch
            .waitForExistence(timeout: 40), "no review")
        let install = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Install on '")).firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.tap()
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "no key field")
        field.tap()
        field.typeText("client-id-for-the-test")
        app.buttons["Save Keys"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Spotify Is On'")).firstMatch.waitForExistence(timeout: 30),
                      "didn't finish")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'client-id-for-the-test'")).firstMatch.exists,
                       "the key is shown")
    }

    /// Without Bot Mode the app can't reach the plugins: it never asks.
    @MainActor
    func testNoAskWithoutBotMode() async throws {
        try await mock.set("missing")
        let app = launch(["-HERMES_PLUGINS_FORGET", "YES"], botMode: false)
        XCTAssertFalse(app.staticTexts.matching(Self.askTitle).firstMatch.waitForExistence(timeout: 25), "asked without Bot Mode")
    }
}

/// The mock gateway (`Tools/mock-hermes`): its API server and its dashboard.
private struct PluginsMock {
    let gateway: URL
    let backend: URL
    let key = "dev-key-0123456789abcdef"
    /// The catalog feed the mock serves, so the app never reaches the network.
    var feed: URL { backend.appending(path: "docs/api/plugin-catalog.json") }

    init() {
        let bundle = Bundle(for: PluginsUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        gateway = URL(string: setting("HermesMockGateway", "http://127.0.0.1:18642"))!
        backend = URL(string: setting("HermesMockBackend", "http://127.0.0.1:19119"))!
    }

    /// The dashboard's session token, as its page hands it to the app (ungated mock).
    private func token() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: backend)
        let page = String(decoding: data, as: UTF8.self)
        guard let start = page.range(of: "__HERMES_SESSION_TOKEN__=\"")?.upperBound,
              let end = page[start...].firstIndex(of: "\"") else { throw URLError(.userAuthenticationRequired) }
        return String(page[start..<end])
    }

    /// Catalog installs since the mock started go again (`plugin_hub.py`).
    func resetHub() async throws {
        try await post("api/mock/plugin-hub", "{\"reset\":true}")
    }

    private func post(_ path: String, _ body: String) async throws {
        var request = URLRequest(url: backend.appending(path: path))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        _ = try await URLSession.shared.data(for: request)
    }

    /// Where the app's plugins stand on every profile (`app_plugins.py`).
    func set(_ state: String) async throws {
        var request = URLRequest(url: backend.appending(path: "api/mock/app-plugins"))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"state\":\"\(state)\"}".utf8)
        _ = try await URLSession.shared.data(for: request)
    }
}
