import Foundation
import Testing
@testable import HermesKit

struct VoiceMediaTests {
    @Test func audioLinesBecomeAudio() {
        let reply = AgentAudio.split("Here's the summary.\nMEDIA:/tmp/tts/summary.mp3\nMEDIA:/tmp/out/chart.png")
        #expect(reply.audio == [AgentAudio(path: "/tmp/tts/summary.mp3", isVoice: false)])
        #expect(reply.text == "Here's the summary.\nMEDIA:/tmp/out/chart.png")
        #expect(TranscriptBuilder.cleanAssistantText(reply.text) == "Here's the summary.\n*Attachment on server: chart.png*")
    }

    @Test func voiceMarkerAppliesToTheWholeMessageAndOnlyToAudio() {
        let reply = AgentAudio.split("[[audio_as_voice]]\nMEDIA:`/tmp/tts/reply.ogg`\nMEDIA:/tmp/out/notes.pdf")
        #expect(reply.audio == [AgentAudio(path: "/tmp/tts/reply.ogg", isVoice: true)])
        #expect(!reply.text.contains("audio_as_voice"))
        #expect(reply.text.contains("notes.pdf"))
    }

    @Test func examplesInCodeAreNotPlayed() {
        let reply = AgentAudio.split("Send it like this:\n```\nMEDIA:/tmp/example.mp3\n```")
        #expect(reply.audio.isEmpty)
        #expect(reply.text.contains("MEDIA:/tmp/example.mp3"))
    }

    @Test func sameFileOnce() {
        let reply = AgentAudio.split("MEDIA:/a/b.m4a\nAgain:\nMEDIA:/a/b.m4a")
        #expect(reply.audio.count == 1)
    }

    @Test func plainTextUntouched() {
        #expect(AgentAudio.split("Nothing to play.").text == "Nothing to play.")
    }

    @Test func voiceMessageFiles() {
        let name = VoiceMessageFile.name()
        #expect(name.hasPrefix("voice-") && name.hasSuffix(".m4a"))
        #expect(VoiceMessageFile.isVoiceMessage(name))
        #expect(!VoiceMessageFile.isVoiceMessage("voice-notes.m4a"))
        #expect(!VoiceMessageFile.isVoiceMessage("report.m4a"))
        let text = "Check the NAS tonight\n\n@file:/Users/sam/.hermes/uploads/\(name)"
        #expect(VoiceMessageFile.path(in: text) == "/Users/sam/.hermes/uploads/\(name)")
        #expect(VoiceMessageFile.path(in: "@file:/tmp/report.pdf") == nil)
    }

    @Test func voiceMessageRowsCarryTheirRecording() throws {
        let name = VoiceMessageFile.name()
        let message = try JSONDecoder().decode(SessionMessage.self, from: Data("""
        {"id": 7, "role": "user", "content": "Check the NAS tonight\\n\\n@file:/srv/uploads/\(name)"}
        """.utf8))
        let entry = TranscriptBuilder.userEntry(id: "7", message: message)
        #expect(entry.voicePath == "/srv/uploads/\(name)")
        #expect(entry.fileNames.isEmpty)
        #expect(entry.text == "Check the NAS tonight")
    }
}

struct WaveformTests {
    @Test func barsKeepTheLoudestOfTheirShare() {
        #expect(Waveform.bars([0.1, 0.9, 0.2, 0.3], count: 2) == [0.9, 0.3])
        #expect(Waveform.bars([0.5], count: 3) == [0.5, 0.5, 0.5])
        #expect(Waveform.bars([], count: 2) == [0, 0])
        #expect(Waveform.bars([0.1, 0.2], count: 0).isEmpty)
    }

    @Test func times() {
        #expect(Waveform.time(7.9) == "0:07")
        #expect(Waveform.time(83) == "1:23")
        #expect(Waveform.time(600) == "10:00")
        #expect(Waveform.time(-1) == "0:00")
    }
}

