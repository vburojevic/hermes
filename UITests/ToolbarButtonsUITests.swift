import XCTest

/// The buttons in a chat's toolbar answer a tap, whether or not a tip hangs off them
/// (`hermesTip`). Wrapped by a popover tip, the sidebar button and a Bot Chat's title did nothing
/// on iPhone: the drawer opened only with a swipe from the edge. Start the mock first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class ToolbarButtonsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheSidebarButtonOpensTheDrawerInABotChat() throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher"])
        XCTAssertTrue(app.buttons["botChatTitle"].waitForExistence(timeout: 60), "the Bot Chat didn't open")
        try expectTheButtonOpensTheDrawer(app)
    }

    @MainActor
    func testTheSidebarButtonOpensTheDrawerInAHermesChat() throws {
        let app = launch(["-HERMES_SEND", "hello there"])
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'hello there'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the chat didn't open")
        try expectTheButtonOpensTheDrawer(app)
    }

    @MainActor
    func testTheBotsTitleOpensItsSettings() throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher"])
        let title = app.buttons["botChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 60), "no Bot title")
        Thread.sleep(forTimeInterval: 2)
        title.tap()
        XCTAssertTrue(app.navigationBars["Edit Bot"].waitForExistence(timeout: 5), "the title didn't open Edit Bot")
    }

    /// A tip still shows where it did (from a fresh start, one an hour), and once put away the
    /// button under it works.
    @MainActor
    func testATipStillShowsAndGivesWay() throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher"], tips: "reset")
        let gotIt = app.buttons["Got It"]
        XCTAssertTrue(gotIt.waitForExistence(timeout: 60), "no tip")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "toolbar-tip"
        attachment.lifetime = .keepAlways
        add(attachment)
        gotIt.tap()
        XCTAssertTrue(gotIt.waitForNonExistence(timeout: 5), "the tip didn't go")
        try expectTheButtonOpensTheDrawer(app)
    }

    // MARK: Helpers

    @MainActor
    private func expectTheButtonOpensTheDrawer(_ app: XCUIApplication) throws {
        // iPad shows the sidebar beside the chat; the drawer is the iPhone's.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "no drawer on iPad")
        let button = app.buttons["Show sidebar"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "no sidebar button")
        // Settled first: the screen it's on can still be coming in.
        Thread.sleep(forTimeInterval: 2)
        // Open, the drawer pushes the screen aside, the button with it (a shut drawer's rows can
        // still reach the test, so where things are is the tell).
        let before = button.frame.minX
        button.tap()
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline, button.exists, button.frame.minX < before + 100 {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(!button.exists || button.frame.minX >= before + 100,
                      "the sidebar button didn't open the drawer (it's still at \(button.frame.minX))")
    }

    @MainActor
    private func launch(_ arguments: [String], tips: String = "hide") -> XCUIApplication {
        let bundle = Bundle(for: ToolbarButtonsUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", tips, "-HERMES_WHATS_NEW", "NO", "-push.primeDeclines", "2",
        ] + arguments
        app.launch()
        return app
    }
}
