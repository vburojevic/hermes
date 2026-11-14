import XCTest

/// The system's navigation (`docs/design-to-swiftui.md` §6): on iPhone the chat list is the first
/// screen, a chat pushes over it, and the back button or a swipe from the edge returns to it; on
/// iPad the list is the sidebar beside the chat, and the system's sidebar button puts it away and
/// brings it back. Swiped rows show the system's actions (`docs/inbox.md` §5). Start the mock
/// first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class NativeNavigationUITests: XCTestCase {
    private let chatTitle = "Hermes app in SwiftUI"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAChatPushesAndTheBackButtonReturns() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the list is a sidebar on iPad")
        let app = launch()
        let compose = app.buttons["sidebar.compose"].firstMatch
        try openChat(in: app)
        XCTAssertTrue(compose.waitForNonExistence(timeout: 5), "the chat didn't push over the list")
        attach("iphone-pushed-chat")

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button")
        back.tap()
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the back button didn't return to the list")
    }

    @MainActor
    func testASwipeFromTheEdgeReturnsToTheList() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the list is a sidebar on iPad")
        let app = launch()
        let compose = app.buttons["sidebar.compose"].firstMatch
        try openChat(in: app)
        XCTAssertTrue(compose.waitForNonExistence(timeout: 5), "the chat didn't push over the list")
        // Settled first: a swipe while the push is still running is the push's.
        Thread.sleep(forTimeInterval: 1)

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(compose.waitForExistence(timeout: 5), "the swipe from the edge didn't return to the list")
    }

    @MainActor
    func testTheSidebarStaysBesideTheChatOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPhone pushes the chat instead")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        try openChat(in: app)
        let row = chatRow(in: app)
        // Landscape keeps the sidebar docked beside the chat.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(row.isHittable, "the sidebar went away when the chat opened")
        XCTAssertTrue(row.isSelected, "the open chat's row isn't marked as selected")
        attach("ipad-sidebar-and-chat")

        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no system sidebar button")
        toggle.tap()
        try expect(timeout: 5, "the sidebar button didn't put the sidebar away") { !row.isHittable }
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch.tap()
        try expect(timeout: 5, "the sidebar button didn't bring the sidebar back") { row.isHittable }
    }

    /// Turning the device keeps the open chat on screen and what was typed in it.
    @MainActor
    func testTurningTheDeviceKeepsTheChatAndItsDraft() throws {
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let draft = "A draft that stays"
        let app = launch()
        try openChat(in: app)
        var composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "no composer")
        composer.tap()
        composer.typeText(draft)

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1)
            attach("turned-\(orientation == .portrait ? "portrait" : "landscape")")
            if UIDevice.current.userInterfaceIdiom == .phone {
                XCTAssertFalse(app.buttons["sidebar.compose"].firstMatch.exists, "turning went back to the list")
            }
            composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 5), "the chat closed when the device turned")
            XCTAssertEqual(composer.value as? String, draft, "the draft went away when the device turned")
        }

        // Put back, so the next run starts the same.
        composer.tap()
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draft.count))
    }

    /// A tap on an action behind a swiped row does what it says, then the row shows it.
    @MainActor
    func testMuteBehindASwipedRowWorks() throws {
        // iPad keeps the sidebar docked only in landscape.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        }
        let app = launch()
        showChats(in: app)
        let row = chatRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no chat row")
        XCTAssertFalse(row.label.contains("muted"), "the row starts muted")

        try tapAction("Mute", behind: row, in: app)
        let muted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'muted'", chatTitle)).firstMatch
        XCTAssertTrue(muted.waitForExistence(timeout: 5), "Mute didn't mute the chat")

        // Put back, so the next run starts the same.
        try tapAction("Unmute", behind: muted, in: app)
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5), "Unmute didn't unmute the chat")
    }

    // MARK: Helpers

    @MainActor
    private func chatRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", chatTitle)).firstMatch
    }

    /// The list opens in whichever mode it showed last. The chat these tests use came from the
    /// terminal, so after the list's own chats are in, it's hidden until Show is All Chats
    /// (`docs/inbox.md` §5); each test picks that itself.
    @MainActor
    private func showChats(in app: XCUIApplication) {
        let chats = app.buttons["Chats"].firstMatch
        if chats.waitForExistence(timeout: 60) { chats.tap() }
        let own = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Swift 6 migration plan'")).firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 60), "no chat from this app in the list")
        XCTAssertFalse(chatRow(in: app).exists, "a chat from the terminal shows under This App")
        let filter = app.buttons["inbox.filter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "no filter button")
        filter.tap()
        let all = app.buttons["All Chats"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), "no All Chats in the filter")
        all.tap()
    }

    @MainActor
    private func openChat(in app: XCUIApplication) throws {
        showChats(in: app)
        let row = chatRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no chat row")
        row.tap()
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        _ = composer.waitForExistence(timeout: 10)
    }

    @MainActor
    private func tapAction(_ title: String, behind row: XCUIElement, in app: XCUIApplication) throws {
        // Partway: a full swipe runs the first action itself, and on a sidebar as narrow as
        // iPad's a plain swipe goes all the way.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        // iOS 27's system actions read their label twice ("Mute, Mute").
        let action = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "no \(title) behind the row")
        Thread.sleep(forTimeInterval: 1)
        attach("swiped-\(title)")
        action.tap()
    }

    @MainActor
    private func expect(timeout: TimeInterval, _ message: String, _ check: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, !check() { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(check(), message)
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
        let bundle = Bundle(for: NativeNavigationUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-push.primeDeclines", "2",
        ]
        app.launch()
        return app
    }
}
