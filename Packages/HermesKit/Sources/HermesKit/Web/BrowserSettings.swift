import Foundation

// Where Hermes browses (`docs/web.md` §5). Read from the profile's config (`GET /api/config`) and
// `browser.manage {action: status}`; written with `PUT /api/config` (deep-merged; lists replace)
// and `browser.manage`. Keys and defaults from Hermes Agent's `hermes_cli/config_defaults.py`,
// `tools/browser_tool_cloud.py`, `tools/browser_use_cli.py` and `tui_gateway/methods_browser.py`.

/// The browser settings of one profile, as `GET /api/config` returns them (defaults filled in).
public struct BrowserSettings: Equatable, Sendable {
    /// `browser.cloud_provider`. Nil when it was never chosen: Hermes then uses a cloud provider it
    /// has a key for (Browser Use, then Browserbase), else a local browser.
    public var cloudProvider: String?
    /// `browser.use_real_profile`: browse with a copy of the default browser's profile.
    public var useRealProfile = false
    /// `browser.engine`: `auto`, `lightpanda` or `chrome`.
    public var engine = "auto"
    /// `browser.auto_local_for_private_urls`: with a cloud provider, private addresses still open
    /// in a local browser.
    public var localForPrivateAddresses = true
    /// `browser.record_sessions`: videos of each session, kept on the gateway.
    public var recordSessions = false
    /// `browser.extension_control.enabled`: a browser controller (this app) may drive the tools.
    public var extensionControl = false
    /// `security.website_blocklist`.
    public var blocklistEnabled = false
    public var blockedDomains: [String] = []

    public init() {}

    public init(config: JSONValue) {
        let browser = config["browser"]
        cloudProvider = browser?["cloud_provider"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        useRealProfile = browser?["use_real_profile"]?.boolValue ?? false
        engine = browser?["engine"]?.stringValue?.lowercased() ?? "auto"
        localForPrivateAddresses = browser?["auto_local_for_private_urls"]?.boolValue ?? true
        recordSessions = browser?["record_sessions"]?.boolValue ?? false
        extensionControl = browser?["extension_control"]?["enabled"]?.boolValue ?? false
        let blocklist = config["security"]?["website_blocklist"]
        blocklistEnabled = blocklist?["enabled"]?.boolValue ?? false
        if case .array(let domains)? = blocklist?["domains"] {
            blockedDomains = domains.compactMap(\.stringValue)
        }
    }

    /// A cloud provider is chosen (anything but `local`).
    public var cloud: String? {
        guard let cloudProvider, !cloudProvider.isEmpty, cloudProvider != "local" else { return nil }
        return cloudProvider
    }

    /// Lightpanda: faster, text only, no screenshots.
    public var fastTextOnly: Bool { engine == "lightpanda" }

    /// "Browserbase", "Browser Use with your Nous plan".
    public static func cloudName(_ provider: String) -> String {
        switch provider {
        case "nous": String(localized: "Browser Use with your Nous plan")
        case "browser-use", "browser_use": String(localized: "Browser Use")
        case "browserbase": String(localized: "Browserbase")
        case "firecrawl": String(localized: "Firecrawl")
        case "camofox": String(localized: "Camofox")
        default: provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }

    // MARK: Writes (`PUT /api/config` bodies; Hermes deep-merges objects and replaces lists)

    /// A clean local browser: no cloud, no copied profile. `local` is written rather than left
    /// unset, so Hermes doesn't pick a cloud provider by itself.
    public static var cleanBrowserPatch: JSONValue {
        .object(["browser": .object(["cloud_provider": .string("local"), "use_real_profile": .bool(false)])])
    }

    /// A copy of the person's browser profile, locally. Needs the consent first.
    public static var withYourLoginsPatch: JSONValue {
        .object(["browser": .object(["cloud_provider": .string("local"), "use_real_profile": .bool(true)])])
    }

    /// Leaving the copied profile when going to the cloud: Hermes deletes the copy.
    public static var cloudPatch: JSONValue {
        .object(["browser": .object(["use_real_profile": .bool(false)])])
    }

    public static func fastTextOnlyPatch(_ on: Bool) -> JSONValue {
        .object(["browser": .object(["engine": .string(on ? "lightpanda" : "auto")])])
    }

    public static func localForPrivateAddressesPatch(_ on: Bool) -> JSONValue {
        .object(["browser": .object(["auto_local_for_private_urls": .bool(on)])])
    }

    public static func recordSessionsPatch(_ on: Bool) -> JSONValue {
        .object(["browser": .object(["record_sessions": .bool(on)])])
    }

    /// The whole blocklist: a list in config is replaced, never merged.
    public static func blocklistPatch(enabled: Bool, domains: [String]) -> JSONValue {
        .object(["security": .object(["website_blocklist": .object([
            "enabled": .bool(enabled), "domains": .array(domains.map(JSONValue.string)),
        ])])])
    }

    /// A site as the blocklist keeps it: the host, lowercased, without a scheme, path or
    /// `www.`. Nil when there's no host. Hermes also takes `*.` wildcards, which pass as typed.
    public static func blockedDomain(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.hasPrefix("*.") {
            let rest = String(text.dropFirst(2))
            return blockedDomain(rest).map { "*." + $0 }
        }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URLComponents(string: text)?.host, host.contains(".") || host == "localhost" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// `browser.manage {action: status}`: a window Hermes is attached to (`connected`, its CDP
/// `url`), and whether new chats get Browser Use (`browser_exec`) or the built-in tools.
public struct BrowserConnection: Equatable, Sendable {
    public var connected: Bool
    public var url: String?
    /// Nil on a Hermes that doesn't say.
    public var browserUse: Bool?

    public init(connected: Bool = false, url: String? = nil, browserUse: Bool? = nil) {
        self.connected = connected
        self.url = url
        self.browserUse = browserUse
    }

    public init(json: JSONValue) {
        connected = json["connected"]?.boolValue ?? false
        url = json["url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        browserUse = json["browser_use"]?.boolValue
    }

    /// "127.0.0.1:9222".
    public var address: String? {
        guard let url, let components = URLComponents(string: url.contains("://") ? url : "http://" + url),
              let host = components.host else { return url }
        return components.port.map { "\(host):\($0)" } ?? host
    }
}

/// Where Hermes browses, as the Browser page offers it (`browserOption`).
public enum BrowserPlace: String, CaseIterable, Identifiable, Sendable {
    /// A local Chromium that starts fresh each time (Hermes's default).
    case cleanBrowser
    /// A copy of the person's Chrome, Edge or Brave profile on the gateway.
    case withYourLogins
    /// A visible Chrome window on the gateway, attached with `browser.manage connect`.
    case window
    /// A cloud browser provider.
    case cloud

    public var id: String { rawValue }

    /// Which place new chats use, in Hermes's own order when it builds a browser session: an
    /// attached window first, then a cloud provider, then a copied profile, else a clean browser.
    public static func current(_ settings: BrowserSettings, _ connection: BrowserConnection?) -> BrowserPlace {
        if connection?.connected == true { return .window }
        if settings.cloud != nil { return .cloud }
        if settings.useRealProfile { return .withYourLogins }
        return .cleanBrowser
    }
}
