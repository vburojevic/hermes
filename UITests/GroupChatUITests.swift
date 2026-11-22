import XCTest

/// A group chat opens at its newest messages, in a centered column (`docs/bots-groups-skills.md`
/// §2), against the mock with its long rooms:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642 --group-counts`.
/// Elsewhere: pass `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild.
final class GroupChatUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    }

    /// On iPad, Release log opened from the sidebar in landscape rests on its newest messages in
    /// the centered column, and stays so after turning to portrait.
    @MainActor
    func testALongGroupChatOpensAtItsNewestMessagesInACenteredColumn() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The sidebar opens rooms on iPad") }
        let bundle = Bundle(for: GroupChatUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-HERMES_PASTEBOARD", "none",
            "-push.primeDeclines", "2", "-welcome.checklist.hidden", "YES",
        ]
        app.launch()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }

        XCUIDevice.shared.orientation = .landscapeLeft
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Release log'")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30), "no Release log in the sidebar")
        room.tap()
        try await Task.sleep(for: .seconds(4))
        try checkNewestInCenteredColumn(app, "Landscape")

        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(for: .seconds(2))
        try checkNewestInCenteredColumn(app, "Portrait")
    }

    /// The room's last note is on screen in its lower half with no pill to the latest, and the
    /// members' messages start inside the readable column, not at the scroll view's edge.
    @MainActor
    private func checkNewestInCenteredColumn(_ app: XCUIApplication, _ name: String) throws {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name): Release log"
        shot.lifetime = .keepAlways
        add(shot)
        let reply = NSPredicate(format: "label BEGINSWITH 'On it. I'")
        let transcript = app.scrollViews.containing(reply).firstMatch
        XCTAssertTrue(transcript.exists, "\(name): no transcript with the members' messages")
        let frame = transcript.frame
        let settled = transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Room settled'"))
            .allElementsBoundByIndex.filter { $0.frame.intersects(frame) }
        let newest = try XCTUnwrap(settled.max { $0.frame.maxY < $1.frame.maxY }, "\(name): no note on screen")
        XCTAssertGreaterThan(newest.frame.midY, frame.midY, "\(name): the newest note isn't in the lower half")
        XCTAssertFalse(app.buttons["Scroll to latest"].exists, "\(name): the pill to the latest is up")
        let replies = transcript.staticTexts.matching(reply).allElementsBoundByIndex.filter { $0.frame.intersects(frame) }
        let lowest = try XCTUnwrap(replies.max { $0.frame.maxY < $1.frame.maxY }, "\(name): no reply on screen")
        // The column is 760 pt wide (`Theme.readableWidth`), centered in the scroll view.
        let margin = (frame.width - 760) / 2
        XCTAssertGreaterThanOrEqual(lowest.frame.minX - frame.minX, margin - 1, "\(name): the column isn't centered")
    }
}
