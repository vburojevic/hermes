import HermesKit
import Observation
import SwiftUI

/// A sheet a window shows. One at a time, owned by that window, so Mac windows and iPad
/// scenes never mirror each other's sheets.
enum WindowSheet: Identifiable {
    case addGateway
    case editGateway(BotConfiguration)
    /// Settings as a sheet (iPhone and iPad; the Mac has its Settings window).
    case settings
    /// A gateway's pairing QR code.
    case pairing(UUID)
    /// Connecting from a pairing code or link. `rightAway` skips the confirmation step,
    /// for codes the person just scanned in Hermes.
    case connect(PairingLink, rightAway: Bool)
    /// The pairing-code scanner (iPhone and iPad).
    case scanner
    /// ⌘K: jump to a chat, Bot, place or gateway.
    case quickOpen

    var id: String {
        switch self {
        case .addGateway: "add"
        case .editGateway(let bot): "edit-\(bot.id)"
        case .settings: "settings"
        case .pairing(let botID): "pairing-\(botID)"
        case .connect(let link, _): "connect-\(link.gateway.absoluteString)"
        case .scanner: "scanner"
        case .quickOpen: "quick-open"
        }
    }
}

/// Presents this window's sheets. Changing `sheet` while one is up swaps it: the scanner hands
/// over to the connect sheet, Add Gateway to the pairing code.
@MainActor
@Observable
final class WindowRouter {
    /// Names this window to `AppModel`, which keeps the gateway each window shows.
    let windowID = UUID()
    var sheet: WindowSheet?
    /// Runs once the current sheet has gone: for actions that bring up another of the
    /// window's sheets, which can't appear while this one is still leaving.
    @ObservationIgnored var afterDismiss: (() -> Void)?

    /// The Mac's ⌘K search palette (`macSearch`), over the window.
    var showsSearchPalette = false
    /// Bumped to put the sidebar's search field in focus (⌥⌘F, Show All Results).
    private(set) var sidebarSearchFocus = 0

    func focusSidebarSearch() {
        #if os(macOS)
        // A narrow window's sidebar comes over the chat first, and its field takes the focus once
        // it's on screen (`SidebarOverChat`).
        if layout.isNarrow, !layout.showsSidebarOver {
            layout.toggleSidebar()
            searchesWhenSidebarShows = true
            return
        }
        #endif
        sidebarSearchFocus += 1
    }

    var isShowingQuickOpen: Bool {
        if case .quickOpen = sheet { true } else { false }
    }

    /// ⌘K: opens Quick Open, or closes it if it's up. Leaves other sheets alone.
    func toggleQuickOpen() {
        if isShowingQuickOpen {
            sheet = nil
        } else if sheet == nil {
            sheet = .quickOpen
        }
    }

    func sheetDidDismiss() {
        let action = afterDismiss
        afterDismiss = nil
        action?()
    }

    /// Settings opens on Apps and Tools (Skills' Tools and Apps row).
    var opensAppsAndTools = false

    /// The Inspector is open: on iPad it takes the sidebar's room; on a Mac window under 1,400 pt
    /// opening it beside the chat collapses the sidebar, and opening it over the chat, under
    /// 840 pt, doesn't (`docs/inspector.md` §1, `WindowLayout.inspectorChanged`).
    var inspectorIsOpen = false

    #if os(macOS)
    /// What the window shows at its width (`docs/chat.md` §4): the sidebar beside the chat, over
    /// it or put away, and the Inspector beside the chat or over it. `MainView` measures the
    /// window; the sidebar button and View > Show/Hide Sidebar go through `toggleSidebar()`.
    var layout = WindowLayout()

    /// ⌃⌘S and the sidebar button: beside the chat in a wide window, over it in a narrow one.
    func toggleSidebar() {
        layout.toggleSidebar()
    }

    /// ⌥⌘F brought the sidebar over the chat: its search field takes the focus as it appears.
    @ObservationIgnored var searchesWhenSidebarShows = false

    /// Bumped to open the Settings window: the Mac has no Settings sheet, and only a view can
    /// call `openSettings` (RootView does).
    private(set) var settingsWindowRequest = 0
    #endif

    /// Settings → Apps and Tools: the Settings sheet (iPhone, iPad), or the Settings window on
    /// its Apps & Tools pane (Mac).
    func showAppsAndTools() {
        #if os(macOS)
        UserDefaults.standard.set("apps", forKey: MacSettingsView.paneKey)
        settingsWindowRequest += 1
        #else
        opensAppsAndTools = true
        sheet = .settings
        #endif
    }

    /// Settings opens on Voice & Audio (a fallback note's Set Up…, `docs/voice.md` §6.1).
    var opensVoiceSettings = false

    /// Settings → Voice & Audio, in the Settings sheet (iPhone, iPad).
    func showVoiceSettings() {
        opensVoiceSettings = true
        sheet = .settings
    }

    /// A catalog plugin a `plugin/install?catalog=` link asked for: Settings → Apps and Tools
    /// takes it and asks before installing. On the Mac, RootView hands it to the gateway's Apps &
    /// Tools for the Settings window, which has no router.
    var pluginInstallRequest: String?

    /// Opens `hermesapp://connect` and `hermesapp://plugin/install?catalog=<name>` links; ignores
    /// everything else.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if url.host() == "plugin", url.path() == "/install",
           let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "catalog" })?.value,
           !name.isEmpty {
            pluginInstallRequest = name
            #if os(macOS)
            showAppsAndTools()
            #else
            sheet = .settings
            #endif
            return true
        }
        guard let link = PairingLink(url: url) else { return false }
        sheet = .connect(link, rightAway: false)
        return true
    }
}

extension FocusedValues {
    /// The key window's router, for menu commands.
    @Entry var windowRouter: WindowRouter?
}

extension EnvironmentValues {
    /// A Mac window under 700 pt (`docs/chat.md` §4): toolbars keep only what fits.
    @Entry var windowIsNarrow = false
    /// The sidebar is over a narrow window's chat: the toolbar's centered item steps aside, so
    /// the window's toolbar never draws over its glass.
    @Entry var sidebarShowsOverChat = false
}
