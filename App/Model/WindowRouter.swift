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
    var sheet: WindowSheet?
    /// Runs once the current sheet has gone: for actions that bring up another of the
    /// window's sheets, which can't appear while this one is still leaving.
    @ObservationIgnored var afterDismiss: (() -> Void)?

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

    /// A catalog plugin a `plugin/install?catalog=` link asked for: Settings → Apps and Tools
    /// takes it and asks before installing.
    var pluginInstallRequest: String?

    /// Opens `hermesapp://connect` and `hermesapp://plugin/install?catalog=<name>` links; ignores
    /// everything else.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if url.host() == "plugin", url.path() == "/install",
           let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "catalog" })?.value,
           !name.isEmpty {
            pluginInstallRequest = name
            sheet = .settings
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
