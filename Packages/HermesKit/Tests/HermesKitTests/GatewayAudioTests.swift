import Foundation
import Testing
@testable import HermesKit

@Suite("Gateway audio")
struct GatewayAudioTests {
    @Test func pcmFramesAreCutIntoWholeSamples() {
        var assembler = PCMAssembler()
        #expect(assembler.append(Data([1, 2, 3])) == Data([1, 2]))
        #expect(assembler.append(Data([4])) == Data([3, 4]))
        #expect(assembler.append(Data([5, 6, 7, 8, 9])) == Data([5, 6, 7, 8]))
        #expect(assembler.append(Data()) == Data())
        #expect(assembler.append(Data([10])) == Data([9, 10]))
    }

    @Test func realtimeNeedsGPTLiveAndAKey() throws {
        let off = VoiceLiveStatus(json: try JSONValue.decode(Data(#"{"ok":true,"mode":"gpt-live","available":false,"reason":"no OpenAI API key (set OPENAI_API_KEY or voice.gpt_live.api_key)","model":"gpt-live-1","voice":"marin"}"#.utf8)))
        #expect(!off.isRealtime)
        #expect(off.reason?.hasPrefix("no OpenAI API key") == true)
        let on = VoiceLiveStatus(json: try JSONValue.decode(Data(#"{"ok":true,"mode":"gpt-live","available":true,"reason":null}"#.utf8)))
        #expect(on.isRealtime)
        let chained = VoiceLiveStatus(json: try JSONValue.decode(Data(#"{"ok":true,"mode":"chained","available":true}"#.utf8)))
        #expect(!chained.isRealtime)
    }

    @Test func voiceConfigKeysNeverShowInDescriptions() throws {
        let json = #"{"ok":true,"stt":{"mode":"relay","reason":"local provider","streaming":false},"tts":{"mode":"direct","wire":"openai-speech","provider":"openai","base_url":"https://api.openai.com/v1","api_key":"sk-secret-123","model":"gpt-4o-mini-tts","voice":"alloy"}}"#
        let config = VoiceConfig(json: try JSONValue.decode(Data(json.utf8)))
        #expect(config.tts.isDirect)
        #expect(!config.stt.isDirect)
        #expect(!config.description.contains("sk-secret"))
        #expect(!String(describing: config.tts).contains("sk-secret"))
        #expect(!String(reflecting: config).contains("sk-secret"))
        #expect(config.tts.withKey { $0.count } == 13)
    }
}

@Suite("Voice turns")
struct VoiceTurnTests {
    @Test func hermesVoiceTurnsCarryEverything() {
        let turn = VoiceTurn(context: "User: hi", interrupted: true)
        #expect(turn.submitParams == [
            "surface": .string("voice-live"), "voice_turn": .bool(true),
            "voice_context": .string("User: hi"), "interrupted": .bool(true),
        ])
        // A Realtime delegation runs on the chat's model.
        #expect(VoiceTurn(isVoiceTurn: false).submitParams == ["surface": .string("voice-live")])
    }

    @Test func contextKeepsTheNewestLinesThatFit() {
        let lines = (1...200).map { (isUser: $0 % 2 == 1, text: "Line \($0) " + String(repeating: "x", count: 60)) }
        let context = VoiceTurn.context(lines)
        #expect(context.count <= VoiceTurn.contextLimit)
        #expect(context.hasSuffix("Voice assistant: Line 200 " + String(repeating: "x", count: 60)))
        #expect(context.contains("User: Line 199"))
        #expect(!context.contains("Line 1 "))
        #expect(VoiceTurn.context([(true, "  "), (false, "Hi.")]) == "Voice assistant: Hi.")
    }
}
