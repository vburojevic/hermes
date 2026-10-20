import Foundation
#if os(iOS)
import AudioToolbox
#else
import AppKit
#endif

/// Settings → Chat → Sounds (`docs/inbox.md` §3): a soft sound when you send and when a reply
/// lands in the chat on screen. Off until turned on.
enum ChatSounds {
    enum Sound {
        case sent, received
    }

    static func play(_ sound: Sound) {
        guard UserDefaults.standard.bool(forKey: PreferenceKey.chatSounds) else { return }
        #if os(iOS)
        AudioServicesPlaySystemSound(sound == .sent ? 1004 : 1003)
        #else
        NSSound(named: sound == .sent ? "Pop" : "Tink")?.play()
        #endif
    }
}