struct VoiceRepliesTests {
    private func user(_ id: String, voice: Bool) -> TranscriptItem {
        var entry = UserEntry(id: id, text: "words")
        if voice { entry.voicePath = VoiceMessageFile.name() }
        return .user(entry)
    }

    private func reply(_ id: String) -> TranscriptItem {
        .assistant(AssistantTurn(id: id))
    }

    @Test func repliesToVoiceMessagesOnly() {
        let items = [user("1", voice: true), reply("a"), user("2", voice: false), reply("b"), user("3", voice: true), reply("c")]
        #expect(VoiceReplies.turns(in: items, setting: .whenISpeak) == ["a", "c"])
        #expect(VoiceReplies.turns(in: items, setting: .always) == ["a", "b", "c"])
        #expect(VoiceReplies.turns(in: items, setting: .never).isEmpty)
    }
}

struct VoiceFactsTests {
    @Test func keysAreMissingOnlyWhenTheProviderNeedsOne() {
        #expect(VoiceFacts(speechProvider: "edge").missingSpeechKey == nil)
        #expect(VoiceFacts(speechProvider: "elevenlabs").missingSpeechKey == "ELEVENLABS_API_KEY")
        #expect(VoiceFacts(speechProvider: "elevenlabs", keysSet: ["ELEVENLABS_API_KEY"]).missingSpeechKey == nil)
        // OpenAI takes either of its keys.
        #expect(VoiceFacts(speechProvider: "openai", keysSet: ["VOICE_TOOLS_OPENAI_KEY"]).missingSpeechKey == nil)
        #expect(VoiceFacts(speechProvider: "openai").missingSpeechKey == "OPENAI_API_KEY")
        #expect(VoiceFacts(transcriptionProvider: "groq").missingTranscriptionKey == "GROQ_API_KEY")
        #expect(VoiceFacts(transcriptionProvider: "local").missingTranscriptionKey == nil)
    }

    @Test func aFailureMeansTheGatewayDoesntSpeak() {
        #expect(VoiceFacts().gatewaySpeaks)
        #expect(!VoiceFacts(lastSpeechFailure: "The provider timed out.").gatewaySpeaks)
    }
}

struct VoiceSetupRulesTests {
    @Test func everythingSetUp() {
        let facts = VoiceFacts(speechProvider: "elevenlabs", speechVoice: "Adam", realtimeVoice: "cedar",
                               keysSet: ["ELEVENLABS_API_KEY", "OPENAI_API_KEY"], realtimeAvailable: true)
        let statuses = VoiceSetupRules.statuses(facts, device: "iPhone")
        #expect(statuses.map(\.state) == [.ready, .ready, .ready])
        #expect(statuses[0].detail == "Realtime · Cedar")
        #expect(statuses[1].detail == "ElevenLabs · Adam")
    }

    @Test func noRealtimeFallsBackToHermesVoiceAndSaysWhy() {
        let facts = VoiceFacts(realtimeReason: "no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)")
        let talk = VoiceSetupRules.statuses(facts, device: "iPhone")[0]
        #expect(talk.state == .limited)
        #expect(talk.fallback?.contains("no OpenAI API key") == true)
        #expect(talk.fix?.title == "Add OpenAI Key…")
        #expect(talk.steps.first?.command == "hermes config set OPENAI_API_KEY <your key>")
    }

