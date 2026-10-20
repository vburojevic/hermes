import Foundation

/// Where inline ` ```widget ` blocks draw (`docs/widgets.md` §2, §11).
enum WidgetSettings {
    /// Settings → Developer → Render Inline Widgets: for the mock gateway and tests.
    static let renderInlineKey = "widgets.renderInline"

    static var rendersInlineBlocks: Bool {
        UserDefaults.standard.bool(forKey: renderInlineKey)
    }

    /// A routine's delivery: blocks the plugin wrote draw on a gateway with the plugin; without
    /// it, in Debug builds or with the setting.
    static func rendersDeliveryBlocks(pluginPresent: Bool) -> Bool {
        #if DEBUG
        true
        #else
        pluginPresent || rendersInlineBlocks
        #endif
    }
}
