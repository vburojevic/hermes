import XCTest

/// A new chat always shows its composer (`docs/composer.md` §1, §6). A tester on iOS 26 saw a new
/// chat whose bottom bar kept its room and drew nothing in it. An approval card rising over the
/// composer did that: its command box sized itself in a second pass (`docs/quick-actions.md` §1). These open
/// a new chat from each place and state that could leave the bar empty, and check the composer's
/// field is there to type in each time. Start the mock first:
/// `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class NewChatComposerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// From a Hermes chat, by the toolbar and by the chat list, in light and dark, with the
    /// getting-started checklist and without it.
    @MainActor
    func testANewChatFromAHermesChatShowsTheComposer() throws {
        let phone = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = phone }
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            for checklist in [true, false] {
                let app = launch(["-HERMES_SEND", "hello there"], checklist: checklist)
                try waitForSent("hello there", in: app)
                let label = "\(name)-\(checklist ? "checklist" : "no-checklist")"
                try newChatFromToolbar(in: app)
                try expectComposer(in: app, "hermes-chat-toolbar-\(label)")
                try newChatFromList(in: app)
                try expectComposer(in: app, "hermes-chat-list-\(label)")
                app.terminate()
            }
        }
    }

    /// From a Bot Chat and from the Bots page.
    @MainActor
    func testANewChatFromABotChatOrTheBotsPageShowsTheComposer() throws {
        var app = launch(["-HERMES_OPEN", "bot:researcher"])
        XCTAssertTrue(app.buttons["botChatTitle"].waitForExistence(timeout: 60), "the Bot Chat didn't open")
        Thread.sleep(forTimeInterval: 2)
        try newChatFromList(in: app)
        try expectComposer(in: app, "bot-chat-list")
        app.terminate()

        app = launch(["-HERMES_OPEN", "bots"])
        let bot = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Research Buddy'")).firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 60), "the Bots page didn't open")
        Thread.sleep(forTimeInterval: 2)
        try newChatFromList(in: app)
        try expectComposer(in: app, "bots-page-list")
    }

    /// From a chat with an approval card up, and with the card stepped aside for the dock while
    /// the person types. XCTest runs a class's tests in name order, and this one's name puts it
    /// first: after all the others had run against the same mock, the blank bar didn't show.
    @MainActor
    func testACardUpLeavesTheComposerAndANewChatsComposerDrawn() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(["-HERMES_SEND", "approve the cleanup"])
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Approval needed'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "no approval card")
        Thread.sleep(forTimeInterval: 1)
        try expectComposer(in: app, "card-up")
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "card-up-toolbar")

        try openFirstChat(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the card went")
        let field = try composerField(in: app)
        field.tap()
        field.typeText("a note")
        // Only a phone docks the card while typing; a full-screen iPad keeps it up above the composer.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let dock = app.descendants(matching: .any)["needsYouDock"].firstMatch
            XCTAssertTrue(dock.waitForExistence(timeout: 10), "the card didn't step aside for the dock")
        }
        attach("card-docked")
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "card-docked-toolbar")
    }

    /// A command taller than the card's command box: the box stops at its cap and scrolls, and
    /// the answers and the composer stay on screen, upright and turned. Turned, a phone has less
    /// room than the card, which then scrolls above the composer (`docs/quick-actions.md` §1).
    @MainActor
    func testALongCommandScrollsInsideItsCardAboveTheComposer() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(["-HERMES_SEND", "approve script"])
        // The scroll view carries the command as its label; its text inside does too, and is taller.
        let box = app.scrollViews.matching(NSPredicate(format: "label BEGINSWITH %@", "python3 - <<'PY'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 60), "no command box")
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            // A turned iPhone caps the box at 96 pt, but its accessibility frame reads taller than
            // what's drawn there, so it's only checked to be under the upright cap.
            let capped: () -> Bool = phone && orientation.isLandscape
                ? { box.frame.height < 188 } : { abs(box.frame.height - 190) <= 2 }
            try expect(timeout: 5, "\(name): the box is \(box.frame.height) pt tall, not capped", capped)
            let allow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Allow Once'")).firstMatch
            try expect(timeout: 5, "\(name): Allow Once isn't on screen") { allow.isHittable }
            try expectComposer(in: app, "long-command-\(name)")
            // Turned, the card is taller than the room under the top bar: it opens at its answers
            // with the command scrolled away above them, and scrolls back down to it.
            let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Allowing covers'")).firstMatch
            for _ in 0..<3 where !box.isHittable {
                drag(note, by: 150)
                Thread.sleep(forTimeInterval: 1)
            }
            XCTAssertTrue(box.isHittable, "\(name): the card didn't scroll to the command")
            try expectComposer(in: app, "long-command-\(name)-card-scrolled")
            box.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            attach("long-command-\(name)-scrolled")
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Run this command?'")).firstMatch
            for _ in 0..<3 where !allow.isHittable {
                drag(title, by: -150)
                Thread.sleep(forTimeInterval: 1)
            }
            XCTAssertTrue(allow.isHittable, "\(name): Allow Once can't be scrolled back to")
            try expectComposer(in: app, "long-command-\(name)-answers")
        }
    }

    /// With the software keyboard up in the chat being left, by the toolbar and by the list.
    @MainActor
    func testANewChatWhileTheKeyboardIsUpShowsTheComposer() throws {
        let app = launch(["-HERMES_SEND", "hello there"])
        try waitForSent("hello there", in: app)
        for (via, open) in [("toolbar", newChatFromToolbar), ("list", newChatFromList)] {
            let field = try composerField(in: app)
            field.tap()
            field.typeText("half a thought")
            let keyboard = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            attach("keyboard-\(keyboard ? "software" : "hardware")-before-\(via)")
            try open(app)
            try expectComposer(in: app, "keyboard-\(keyboard ? "software" : "hardware")-\(via)")
        }
    }

    /// Right after coming back from the Home Screen, with the model sheet open when it left, and
    /// after locking and unlocking.
    @MainActor
    func testANewChatAfterTheBackgroundShowsTheComposer() throws {
        let app = launch(["-HERMES_SEND", "hello there"])
        try waitForSent("hello there", in: app)

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "home-screen-and-back")

        try openModelSheet(in: app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        attach("sheet-back-from-home")
        closeModelSheet(in: app)
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "sheet-back-from-home-toolbar")

        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        Thread.sleep(forTimeInterval: 2)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        app.activate()
        try newChatFromList(in: app)
        try expectComposer(in: app, "lock-and-unlock-list")
    }

    /// After choosing another model for a chat, and in landscape and back.
    @MainActor
    func testANewChatAfterAModelChangeOrTurningShowsTheComposer() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(["-HERMES_SEND", "hello there"])
        try waitForSent("hello there", in: app)
        try openModelSheet(in: app)
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model: '")).firstMatch
        let before = picker.label
        let current = String(before.dropFirst("Model: ".count))
        let other = app.buttons.matching(NSPredicate(
            format: "NOT (label BEGINSWITH 'Model') AND NOT (label CONTAINS %@) AND NOT (label BEGINSWITH 'Gateway default') AND NOT (label IN {'Done', 'Refresh models', 'Add Key…', 'Sheet Grabber'}) AND NOT (label BEGINSWITH 'Show all')", current))
            .allElementsBoundByIndex.first { $0.isHittable && !$0.isSelected && $0.frame.minY > 150 && $0.frame.height >= 36 }
        XCTAssertNotNil(other, "no other model to choose")
        other?.tap()
        closeModelSheet(in: app)
        try expect(timeout: 10, "the model didn't change (still \(before))") { picker.label != before }
        attach("model-changed")
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "model-changed-toolbar")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "landscape-toolbar")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.5)
        try expectComposer(in: app, "landscape-and-back")
    }

    /// During Talk, from the chat behind the minimised call. A simulator has no speech model, so
    /// the call stops at once ("Talk stopped") and stays up with End: the chat behind it is the same.
    @MainActor
    func testANewChatDuringTalkShowsTheComposer() throws {
        let app = launch(["-HERMES_TALK_TO", "hermes"])
        let end = app.buttons.matching(NSPredicate(format: "label IN {'End call', 'End'}")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 60), "no call")
        addTeardownBlock { @MainActor in
            guard app.state == .runningForeground, end.exists else { return }
            end.tap()
        }
        Thread.sleep(forTimeInterval: 2)
        attach("talk-call")
        let minimise = app.buttons["Minimise"].firstMatch
        XCTAssertTrue(minimise.waitForExistence(timeout: 10), "no Minimise")
        minimise.tap()
        Thread.sleep(forTimeInterval: 1)
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "talk-toolbar")
        try newChatFromList(in: app)
        try expectComposer(in: app, "talk-list")
        end.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 10), "the call didn't end")
        try expectComposer(in: app, "talk-ended")
    }

    /// At the largest Dynamic Type size, by the toolbar and by the list.
    @MainActor
    func testANewChatAtTheLargestTextSizeShowsTheComposer() throws {
        let app = launch(["-HERMES_SEND", "hello there",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        try waitForSent("hello there", in: app)
        try newChatFromToolbar(in: app)
        try expectComposer(in: app, "largest-text-toolbar")
        try newChatFromList(in: app)
        try expectComposer(in: app, "largest-text-list")
    }

    // MARK: Helpers

    /// The composer's field, typed into and on screen above the keyboard, and the composer's
    /// trailing button with it: a bar that keeps its room and draws nothing has neither.
    @MainActor
    private func expectComposer(in app: XCUIApplication, _ name: String) throws {
        let field = try composerField(in: app)
        try expect(timeout: 10, "\(name): the composer's field isn't on screen") { field.isHittable }
        let window = app.windows.firstMatch.frame
        let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : window.maxY
        XCTAssertTrue(field.frame.height >= 20 && field.frame.minY >= window.minY && field.frame.maxY <= keyboardTop + 1,
                      "\(name): the composer's field sits at \(field.frame), outside \(window) above \(keyboardTop)")
        // Stop while a turn runs (the chat with the card), Talk or Send otherwise.
        let action = app.buttons.matching(NSPredicate(format: "label IN {'Talk', 'Send', 'Stop'}")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isHittable, "\(name): no Talk, Send or Stop button")
        attach(name)
    }

    @MainActor
    private func composerField(in app: XCUIApplication) throws -> XCUIElement {
        let view = app.textViews.firstMatch
        if view.waitForExistence(timeout: 15) { return view }
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.exists, "no composer field")
        return field
    }

    @MainActor
    private func waitForSent(_ text: String, in app: XCUIApplication) throws {
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "the chat didn't open")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func newChatFromToolbar(in app: XCUIApplication) throws {
        let button = app.buttons["New chat"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "no New chat in the toolbar")
        button.tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// New Chat on the chat list: in the drawer behind Show Sidebar on builds that have one,
    /// otherwise on the list the back button returns to.
    @MainActor
    private func newChatFromList(in app: XCUIApplication) throws {
        let drawer = app.buttons["Show sidebar"].firstMatch
        if drawer.exists {
            drawer.tap()
            let row = app.buttons["New Chat"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "no New Chat in the drawer")
            Thread.sleep(forTimeInterval: 0.5)
            row.tap()
        } else {
            let compose = app.buttons["sidebar.compose"].firstMatch
            if !compose.isHittable, UIDevice.current.userInterfaceIdiom == .phone {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button")
                back.tap()
            }
            XCTAssertTrue(compose.waitForExistence(timeout: 10), "no New Chat on the chat list")
            // In Bots mode the list's compose button makes Bots, so a new chat starts from Chats.
            let chats = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Chats'")).firstMatch
            if compose.label == "New", chats.exists {
                chats.tap()
                try expect(timeout: 5, "the list didn't switch to Chats") { compose.label == "New Chat" }
            }
            try expect(timeout: 5, "New Chat isn't on screen") { compose.isHittable }
            compose.tap()
        }
        Thread.sleep(forTimeInterval: 1)
    }

    /// Opens the first chat with a message in it, from wherever the list is.
    @MainActor
    private func openFirstChat(in app: XCUIApplication) throws {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'approve the cleanup'")).firstMatch
        let drawer = app.buttons["Show sidebar"].firstMatch
        var turned = false
        if drawer.exists {
            drawer.tap()
        } else if UIDevice.current.userInterfaceIdiom == .phone {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else if !row.exists {
            // An upright iPad puts the sidebar away; turned, it sits beside the chat.
            XCUIDevice.shared.orientation = .landscapeLeft
            turned = true
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no row for the chat with the card")
        row.tap()
        Thread.sleep(forTimeInterval: 1)
        if turned {
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    @MainActor
    private func openModelSheet(in app: XCUIApplication) throws {
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Model: '")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15), "no model picker")
        picker.tap()
        XCTAssertTrue(app.navigationBars["Model"].waitForExistence(timeout: 10), "the model sheet didn't open")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func closeModelSheet(in app: XCUIApplication) {
        let done = app.navigationBars["Model"].buttons["Done"]
        if done.exists { done.tap() }
        _ = app.navigationBars["Model"].waitForNonExistence(timeout: 5)
    }

    @MainActor
    private func expect(timeout: TimeInterval, _ message: @autoclosure () -> String, _ check: () -> Bool) throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, !check() { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(check(), message())
    }

    /// Drags from the middle of an element by `dy` points. A coordinate drag, because on a turned
    /// iPhone the card's texts are drawn but read an empty visible frame in its clipped scroll
    /// view, so XCUITest refuses to swipe them.
    @MainActor
    private func drag(_ element: XCUIElement, by dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)))
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(_ arguments: [String], checklist: Bool = true) -> XCUIApplication {
        let bundle = Bundle(for: NewChatComposerUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", setting("HermesMockGateway", "http://127.0.0.1:18642"),
            "-HERMES_BOOTSTRAP_KEY", "dev-key-0123456789abcdef",
            "-HERMES_BOOTSTRAP_BACKEND", setting("HermesMockBackend", "http://127.0.0.1:19119"),
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO", "-HERMES_PASTEBOARD", "none",
            "-push.primeDeclines", "2", "-welcome.checklist.hidden", checklist ? "NO" : "YES",
        ] + arguments
        app.launch()
        // The ask to install the app's plugin, on a fresh install.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        return app
    }
}
