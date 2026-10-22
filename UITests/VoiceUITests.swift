import XCTest

/// Voice against the mock (`docs/voice.md` §12): a voice message's round trip, a Bot's audio, and
/// a Talk call answered by voice. The microphone is the simulated one: spoken clips from
/// `Tools/mock-hermes/voice` (`-HERMES_VOICE_INPUT`), whose words come from the `.txt` beside each.
/// Start the mock first: `python3 -I Tools/mock-hermes/backend.py --port 19119 --gateway-port 18642`.
final class VoiceUITests: XCTestCase {
    private let mock = VoiceMock()

    override func setUp() async throws {
        continueAfterFailure = false
        try await mock.reset()
    }

    /// Hold the microphone, speak, let go: the transcript is the message, the recording goes with
    /// it (file.attach), and the chat draws it as a voice message.
    @MainActor
    func testVoiceMessageRoundTrip() async throws {
        let app = launch(["-HERMES_OPEN", "bot:researcher", "-HERMES_VOICE_INPUT", mock.clip("weekly", at: 0.4)])
        openResearchBuddy(in: app)
        let microphone = app.buttons["Dictate"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 30), "no microphone in the composer")
        microphone.press(forDuration: 6)

        // The transcript is the message (the chat may hold voice messages from earlier runs).
        let bubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Your voice message' AND label CONTAINS 'keep the weekly ones'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "no voice message with its transcript")
        try await eventually(timeout: 20) {
            try await self.mock.files().contains { ($0 as NSString).lastPathComponent.hasPrefix("voice-") && $0.hasSuffix(".m4a") }
        }
    }

    /// A Bot's text_to_speech reply plays as a strip before its words.
    @MainActor
    func testBotAudioReplyShowsAStrip() async throws {
        let app = launch([
            "-HERMES_OPEN", "bot:researcher",
            "-HERMES_SEND_HERE", "Send me the roundup as audio.", "-HERMES_SEND_HERE_AFTER", "6", "-HERMES_SEND_HERE_ROUNDS", "1",
        ])
        openResearchBuddy(in: app)
        let strip = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Voice message'")).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 60), "no listen strip for the Bot's audio")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'summary you asked for'")).firstMatch.exists,
                      "the reply's words didn't follow the strip")
    }

    /// A call as a Shortcut starts one: "Check the disk space on the NAS" is a voice turn, the
    /// approval is asked aloud and answered "Allow once", and the reply is spoken.
    @MainActor
    func testTalkApprovalAnsweredByVoice() async throws {
        let app = launch([
            "-HERMES_TALK_TO", "researcher",
            "-HERMES_VOICE_INPUT", mock.clip("check-nas", at: 2) + "," + mock.clip("allow-once", at: 16),
        ])
        XCTAssertTrue(app.buttons["End call"].waitForExistence(timeout: 60), "no call")
        try await eventually(timeout: 90) {
            let audio = try await self.mock.audio()
            return audio.spoken.contains { $0.contains("Freed 14 GB") }
        }
        let audio = try await mock.audio()
        XCTAssertTrue(audio.turns.contains("Check the disk space on the NAS."), "the turn wasn't a voice turn: \(audio.turns)")
        XCTAssertTrue(audio.spoken.contains { $0.contains("I need your OK") }, "the approval wasn't asked aloud")
        app.buttons["End call"].tap()
    }

    /// "Stop" said over a long reply stops it (`TalkEars`): the Bot dips as the word starts, stops
    /// when it's heard, and the rest of the reply is never asked of the gateway's voice.
    @MainActor
    func testTalkStopCutsALongReply() async throws {
        let app = launch([
            "-HERMES_TALK_TO", "researcher",
            "-HERMES_VOICE_INPUT", mock.clip("essay", at: 2) + "," + mock.clip("stop", at: 12),
        ])
        XCTAssertTrue(app.buttons["End call"].waitForExistence(timeout: 60), "no call")
        try await eventually(timeout: 60) {
            try await self.mock.audio().spoken.contains { $0.contains("Swift 6") }
        }
        // Long enough for the whole reply to have been read, had it not been stopped.
        try await Task.sleep(for: .seconds(40))
        let audio = try await mock.audio()
        XCTAssertTrue(audio.turns.contains("Write me a short essay about backups."), "the turn wasn't a voice turn: \(audio.turns)")
        XCTAssertFalse(audio.spoken.contains { $0.contains("report the warning count") }, "the reply was read to its end")
        XCTAssertFalse(audio.turns.contains { $0.lowercased().hasPrefix("stop") }, "“stop” was sent to Hermes")
        app.buttons["End call"].tap()
    }

    /// A TV as loud as the person, playing over a long reply (`loud-tv`: three voices, no words for
    /// the transcriber): the Bot may dip, but it reads to the end, nothing is sent, and the call
    /// says the room is loud and offers Voice Isolation.
    @MainActor
    func testTalkNoiseNeverStopsTheReply() async throws {
        let app = launch([
            "-HERMES_TALK_TO", "researcher",
            "-HERMES_VOICE_INPUT", mock.clip("essay", at: 2) + "," + mock.clip("loud-tv", at: 12),
        ])
        XCTAssertTrue(app.buttons["End call"].waitForExistence(timeout: 60), "no call")
        XCTAssertTrue(app.buttons["Use Voice Isolation"].waitForExistence(timeout: 40), "the loud room wasn't noticed")
        try await eventually(timeout: 120) {
            try await self.mock.audio().spoken.contains { $0.contains("report the warning count") }
        }
        let audio = try await mock.audio()
        XCTAssertEqual(audio.turns, ["Write me a short essay about backups."], "noise was sent as a turn")
        app.buttons["End call"].tap()
    }

    /// Transcribe on: The gateway: a turn's words come from `transcribe-stream` (16 kHz, one socket
    /// per turn); when the provider drops a turn, it goes to `POST /api/audio/transcribe` whole.
    @MainActor
    func testTalkTranscribedByTheGateway() async throws {
        try await mock.switchAudio(["stt_streaming": true, "transcript": "What's on my calendar today?"])
        let app = launch([
            "-HERMES_TALK_TO", "researcher", "-voice.transcribeOn", "gateway",
            "-HERMES_VOICE_INPUT", mock.clip("check-nas", at: 2) + "," + mock.clip("allow-once", at: 24),
        ])
        XCTAssertTrue(app.buttons["End call"].waitForExistence(timeout: 60), "no call")
        try await eventually(timeout: 90) {
            try await self.mock.audio().turns.contains("What's on my calendar today?")
        }
        let live = try await mock.live()
        XCTAssertEqual(live.first?["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(live.first?["ended"] as? String, "final")

        // The provider drops the next turn: it's sent whole and still arrives.
        try await mock.switchAudio(["stt_live_fail": "live transcription failed: connection reset", "transcript": "Allow once."])
        try await eventually(timeout: 90) {
            try await self.mock.audio().turns.contains("Allow once.")
        }
        let whole = try await mock.whole()
        XCTAssertFalse(whole.isEmpty, "the dropped turn wasn't sent whole")
        app.buttons["End call"].tap()
    }

    /// Hey Hermes: the microphone streams to the gateway's wake word (`wake.feed`), `wake.detected`
    /// opens a call, and the detector listens again after it (`wake.resume`). Simulated
    /// microphone and charging only.
    @MainActor
    func testHeyHermesStartsACall() async throws {
        try await mock.wake(["enabled": true, "detect_after": 1.0])
        let app = launch([
            "-voice.heyHermes", "YES", "-HERMES_CHARGING", "YES",
            "-HERMES_VOICE_INPUT", mock.clip("check-nas", at: 0.5),
        ])
        XCTAssertTrue(app.buttons["End call"].waitForExistence(timeout: 90), "the wake word didn't start a call")
        let heard = try await mock.wakeState()
        XCTAssertGreaterThanOrEqual(heard["detections"] as? Int ?? 0, 1)
        XCTAssertGreaterThan(heard["feeds"] as? Int ?? 0, 0)
        app.buttons["End call"].tap()
        try await eventually(timeout: 30) {
            (try await self.mock.wakeState()["resumes"] as? Int ?? 0) >= 1
        }
    }

    /// Voice & Audio says what the gateway lacks and takes the key: ElevenLabs without its key is
    /// "Partly set up"; a refused key shows Hermes's reason; a saved one makes Listen ready.
    @MainActor
    func testSetupShowsAMissingKeyAndTakesIt() async throws {
        try await mock.setSpeechProvider("elevenlabs")
        try await mock.switchAudio(["env_refusal": "ELEVENLABS_API_KEY is managed by your administrator"])
        // The plugin ask takes the Settings sheet's place on a fresh install: answer it once first.
        launch([]).terminate()
        let app = launch(["-HERMES_OPEN", "settings"])
        let row = app.buttons["Voice & Audio"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Voice & Audio in Settings")
        row.tap()

        let missing = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ELEVENLABS_API_KEY'")).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 30), "the missing key isn't named")
        let addKey = app.buttons["Add Key…"].firstMatch
        XCTAssertTrue(addKey.waitForExistence(timeout: 5))
        addKey.tap()
        let field = app.secureTextFields["ELEVENLABS_API_KEY"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("sk-test-not-real")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["ELEVENLABS_API_KEY is managed by your administrator"].waitForExistence(timeout: 10),
                      "the gateway's refusal isn't shown")

        try await mock.switchAudio(["env_refusal": ""])
        app.buttons["Save"].tap()
        XCTAssertTrue(missing.waitForNonExistence(timeout: 20), "Listen still says the key is missing")
        try await eventually(timeout: 10) { try await self.mock.keysSet().contains("ELEVENLABS_API_KEY") }
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-HERMES_BOOTSTRAP_URL", mock.gateway.absoluteString, "-HERMES_BOOTSTRAP_KEY", mock.key,
            "-HERMES_BOOTSTRAP_BACKEND", mock.backend.absoluteString,
            "-HERMES_TIPS", "hide", "-HERMES_WHATS_NEW", "NO",
        ] + arguments
        app.launch()
        addTeardownBlock { @MainActor in Self.endCallLeftRunning(in: app) }
        // The ask to install the app's plugin, on a fresh install.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 8) { notNow.tap() }
        return app
    }

    /// `-HERMES_OPEN bot:` can land on the Bots page before the roster has the Bot: open it.
    @MainActor
    private func openResearchBuddy(in app: XCUIApplication) {
        guard !app.buttons["Dictate"].waitForExistence(timeout: 12) else { return }
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Research Buddy'")).firstMatch
        if card.waitForExistence(timeout: 10) { card.tap() }
    }

    /// A test that fails or stops mid-call leaves its call running when the app is stopped, and
    /// the call's Live Activity stays. Installing the next build then makes the system launch the
    /// app for it just as the next run's first test launches it, and that test gets the system's
    /// launch, without its arguments: no call. So the call ends here, whatever happened.
    @MainActor
    private static func endCallLeftRunning(in app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let end = app.buttons["End call"]
        // A call the test just ended is still closing: give it the moment.
        guard !end.waitForNonExistence(timeout: 3) else { return }
        end.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 10), "the call didn't end")
    }

    private func eventually(timeout: TimeInterval, _ check: @escaping () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("timed out after \(Int(timeout)) s")
    }
}

