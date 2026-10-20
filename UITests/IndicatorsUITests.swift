import XCTest

/// One moving thing per place (`docs/chat.md` §4a): each live state against the mock, counted by
/// the app's motion probe (`-HERMES_MOTION_PROBE YES`: how many `ShimmerText`s sweep on screen),
/// with no spinner anywhere. Start the mock first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`. Elsewhere: pass
/// `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild (they go in the test bundle's
/// Info.plist). The snapshot tests need no mock.
final class IndicatorsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: States against the mock

    /// Before the first words: the turn header's "Thinking…" is the one thing moving, it says for
    /// how long after 10 s, and the Bot's toolbar keeps its handle throughout.
    @MainActor
    func testThinkingIsOneLiveLineAndTheToolbarKeepsTheHandle() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "ponder the launch date", "-HERMES_SEND_HERE_AFTER", "4"])
        let thinking = element(app, "label BEGINSWITH 'Thinking…'")
        XCTAssertTrue(thinking.waitForExistence(timeout: 60), "no Thinking… line")
        try await expectMotion(app, sweeps: 1)
        let title = app.buttons["botChatTitle"]
        XCTAssertTrue(title.exists, "no Bot title")
        XCTAssertTrue(title.label.contains("@"), "the subtitle isn't the handle: \(title.label)")
        // Thinking… · 10s and on; the toolbar never says Thinking….
        let elapsed = element(app, "label BEGINSWITH 'Thinking… · 1'")
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline, !elapsed.exists {
            XCTAssertFalse(title.label.contains("Thinking"), "the toolbar says \(title.label)")
            try await Task.sleep(for: .milliseconds(400))
        }
        XCTAssertTrue(elapsed.exists, "no elapsed time after 10 s of thinking")
        try await expectMotion(app, sweeps: 1)
    }

    /// A running tool: the header says the step and shimmers; the step shows its glyph and its
    /// time, no spinner.
    @MainActor
    func testToolRunningIsOneLiveLine() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "slow: check six sources", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Searching the web'").waitForExistence(timeout: 60), "no running step")
        try await expectMotion(app, sweeps: 1)
    }

    /// While the reply's words stream, nothing animates.
    @MainActor
    func testStreamingMovesNothing() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "write me an essay", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 60), "the turn didn't start")
        XCTAssertTrue(element(app, "label BEGINSWITH 'Working'").waitForExistence(timeout: 30), "the header didn't go still")
        try await expectMotion(app, sweeps: 0)
    }

    /// Helpers at work: the header's line moves; helper rows count their time, no spinner.
    @MainActor
    func testHelpersCountTheirTime() async throws {
        // A Hermes chat: the mock's helpers run there (`Tools/mock-hermes/helpers.py`).
        let app = launch(["-HERMES_SEND", "helpers: audit the app for swift 6"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Working with'").waitForExistence(timeout: 60), "no helpers at work")
        try await expectMotion(app, sweeps: 1)
    }

    /// Waiting for your approval: solid orange words, nothing moves.
    @MainActor
    func testWaitingForApprovalHoldsStill() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "approve a cleanup", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label == 'Waiting for your approval'").waitForExistence(timeout: 60), "no approval wait")
        try await expectMotion(app, sweeps: 0)
    }

    /// A turn that stopped: nothing moves.
    @MainActor
    func testStoppedHoldsStill() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "this will fail", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 60), "the turn didn't start")
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 30), "the turn didn't end")
        try await expectMotion(app, sweeps: 0)
    }

    /// A group chat with three Bots thinking at once: two named lines, then "+1 more".
    @MainActor
    func testGroupChatNamesTwoThinkingBots() async throws {
        let app = launch(["-HERMES_OPEN", "group:launch-crew"])
        XCTAssertTrue(element(app, "label CONTAINS 'Launch crew'").waitForExistence(timeout: 60), "the group chat didn't open")
        // Said in the room as another device would: the mock's "together" has three Bots think at once.
        try await sayInRoom("launch-crew", "Plan the launch post together")
        XCTAssertTrue(element(app, "label CONTAINS 'is thinking…'").waitForExistence(timeout: 30), "no thinking line")
        XCTAssertTrue(element(app, "label == '+1 more'").waitForExistence(timeout: 10), "no +1 more")
        try await expectMotion(app, sweeps: 2)
    }

    /// Run in Background: its line shimmers with no spinner, beside the turn's own live line.
    @MainActor
    func testBackgroundJobShimmers() async throws {
        let app = launch([
            "-HERMES_SEND", "slow: check six sources",
            "-HERMES_FOLLOWUP", "Audit the app for strict concurrency", "-HERMES_FOLLOWUP_MODE", "background",
            "-HERMES_FOLLOWUP_SEND", "YES", "-HERMES_FOLLOWUP_AFTER", "3",
        ])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Working in the background'").waitForExistence(timeout: 60), "no background line")
        XCTAssertEqual(app.activityIndicators.count, 0, "a spinner is on screen")
        XCTAssertGreaterThanOrEqual(try probe(app), 1)
    }

    // MARK: Snapshots

    @MainActor func testSnapshotLight() throws { try snapshot("light") }
    @MainActor func testSnapshotDark() throws { try snapshot("dark") }
    @MainActor func testSnapshotIncreasedContrastLight() throws { try snapshot("light+contrast") }
    @MainActor func testSnapshotIncreasedContrastDark() throws { try snapshot("dark+contrast") }

    /// Reduce Motion: the same words, still, and nothing sweeps.
    @MainActor
    func testSnapshotReduceMotionHasNoSweep() throws {
        let app = try snapshot("light+reducemotion")
        XCTAssertEqual(try probe(app), 0, "a shimmer sweeps with Reduce Motion")
    }

    /// Every indicator from the Debug gallery (`-HERMES_GALLERY indicators`), a screenshot per
    /// page, named `indicators-<look>-<page>` in the result bundle, to compare with the Elyx renders.
    @MainActor
    @discardableResult
    private func snapshot(_ look: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_GALLERY", "indicators", "-HERMES_GALLERY_LOOK", look, "-HERMES_MOTION_PROBE", "YES",
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
        ]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["gallery.indicators"].waitForExistence(timeout: 20), "the gallery didn't open")
        for page in 1...3 {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "indicators-\(look)-\(page)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if !look.contains("reducemotion") {
                XCTAssertGreaterThan(try probe(app), 0, "nothing shimmers on page \(page)")
            }
            app.swipeUp()
        }
        return app
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let bundle = Bundle(for: IndicatorsUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_MOTION_PROBE", "YES", "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
            // One message, and no notifications ask over the chat.
            "-HERMES_SEND_HERE_ROUNDS", "1", "-push.primeDeclines", "2",
        ] + arguments
        app.launch()
        return app
    }

    /// `POST /api/mock/room-say` on the mock backend, with the dashboard's session token.
    private func sayInRoom(_ room: String, _ text: String) async throws {
        let backend = URL(string: (Bundle(for: IndicatorsUITests.self).object(forInfoDictionaryKey: "HermesMockBackend") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:19119")!
        let (page, _) = try await URLSession.shared.data(from: backend)
        let html = String(decoding: page, as: UTF8.self)
        guard let start = html.range(of: "__HERMES_SESSION_TOKEN__=\"")?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: backend.appending(path: "api/mock/room-say"))
        request.httpMethod = "POST"
        request.setValue(String(html[start..<end]), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["room": room, "text": text])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the mock didn't take it (restart it after pulling)")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }

    /// How many shimmers sweep on screen now.
    @MainActor
    private func probe(_ app: XCUIApplication) throws -> Int {
        let probe = app.descendants(matching: .any)["motionProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "no motion probe")
        return try XCTUnwrap(Int(probe.value as? String ?? ""), "the probe reads \(String(describing: probe.value))")
    }

    /// Exactly `sweeps` shimmers on screen and no spinner, once things settle (a second's grace
    /// for a cross-fade to finish).
    @MainActor
    private func expectMotion(_ app: XCUIApplication, sweeps: Int) async throws {
        var seen = -1
        for _ in 0..<6 {
            seen = try probe(app)
            if seen == sweeps { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(seen, sweeps, "\(seen) shimmers on screen, expected \(sweeps)")
        XCTAssertEqual(app.activityIndicators.count, 0, "a spinner is on screen")
    }
}
