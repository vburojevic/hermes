import AppIntents
import Foundation

/// "Talk to Hermes" and "Talk to <Bot> in Hermes" for Siri, Spotlight and the Shortcuts app
/// (`docs/voice.md` §4.4).
struct HermesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTalkIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Call \(.applicationName)",
                "Talk to \(\.$bot) in \(.applicationName)",
                "Call \(\.$bot) in \(.applicationName)",
            ],
            shortTitle: "Talk",
            systemImageName: "waveform"
        )
    }
}
