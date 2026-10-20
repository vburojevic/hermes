import Foundation

/// One suggestion in Apps and Tools → Plugins → Suggested (`pluginOfferRow`).
public struct PluginSuggestion: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        /// One of the app's own plugins (its registry).
        case app(AppPlugin)
        /// Hermes's curated list (`plugins.manage onboarding`), with its catalog entry when the
        /// feed has one.
        case curated(CatalogPlugin, PluginCatalogEntry?)
    }

    public enum Action: Sendable, Hashable {
        case install
        /// Installed and turned off (`pluginOfferRowOff`).
        case turnOn
    }

    public let source: Source
    public let action: Action

    public var id: String { name }

    public var name: String {
        switch source {
        case .app(let plugin): plugin.name
        case .curated(let entry, _): entry.name
        }
    }

    public var isAppPlugin: Bool {
        if case .app = source { true } else { false }
    }
}

/// Where one of the app's plugins stands on a gateway, for offers: on somewhere (keeping current
/// does the rest), installed but off everywhere, or nowhere.
public enum AppPluginPresence: Sendable, Hashable {
    case on
    case off
    case missing

    public init(_ entries: [AppPluginsSurvey.Entry]) {
        if entries.contains(where: \.isOn) {
            self = .on
        } else if entries.contains(where: { $0.state != .missing }) {
            self = .off
        } else {
            self = .missing
        }
    }
}

/// Picking what's offered (`docs/plugins.md` §3.2): the app's plugins first, then Hermes's curated
/// ones whose app is on the gateway, at most five. Left out: what's installed and on, what's
/// hidden, and what can't run there (another OS, a newer Hermes, an app the gateway doesn't have).
/// Installed but off is offered with Turn On.
public enum PluginOffers {
    public static let limit = 5

    /// - Parameters:
    ///   - app: each of the app's plugins with where it stands; nil presence means unknown (no
    ///     Bot Mode yet), offered to install.
    ///   - curated: `plugins.manage onboarding`.
    ///   - installed: the root profile's `plugins.manage list`.
    ///   - catalog: the feed, for platforms and the Hermes version an entry needs.
    public static func suggested(
        app: [(plugin: AppPlugin, presence: AppPluginPresence?)],
        curated: [CatalogPlugin],
        installed: [HermesPlugin],
        catalog: PluginCatalog?,
        gatewayOS: String?,
        hermesVersion: String?,
        hidden: Set<String>
    ) -> [PluginSuggestion] {
        var suggestions: [PluginSuggestion] = []
        for (plugin, presence) in app where !hidden.contains(plugin.name) {
            switch presence {
            case .on?: continue
            case .off?: suggestions.append(PluginSuggestion(source: .app(plugin), action: .turnOn))
            case .missing?, nil: suggestions.append(PluginSuggestion(source: .app(plugin), action: .install))
            }
        }
        for entry in curated where entry.appState == "present" && !hidden.contains(entry.name) {
            let catalogEntry = catalog?.entry(named: entry.name)
            if let catalogEntry {
                if let gatewayOS, !catalogEntry.runs(on: gatewayOS) { continue }
                if !catalogEntry.supports(hermes: hermesVersion) { continue }
            }
            let row = installed.first { $0.catalogName == entry.name || $0.key == entry.name || $0.name == entry.name }
            if let row {
                if row.isEnabled { continue }
                suggestions.append(PluginSuggestion(source: .curated(entry, catalogEntry), action: .turnOn))
            } else {
                suggestions.append(PluginSuggestion(source: .curated(entry, catalogEntry), action: .install))
            }
        }
        return Array(suggestions.prefix(limit))
    }

    /// Why a catalog entry can't install on this gateway, in the row's words, or nil when it can.
    public static func unavailable(_ entry: PluginCatalogEntry, gateway: String, gatewayOS: String?, hermesVersion: String?,
                                   appState: String? = nil, sentence: String? = nil) -> String? {
        if let gatewayOS, !entry.runs(on: gatewayOS) {
            return String(localized: "Runs on \(PluginInstallFailure.platformWords(entry.platforms.joined(separator: ",")))")
        }
        if !entry.supports(hermes: hermesVersion), let minimum = entry.minimumHermes {
            return String(localized: "Needs Hermes \(minimum) or later on \(gateway)")
        }
        if appState == "missing_app" {
            return sentence?.isEmpty == false ? sentence : String(localized: "Needs an app \(gateway) doesn’t have")
        }
        return nil
    }
}
