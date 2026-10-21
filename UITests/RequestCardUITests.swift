import XCTest

/// The request card above the composer is never wider than the screen (`docs/quick-actions.md` §1):
/// a two-question clarify whose first answer is long, answered, then "Question 2 of 2" checked
/// element by element against the window. The answer's one-line summary, laid out at its own
/// width, once made the whole bottom bar wider than the screen, clipped on both sides. Start the
/// mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
/// Run it on the smallest iPhone, a large one and an iPad.
final class RequestCardUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testALongAnswerKeepsTheNextQuestionOnScreen() throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_SEND_HERE", "clarify pair", "-HERMES_SEND_HERE_AFTER", "4"])
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 1 of 2'").waitForExistence(timeout: 60), "no clarify card")
        try expectOnScreen(app, "question 1")

        let pick = element(app, "label BEGINSWITH 'Yes—Gmail'")
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "no long pick")
        pick.tap()
        app.buttons["Next"].tap()
        XCTAssertTrue(element(app, "label BEGINSWITH 'Question 2 of 2'").waitForExistence(timeout: 10), "didn't move to question 2")
        // The card moves in with a blur; measure where it settles.
        Thread.sleep(forTimeInterval: 1)
        try expectOnScreen(app, "question 2")
        XCTAssertTrue(element(app, "label BEGINSWITH 'Which Google Workspace'").exists, "no summary of the first answer")

        // Answered, the card goes (and the mock's turn ends, so the next run starts clean).
        element(app, "label BEGINSWITH 'No or not sure'").tap()
        app.buttons["Send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["requestCard"].waitForNonExistence(timeout: 10), "the card stayed")
    }

    // MARK: Helpers

    /// Every part of the card, and the composer under it, inside the window (half a point's grace
    /// for rounding), with a screenshot to look at.
    @MainActor
    private func expectOnScreen(_ app: XCUIApplication, _ name: String) throws {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "request-card-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let window = app.windows.firstMatch.frame.insetBy(dx: -0.5, dy: -0.5)
        let card = app.descendants(matching: .any)["requestCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no request card")
        XCTAssertTrue(window.contains(card.frame), "the card is \(card.frame), the window \(window)")
        var outside: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if !node.frame.isEmpty, !window.contains(node.frame) {
                outside.append("\(node.label.isEmpty ? node.identifier : node.label) at \(node.frame)")
            }
            node.children.forEach(walk)
        }
        walk(try card.snapshot())
        XCTAssertEqual(outside, [], "past the window's edges (\(window))")

        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.exists, "no composer")
        XCTAssertTrue(window.contains(composer.frame), "the composer is \(composer.frame), the window \(window)")
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let bundle = Bundle(for: RequestCardUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
            // One message, and no notifications ask over the chat.
            "-HERMES_SEND_HERE_ROUNDS", "1", "-push.primeDeclines", "2",
        ] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }
}
