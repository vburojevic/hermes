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

    static var listenSpeed: Double {
        let speed = defaults.object(forKey: Key.listenSpeed) as? Double ?? 1
        return min(2, max(1, speed))
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
