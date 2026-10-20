import XCTest

/// Snapshots of every widget example (`docs/widgets.md` §13): light, dark and both with Increase
/// Contrast, at both densities, from the Debug gallery (`-HERMES_GALLERY widgets`). Each card is an
/// attachment named `<example>-<look>-<density>` in the result bundle, to compare with the Elyx
/// renders; the test fails when a valid example doesn't draw as a card. Needs no mock.
final class WidgetGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testLightRegular() { snapshot(look: "light", compact: false) }
    @MainActor func testLightCompact() { snapshot(look: "light", compact: true) }
    @MainActor func testDarkRegular() { snapshot(look: "dark", compact: false) }
    @MainActor func testDarkCompact() { snapshot(look: "dark", compact: true) }
    @MainActor func testIncreasedContrastLight() { snapshot(look: "light+contrast", compact: false) }
    @MainActor func testIncreasedContrastLightCompact() { snapshot(look: "light+contrast", compact: true) }
    @MainActor func testIncreasedContrastDark() { snapshot(look: "dark+contrast", compact: false) }
    @MainActor func testIncreasedContrastDarkCompact() { snapshot(look: "dark+contrast", compact: true) }

    @MainActor
    private func snapshot(look: String, compact: Bool) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_GALLERY", compact ? "widgets:compact" : "widgets", "-HERMES_GALLERY_LOOK", look,
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
        ]
        app.launch()
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'gallery.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20), "the gallery didn't open")
        // Page by page: each card's caption ("metric-1 · ready") names it in the picture.
        let density = compact ? "compact" : "regular"
        let fallbacks = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Shown as text'"))
        var lastTop = CGFloat.infinity
        for page in 1...80 {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = String(format: "%@-%@-%02d", look, density, page)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(fallbacks.count, 0, "a valid example drew as text (page \(page))")
            app.swipeUp()
            // The end: a swipe that no longer moves the first card.
            let top = first.frame.minY
            if abs(top - lastTop) < 1 { break }
            lastTop = top
        }
    }
}
