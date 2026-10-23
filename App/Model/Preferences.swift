import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Keys for the handful of app-wide preferences stored in `UserDefaults`.
enum PreferenceKey {
    static let appearance = "appearance"
    static let sendWithReturn = "sendWithReturn"
    static let expandAgentActivity = "expandAgentActivity"
    /// Show tokens, cost and context under every finished reply (otherwise after tapping its header).
    static let showUsage = "showUsage"
    static let haptics = "haptics"
    static let selectedBot = "selectedBot"
    /// Settings → Chat → Open Chats At (`docs/inbox.md` §4).
    static let openChatsAt = "openChatsAt"
    /// Settings → Chat → Sounds: soft "sent" and "received" sounds, off until turned on.
    static let chatSounds = "chatSounds"
    /// A turn's diffs wrap their lines instead of scrolling sideways (`docs/chat.md` §1).
    static let wrapsDiffLines = "wrapsDiffLines"
}

/// Where a chat with unread messages opens (`docs/inbox.md` §4).
enum OpenChatsAt: String, CaseIterable, Identifiable {
    case firstUnread, latest

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .firstUnread: "First Unread"
        case .latest: "Latest"
        }
    }
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

    #if os(iOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
    #endif
}

#if os(iOS)
/// The Appearance setting on the window itself (`docs/design-to-swiftui.md` §1). iOS draws the app
/// switcher's picture of the app with the window's style: with only SwiftUI's
/// `.preferredColorScheme`, an app set to Dark on a phone in Light Mode left a light picture, so
/// the switcher showed it light and it turned dark as it opened. Sheets share the window, so they
/// follow it too.
struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> StyleView { StyleView() }

    func updateUIView(_ view: StyleView, context: Context) {
        view.style = style
    }

    final class StyleView: UIView {
        var style = UIUserInterfaceStyle.unspecified {
            didSet { apply() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
#endif
