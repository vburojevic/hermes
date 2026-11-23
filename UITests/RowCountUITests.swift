import XCTest

/// A Bot's row (its chats counted together) and a group chat's row show the messages that came in
/// after you left them, and keep counting after the socket drops (`docs/inbox.md` §7,
/// `docs/notifications.md` §2 Badge). Against the mock with its long rooms and without its routines,
/// whose digest would land in Research Buddy's chat after the test's own message:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642 --group-counts --quiet-world`.
/// Elsewhere: pass `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild.
final class RowCountUITests: XCTestCase {
    private let mock = Mock()

    override func setUp() async throws {
        continueAfterFailure = false
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        try await mock.reset()
    }

    /// iPhone and iPad in portrait: on iPhone the chat is left with Back, on iPad by opening Skills.
    @MainActor
    func testRowsCountAfterLeavingAndAfterADroppedSocketInPortrait() async throws {
        XCUIDevice.shared.orientation = .portrait
        try await checkRowCounts(named: "Portrait")
    }

    /// iPad in landscape, where the sidebar stays beside the chat.
    @MainActor
    func testRowsCountAfterLeavingAndAfterADroppedSocketInLandscape() async throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPhone keeps the list in portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        try await checkRowCounts(named: "Landscape")
    }

    @MainActor
    private func checkRowCounts(named name: String) async throws {
        let app = launch()
        let group = row("Launch crew", in: app)
        let bot = row("Research Buddy", in: app)
        try noAlerts(app)
        await showList(app)
        XCTAssertTrue(group.waitForExistence(timeout: 60), "no Launch crew row")
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "no Research Buddy row")

        // A group chat: open it, leave it, and a member's message counts on its row.
        try noAlerts(app)
        try await open(group, in: app)
        try await leave(app)
        let groupBefore = count(group)
        // A say runs the room's whole discussion; its last message is the reply given here.
        try await mock.post("api/mock/room-say", ["room": "launch-crew", "reply": "\(name) check one."])
        await eventually(app, timeout: 60, "\(name): Launch crew didn't count the discussion after leaving") {
            group.label.contains("\(name) check one.") && self.count(group) > groupBefore
        }
        let groupCount = count(group)

        // A Bot's chats: open the Bot, leave it, and its delivery counts on its row.
        try noAlerts(app)
        try await open(bot, in: app)
        try await leave(app)
        let botBefore = count(bot)
        try await mock.post("api/mock/deliver", ["profile": "researcher", "reply": "\(name) check two."])
        await eventually(app, timeout: 60, "\(name): Research Buddy didn't count the delivery after leaving") {
            bot.label.contains("\(name) check two.") && self.count(bot) > botBefore
        }
        let botCount = count(bot)
        XCTAssertEqual(count(group), groupCount, "\(name): Launch crew's count changed when the Bot was opened")
        attach("\(name): counts after leaving")

        // The socket drops: both rows keep their counts, and what comes after counts on top.
        try noAlerts(app)
        try await mock.post("api/mock/drop-sockets", [:])
        try await mock.post("api/mock/room-say", ["room": "launch-crew", "reply": "\(name) check three."])
        try await mock.post("api/mock/deliver", ["profile": "researcher", "reply": "\(name) check four."])
        await eventually(app, timeout: 90, "\(name): the rows didn't count what came after the dropped socket") {
            group.label.contains("\(name) check three.") && self.count(group) > groupCount
                && bot.label.contains("\(name) check four.") && self.count(bot) > botCount
        }
        try noAlerts(app)
        attach("\(name): counts after the dropped socket")
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
            "-HERMES_BOOTSTRAP_BACKEND", mock.backend.absoluteString,
            "-HERMES_RESET_INBOX", "YES", "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
            "-HERMES_PASTEBOARD", "none", "-push.primeDeclines", "2", "-welcome.checklist.hidden", "YES",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title),")).firstMatch
    }

    /// The row's count, from its label ("Launch crew, 4 unread, …"); none counts 0.
    @MainActor
    private func count(_ row: XCUIElement) -> Int {
        guard row.exists else { return 0 }
        return row.label.components(separatedBy: ", ")
            .first { $0.hasSuffix(" unread") }
            .flatMap { Int($0.dropLast(" unread".count)) } ?? 0
    }

    /// Opens the row's chat and waits for its composer.
    @MainActor
    private func open(_ row: XCUIElement, in app: XCUIApplication) async throws {
        await showList(app)
        XCTAssertTrue(becomes(row, "isHittable == true", timeout: 5), "the row isn't on screen")
        row.tap()
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "the chat didn't open")
    }

    /// Leaves the open chat: Back on iPhone; on iPad, Skills in the sidebar opens in its place. Not
    /// All Bots: its cards carry the Bots' names too, and would stand in for their rows.
    @MainActor
    private func leave(_ app: XCUIApplication) async throws {
        if UIDevice.current.userInterfaceIdiom == .phone {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button")
            back.tap()
            XCTAssertTrue(app.buttons["sidebar.compose"].firstMatch.waitForExistence(timeout: 5), "Back didn't return to the list")
        } else {
            await showList(app)
            let skills = app.buttons["Skills"].firstMatch
            XCTAssertTrue(becomes(skills, "isHittable == true", timeout: 5), "no Skills in the sidebar")
            skills.tap()
            XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 5), "Skills didn't open in place of the chat")
        }
        try noAlerts(app)
    }

    /// On iPad the list is the sidebar. In portrait it slides away once a row opens, and the app
    /// can start with it put away; the system's Show Sidebar brings it back. iPhone's list is the
    /// first screen, where Back returns.
    @MainActor
    private func showList(_ app: XCUIApplication) async {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let hide = app.buttons["Hide Sidebar"].firstMatch
        let show = app.buttons["Show Sidebar"].firstMatch
        // Either button stands once the app is up: one with the sidebar out, the other with it away.
        guard await until(timeout: 60, { hide.isHittable || show.isHittable }), !hide.isHittable, show.isHittable else { return }
        show.tap()
        _ = becomes(hide, "isHittable == true", timeout: 5)
    }

    /// Waits until the condition holds; false when it doesn't in time. Awaited, XCTest checks it on the
    /// main actor.
    @MainActor
    private func until(timeout: TimeInterval, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated(condition) }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return await XCTWaiter().fulfillment(of: [expectation], timeout: timeout) == .completed
    }

    /// Waits until the element matches the predicate; false when it doesn't in time.
    @MainActor
    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// No alert may stand over the app, its own or the system's: nobody answers one here.
    @MainActor
    private func noAlerts(_ app: XCUIApplication) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(springboard.alerts.count, 0, "a system alert is up")
        if app.state == .runningForeground {
            XCTAssertEqual(app.alerts.count, 0, "an alert is up in the app")
        }
    }

    /// Waits for something that takes a round trip or two to come true. On iPad in portrait the
    /// sidebar can slide away meanwhile, so it's brought back between short waits.
    @MainActor
    private func eventually(_ app: XCUIApplication, timeout: TimeInterval, _ message: String, _ check: @escaping @MainActor () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            await showList(app)
            if await until(timeout: 5, check) { return }
        } while Date.now < deadline
        XCTFail(message)
    }

    @MainActor
    private func attach(_ name: String) {
        // The whole screen: the app's own screenshot crops a landscape simulator to a portrait frame.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// The mock's dashboard, as the app reaches it.
private struct Mock {
    let gateway: URL
    let backend: URL
    let key = "dev-key-0123456789abcdef"

    init() {
        let bundle = Bundle(for: RowCountUITests.self)
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

    /// The seeded read marks again.
    func reset() async throws {
        try await post("api/mock/inbox/reset", [:])
    }

    func post(_ path: String, _ body: [String: String]) async throws {
        var request = URLRequest(url: backend.appending(path: path))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        // A mock older than this test (restart it after pulling) answers 404.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