/// The mock's audio side: what was spoken and sent.
private struct VoiceMock {
    let gateway: URL
    let backend: URL
    let clips: String
    let key = "dev-key-0123456789abcdef"

    init() {
        let bundle = Bundle(for: VoiceUITests.self)
        func setting(_ key: String, _ fallback: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        gateway = URL(string: setting("HermesMockGateway", "http://127.0.0.1:18642"))!
        backend = URL(string: setting("HermesMockBackend", "http://127.0.0.1:19119"))!
        clips = setting("HermesVoiceClips", "")
    }

    func clip(_ name: String, at seconds: Double) -> String {
        "\(clips)/\(name).m4a@\(seconds)"
    }

    private func token() async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: backend)
        let page = String(decoding: data, as: UTF8.self)
        guard let start = page.range(of: "__HERMES_SESSION_TOKEN__=\"")?.upperBound,
              let end = page[start...].firstIndex(of: "\"") else { throw URLError(.userAuthenticationRequired) }
        return String(page[start..<end])
    }

    private func request(_ path: String, method: String = "GET") async throws -> Data {
        var request = URLRequest(url: backend.appending(path: path))
        request.httpMethod = method
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        return try await URLSession.shared.data(for: request).0
    }

    func reset() async throws {
        _ = try await request("api/mock/audio/reset", method: "POST")
    }

    func audio() async throws -> (turns: [String], spoken: [String]) {
        let json = try JSONSerialization.jsonObject(with: try await request("api/mock/audio/turns")) as? [String: Any] ?? [:]
        let turns = (json["turns"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let spoken = (json["spoken"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return (turns, spoken)
    }

    func setSpeechProvider(_ provider: String) async throws {
        var request = URLRequest(url: backend.appending(path: "api/config"))
        request.httpMethod = "PUT"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["config": ["tts": ["provider": provider]]])
        _ = try await URLSession.shared.data(for: request)
    }

    func switchAudio(_ switches: [String: Any]) async throws {
        var request = URLRequest(url: backend.appending(path: "api/mock/audio"))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: switches)
        _ = try await URLSession.shared.data(for: request)
    }

    func keysSet() async throws -> Set<String> {
        let json = try JSONSerialization.jsonObject(with: try await request("api/env")) as? [String: [String: Any]] ?? [:]
        return Set(json.compactMap { key, row in (row["is_set"] as? Bool) == true ? key : nil })
    }

    func wake(_ switches: [String: Any]) async throws {
        var request = URLRequest(url: backend.appending(path: "api/mock/wake"))
        request.httpMethod = "POST"
        request.setValue(try await token(), forHTTPHeaderField: "X-Hermes-Session-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: switches)
        _ = try await URLSession.shared.data(for: request)
    }

    func wakeState() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try await request("api/mock/wake")) as? [String: Any] ?? [:]
    }

    /// transcribe-stream's turns: sample_rate, bytes and how each ended.
    func live() async throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: try await request("api/mock/audio/turns")) as? [String: Any] ?? [:]
        return json["live"] as? [[String: Any]] ?? []
    }

    /// Turns sent whole to `POST /api/audio/transcribe`.
    func whole() async throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: try await request("api/mock/audio/turns")) as? [String: Any] ?? [:]
        return json["whole"] as? [[String: Any]] ?? []
    }

    func files() async throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: try await request("api/mock/audio/turns")) as? [String: Any] ?? [:]
        return json["files"] as? [String] ?? []
    }
}
