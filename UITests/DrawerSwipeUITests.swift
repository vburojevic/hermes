import XCTest

/// The actions behind a chat row swiped in the iPhone drawer answer a tap (`docs/inbox.md` §5).
/// Before iOS 27 the drawer draws its own swipes, and a tap on Mute or Archive only closed the
/// row: the layer that closes an open row on a tap stayed where the row had been, over the
/// actions. Start the mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119
/// --gateway-port 18642`. Run it on iOS 26 and 27.
final class DrawerSwipeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMuteBehindASwipedRowWorks() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the drawer is the iPhone's")
        let app = launch(["-HERMES_DRAWER", "YES"])
        // The drawer opens on whichever list it showed last.
        let chats = app.buttons["Chats"].firstMatch
        if chats.waitForExistence(timeout: 60) { chats.tap() }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hermes app in SwiftUI'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "no chat row in the drawer")
        XCTAssertFalse(row.label.contains("muted"), "the row starts muted")
        // The drawer slides in first.
        Thread.sleep(forTimeInterval: 2)

        try tapAction("Mute", behind: row, in: app)
        let muted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hermes app in SwiftUI' AND label CONTAINS 'muted'")).firstMatch
        XCTAssertTrue(muted.waitForExistence(timeout: 5), "Mute didn't mute the chat")

        // Put back, so the next run starts the same.
        try tapAction("Unmute", behind: muted, in: app)
        XCTAssertTrue(muted.waitForNonExistence(timeout: 5), "Unmute didn't unmute the chat")
    }

    // MARK: Helpers

    @MainActor
    private func tapAction(_ title: String, behind row: XCUIElement, in app: XCUIApplication) throws {
        row.swipeLeft()
        // iOS 27's system actions read their label twice ("Mute, Mute"); the drawer's own, once.
        let action = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "no \(title) behind the row")
        // Open and settled before the tap.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "swiped-\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
        action.tap()
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let bundle = Bundle(for: DrawerSwipeUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-push.primeDeclines", "2",
        ] + arguments
        app.launch()
        return app
    }
}
