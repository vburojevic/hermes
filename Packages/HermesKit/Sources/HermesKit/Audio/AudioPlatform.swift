@preconcurrency import AVFAudio
import Foundation

/// What the coordinator asks of the system: set the session up for a role, let it go, and say
/// what happened (interruptions, routes, resets). The live one talks to `AVAudioSession`; tests
/// use their own.
public protocol AudioPlatform: Sendable {
    /// Configures and activates the session, and prepares the engine (voice processing on or off).
    func apply(_ profile: AudioSessionProfile, graph: AudioGraph) async throws
    /// Stops the engine and releases the session so other apps' audio comes back.
    func deactivate(graph: AudioGraph) async
    func route() async -> AudioRoute
    /// System events, for one listener (the coordinator).
    func events() -> AsyncStream<AudioPlatformEvent>
}

public enum AudioPlatformEvent: Sendable, Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(AudioRouteChange)
    /// The engine stopped because the hardware changed (sample rate, channel count) and was started again.
    case engineConfigurationChanged
    /// The media server restarted: every audio object is gone and must be made again.
    case mediaServicesReset
    case inputMuteChanged(Bool)
}

public enum AudioRouteChangeReason: String, Sendable, Equatable {
    case newDeviceAvailable, oldDeviceUnavailable, categoryChange, override, other
}

public struct AudioRouteChange: Sendable, Equatable {
    public var reason: AudioRouteChangeReason
    public var route: AudioRoute

    public init(reason: AudioRouteChangeReason, route: AudioRoute) {
        self.reason = reason
        self.route = route
    }
}

/// Where sound goes, simplified to what the app decides on.
public struct AudioRoute: Sendable, Hashable, CustomStringConvertible {
    public enum Output: String, Sendable, Hashable {
        case speaker, receiver, headphones, bluetooth, airPlay, car, usb, other, unknown
    }

    public var output: Output
    /// What the person sees on the route button ("AirPods Pro", "iPhone", "Speaker").
    public var name: String
    /// The microphone in use is a Bluetooth one that can record at studio quality.
    public var supportsHighQualityRecording: Bool

    public init(output: Output, name: String, supportsHighQualityRecording: Bool = false) {
        self.output = output
        self.name = name
        self.supportsHighQualityRecording = supportsHighQualityRecording
    }

    public static let unknown = AudioRoute(output: .unknown, name: "")

    /// Only the person hears it: headphones, AirPods, the receiver at the ear.
    public var isPrivate: Bool {
        switch output {
        case .receiver, .headphones, .bluetooth: true
        case .speaker, .airPlay, .car, .usb, .other, .unknown: false
        }
    }

    public var description: String { "\(output.rawValue)(\(name.isEmpty ? "-" : "named"))" }
}

/// `AVAudioSession` on iPhone and iPad; on the Mac, which has no session, just the engine.
public final class LiveAudioPlatform: AudioPlatform {
    public init() {}

    public func apply(_ profile: AudioSessionProfile, graph: AudioGraph) async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(Self.category(profile.category), mode: Self.mode(profile.mode), options: Self.options(profile.options))
        if profile.category == .playAndRecord {
            // Haptics and the sounds Talk plays still work while the microphone is on.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        if #available(iOS 27, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                session.activate(options: []) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } else {
            try session.setActive(true)
        }
        #endif
        try graph.prepare(voiceProcessing: profile.voiceProcessing, usesInput: profile.category == .playAndRecord)
    }

    public func deactivate(graph: AudioGraph) async {
        graph.stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27, *) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in continuation.resume() }
            }
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    public func route() async -> AudioRoute {
        Self.currentRoute()
    }

    public func events() -> AsyncStream<AudioPlatformEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioPlatformEvent.self)
        let center = NotificationCenter.default
        var tokens: [any NSObjectProtocol] = []

        tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
            continuation.yield(.engineConfigurationChanged)
        })
        tokens.append(center.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: nil) { note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue ?? AVAudioApplication.shared.isInputMuted
            continuation.yield(.inputMuteChanged(muted))
        })

        #if os(iOS)
        if #available(iOS 27, *) {
            tokens.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                // Only the system taking the session away is an interruption; the app's own release isn't.
                if context?.source == .system { continuation.yield(.interruptionBegan) }
            })
            tokens.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: nil) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                continuation.yield(.interruptionEnded(shouldResume: context?.recommendation == .shouldResume))
            })
        } else {
            tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    continuation.yield(.interruptionBegan)
                case .ended:
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    continuation.yield(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
                @unknown default:
                    break
                }
            })
        }
        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason: AudioRouteChangeReason = switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
            case .newDeviceAvailable: .newDeviceAvailable
            case .oldDeviceUnavailable: .oldDeviceUnavailable
            case .categoryChange: .categoryChange
            case .override: .override
            default: .other
            }
            continuation.yield(.routeChanged(AudioRouteChange(reason: reason, route: Self.currentRoute())))
        })
        tokens.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            continuation.yield(.mediaServicesReset)
        })
        #endif

        let observers = ObserverTokens(tokens)
        continuation.onTermination = { _ in observers.remove() }
        return stream
    }

    static func currentRoute() -> AudioRoute {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let port = route.outputs.first else { return .unknown }
        let output: AudioRoute.Output = switch port.portType {
        case .builtInSpeaker: .speaker
        case .builtInReceiver: .receiver
        case .headphones, .lineOut, .HDMI: .headphones
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        case .airPlay: .airPlay
        case .carAudio: .car
        case .usbAudio: .usb
        default: .other
        }
        let input = route.inputs.first
        let highQuality = input?.bluetoothMicrophoneExtension?.highQualityRecording.isSupported ?? false
        return AudioRoute(output: output, name: port.portName, supportsHighQualityRecording: highQuality)
        #else
        return AudioRoute(output: .speaker, name: "")
        #endif
    }

    #if os(iOS)
    static func category(_ category: AudioSessionProfile.Category) -> AVAudioSession.Category {
        switch category {
        case .playAndRecord: .playAndRecord
        case .playback: .playback
        }
    }

    static func mode(_ mode: AudioSessionProfile.Mode) -> AVAudioSession.Mode {
        switch mode {
        case .voiceChat: .voiceChat
        case .measurement: .measurement
        case .spokenAudio: .spokenAudio
        case .default: .default
        }
    }

    static func options(_ options: Set<AudioSessionProfile.Option>) -> AVAudioSession.CategoryOptions {
        var result: AVAudioSession.CategoryOptions = []
        for option in options {
            switch option {
            case .allowBluetoothHFP: result.insert(.allowBluetoothHFP)
            case .allowBluetoothA2DP: result.insert(.allowBluetoothA2DP)
            case .bluetoothHighQualityRecording: result.insert(.bluetoothHighQualityRecording)
            case .defaultToSpeaker: result.insert(.defaultToSpeaker)
            case .duckOthers: result.insert(.duckOthers)
            case .interruptSpokenAudioAndMixWithOthers: result.insert(.interruptSpokenAudioAndMixWithOthers)
            case .mixWithOthers: result.insert(.mixWithOthers)
            }
        }
        return result
    }
    #endif
}

/// Notification observers removed together when the event stream ends.
private final class ObserverTokens: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol]
    private let lock = NSLock()

    init(_ tokens: [any NSObjectProtocol]) {
        self.tokens = tokens
    }

    func remove() {
        lock.withLock {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
        }
    }
}
