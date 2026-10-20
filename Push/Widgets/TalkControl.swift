import AppIntents
import SwiftUI
import WidgetKit

/// Talk from Control Center, the Lock Screen or the Action button (`docs/voice.md` §4.4).
struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "co.caffeinatedcode.hermes.talk") {
            ControlWidgetButton(action: StartTalkIntent()) {
                Label("Talk to Hermes", systemImage: "waveform")
            }
        }
        .displayName("Talk to Hermes")
        .description("Starts a call with Hermes.")
    }
}