    @Test func aMissingKeyMeansTheDevicesVoice() {
        let facts = VoiceFacts(speechProvider: "elevenlabs")
        let statuses = VoiceSetupRules.statuses(facts, device: "iPhone", profile: "researcher")
        #expect(statuses[1].id == "voice.listen@researcher")
        #expect(statuses[1].state == .limited)
        #expect(statuses[1].detail == "In this iPhone's voice")
        #expect(statuses[1].fallback == "Replies are read in this iPhone's voice: ElevenLabs needs ELEVENLABS_API_KEY on the gateway.")
        #expect(statuses[1].steps.map(\.command) == ["hermes -p researcher config set ELEVENLABS_API_KEY <your key>",
                                                     "hermes -p researcher config set tts.provider edge"])
        #expect(statuses[0].detail == "Hermes Voice, in this iPhone's voice")
    }

    @Test func transcriptionKey() {
        let messages = VoiceSetupRules.statuses(VoiceFacts(transcriptionProvider: "groq"), device: "Mac")[2]
        #expect(messages.state == .limited)
        #expect(messages.fallback?.contains("Groq needs GROQ_API_KEY") == true)
        let local = VoiceSetupRules.statuses(VoiceFacts(), device: "Mac")[2]
        #expect(local.state == .ready)
        #expect(local.detail == "On this Mac, with Whisper on the gateway as a backup")
    }

    @Test func liveTranscriptionOnlyWhenChosen() {
        #expect(VoiceSetupRules.statuses(VoiceFacts(), device: "iPhone").count == 3)
        let chosen = VoiceSetupRules.statuses(VoiceFacts(wantsLiveTranscription: true), device: "iPhone")
        #expect(chosen.count == 4)
        #expect(chosen[3].id == "voice.transcription")
    }

    @Test func liveTranscriptionStates() {
        func status(_ facts: VoiceFacts) -> SetupStatus {
            var facts = facts
            facts.wantsLiveTranscription = true
            return VoiceSetupRules.statuses(facts, device: "iPhone", profile: "researcher")[3]
        }
        let ready = status(VoiceFacts(transcriptionProvider: "openai", keysSet: ["OPENAI_API_KEY"], liveTranscriptionOn: true, liveTranscriptionAvailable: true))
        #expect(ready.state == .ready)
        #expect(ready.detail == "OpenAI, as you speak")

        let local = status(VoiceFacts())
        #expect(local.state == .limited)
        #expect(local.fallback == "Talk transcribes on this iPhone: Whisper can't transcribe as you speak.")
        #expect(local.fix == nil)
        #expect(local.steps.map(\.command) == ["hermes -p researcher config set stt.provider openai",
                                               "hermes -p researcher config set OPENAI_API_KEY <your key>",
                                               "hermes -p researcher config set stt.streaming true"])

        let noKey = status(VoiceFacts(transcriptionProvider: "elevenlabs"))
        #expect(noKey.fix?.title == "Add Key…")
        #expect(noKey.fallback?.contains("ElevenLabs needs ELEVENLABS_API_KEY") == true)

        let off = status(VoiceFacts(transcriptionProvider: "xai", keysSet: ["XAI_API_KEY"]))
        #expect(off.fix?.title == "Turn On")
        #expect(off.steps.map(\.command) == ["hermes -p researcher config set stt.streaming true"])

        let failed = status(VoiceFacts(transcriptionProvider: "openai", keysSet: ["OPENAI_API_KEY"], liveTranscriptionOn: true,
                                       liveTranscriptionAvailable: true, lastTranscriptionFailure: "live transcription failed: 401"))
        #expect(failed.state == .limited)
        #expect(failed.fallback == "Talk transcribes on this iPhone: live transcription failed: 401.")
    }
}

struct TranscribeStreamTests {
    @Test func messages() {
        #expect(TranscribeStream.event(#"{"type":"partial","text":"Check the disk"}"#) == .partial("Check the disk"))
        #expect(TranscribeStream.event(#"{"type":"final","transcript":"Check the disk space.","provider":"openai"}"#) == .final("Check the disk space."))
        #expect(TranscribeStream.event(#"{"type":"error","message":"no live STT for the configured provider"}"#) == .failed("no live STT for the configured provider"))
        #expect(TranscribeStream.event(#"{"type":"ready"}"#) == nil)
        #expect(TranscribeStream.event("not json") == nil)
    }

    @Test func wavHeader() {
        let pcm = Data(repeating: 1, count: 3200)
        let wav = WAVFile.make(pcm: pcm, sampleRate: 16_000)
        #expect(wav.count == 44 + 3200)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        // Byte rate: 16 kHz of 16-bit mono.
        let byteRate = wav[28..<32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: byteRate) == 32_000)
    }
}
