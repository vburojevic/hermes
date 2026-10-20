import XCTest

/// Unread and live activity against the mock (`docs/inbox.md` §7). Start it first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`. Elsewhere: pass
/// `HERMES_MOCK_GATEWAY=…` and `HERMES_MOCK_BACKEND=…` to xcodebuild (they go in the test bundle's
/// Info.plist).
final class InboxUITests: XCTestCase {
    private let mock = Mock()

    override func setUp() async throws {
        continueAfterFailure = false
        try await mock.reset()
    }

    /// A chat with replies since it was read opens at the New Messages line, on screen.
    @MainActor
    func testOpensAtTheNewMessagesLine() async throws {
        let app = launch(["-HERMES_OPEN_SESSION", "cli_release_prep"])
        let line = app.descendants(matching: .any)["newMessagesLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no New Messages line")
        // On screen, below the toolbar, in the top half (a quarter of the way down).
        let screen = app.windows.firstMatch.frame
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !(line.frame.minY > screen.minY + 80 && line.frame.maxY < screen.midY + 40) {
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertTrue(line.frame.minY > screen.minY + 80 && line.frame.maxY < screen.midY + 40, "the line is at \(line.frame) on \(screen)")
    }

    /// The pill goes to the first new message, then to the end; reaching the end marks the chat
    /// read on the gateway.
    @MainActor
    func testJumpReachesTheEndAndMarksRead() async throws {
        let before = Date.now.timeIntervalSince1970 - 1
        let app = launch(["-HERMES_OPEN_SESSION", "cli_release_prep"])
        XCTAssertTrue(app.descendants(matching: .any)["newMessagesLine"].waitForExistence(timeout: 30))
        let pill = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jump to' OR label == 'Scroll to latest'")).firstMatch
        // To the first new message (when there's more below), then to the end.
        for _ in 0..<2 where pill.waitForExistence(timeout: 5) {
            pill.tap()
            try await Task.sleep(for: .seconds(1))
        }
        try await eventually(timeout: 20) { try await self.mock.readMark("cli_release_prep") > before }
    }

    /// Mark as Read and Mark as Unread reach Hermes, and another device's marks reach this one.
    @MainActor
    func testMarkAsUnreadSyncsBetweenClients() async throws {
        let before = Date.now.timeIntervalSince1970 - 1
        let app = launch(["-HERMES_DRAWER", "YES"])
        // The drawer opens in the mode it was left in.
        let chats = app.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 30))
        chats.tap()
        let briefing = row("Morning briefing", in: app)
        XCTAssertTrue(briefing.waitForExistence(timeout: 30), "no Morning briefing row")
        try await eventually(timeout: 20) { briefing.label.contains("1 unread") }

        // This device reads it, then marks it unread: Hermes' mark follows.
        briefing.press(forDuration: 1.2)
        app.buttons["Mark as Read"].tap()
        try await eventually(timeout: 15) { try await self.mock.readMark("tg_88213") > before }
        briefing.press(forDuration: 1.2)
        app.buttons["Mark as Unread"].tap()
        try await eventually(timeout: 15) { try await self.mock.readMark("tg_88213") == 0 }
        XCTAssertTrue(briefing.label.contains("marked unread"))

        // Another device reads Stand-up summary and marks Disk cleanup unread.
        let standUp = row("Stand-up summary", in: app)
        XCTAssertTrue(standUp.label.contains("marked unread"))
        try await mock.setUnread("slack_5521", false)
        try await mock.setUnread("cli_2026_1011", true)
        let disk = row("Disk cleanup on the NAS", in: app)
        try await eventually(timeout: 30) {
            !standUp.label.contains("marked unread") && disk.label.contains("marked unread")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
            "-HERMES_BOOTSTRAP_BACKEND", mock.backend.absoluteString,
            "-HERMES_RESET_INBOX", "YES", "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
        ] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Waits for something that takes a round trip or two to come true.
    @MainActor
    private func eventually(timeout: TimeInterval, _ check: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("still not true after \(Int(timeout)) s")
    }
}

/// The mock gateway (`Tools/mock-hermes`): its API server and its dashboard.
private struct Mock {
    let gateway: URL
    let backend: URL
    let key: String

    init() {
        let bundle = Bundle(for: InboxUITests.self)
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

    private func dashboard(_ path: String, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: backend.appending(path: path))
        request.httpMethod = method
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        // A mock older than this test (restart it after pulling) answers 404.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// The seeded read marks again.
    func reset() async throws {
        _ = try await dashboard("api/mock/inbox/reset", method: "POST")
    }

    /// Hermes' read mark for a chat: 0 marked unread, else when it was read (`-1` never).
    func readMark(_ id: String) async throws -> Double {
        let data = try await dashboard("api/sessions/\(id)")
        let row = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (row?["last_read_at"] as? Double) ?? -1
    }

    /// Another device reads a chat, or marks it unread (the API server's PATCH).
    func setUnread(_ id: String, _ unread: Bool) async throws {
        var request = URLRequest(url: gateway.appending(path: "api/sessions/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["unread": unread])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
