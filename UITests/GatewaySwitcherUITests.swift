import XCTest

/// iPhone's gateway switcher (`docs/design-to-swiftui.md` §6): the chat list's top bar leads with a
/// gateway menu that shows at rest, with no scrolling, and switches gateways. Start the mock first:
/// `python3 -I Tools/mock-hermes/server.py --port 18642`.
final class GatewaySwitcherUITests: XCTestCase {
    private let first = "Hermes"
    private let second = "Studio"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheToolbarMenuSwitchesGatewaysAtRest() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad keeps the switcher in the sidebar header")
        let app = launch()
        let menu = app.buttons["sidebar.gatewayMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "no gateway menu in the chat list's top bar at rest")
        XCTAssertTrue(menu.isHittable, "the gateway menu isn't tappable at rest")
        // The system draws toolbar items at its own size, so this checks the menu against its
        // neighbour rather than 44 pt: the Settings gear is a 36 pt glass button whose touch
        // target the system pads past its frame, and the gateway menu gets the same.
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.exists, "no Settings button beside the gateway menu")
        XCTAssertEqual(menu.frame.size, settings.frame.size, "the gateway menu isn't the Settings button's size")

        if !(try opens(second, from: menu, in: app)) {
            // The second gateway, the same mock under another name, added from the same menu.
            item("Add Gateway…", in: app).tap()
            // The form's fields carry no label of their own, so they're found by their prompts.
            let address = field(app.textFields, prompt: "mac-mini.local:8642 or https://…")
            XCTAssertTrue(address.waitForExistence(timeout: 5), "Add Gateway didn't open")
            address.tap()
            address.typeText(setting("HermesMockGateway", "http://127.0.0.1:18642"))
            let key = field(app.secureTextFields, prompt: "API_SERVER_KEY")
            key.tap()
            key.typeText("dev-key-0123456789abcdef")
            // The name sits further down the form, which builds its rows only as they scroll in.
            // The form is the sheet's list, the last one; the chat list lies under it.
            let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
            let name = field(app.textFields, prompt: "Hermes")
            for _ in 0..<6 where !name.isHittable {
                form.swipeUp()
            }
            name.tap()
            name.typeText(second)
            app.buttons["Connect"].firstMatch.tap()
        }
        XCTAssertTrue(gateway(second, in: app).waitForExistence(timeout: 15), "the list didn't switch to \(second)")
        attach("switched-to-\(second)")

        XCTAssertTrue(try opens(first, from: menu, in: app), "\(first) isn't in the gateway menu")
        XCTAssertTrue(gateway(first, in: app).waitForExistence(timeout: 15), "the list didn't switch back to \(first)")
        attach("switched-to-\(first)")
    }

    /// Opens the menu and picks `name` if it's listed; leaves the menu open when it isn't.
    @MainActor
    private func opens(_ name: String, from menu: XCUIElement, in app: XCUIApplication) throws -> Bool {
        menu.tap()
        XCTAssertTrue(item("Add Gateway…", in: app).waitForExistence(timeout: 5), "the gateway menu didn't open")
        let row = item(name, in: app)
        guard row.exists else { return false }
        row.tap()
        return true
    }

    /// A menu item by its title; a gateway's item also carries its address or status.
    @MainActor
    private func item(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.collectionViews.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title),")).firstMatch
    }

    @MainActor
    private func field(_ query: XCUIElementQuery, prompt: String) -> XCUIElement {
        query.matching(NSPredicate(format: "placeholderValue == %@", prompt)).firstMatch
    }

    /// The gateway menu once it names `name`, which it does when the list is that gateway's.
    @MainActor
    private func gateway(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "sidebar.gatewayMenu", "Gateway, \(name)")).firstMatch
    }

    private func setting(_ key: String, _ fallback: String) -> String {
        (Bundle(for: GatewaySwitcherUITests.self).object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-push.primeDeclines", "2",
        ]
        app.launch()
        return app
    }
}
