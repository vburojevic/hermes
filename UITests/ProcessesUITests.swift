import XCTest

/// Background processes against the mock (`docs/background-processes.md` §10). Start it first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`. Elsewhere: pass
/// `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild (they go in the test bundle's
/// Info.plist).
final class ProcessesUITests: XCTestCase {
    private let mock = ProcessesMock()

    override func setUp() async throws {
        continueAfterFailure = false
        try await mock.reset()
    }

    /// A message sent after a turn that started background processes lands below their steps,
    /// never between a process and the composer (the cards after the last turn are gone).
    @MainActor
    func testANewMessageLandsBelowTheProcessSteps() async throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
            "-HERMES_BOOTSTRAP_BACKEND", mock.backend.absoluteString,
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
            "-HERMES_OPEN", "bot:ops",
            "-HERMES_SEND_HERE", "Build the 1.3 release, and keep the docs site up so I can check the changelog.",
            "-HERMES_SEND_HERE_AFTER", "8", "-HERMES_SEND_HERE_ROUNDS", "1",
        ]
        app.launch()

        // The turn starts two processes: their steps, and the chip.
        let steps = app.descendants(matching: .any).matching(Self.processStep)
        let release = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Release build'")).firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 60), "no Release build step")
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS 'background processes running'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "the chip doesn't say 2 running")

        // Once the turn is over (Talk is back), the person asks something else.
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 30), "the turn didn't end")
        let field = app.textViews["Message"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Is the changelog up to date?")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        let message = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Is the changelog up to date?'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the message didn't show")
        // Every process step on screen sits above it (one scrolled off the top is above too).
        for index in 0..<steps.count {
            let step = steps.element(boundBy: index)
            guard step.exists, !step.frame.isEmpty else { continue }
            XCTAssertLessThanOrEqual(step.frame.maxY, message.frame.minY + 1, "a process step is below the new message")
        }
    }

    /// A process step reads "Docs site, running for …" or "Release build, finished after …".
    private static var processStep: NSPredicate {
        NSPredicate(format: "label BEGINSWITH 'Docs site,' OR label BEGINSWITH 'Release build,'")
    }
}

/// The mock gateway (`Tools/mock-hermes`): its API server and its dashboard.
private struct ProcessesMock {
    let gateway: URL
    let backend: URL
    let key: String

    init() {
        let bundle = Bundle(for: ProcessesUITests.self)
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

    /// No processes from an earlier run.
    func reset() async throws {
        var request = URLRequest(url: backend.appending(path: "api/mock/processes/reset"))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: request)
    }
}
