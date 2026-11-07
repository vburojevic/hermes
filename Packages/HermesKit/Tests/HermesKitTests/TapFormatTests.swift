import Testing
@testable import HermesKit

/// The microphone tap's format (`docs/voice.md` §7): never one `AVAudioEngine` refuses.
struct TapFormatTests {
    @Test(arguments: [false, true])
    func agreeingFormatsKeepTheNodesOwn(voiceProcessing: Bool) {
        #expect(TapFormat.decide(output: (48_000, 1), hardware: (48_000, 1), voiceProcessing: voiceProcessing) == .output)
        #expect(TapFormat.decide(output: (44_100, 2), hardware: (44_100, 2), voiceProcessing: voiceProcessing) == .output)
    }

    @Test func voiceProcessingCountsMoreMicrophonesThanItHandsOn() {
        // The hardware side counts every microphone; the node hands on the processed channel.
        #expect(TapFormat.decide(output: (48_000, 1), hardware: (48_000, 3), voiceProcessing: true) == .output)
    }

    @Test func aMismatchedRateFollowsTheHardwareWithoutVoiceProcessing() {
        // AirPods connected: the node still reports the old tap's rate.
        #expect(TapFormat.decide(output: (48_000, 2), hardware: (24_000, 1), voiceProcessing: false)
                == .hardware(sampleRate: 24_000, channels: 1))
        #expect(TapFormat.decide(output: (16_000, 1), hardware: (48_000, 1), voiceProcessing: false)
                == .hardware(sampleRate: 48_000, channels: 1))
    }

    @Test func aMismatchedRateKeepsTheProcessedChannelsWithVoiceProcessing() {
        #expect(TapFormat.decide(output: (48_000, 1), hardware: (24_000, 3), voiceProcessing: true)
                == .hardware(sampleRate: 24_000, channels: 1))
    }

    @Test(arguments: [false, true])
    func zeroChannelsIsNoInput(voiceProcessing: Bool) {
        #expect(TapFormat.decide(output: (48_000, 0), hardware: (48_000, 1), voiceProcessing: voiceProcessing) == .noInput)
        #expect(TapFormat.decide(output: (48_000, 1), hardware: (48_000, 0), voiceProcessing: voiceProcessing) == .noInput)
        #expect(TapFormat.decide(output: (48_000, 0), hardware: (24_000, 1), voiceProcessing: voiceProcessing) == .noInput)
    }

    @Test(arguments: [false, true])
    func zeroSampleRateIsNoInput(voiceProcessing: Bool) {
        #expect(TapFormat.decide(output: (0, 1), hardware: (48_000, 1), voiceProcessing: voiceProcessing) == .noInput)
        #expect(TapFormat.decide(output: (48_000, 1), hardware: (0, 1), voiceProcessing: voiceProcessing) == .noInput)
        #expect(TapFormat.decide(output: (0, 0), hardware: (0, 0), voiceProcessing: voiceProcessing) == .noInput)
    }
}
