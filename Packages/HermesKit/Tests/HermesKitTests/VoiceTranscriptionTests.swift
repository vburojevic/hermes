import Foundation
import Testing
@testable import HermesKit

struct VoiceTranscriptionTests {
    @Test func wordsSettleItAndAnEmptyTranscriptIsNoWords() {
        #expect(VoiceTranscription.outcome(of: .success("  Check the NAS.\n")) == .settled(.heard("Check the NAS.")))
        #expect(VoiceTranscription.outcome(of: .success("")) == .settled(.noWords))
        #expect(VoiceTranscription.outcome(of: .success(" \n")) == .settled(.noWords))
    }

    @Test func aGatewayThatDidntAnswerIsAskedAgain() {
        let away: [any Error] = [
            HermesError.unreachable(host: "mac.local", reason: .cannotConnect),
            HermesError.gatewayRestarting,
            BackendClient.Failure.http(503, nil),
            BackendClient.Failure.http(504, "Gateway Timeout"),
            BackendClient.Failure.rateLimited,
            URLError(.networkConnectionLost),
        ]
        for error in away {
            #expect(VoiceTranscription.outcome(of: .failure(error)) == .tryAgain)
        }
    }

    @Test func hermesRefusingItIsAFailureWithItsFirstSentence() {
        let noProvider = BackendClient.Failure.http(400, "No STT provider available. Install faster-whisper for free local transcription, configure HERMES_LOCAL_STT_COMMAND …")
        #expect(VoiceTranscription.outcome(of: .failure(noProvider)) == .settled(.failed("No STT provider available.")))
        let provider = BackendClient.Failure.http(500, "Transcription failed: quota exceeded")
        #expect(VoiceTranscription.outcome(of: .failure(provider)) == .settled(.failed("Transcription failed: quota exceeded.")))
        // A setting on this device isn't waited out either.
        let local = HermesError.unreachable(host: "mac.local", reason: .localNetworkDenied)
        if case .settled(.failed) = VoiceTranscription.outcome(of: .failure(local)) {} else {
            Issue.record("a denied local network should fail, not wait")
        }
    }

    @Test func stopIsNotAFailure() {
        #expect(VoiceTranscription.outcome(of: .failure(CancellationError())) == .cancelled)
    }

    @Test func onlyHeardWordsGoWithTheMessage() {
        #expect(VoiceTranscription.heard("Hello").words == "Hello")
        #expect(VoiceTranscription.noWords.words.isEmpty)
        #expect(VoiceTranscription.failed("No STT provider available.").words.isEmpty)
        #expect(VoiceTranscription.pending.words.isEmpty)
    }

    @Test func theBubbleSaysWhyThereAreNoWordsButNotWhileTheyreComing() {
        #expect(VoiceTranscription.note(text: "Check the NAS.", state: .failed("x")) == nil)
        #expect(VoiceTranscription.note(text: "", state: .pending) == nil)
        #expect(VoiceTranscription.note(text: "", state: .noWords) == "No words were heard in it.")
        #expect(VoiceTranscription.note(text: "", state: .failed("No STT provider available.")) == "Couldn't transcribe it. No STT provider available.")
        #expect(VoiceTranscription.note(text: "", state: .failed("")) == "Couldn't transcribe it.")
        #expect(VoiceTranscription.note(text: "", state: nil) == "No transcript.")
    }

    @Test func voiceOverHearsTheLengthThenTheWordsOrWhatBecameOfThem() {
        #expect(VoiceTranscription.spokenLabel(duration: "0:07", text: "Check the NAS.", state: nil) == "Your voice message, 0:07: Check the NAS.")
        #expect(VoiceTranscription.spokenLabel(duration: "0:07", text: "", state: .pending) == "Your voice message, 0:07, transcribing")
        // The words are back before the row Hermes stored is.
        #expect(VoiceTranscription.spokenLabel(duration: "0:07", text: "", state: .heard("Check the NAS.")) == "Your voice message, 0:07: Check the NAS.")
        #expect(VoiceTranscription.spokenLabel(duration: nil, text: "", state: .noWords) == "Your voice message. No words were heard in it.")
    }

    @Test @MainActor func oneStateForTheRecordingHereAndItsPathOnTheGateway() {
        let store = VoiceTranscripts()
        let name = VoiceMessageFile.name()
        store.set(.pending, for: name)
        #expect(store.state(for: "/home/hermes/attachments/\(name)") == .pending)
        store.set(.heard("Hi"), for: "/home/hermes/attachments/\(name.uppercased())")
        #expect(store.state(for: name) == .heard("Hi"))
        store.set(nil, for: name)
        #expect(store.state(for: name) == nil)
    }
}
