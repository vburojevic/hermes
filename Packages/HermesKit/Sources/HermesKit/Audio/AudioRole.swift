import Foundation

/// What the app is using audio for (`docs/voice.md` §7). One role holds the audio at a time; the
/// order is the priority: a call outranks a recording, which outranks dictation, then reading a
/// reply aloud, then playing a voice message, then listening for "Hey Hermes".
public enum AudioRole: Int, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    /// Hey Hermes: the microphone open for the gateway's wake word. Everything else comes first.
    case wake = -1
    /// A voice message or a Bot's audio file playing.
    case playback = 0
    /// Listen: a reply read aloud.
    case listen = 1
    /// Dictation into the composer.
    case dictation = 2
    /// Recording a voice message.
    case recording = 3
    /// Talk, a call with a Bot.
    case talk = 4

    public static func < (lhs: AudioRole, rhs: AudioRole) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The microphone is on for this role.
    public var usesMicrophone: Bool {
        switch self {
        case .talk, .recording, .dictation, .wake: true
        case .listen, .playback: false
        }
    }

    /// What this role does when `higher` takes the audio: Listen pauses while you record and
    /// resumes after; a voice message stops when a call starts; dictation stops (its words stay).
    public func whenPreempted(by higher: AudioRole) -> AudioPreemption {
        switch self {
        case .playback: higher == .talk ? .stop : .pause
        case .listen: higher == .talk ? .stop : .pause
        case .dictation: .stop
        case .recording: .pause
        case .talk: .pause
        // It listens again when the call, the recording or the reply is over.
        case .wake: .pause
        }
    }

    public var description: String {
        switch self {
        case .playback: "playback"
        case .listen: "listen"
        case .dictation: "dictation"
        case .recording: "recording"
        case .talk: "talk"
        case .wake: "wake"
        }
    }
}

public enum AudioPreemption: Sendable, Equatable {
    /// Wait, and carry on when the higher role is done.
    case pause
    /// End now.
    case stop
}

/// How a role wants the audio set up beyond its category.
public struct AudioRoleOptions: Sendable, Hashable {
    /// Talk on iPhone: the loudspeaker, not the earpiece.
    public var prefersSpeaker: Bool
    /// Voice messages with AirPods that support it: studio-quality recording. Never for Talk,
    /// which it would slow down.
    public var highQualityBluetoothRecording: Bool
    /// Raise to Listen: the phone is at the ear, so play through the receiver.
    public var receiver: Bool

    public init(prefersSpeaker: Bool = true, highQualityBluetoothRecording: Bool = false, receiver: Bool = false) {
        self.prefersSpeaker = prefersSpeaker
        self.highQualityBluetoothRecording = highQualityBluetoothRecording
        self.receiver = receiver
    }
}

/// The audio session a role runs in, described so it can be logged and tested on any platform.
public struct AudioSessionProfile: Sendable, Hashable, CustomStringConvertible {
    public enum Category: String, Sendable { case playAndRecord, playback }
    public enum Mode: String, Sendable { case voiceChat, measurement, spokenAudio, `default` }
    public enum Option: String, Sendable, Hashable, CaseIterable {
        case allowBluetoothHFP, allowBluetoothA2DP, bluetoothHighQualityRecording, defaultToSpeaker, duckOthers
        case interruptSpokenAudioAndMixWithOthers, mixWithOthers
    }

    public var category: Category
    public var mode: Mode
    public var options: Set<Option>
    /// Echo cancellation, noise suppression and gain control on the engine's input.
    public var voiceProcessing: Bool

    public init(category: Category, mode: Mode, options: Set<Option>, voiceProcessing: Bool) {
        self.category = category
        self.mode = mode
        self.options = options
        self.voiceProcessing = voiceProcessing
    }

    /// `docs/voice.md` §4.2 (Talk), §2 (recording), §5 (dictation), §3 (Listen), §4.6 (Hey Hermes).
    public static func `for`(_ role: AudioRole, options: AudioRoleOptions = .init()) -> AudioSessionProfile {
        switch role {
        case .talk:
            AudioSessionProfile(
                category: .playAndRecord, mode: .voiceChat,
                options: options.prefersSpeaker ? [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers] : [.allowBluetoothHFP, .duckOthers],
                voiceProcessing: true
            )
        case .recording:
            AudioSessionProfile(
                category: .playAndRecord, mode: .default,
                options: options.highQualityBluetoothRecording
                    ? [.bluetoothHighQualityRecording, .allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
                    : [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers],
                voiceProcessing: false
            )
        case .dictation:
            AudioSessionProfile(
                category: .playAndRecord, mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers],
                voiceProcessing: false
            )
        case .wake:
            // The built-in microphone, mixed with whatever plays: music carries on, and AirPods
            // never drop to their call mode just to listen.
            AudioSessionProfile(category: .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker], voiceProcessing: false)
        case .listen, .playback:
            options.receiver
                // At the ear: play-and-record routes to the receiver unless told otherwise.
                ? AudioSessionProfile(category: .playAndRecord, mode: .spokenAudio, options: [.allowBluetoothA2DP, .duckOthers], voiceProcessing: false)
                : AudioSessionProfile(
                    category: .playback, mode: .spokenAudio,
                    // Listen owns Now Playing, which takes a session that doesn't mix: other
                    // audio pauses while a reply is read, as for a podcast.
                    options: role == .listen ? [] : [.duckOthers],
                    voiceProcessing: false
                )
        }
    }

    public var description: String {
        let flags = options.map(\.rawValue).sorted().joined(separator: ",")
        return "\(category.rawValue)/\(mode.rawValue)[\(flags)]\(voiceProcessing ? "+vp" : "")"
    }
}
