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

    /// Hermes's verdict for xAI through the xAI Grok sign-in: relay, the same words with or
    /// without it (`tools/voice_client_config.py`), so the sign-in decides.
    static func xaiSignedIn(_ signedIn: Bool = true) -> VoiceFacts {
        var facts = VoiceFacts(speechProvider: "xai", transcriptionProvider: "xai")
        facts.speechVerdict = VoiceVerdict(mode: "relay", reason: "provider 'xai' has no client wire")
        facts.transcriptionVerdict = VoiceVerdict(mode: "relay", reason: "xai oauth (server-managed) or no credentials")
        facts.signedIn = signedIn ? ["xai-oauth", "nous"] : ["nous"]
        return facts
    }

    @Test func theXAISignInSpeaksAndTranscribesButNotLive() {
        let facts = Self.xaiSignedIn()
        #expect(facts.missingSpeechKey == nil)
        #expect(facts.gatewaySpeaks)
        #expect(facts.missingTranscriptionKey == nil)
        #expect(facts.missingLiveTranscriptionKey == "XAI_API_KEY")
        #expect(facts.transcriptionUsesSignIn)

        let signedOut = Self.xaiSignedIn(false)
        #expect(signedOut.missingSpeechKey == "XAI_API_KEY")
        #expect(!signedOut.gatewaySpeaks)
        #expect(signedOut.missingTranscriptionKey == "XAI_API_KEY")
        #expect(!signedOut.transcriptionUsesSignIn)

        // With the key, live transcription has what it needs too.
        var keyed = facts
        keyed.keysSet = ["XAI_API_KEY"]
        #expect(keyed.missingLiveTranscriptionKey == nil)
        #expect(!keyed.transcriptionUsesSignIn)
    }

    @Test func aDirectVerdictMeansTheGatewayHasCredentials() {
        // A key from `hermes auth add elevenlabs` isn't in /api/env, but voice-config hands it out.
        var pooled = VoiceFacts(speechProvider: "elevenlabs", transcriptionProvider: "elevenlabs")
        pooled.speechVerdict = VoiceVerdict(mode: "direct", provider: "elevenlabs")
        pooled.transcriptionVerdict = VoiceVerdict(mode: "direct", provider: "elevenlabs")
        #expect(pooled.missingSpeechKey == nil)
        #expect(pooled.missingTranscriptionKey == nil)
        #expect(pooled.missingLiveTranscriptionKey == nil)

        // OpenAI through a Nous subscription: whole recordings, never live.
        var managed = VoiceFacts(speechProvider: "openai", transcriptionProvider: "openai")
        managed.speechVerdict = VoiceVerdict(mode: "direct", provider: "openai")
        managed.transcriptionVerdict = VoiceVerdict(mode: "direct", provider: "openai")
        #expect(managed.missingSpeechKey == nil)
        #expect(managed.missingTranscriptionKey == nil)
        #expect(managed.missingLiveTranscriptionKey == "OPENAI_API_KEY")

        // A verdict for another provider (the config changed since) proves nothing.
        var stale = VoiceFacts(speechProvider: "elevenlabs")
        stale.speechVerdict = VoiceVerdict(mode: "direct", provider: "openai")
        #expect(stale.missingSpeechKey == "ELEVENLABS_API_KEY")

        // "No credentials" is what it says.
        var none = VoiceFacts(speechProvider: "deepinfra")
        none.speechVerdict = VoiceVerdict(mode: "relay", reason: "no credentials")
        #expect(none.missingSpeechKey == "DEEPINFRA_API_KEY")
    }

    @Test func miniMaxTakesEitherRegionsKey() {
        #expect(VoiceFacts(speechProvider: "minimax").missingSpeechKey == "MINIMAX_API_KEY")
        #expect(VoiceFacts(speechProvider: "minimax", keysSet: ["MINIMAX_CN_API_KEY"]).missingSpeechKey == nil)
    }

    @Test func signInsAreReadFromTheOAuthList() throws {
        let json = try JSONValue.decode(Data(#"{"providers": [{"id": "xai-oauth", "status": {"logged_in": true}}, {"id": "nous", "status": {"logged_in": false}}, {"id": "minimax-oauth", "status": {}}]}"#.utf8))
        #expect(GatewaySetup.signedIn(oauthProviders: json) == ["xai-oauth"])
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

    @Test func theXAISignInAsksForNoKey() {
        let statuses = VoiceSetupRules.statuses(VoiceFactsTests.xaiSignedIn(), device: "iPhone")
        #expect(statuses[1].state == .ready)
        #expect(statuses[1].detail == "xAI")
        #expect(statuses[2].state == .ready)
        #expect(statuses[2].detail == "On this iPhone, with xAI on the gateway as a backup")
        // No Realtime here, but Talk answers in the gateway's voice and asks only for Realtime's key.
        #expect(statuses[0].detail == "Hermes Voice · xAI")
        #expect(statuses.allSatisfy { !($0.fallback ?? "").contains("XAI_API_KEY") })
        #expect(statuses.allSatisfy { $0.steps.allSatisfy { !($0.command ?? "").contains("XAI_API_KEY") } })
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

        var signedIn = VoiceFactsTests.xaiSignedIn()
        signedIn.liveTranscriptionOn = true
        let signIn = status(signedIn)
        #expect(signIn.fix?.title == "Add Key…")
        #expect(signIn.fallback == "Talk transcribes on this iPhone: the xAI sign-in doesn't cover transcribing as you speak, which needs XAI_API_KEY on the gateway.")
        #expect(signIn.steps.map(\.command) == ["hermes -p researcher config set XAI_API_KEY <your key>"])

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
