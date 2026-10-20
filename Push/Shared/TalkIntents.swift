#if os(iOS)
import AppIntents
import Foundation

/// Mute on the call's Live Activity and in the Dynamic Island (`liveActivityTalk`). Compiled into
/// the widget for its button; the system runs it in the app, which holds the call.
struct TalkMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or Unmute the Call"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !HERMES_WIDGET
        await MainActor.run { TalkCenter.shared.toggleMute() }
        #endif
        return .result()
    }
}

/// End on the call's Live Activity and in the Dynamic Island.
struct TalkEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the Call"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        #if !HERMES_WIDGET
        await MainActor.run { TalkCenter.shared.end() }
        #endif
        return .result()
    }
}
#endif
