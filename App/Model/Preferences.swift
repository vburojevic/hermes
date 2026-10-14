import SwiftUI

/// Keys for the handful of app-wide preferences stored in `UserDefaults`.
enum PreferenceKey {
    static let appearance = "appearance"
    static let sendWithReturn = "sendWithReturn"
    static let expandAgentActivity = "expandAgentActivity"
    /// Show tokens, cost and context under every finished reply (otherwise after tapping its header).
    static let showUsage = "showUsage"
    static let haptics = "haptics"
    static let selectedBot = "selectedBot"
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
