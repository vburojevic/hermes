import Foundation
import Testing
@testable import HermesKit

/// Hey Hermes (`docs/voice.md` §4.6): Hermes's `wake.*` answers, the frames `wake.feed` takes, and
/// what the setup says.
struct WakeWordTests {
    private func json(_ text: String) -> JSONValue {
        JSONValue.parse(Data(text.utf8))!
    }

    @Test func startAndRefusals() {
        let started = WakeStart(json: json(#"{"started":true,"phrase":"hey hermes","capture":"client","sample_rate":16000,"frame_length":1280}"#))
        #expect(started.started && started.refusal == nil && !started.listensLocally)
        #expect(WakeStart(json: json(#"{"started":true,"capture":"local"}"#)).listensLocally)
        #expect(WakeStart(json: json(#"{"started":false,"reason":"unavailable","hint":"pip install pyopen-wakeword"}"#)).refusal == .unavailable("pip install pyopen-wakeword"))
        #expect(WakeStart(json: json(#"{"started":false,"reason":"disabled"}"#)).refusal == .disabled)
        #expect(WakeStart(json: json(#"{"started":false,"reason":"disabled_for_surface"}"#)).refusal == .otherSurface)
        #expect(WakeStart(json: json(#"{"started":false,"reason":"owned","owner_surface":"tui"}"#)).refusal == .owned("tui"))
    }

    @Test func statusAndDetection() {
        let state = WakeState(status: json(#"{"listening":true,"owned_by_caller":false,"owner_surface":"tui","available":true,"enabled":true,"configured_surface":"auto","capture":"client","frame_length":1280}"#))
        #expect(state.heldElsewhere && !state.keptForOtherSurface)
        #expect(WakeState(status: json(#"{"available":true,"enabled":true,"configured_surface":"tui"}"#)).keptForOtherSurface)

        #expect(WakeDetection(payload: json(#"{"phrase":"hey research","profile":"researcher","start_new_session":true}"#))
            == WakeDetection(phrase: "hey research", profile: "researcher"))
        #expect(WakeDetection(payload: json(#"{"phrase":"hey hermes","profile":null,"start_new_session":false}"#))?.profile == nil)
        #expect(WakeDetection(payload: nil) == nil)
    }

    @Test func framesGoFourAtATime() {
        var frames = WakeFrames(frameLength: 1_280)
        // 1,280 samples of int16 a frame, four a call: 10,240 bytes.
        #expect(frames.append(Data(count: 10_000)).isEmpty)
        let batches = frames.append(Data(count: 10_000 + 10_240))
        #expect(batches.map(\.count) == [10_240, 10_240])
        // 9,760 bytes wait; 480 more make a whole batch.
        #expect(frames.append(Data(count: 240)).isEmpty)
        #expect(frames.append(Data(count: 240)).count == 1)
    }

    @Test func setupStates() {
        func status(_ wake: WakeState?, pause: String? = nil) -> SetupStatus {
            var facts = VoiceFacts()
            facts.wantsWake = true
            facts.wake = wake
            facts.wakePause = pause
            return VoiceSetupRules.statuses(facts, device: "iPhone").last!
        }
        // Only for the gateway's own profile, and only when it's on.
        #expect(VoiceSetupRules.statuses(VoiceFacts(), device: "iPhone").allSatisfy { $0.id != "voice.wake" })
        var bot = VoiceFacts()
        bot.wantsWake = true
        #expect(VoiceSetupRules.statuses(bot, device: "iPhone", profile: "researcher").allSatisfy { !$0.id.hasPrefix("voice.wake") })

        #expect(status(WakeState(listening: true, ownedByCaller: true)).state == .ready)
        #expect(status(WakeState(listening: true, ownedByCaller: true)).detail == "Listening for “Hey Hermes”")
        #expect(status(WakeState(capture: "local")).detail == "The gateway's own microphone listens for “Hey Hermes”")

        let off = status(WakeState(enabled: false))
        #expect(off.state == .notSetUp && off.fix?.title == "Turn On")
        #expect(off.steps.map(\.command) == ["hermes config set wake_word.enabled true"])

        let missing = status(WakeState(available: false, hint: "Install openWakeWord on the gateway."))
        #expect(missing.state == .notSetUp && missing.detail == "Install openWakeWord on the gateway.")

        #expect(status(WakeState(listening: true, ownedByCaller: false, ownerSurface: "tui")).state == .limited)
        #expect(status(WakeState(configuredSurface: "tui")).steps.map(\.command) == ["hermes config set wake_word.surface auto"])
        #expect(status(WakeState(), pause: "Listens while this iPhone is charging and Hermes is open").state == .limited)
        #expect(status(nil).state == .unknown)
    }
}
