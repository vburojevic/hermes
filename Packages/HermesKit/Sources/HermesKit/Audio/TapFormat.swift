import Foundation

/// The format the microphone's tap goes on in (`docs/voice.md` §7).
///
/// `AVAudioEngine` raises an Objective-C exception, which Swift can't catch, when a tap's format
/// has no sample rate or channels, or when its rate differs from the input hardware's. A tap's
/// format is applied to the input node's output, so after AirPods connect or a call starts the
/// node can still report the old tap's rate while the hardware runs at the new one. The input node
/// does no conversion (its output must match the hardware), so the tap then goes on at the
/// hardware's rate.
public enum TapFormat: Equatable, Sendable {
    /// The node's own output format, unchanged.
    case output
    /// A format at the hardware's rate with this many channels.
    case hardware(sampleRate: Double, channels: UInt32)
    /// There's no input to tap (no microphone, no permission).
    case noInput

    /// - Parameters:
    ///   - output: the input node's output format (what a tap is given by default).
    ///   - hardware: the input hardware's format (the input node's input format).
    ///   - voiceProcessing: whether voice processing is on, so the node hands on its processed
    ///     channels rather than every microphone the hardware counts.
    public static func decide(
        output: (sampleRate: Double, channels: UInt32),
        hardware: (sampleRate: Double, channels: UInt32),
        voiceProcessing: Bool
    ) -> TapFormat {
        guard hardware.sampleRate > 0, hardware.channels > 0,
              output.sampleRate > 0, output.channels > 0 else { return .noInput }
        guard output.sampleRate != hardware.sampleRate else { return .output }
        // With voice processing on, the hardware side counts every microphone while the node hands
        // on the processed channels, and Apple documents no other count: keep the node's.
        return .hardware(sampleRate: hardware.sampleRate, channels: voiceProcessing ? output.channels : hardware.channels)
    }
}
