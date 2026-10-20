import Foundation

/// What the person answered about plugin offers on one gateway (`docs/plugins.md` §3.4), and which
/// catalog names this device has shown there (§3.1, New in the Catalog). Nothing offered is lost:
/// Not Now leaves a plugin in Suggested, Don't Suggest Again moves it to Hidden Suggestions, Show
/// Again brings it back.
public struct PluginAnswers: Codable, Hashable, Sendable {
    /// Not Now on one moment's offer.
    public struct NotNow: Codable, Hashable, Sendable {
        public var date: Date
        /// The card came back once already, after the wait.
        public var cameBack: Bool
    }

    /// A card answered Not Now may come back once, at its next natural moment, after this long.
    public static let comeBackAfter: TimeInterval = 14 * 86_400

    /// By "<plugin>|<moment>": this device, this gateway.
    public var notNow: [String: NotNow] = [:]
    /// Names hidden on this gateway, with when (synced through `HiddenSuggestionStore`).
    public var hidden: [String: Date] = [:]
    /// Catalog names shown on this device for this gateway; nil until the first visit.
    public var seen: Set<String>?

    public init() {}

    static func key(_ plugin: String, _ moment: String) -> String { "\(plugin)|\(moment)" }

    // MARK: Not Now

    public mutating func notNow(_ plugin: String, at moment: String, on date: Date = .now) {
        notNow[Self.key(plugin, moment)] = NotNow(date: date, cameBack: false)
    }

    /// Whether `moment` may offer `plugin` now: never hidden; never answered, or answered Not Now
    /// at least 14 days ago and not back since.
    public func mayOffer(_ plugin: String, at moment: String, now: Date = .now) -> Bool {
        guard hidden[plugin] == nil else { return false }
        guard let answer = notNow[Self.key(plugin, moment)] else { return true }
        return !answer.cameBack && now.timeIntervalSince(answer.date) >= Self.comeBackAfter
    }

    /// The card is showing: if it came back after a Not Now, that was its one return.
    public mutating func offered(_ plugin: String, at moment: String) {
        let key = Self.key(plugin, moment)
        if notNow[key] != nil { notNow[key]?.cameBack = true }
    }

    // MARK: Hidden

    public mutating func hide(_ plugin: String, on date: Date = .now) { hidden[plugin] = date }
    public mutating func showAgain(_ plugin: String) { hidden[plugin] = nil }
    public func isHidden(_ plugin: String) -> Bool { hidden[plugin] != nil }

    // MARK: New in the Catalog

    /// Names this device hasn't shown for this gateway. The first visit counts everything as
    /// seen, so New starts empty and fills as the catalog grows.
    public mutating func unseen(in names: [String]) -> [String] {
        guard let seen else {
            seen = Set(names)
            return []
        }
        return names.filter { !seen.contains($0) }
    }

    /// The person saw them (the catalog was opened, or the rows were on screen).
    public mutating func markSeen(_ names: [String]) {
        seen = (seen ?? []).union(names)
    }
}

/// Where hidden suggestions are kept, so every device on a gateway can agree. Each device keeps its
/// own copy (`UserDefaults`); `CloudHiddenSuggestions` adds iCloud key-value storage once the app
/// has that entitlement.
public protocol HiddenSuggestionStore: AnyObject {
    func hidden(gateway: String) -> [String: Date]
    func setHidden(_ hidden: [String: Date], gateway: String)
}

/// This device only.
public final class LocalHiddenSuggestions: HiddenSuggestionStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ gateway: String) -> String { "plugins.hidden.\(gateway)" }

    public func hidden(gateway: String) -> [String: Date] {
        (defaults.dictionary(forKey: Self.key(gateway)) as? [String: Date]) ?? [:]
    }

    public func setHidden(_ hidden: [String: Date], gateway: String) {
        defaults.set(hidden.isEmpty ? nil : hidden, forKey: Self.key(gateway))
    }
}

/// This device, and iCloud key-value storage for the person's other devices. A name hidden on any
/// device is hidden on all; Show Again removes it everywhere (the latest write wins).
public final class CloudHiddenSuggestions: HiddenSuggestionStore {
    private let local: LocalHiddenSuggestions
    private let cloud: NSUbiquitousKeyValueStore

    public init(local: LocalHiddenSuggestions = LocalHiddenSuggestions(), cloud: NSUbiquitousKeyValueStore = .default) {
        self.local = local
        self.cloud = cloud
    }

    public func hidden(gateway: String) -> [String: Date] {
        if let synced = cloud.dictionary(forKey: LocalHiddenSuggestions.key(gateway)) as? [String: Date] {
            local.setHidden(synced, gateway: gateway)
            return synced
        }
        return local.hidden(gateway: gateway)
    }

    public func setHidden(_ hidden: [String: Date], gateway: String) {
        local.setHidden(hidden, gateway: gateway)
        cloud.set(hidden, forKey: LocalHiddenSuggestions.key(gateway))
    }
}
