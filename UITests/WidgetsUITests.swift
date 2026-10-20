import XCTest

/// Widgets against the mock's plugin (`docs/widgets.md` §13). Start it first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`. Elsewhere: pass
/// `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild (they go in the test bundle's
/// Info.plist).
final class WidgetsUITests: XCTestCase {
    private let mock = WidgetsMock()

    override func setUp() {
        continueAfterFailure = false
    }

    /// Request → your answer → the agent's resolution in place of the buttons.
    @MainActor
    func testAnApprovalGoesFromRequestToDone() {
        let app = launch(sending: "widget publish")
        let publish = app.buttons["Publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 40), "no approval card")
        publish.tap()
        XCTAssertTrue(element(in: app, beginsWith: "Approved,").waitForExistence(timeout: 30), "no action bubble")
        XCTAssertTrue(element(in: app, beginsWith: "Publish · done").waitForExistence(timeout: 20), "no resolution line")
        XCTAssertFalse(app.buttons["Reject"].exists, "the actions stayed after the resolution")
    }

    /// At `expires_at` the actions turn off with no message from the agent.
    @MainActor
    func testAnApprovalExpires() {
        let app = launch(sending: "widget expiring")
        XCTAssertTrue(app.buttons["Publish"].waitForExistence(timeout: 40), "no approval card")
        XCTAssertTrue(element(in: app, beginsWith: "Expired at").waitForExistence(timeout: 90), "it never expired")
        XCTAssertFalse(app.buttons["Publish"].isHittable && app.buttons["Publish"].isEnabled, "Publish still answers")
    }

    /// Another device answers first: this one locks ("Answered on Mac"), then shows the outcome.
    @MainActor
    func testAnAnswerOnAnotherDeviceLocksTheWidget() async throws {
        let app = launch(sending: "widget publish")
        XCTAssertTrue(app.buttons["Publish"].waitForExistence(timeout: 40), "no approval card")
        try await mock.answerElsewhere(action: "approve", device: "Mac", hold: 8)
        XCTAssertTrue(element(in: app, beginsWith: "Answered on Mac").waitForExistence(timeout: 15), "no lock")
        let line = element(in: app, beginsWith: "Publish · done")
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no resolution line")
        XCTAssertTrue(line.label.contains("Mac"), "the resolution doesn't say who answered")
    }

    /// No update 60 s after the answer entered a turn: Try Again sends the same message (mid), and
    /// the agent's claim answers it once.
    @MainActor
    func testTryAgainResendsTheSameAnswer() {
        let app = launch(sending: "widget silent")
        let publish = app.buttons["Publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 40), "no approval card")
        publish.tap()
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 90), "no Try Again after 60 s")
        XCTAssertTrue(element(in: app, beginsWith: "No answer from").exists)
        retry.tap()
        XCTAssertTrue(element(in: app, beginsWith: "Publish · done").waitForExistence(timeout: 30), "Try Again didn't settle it")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Approved,'")).count, 1,
                       "Try Again showed a second answer")
    }

    /// Ticks show at once and go as one message 5 s after the last.
    @MainActor
    func testTicksGoAsOneBatch() {
        let app = launch(sending: "widget checklist")
        let unchecked = app.buttons.matching(NSPredicate(format: "value BEGINSWITH 'not checked'"))
        XCTAssertTrue(unchecked.firstMatch.waitForExistence(timeout: 40), "no checklist")
        let labels = [unchecked.element(boundBy: 0).label, unchecked.element(boundBy: 1).label]
        func item(_ label: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        for label in labels { item(label).tap() }
        for label in labels {
            XCTAssertTrue((item(label).value as? String)?.hasPrefix("checked") == true, "“\(label)” didn't tick at once")
        }
        XCTAssertTrue(element(in: app, beginsWith: "Ticked,").waitForExistence(timeout: 20), "the batch never went")
        XCTAssertTrue(element(in: app, beginsWith: "Ticked.").waitForExistence(timeout: 20), "no update")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Ticked,'")).count, 1,
                       "the ticks went as more than one message")
        for label in labels {
            XCTAssertEqual(item(label).value as? String, "checked", "“\(label)” isn't confirmed by the update")
        }
    }

    /// A ```widget fence the agent typed is code, never a card.
    @MainActor
    func testATypedWidgetFenceStaysCode() {
        let app = launch(sending: "widget fence")
        XCTAssertTrue(element(in: app, contains: "\"type\": \"metric\"").waitForExistence(timeout: 40), "the payload isn't shown as code")
        XCTAssertFalse(element(in: app, beginsWith: "Revenue").exists, "the fence drew a card")
    }

    /// A type this app doesn't know, and a payload missing what it must have, read as their text.
    @MainActor
    func testUnknownAndInvalidWidgetsShowAsText() {
        let app = launch(sending: "widget unknown")
        XCTAssertTrue(element(in: app, contains: "Shown as text").waitForExistence(timeout: 40), "the unknown type isn't text")
        XCTAssertTrue(element(in: app, contains: "Revenue today").exists, "its fallback text is missing")

        let invalid = launch(sending: "widget invalid")
        XCTAssertTrue(element(in: invalid, contains: "Shown as text").waitForExistence(timeout: 40), "the invalid payload isn't text")
        XCTAssertFalse(invalid.buttons["Order"].exists, "an invalid approval can be answered")
    }

    /// A private widget's content stays out of the chat list.
    @MainActor
    func testAPrivateWidgetStaysOutOfTheChatList() {
        let app = launch(sending: "widget private")
        XCTAssertTrue(element(in: app, contains: "pulse").waitForExistence(timeout: 40), "no reply")
        app.buttons["Show sidebar"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'pulse' OR label CONTAINS[c] 'widget private'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no chat row")
        for secret in ["Resting heart rate", "61", "bpm"] {
            XCTAssertFalse(row.label.contains(secret), "the chat list shows “\(secret)”")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(sending text: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
            "-HERMES_BOOTSTRAP_BACKEND", mock.backend.absoluteString,
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-HERMES_PASTEBOARD", "none",
            "-HERMES_SEND", text,
        ]
        app.launch()
        return app
    }

    @MainActor
    private func element(in app: XCUIApplication, beginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    private func element(in app: XCUIApplication, contains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}

/// The mock gateway (`Tools/mock-hermes`): its API server and its dashboard.
private struct WidgetsMock {
    let gateway: URL
    let backend: URL
    let key: String

    init() {
        let bundle = Bundle(for: WidgetsUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        gateway = URL(string: setting("HermesMockGateway", "http://127.0.0.1:18642"))!
        backend = URL(string: setting("HermesMockBackend", "http://127.0.0.1:19119"))!
        key = "dev-key-0123456789abcdef"
    }

    /// The dashboard's session token, as its page hands it to the app (ungated mock).
    private func token() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: backend)
        let page = String(decoding: data, as: UTF8.self)
        guard let start = page.range(of: "__HERMES_SESSION_TOKEN__=\"")?.upperBound,
              let end = page[start...].firstIndex(of: "\"") else { throw URLError(.userAuthenticationRequired) }
        return String(page[start..<end])
    }

    /// Someone answers the newest widget from another device; the agent holds `hold` seconds
    /// between its claim and its update.
    func answerElsewhere(action: String, device: String, hold: Double) async throws {
        var request = URLRequest(url: backend.appending(path: "api/mock/widget-answer"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "device": device, "hold": hold])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the mock couldn't answer")
    }
}
