import XCTest

/// VoiceOver stays where the person put it while a reply arrives (`docs/inbox.md` §6): on a row of
/// the chat list, and on a message in the open chat. VoiceOver runs inside the simulator only, for
/// the length of each test. VoiceOver is placed first; only then does the app send the mock's
/// "slow marathon" turn (its steps, then the answer), so everything the turn changes happens under
/// the focus. Reading back, VoiceOver goes on from the loading row into the earlier messages that
/// come in (`docs/chat.md` §1). Start the mock first, with the long chat:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642 --long-chat`.
final class VoiceOverFocusUITests: XCTestCase {
    /// Seconds after launch the app sends: past the walk to the target, which takes about 30 s.
    private let sendAfter = 45
    /// The longest a test listens for the answer to land.
    private let listening: TimeInterval = 180
    /// How long it keeps listening once the answer is there, for anything it moves late.
    private let settling: TimeInterval = 8
    /// The words the marathon's answer starts with: the gateway's turn, or Bot Mode's.
    private let answers = ["what I found about", "the consensus is clear"]

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        guard #available(iOS 27.0, *) else { return }
        await MainActor.run {
            let service = XCUIDevice.shared.voiceOverService
            if service.isEnabled { try? service.disable() }
        }
    }

    /// VoiceOver reads a chat's row in the list while a chat listed below it replies, and that
    /// chat's row moves above it.
    @MainActor
    func testFocusStaysOnAChatRowWhileAReplyArrives() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the list stays beside the chat on iPad")
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        // Opening the replying chat first loads it, as a chat the person was just in.
        let app = launch(opening: "api_old_2", sending: "slow marathon, list focus check", into: "api_old_2")
        XCTAssertTrue(message("Why does my ingress 404?", in: app).waitForExistence(timeout: 30), "the chat didn't open")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button")
        back.tap()
        XCTAssertTrue(app.buttons["sidebar.compose"].firstMatch.waitForExistence(timeout: 10), "the list didn't come back")
        // The list keeps the mode it was last in; this test reads the chats.
        let chats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chats'")).firstMatch
        if chats.waitForExistence(timeout: 5) { chats.tap() }

        let focused = row("Trip to Lisbon", in: app)
        // A row scrolled out of view isn't in the tree: until it moves up, Kubernetes counts as below.
        let replying = row("Kubernetes ingress debugging", in: app)
        try listen(for: "Trip to Lisbon", name: "chat-row", in: app) {
            let label = replying.exists ? replying.label : ""
            let above = replying.exists && focused.exists && replying.frame.minY < focused.frame.minY
            return Landing(arrived: self.answers.contains { label.contains($0) }, moved: above,
                           state: "\(above ? "above" : "below") · \(label.prefix(90))")
        }
    }

    /// The reply lands in the chat the person is reading, below the message VoiceOver is on.
    @MainActor
    func testFocusStaysInTheOpenChatWhileAReplyArrives() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let sent = "slow marathon, chat focus check"
        let app = launch(opening: "api_old_1", sending: sent)
        let target = "Plan 3 days in Lisbon"
        XCTAssertTrue(message(target, in: app).waitForExistence(timeout: 30), "the chat didn't open")

        try listen(for: target, name: "open-chat", in: app) {
            let mine = self.message(sent, in: app).exists
            let answered = self.answers.contains { self.message($0, in: app).exists }
            return Landing(arrived: answered, moved: mine, state: "sent: \(mine) · answer: \(answered)")
        }
    }

    /// VoiceOver reaches the loading row above the oldest message shown, the way reading a long
    /// chat upward does, and waits there. When the earlier page goes in above that message,
    /// VoiceOver is on the row just above it, and reading on goes up into the page rather than
    /// off to the toolbar.
    @MainActor
    func testReadingBackGoesOnIntoEarlierMessages() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let app = launch(opening: "long_history", settings: ["-openChatsAt", "latest"])
        let oldest = try readBackToLoading(in: app)
        let service = XCUIDevice.shared.voiceOverService
        let step = Self.step
        attach("read-back-on-loading")

        // Waiting on the loading row: the earlier page comes in above the oldest question. The
        // test waits as a person would, without reading the app meanwhile: its reads while the
        // page lands keep VoiceOver busy.
        Thread.sleep(forTimeInterval: 6)
        let earlier = message("Step \(oldest - 1):", in: app)
        XCTAssertTrue(earlier.waitForExistence(timeout: 20), "the messages before step \(oldest) never came in")
        attach("read-back-landed")
        // Step off and back: VoiceOver comes back to wherever focus is now.
        _ = try? service.moveForward()
        let focused = (try? service.moveBackward().utterance) ?? "<no speech>"
        // Reading on from there goes up into the page: a question older than any shown before,
        // before any loading row or the toolbar.
        var onward = [focused]
        var next = step(focused)
        while next == nil, onward.count < 60, !(onward.last ?? "").hasPrefix("Loading") {
            let heard = (try? service.moveBackward().utterance) ?? "<no speech>"
            if onward.last == heard { break }
            onward.append(heard)
            next = step(heard)
        }
        try service.disable()
        let log = onward.joined(separator: "\n")
        keep("oldest shown: step \(oldest)\nafter the page:\n\(log)", as: "read-back-after")
        print("VoiceOver after the page (oldest shown: step \(oldest)):\n\(log)")
        XCTAssertFalse(focused.hasPrefix("Loading"), "VoiceOver stayed on the loading row above the page")
        let into = try XCTUnwrap(next, "VoiceOver didn't go on into the page from “\(focused)”:\n\(log)")
        XCTAssertLessThan(into, oldest, "VoiceOver read a question that was already shown:\n\(log)")
    }

    /// The reader swipes off the loading row while the earlier page lands under it, before
    /// VoiceOver has moved on into the page: VoiceOver stays where the reader went, and nothing
    /// the landing asked for pulls it back (`docs/chat.md` §1).
    @MainActor
    func testSwipingOffTheLoadingRowKeepsVoiceOverWhereTheReaderWent() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let app = launch(opening: "long_history", settings: ["-openChatsAt", "latest"])
        let oldest = try readBackToLoading(in: app)
        let service = XCUIDevice.shared.voiceOverService
        // VoiceOver reached the loading row; the page goes in under it within half a second, the
        // row above asks for VoiceOver from about 0.9 s, and VoiceOver makes that move once it
        // has finished with the loading row, about 2.9 s in. The swipe comes between the two,
        // while the asks are still being made.
        Thread.sleep(forTimeInterval: 1.2)
        let went = (try? service.moveBackward().utterance) ?? "<no speech>"
        XCTAssertFalse(went.hasPrefix("Loading") || went == "<no speech>", "VoiceOver didn't move off the loading row: \(went)")
        attach("swipe-off-moved")
        // Waiting there past every ask, then stepping off and back: VoiceOver comes back to
        // wherever focus is now. Up and down again, so it doesn't pass the loading row.
        Thread.sleep(forTimeInterval: 5)
        let earlier = message("Step \(oldest - 1):", in: app)
        XCTAssertTrue(earlier.waitForExistence(timeout: 20), "the messages before step \(oldest) never came in")
        _ = try? service.moveBackward()
        let after = (try? service.moveForward().utterance) ?? "<no speech>"
        try service.disable()
        let log = "oldest shown: step \(oldest)\nswiped to: \(went)\nafter the page: \(after)"
        keep(log, as: "swipe-off")
        print("VoiceOver swiping off the loading row:\n\(log)")
        // The same element reads the same words first; VoiceOver may add a hint after them.
        XCTAssertTrue(after.hasPrefix(String(went.prefix(24))), "VoiceOver didn't stay where the reader went:\n\(log)")
        XCTAssertFalse(after.hasPrefix("More"), "VoiceOver went to the row the page landed under:\n\(log)")
    }

    /// A reply that ends in a code block lands on its actions, More, like any reply with words, when
    /// the earlier page goes in above the question below it (`docs/chat.md` §1).
    @MainActor
    func testAReplyEndingInCodeLandsOnMore() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let app = launch(opening: "long_code", settings: ["-openChatsAt", "latest"])
        let oldest = try readBackToLoading(in: app, opened: "8023")
        let landed = try landing(below: oldest, in: app, name: "code")
        XCTAssertTrue(landed.hasPrefix("More"), "VoiceOver didn't land on the reply's More: “\(landed)”")
    }

    /// A reply that is only a widget, with no words to copy, lands on the widget's card: its
    /// title (`docs/chat.md` §1).
    @MainActor
    func testAWidgetOnlyReplyLandsOnItsCard() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let app = launch(opening: "long_widget", settings: ["-openChatsAt", "latest"])
        let oldest = try readBackToLoading(in: app, opened: "Check 24")
        let landed = try landing(below: oldest, in: app, name: "widget")
        XCTAssertTrue(landed.contains("Check \(oldest - 1)"), "VoiceOver didn't land on the card of step \(oldest - 1): “\(landed)”")
    }

    /// Reading a chat of two pages back from its end: past the loading row, once the earlier page
    /// is in and the loading row has gone, reading on reaches the chat's first message.
    @MainActor
    func testReadingBackReachesTheFirstMessage() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("driving VoiceOver needs iOS 27") }
        let app = launch(opening: "garden_plan", settings: ["-openChatsAt", "latest"])
        let oldest = try readBackToLoading(in: app, opened: "Bed 14 gets")
        let service = XCUIDevice.shared.voiceOverService
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(message("Step 1:", in: app).waitForExistence(timeout: 20), "the first page never came in")
        attach("start-landed")
        var heard = [String]()
        var pages = 1
        while heard.count < 80 {
            let next = (try? service.moveBackward().utterance) ?? "<no speech>"
            if heard.last == next { break }
            heard.append(next)
            if Self.step(next) == 1 { break }
            // Another page, if the chat had one: it goes in above, as the first did.
            if next.hasPrefix("Loading") { pages += 1; Thread.sleep(forTimeInterval: 6) }
        }
        try service.disable()
        let log = heard.joined(separator: "\n")
        keep("oldest shown: step \(oldest)\npages: \(pages)\nreading back:\n\(log)", as: "start-read-back")
        print("VoiceOver reading back to the start (oldest shown: step \(oldest), pages: \(pages)):\n\(log)")
        XCTAssertEqual(heard.last.flatMap(Self.step), 1, "VoiceOver didn't reach the first message:\n\(log)")
        let steps = heard.compactMap(Self.step)
        XCTAssertEqual(steps, steps.sorted(by: >), "VoiceOver didn't read the questions upward in order:\n\(log)")
    }

    // MARK: Helpers

    /// Waiting on the loading row until the page is in above step `oldest`, then stepping off and
    /// back, so VoiceOver reads wherever focus is now. Answers what it reads.
    @available(iOS 27.0, *)
    @MainActor
    private func landing(below oldest: Int, in app: XCUIApplication, name: String) throws -> String {
        let service = XCUIDevice.shared.voiceOverService
        attach("\(name)-on-loading")
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(message("Step \(oldest - 1):", in: app).waitForExistence(timeout: 20), "the messages before step \(oldest) never came in")
        attach("\(name)-landed")
        _ = try? service.moveForward()
        let focused = (try? service.moveBackward().utterance) ?? "<no speech>"
        try service.disable()
        keep("oldest shown: step \(oldest)\nafter the page: \(focused)", as: "\(name)-landing")
        print("VoiceOver after the page (\(name), oldest shown: step \(oldest)): \(focused)")
        return focused
    }

    /// The number in a question's "Step N:", where it has one.
    private static func step(_ heard: String) -> Int? {
        guard let match = heard.firstMatch(of: /Step (\d+):/) else { return nil }
        return Int(match.1)
    }

    /// With a long chat opened at its end, as a chat read to the end opens (it follows the end
    /// until read back), turns VoiceOver on and reads back to the loading row, the first thing
    /// in the chat, from the toolbar, as it does reading back from below. `last` is words of the
    /// chat's last reply, there once it's open. Answers the oldest step shown before VoiceOver
    /// started: the page goes in above it.
    @available(iOS 27.0, *)
    @MainActor
    private func readBackToLoading(in app: XCUIApplication, opened last: String = "is healthy again") throws -> Int {
        XCTAssertTrue(message(last, in: app).waitForExistence(timeout: 30), "the long chat didn't open")
        Thread.sleep(forTimeInterval: 3)
        let questions = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Step "))
        let shown = questions.allElementsBoundByIndex.compactMap { Self.step($0.label) }
        let oldest = try XCTUnwrap(shown.min(), "no question was shown")
        XCTAssertGreaterThan(oldest, 1, "the whole chat was shown, with no page left to come in")
        attach("read-back-start")

        let service = XCUIDevice.shared.voiceOverService
        for attempt in 0..<3 {
            if attempt > 0 { try service.disable(); Thread.sleep(forTimeInterval: 1) }
            try service.enable()
            Thread.sleep(forTimeInterval: 3)
            if (try? service.currentSpeech()) != nil || (try? service.moveForward()) != nil { break }
        }
        var heard = ""
        var path: [String] = []
        for _ in 0..<20 {
            heard = (try? service.moveForward().utterance) ?? "<no speech>"
            path.append(heard)
            if heard.hasPrefix("Loading") || Self.step(heard) != nil { break }
        }
        keep(path.joined(separator: "\n"), as: "read-back-path")
        XCTAssertTrue(heard.hasPrefix("Loading"), "VoiceOver never reached the loading row:\n\(path.joined(separator: "\n"))")
        return oldest
    }

    /// What a test sees of the reply in the app: whether its answer is there, whether what it
    /// moves has moved, and a line for the log.
    private struct Landing {
        let arrived: Bool
        let moved: Bool
        let state: String
    }

    /// Turns VoiceOver on and moves it to the element that reads `target`, before the app sends.
    /// Then, every half second until the answer has landed (and `settling` after), reads what
    /// VoiceOver is on and what the app shows. Every sample is kept in the test's output.
    @available(iOS 27.0, *)
    @MainActor
    private func listen(for target: String, name: String, in app: XCUIApplication, landing: () -> Landing) throws {
        let service = XCUIDevice.shared.voiceOverService
        attach("\(name)-start")
        // VoiceOver sometimes starts without a place to move from (after a navigation pop, say):
        // every move then fails to send. Starting it again gives it one.
        for attempt in 0..<3 {
            if attempt > 0 { try service.disable(); Thread.sleep(forTimeInterval: 1) }
            try service.enable()
            Thread.sleep(forTimeInterval: 3)
            if (try? service.currentSpeech()) != nil || (try? service.moveForward()) != nil { break }
        }
        var focused = ""
        var path: [String] = []
        for _ in 0..<60 {
            do { focused = try service.moveForward().utterance } catch { focused = "<\(error)>" }
            path.append(focused)
            if focused.contains(target) { break }
        }
        let steps = XCTAttachment(string: path.joined(separator: "\n"))
        steps.name = "\(name)-voiceover-path"
        steps.lifetime = .keepAlways
        add(steps)
        XCTAssertTrue(focused.contains(target), "VoiceOver never reached “\(target)”; path:\n\(path.joined(separator: "\n"))")

        // Nothing of the turn may be there yet: it has to happen under the focus.
        let first = landing()
        attach("\(name)-before")
        XCTAssertFalse(first.arrived || first.moved, "the turn started before VoiceOver was in place: \(first.state)")

        let start = Date.now
        func stamp() -> String { String(format: "%6.1fs ", Date.now.timeIntervalSince(start)) }
        var samples = ["\(stamp())focused: \(focused) | \(first.state)"]
        var readings = samples
        var last = focused
        var lastState = first.state
        var moved: TimeInterval?
        var arrived: TimeInterval?
        while Date.now.timeIntervalSince(start) < listening {
            if let arrived, Date.now.timeIntervalSince(start) > arrived + settling { break }
            Thread.sleep(forTimeInterval: 0.5)
            let heard = (try? service.currentSpeech().utterance) ?? "<no speech>"
            let now = landing()
            if now.moved, moved == nil { moved = Date.now.timeIntervalSince(start) }
            if now.arrived, arrived == nil {
                arrived = Date.now.timeIntervalSince(start)
                attach("\(name)-landed")
            }
            samples.append("\(stamp())\(heard) | \(now.state)")
            if heard != last || now.state != lastState {
                readings.append("\(stamp())\(heard) | \(now.state)")
                last = heard
                lastState = now.state
            }
        }
        attach("\(name)-after")
        // The last speech may be one of the turn's announcements rather than the focused element, so
        // step off and back: VoiceOver comes back to wherever focus was.
        _ = try? service.moveForward()
        let after = (try? service.moveBackward().utterance) ?? "<no speech>"
        readings.append("\(stamp())after: \(after)")
        try service.disable()

        let summary = "moved at \(moved.map { String(format: "%.1fs", $0) } ?? "never"), "
            + "answer at \(arrived.map { String(format: "%.1fs", $0) } ?? "never")"
        let log = ([summary] + readings).joined(separator: "\n")
        print("VoiceOver readings (\(name)):\n\(log)")
        for (suffix, text) in [("readings", log), ("samples", samples.joined(separator: "\n"))] {
            let attachment = XCTAttachment(string: text)
            attachment.name = "\(name)-voiceover-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertNotNil(moved, "the turn never changed what's around the focus: \(lastState)")
        XCTAssertNotNil(arrived, "the answer didn't land while VoiceOver listened: \(lastState)")
        // The turn's three announcements (`docs/chat.md` §4a) are speech, not focus moving.
        let announcements = ["is thinking", "Replying", "Reply finished"]
        let left = readings.dropFirst().dropLast().map { $0.components(separatedBy: " | ")[0] }.filter { reading in
            !reading.contains(target) && !reading.contains("<no speech>")
                && !announcements.contains(where: reading.hasSuffix)
        }
        XCTAssertTrue(left.isEmpty, "VoiceOver left “\(target)”:\n\(left.joined(separator: "\n"))")
        XCTAssertTrue(after.contains(target), "VoiceOver ended on “\(after)”, not “\(target)”")
    }

    @MainActor
    private func message(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// A chat's row in the list: its spoken label starts with the chat's title.
    @MainActor
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func keep(_ text: String, as name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens a chat and, `sendAfter` seconds after launch, sends one message into it, or into the
    /// chat `chat` names. `settings` are more launch arguments.
    @MainActor
    private func launch(opening session: String, sending text: String? = nil, into chat: String? = nil,
                        settings: [String] = []) -> XCUIApplication {
        let bundle = Bundle(for: VoiceOverFocusUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-HERMES_PASTEBOARD", "NO", "-push.primeDeclines", "2",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-HERMES_OPEN_SESSION", session,
        ] + settings
        if let text {
            app.launchArguments += ["-HERMES_SEND_HERE", text, "-HERMES_SEND_HERE_AFTER", "\(sendAfter)", "-HERMES_SEND_HERE_ROUNDS", "1"]
        }
        if let chat { app.launchArguments += ["-HERMES_SEND_HERE_CHAT", chat] }
        app.launch()
        return app
    }
}
