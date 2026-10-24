import XCTest

/// Once open, Hermes is in the appearance it should be: dark on a dark phone, light on a light one,
/// and in Settings → Appearance when that differs from the phone's (`docs/design-to-swiftui.md`
/// §1). Each test opens Hermes cold and again from the background, and reads how bright the screen
/// is once it has settled: after `launch` returns (the app idle, already drawn) and a second after
/// `activate` (iOS's opening animation done). It is a check on the steady state, not on the launch
/// frames: the launch screen, the opening animation and a first frame that changes within that
/// second aren't seen here, only in a recording stepped through frame by frame (that section).
/// Start the mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class LaunchAppearanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testADarkPhoneOpensHermesDark() {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        XCUIDevice.shared.appearance = .dark
        let app = launch(appearance: "system")
        expect(.dark, "cold, dark phone")
        reopen(app)
        expect(.dark, "from the background, dark phone")
    }

    @MainActor
    func testALightPhoneOpensHermesLight() {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        XCUIDevice.shared.appearance = .light
        let app = launch(appearance: "system")
        expect(.light, "cold, light phone")
        reopen(app)
        expect(.light, "from the background, light phone")
    }

    /// The phone turns dark (Automatic, at sunset) while Hermes waits in the background.
    @MainActor
    func testAPhoneThatTurnedDarkWhileAwayOpensHermesDark() {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        XCUIDevice.shared.appearance = .light
        let app = launch(appearance: "system")
        expect(.light, "cold, light phone")
        reopen(app) { XCUIDevice.shared.appearance = .dark }
        expect(.dark, "from the background, after the phone turned dark")
    }

    @MainActor
    func testHermesSetToDarkOpensDarkOnALightPhone() {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        XCUIDevice.shared.appearance = .light
        let app = launch(appearance: "dark")
        expect(.dark, "cold, Hermes set to Dark")
        reopen(app)
        expect(.dark, "from the background, Hermes set to Dark")
    }

    @MainActor
    func testHermesSetToLightOpensLightOnADarkPhone() {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        XCUIDevice.shared.appearance = .dark
        let app = launch(appearance: "light")
        expect(.light, "cold, Hermes set to Light")
        reopen(app)
        expect(.light, "from the background, Hermes set to Light")
    }

    // MARK: Helpers

    private enum Look { case light, dark }

    /// Six screenshots over a second and a half, from the moment Hermes is open: every one as
    /// light or as dark as expected (the canvas is white or black; text and controls barely move
    /// the mean).
    @MainActor
    private func expect(_ look: Look, _ when: String) {
        for shot in 0..<6 {
            let screenshot = XCUIScreen.main.screenshot()
            let level = brightness(screenshot.image)
            if shot == 0 || (look == .dark ? level > 0.35 : level < 0.6) {
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "\(when) \(shot) (\(String(format: "%.2f", level)))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            switch look {
            case .dark: XCTAssertLessThan(level, 0.35, "\(when): screenshot \(shot) is light")
            case .light: XCTAssertGreaterThan(level, 0.6, "\(when): screenshot \(shot) is dark")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Mean brightness (0 black … 1 white) of a 16 × 32 copy.
    private func brightness(_ image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return -1 }
        let width = 16, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total = 0
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[pixel]) + Int(pixels[pixel + 1]) + Int(pixels[pixel + 2])
        }
        return Double(total) / Double(width * height * 765)
    }

    /// To the Home Screen, `meanwhile`, and back.
    @MainActor
    private func reopen(_ app: XCUIApplication, meanwhile: () -> Void = {}) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 10) || app.state == .runningBackground,
                      "Hermes didn't go to the background")
        // Long enough for iOS to take its pictures of the app.
        Thread.sleep(forTimeInterval: 3)
        meanwhile()
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Hermes didn't come back")
        // iOS's opening animation (its picture of the app growing out of the icon, over the Home
        // Screen) outlasts `activate`; the recordings cover it, the screenshots start after it.
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let bundle = Bundle(for: LaunchAppearanceUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-push.primeDeclines", "2",
            // Settings → Appearance, as stored.
            "-appearance", appearance,
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "Hermes didn't open")
        return app
    }
}
