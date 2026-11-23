import Foundation
import HermesKit
import HermesMarkdown
import SwiftUI

/// Settings → Voice & Audio, the rows kept on this device (`docs/voice.md` §6). The Bot's voice
/// lives in its gateway profile instead.
enum TalkPreferences {
    enum Key {
        static let engine = "talk.engine"
        static let pause = "talk.pause"
        static let replies = "voice.replies"
        static let raiseToListen = "voice.raiseToListen"
        static let studioMic = "voice.studioMic"
        static let listenSpeed = "listen.speed"
        static let codeAndTables = "voice.codeAndTables"
        static let transcribeOn = "voice.transcribeOn"
        static let language = "voice.language"
        static let sounds = "voice.sounds"
        static let heyHermes = "voice.heyHermes"
        static let realtimeExplained = "talk.realtimeExplained"
    }

    enum EngineChoice: String, CaseIterable, Identifiable {
        case realtime, hermesVoice
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .realtime: "Realtime"
            case .hermesVoice: "Hermes Voice"
            }
        }
    }

    /// When a reply comes with its own audio strip (Voice replies).
    enum Replies: String, CaseIterable, Identifiable {
        case whenISpeak, always, never
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .whenISpeak: "When I Speak"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    enum TranscribeOn: String, CaseIterable, Identifiable {
        case device, gateway
        var id: String { rawValue }
    }

    private static var defaults: UserDefaults { .standard }

    static var engine: EngineChoice {
        EngineChoice(rawValue: defaults.string(forKey: Key.engine) ?? "") ?? .realtime
    }

    static var pause: Endpointer.Pause {
        Endpointer.Pause(rawValue: defaults.string(forKey: Key.pause) ?? "") ?? .normal
    }

    static var replies: Replies {
        Replies(rawValue: defaults.string(forKey: Key.replies) ?? "") ?? .whenISpeak
    }

    static var raiseToListen: Bool { defaults.object(forKey: Key.raiseToListen) as? Bool ?? true }
    static var studioMic: Bool { defaults.object(forKey: Key.studioMic) as? Bool ?? true }

    /// The stored speed, snapped to a step. A launch argument (`-listen.speed 1.25`) arrives as
    /// text, which `double(forKey:)` reads too.
    static var listenSpeed: Double {
        ListenSpeed.snapped(defaults.object(forKey: Key.listenSpeed) == nil ? nil : defaults.double(forKey: Key.listenSpeed))
    }

    static var codeAndTables: SpokenDetail {
        SpokenDetail(rawValue: defaults.string(forKey: Key.codeAndTables) ?? "") ?? .describe
    }

    static var transcribeOn: TranscribeOn {
        TranscribeOn(rawValue: defaults.string(forKey: Key.transcribeOn) ?? "") ?? .device
    }

    /// The language to transcribe in; `nil` follows the device.
    static var language: Locale? {
        defaults.string(forKey: Key.language).map(Locale.init(identifier:))
    }

    static var sounds: Bool { defaults.object(forKey: Key.sounds) as? Bool ?? true }
    static var heyHermes: Bool { defaults.bool(forKey: Key.heyHermes) }
}

/// The one speed Listen and voice messages play at (`docs/voice.md` §2, §3, §6). The speed
/// button, Now Playing and Settings → Voice & Audio → Speed all change it here, so a change from
/// any of them reaches the others, and a reading or clip that's playing, at once.
@MainActor
@Observable
final class ListenSpeedSetting {
    static let shared = ListenSpeedSetting()

    var rate: Double {
        didSet {
            // Now Playing can ask for any speed: it gets the nearest step.
            let snapped = ListenSpeed.snapped(rate)
            if snapped != rate { rate = snapped }
            UserDefaults.standard.set(rate, forKey: TalkPreferences.Key.listenSpeed)
        }
    }

    private init() {
        rate = TalkPreferences.listenSpeed
    }

    /// A tap on the speed button: the next step, from 2× back to 1×.
    func step() {
        rate = ListenSpeed.next(after: rate)
    }
}
