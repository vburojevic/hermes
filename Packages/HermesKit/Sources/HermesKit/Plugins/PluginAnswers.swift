import CryptoKit
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
    /// Names hidden on this gateway, with when (kept and synced through `HiddenSuggestionStore`).
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

    /// Hidden names are a mirror of `HiddenSuggestions`: hide and Show Again go through it and
    /// its store, never through here.
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

// MARK: - Hidden Suggestions on every device

/// The plugins hidden on one gateway, kept so two devices' lists merge instead of overwriting each
/// other (`docs/plugins.md` §9.3). Each name carries its last answer and when: hidden, or shown
/// again (a tombstone), so hiding one plugin on the iPhone and showing another on the Mac both
/// survive the next sync.
public struct HiddenSuggestions: Codable, Hashable, Sendable {
    public struct Mark: Codable, Hashable, Sendable {
        public var isHidden: Bool
        public var date: Date

        public init(isHidden: Bool, date: Date) {
            self.isHidden = isHidden
            self.date = date
        }
    }

    /// How long a Show Again is remembered. A device that comes back after longer than this with
    /// an older Don't Suggest Again would hide the plugin again, so it's long.
    public static let tombstoneLife: TimeInterval = 180 * 86_400

    public private(set) var marks: [String: Mark]

    public init(marks: [String: Mark] = [:]) {
        self.marks = marks
    }

    /// A list kept before marks had dates for Show Again: every name in it is hidden.
    public init(hidden: [String: Date]) {
        marks = hidden.mapValues { Mark(isHidden: true, date: $0) }
    }

    /// The names hidden now, with when.
    public var hidden: [String: Date] {
        marks.compactMapValues { $0.isHidden ? $0.date : nil }
    }

    public mutating func hide(_ name: String, on date: Date = .now) {
        mark(name, hidden: true, on: date)
    }

    public mutating func showAgain(_ name: String, on date: Date = .now) {
        mark(name, hidden: false, on: date)
    }

    /// The person's tap is always newer than the mark this list holds, even when another device's
    /// clock ran ahead and that mark carries a later date. A mark that hasn't reached this device
    /// yet can still outrank it.
    private mutating func mark(_ name: String, hidden: Bool, on date: Date) {
        let after = marks[name].map { $0.date.addingTimeInterval(0.001) } ?? date
        marks[name] = Mark(isHidden: hidden, date: max(date, after))
    }

    /// Both lists, name by name: the newer answer wins. Equal dates keep the plugin hidden, so
    /// every device settles on the same list whichever side it merges from.
    public func merged(with other: HiddenSuggestions) -> HiddenSuggestions {
        var result = marks
        for (name, theirs) in other.marks {
            guard let mine = result[name] else {
                result[name] = theirs
                continue
            }
            if theirs.date > mine.date || (theirs.date == mine.date && theirs.isHidden && !mine.isHidden) {
                result[name] = theirs
            }
        }
        return HiddenSuggestions(marks: result)
    }

    /// Without Show Agains older than `tombstoneLife`.
    public func trimmed(now: Date = .now) -> HiddenSuggestions {
        HiddenSuggestions(marks: marks.filter { $0.value.isHidden || now.timeIntervalSince($0.value.date) < Self.tombstoneLife })
    }
}

/// The gateway a list belongs to: this device's id for it, and the key every device shares for it
/// once the app knows the gateway's machine (`HiddenSuggestionKey`).
public struct HiddenSuggestionsGateway: Hashable, Sendable {
    public var deviceID: String
    public var sharedKey: String?

    public init(deviceID: String, sharedKey: String? = nil) {
        self.deviceID = deviceID
        self.sharedKey = sharedKey
    }
}

/// The iCloud key for a gateway's list. Every device asks the same gateway for its machine's name
/// (`GET /api/system/stats` `hostname`), so they all reach the same key. The name is hashed: the
/// key stays short (iCloud allows 64 bytes here) and names nothing, and no URL, address or key
/// the person typed ever goes into it.
public enum HiddenSuggestionKey {
    public static let prefix = "hidden-suggestions."
    /// iCloud's limit is 128 UTF-16 characters; the app keeps to 64 bytes of UTF-8.
    public static let maxBytes = 64

    /// "Studio-Mac.local." and "studio-mac" are the same machine: Hermes reports the system's node
    /// name, which can gain or lose `.local` with the network.
    public static func normalized(hostname: String) -> String {
        var name = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        return name
    }

    /// nil for a gateway that reports no name.
    public static func shared(hostname: String) -> String? {
        let name = normalized(hostname: hostname)
        guard !name.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return prefix + digest.prefix(32)
    }

    public static func isShared(_ key: String) -> Bool { key.hasPrefix(prefix) }
}

/// Where hidden suggestions are kept, so every device on a gateway can agree. Each device keeps its
/// own copy (`LocalHiddenSuggestions`); `CloudHiddenSuggestions` adds iCloud key-value storage in
/// builds that have that entitlement.
@MainActor
public protocol HiddenSuggestionStore: AnyObject {
    /// The gateway's list: this device's, merged with the shared one when there is one.
    func suggestions(for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions
    /// Keeps `list` (after a hide or a Show Again), merged with what's kept; answers the result.
    @discardableResult func save(_ list: HiddenSuggestions, for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions
    /// The gateway left this device. Its copy here goes; the person's other devices keep theirs.
    func forget(_ gateway: HiddenSuggestionsGateway)
    /// Calls `handler` with the gateway's list when another device changes it.
    func observe(_ gateway: HiddenSuggestionsGateway, _ handler: @escaping @MainActor (HiddenSuggestions) -> Void)
}

/// This device only.
@MainActor
public final class LocalHiddenSuggestions: HiddenSuggestionStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(_ deviceID: String) -> String { "plugins.hiddenSuggestions.\(deviceID)" }
    static func sharedKeyKey(_ deviceID: String) -> String { "plugins.hiddenSuggestions.\(deviceID).shared" }
    /// Names and dates only, before Show Again had a date.
    static func legacyKey(_ deviceID: String) -> String { "plugins.hidden.\(deviceID)" }

    func list(_ deviceID: String) -> HiddenSuggestions {
        if let data = defaults.data(forKey: Self.key(deviceID)),
           let list = try? JSONDecoder().decode(HiddenSuggestions.self, from: data) {
            return list
        }
        if let legacy = defaults.dictionary(forKey: Self.legacyKey(deviceID)) as? [String: Date] {
            let list = HiddenSuggestions(hidden: legacy)
            store(list, deviceID)
            return list
        }
        return HiddenSuggestions()
    }

    func store(_ list: HiddenSuggestions, _ deviceID: String) {
        defaults.set(list.marks.isEmpty ? nil : try? JSONEncoder().encode(list), forKey: Self.key(deviceID))
        defaults.removeObject(forKey: Self.legacyKey(deviceID))
    }

    /// The shared key last seen for a gateway, so a launch can sync before the gateway answers.
    func sharedKey(for gateway: HiddenSuggestionsGateway) -> String? {
        if let key = gateway.sharedKey {
            if defaults.string(forKey: Self.sharedKeyKey(gateway.deviceID)) != key {
                defaults.set(key, forKey: Self.sharedKeyKey(gateway.deviceID))
            }
            return key
        }
        return defaults.string(forKey: Self.sharedKeyKey(gateway.deviceID))
    }

    public func suggestions(for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions {
        list(gateway.deviceID)
    }

    @discardableResult
    public func save(_ list: HiddenSuggestions, for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions {
        let merged = self.list(gateway.deviceID).merged(with: list).trimmed()
        store(merged, gateway.deviceID)
        return merged
    }

    public func forget(_ gateway: HiddenSuggestionsGateway) {
        for key in [Self.key(gateway.deviceID), Self.sharedKeyKey(gateway.deviceID), Self.legacyKey(gateway.deviceID)] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Nothing changes this device's copy but this device.
    public func observe(_ gateway: HiddenSuggestionsGateway, _ handler: @escaping @MainActor (HiddenSuggestions) -> Void) {}
}

/// The part of `NSUbiquitousKeyValueStore` the app uses, so tests can stand in for iCloud.
public protocol UbiquitousKeyValues: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValues {}

/// This device, and iCloud key-value storage for the person's other devices. Both copies merge
/// name by name (`HiddenSuggestions.merged`) on every read and write and whenever iCloud brings a
/// change, so no device's answer overwrites another's.
@MainActor
public final class CloudHiddenSuggestions: HiddenSuggestionStore {
    private let local: LocalHiddenSuggestions
    private let cloud: any UbiquitousKeyValues
    /// By shared key: the gateways on this device that use it, and who to tell when it changes.
    private var watchers: [String: [String: @MainActor (HiddenSuggestions) -> Void]] = [:]
    private var observer: (any NSObjectProtocol)?

    /// `observesICloud` is off in tests, which call `externalChange` themselves.
    public init(local: LocalHiddenSuggestions = LocalHiddenSuggestions(),
                cloud: any UbiquitousKeyValues = NSUbiquitousKeyValueStore.default,
                observesICloud: Bool = true) {
        self.local = local
        self.cloud = cloud
        if observesICloud, let store = cloud as? NSUbiquitousKeyValueStore {
            // The store lives as long as the app (`PluginHubModel.hiddenStore`), so the observer
            // is never removed.
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
            ) { [weak self] note in
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
                MainActor.assumeIsolated { self?.externalChange(reason: reason, keys: keys) }
            }
        }
        // At first use, so what other devices changed while the app was closed arrives.
        cloud.synchronize()
    }

    /// Asks iCloud for what changed elsewhere; it arrives as `didChangeExternallyNotification`.
    public func synchronize() {
        cloud.synchronize()
    }

    public func suggestions(for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions {
        reconcile(gateway)
    }

    @discardableResult
    public func save(_ list: HiddenSuggestions, for gateway: HiddenSuggestionsGateway) -> HiddenSuggestions {
        local.save(list, for: gateway)
        return reconcile(gateway)
    }

    /// This device's copy goes. The shared one stays: the gateway may still be on the person's
    /// other devices.
    public func forget(_ gateway: HiddenSuggestionsGateway) {
        if let key = local.sharedKey(for: gateway) { watchers[key]?[gateway.deviceID] = nil }
        local.forget(gateway)
    }

    /// Again once the gateway's machine is known: the handler moves to its key.
    public func observe(_ gateway: HiddenSuggestionsGateway, _ handler: @escaping @MainActor (HiddenSuggestions) -> Void) {
        for key in watchers.keys { watchers[key]?[gateway.deviceID] = nil }
        guard let key = local.sharedKey(for: gateway) else { return }
        watchers[key, default: [:]][gateway.deviceID] = handler
    }

    /// iCloud changed some keys (`didChangeExternallyNotification`). A change from another device
    /// or the first sync merges into this device's copy of each gateway that uses the key, and its
    /// hub hears. Over quota, or another Apple Account (or none): this device's copy stays as it
    /// is, and the next read or write merges it with whatever iCloud holds then.
    func externalChange(reason: Int?, keys: [String]) {
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange || reason == NSUbiquitousKeyValueStoreAccountChange {
            return
        }
        for key in keys where HiddenSuggestionKey.isShared(key) {
            for (deviceID, handler) in watchers[key] ?? [:] {
                handler(reconcile(HiddenSuggestionsGateway(deviceID: deviceID, sharedKey: key)))
            }
        }
    }

    /// Merges this device's copy and iCloud's, and writes the result to whichever lacks it.
    private func reconcile(_ gateway: HiddenSuggestionsGateway) -> HiddenSuggestions {
        let mine = local.list(gateway.deviceID)
        guard let key = local.sharedKey(for: gateway) else { return mine }
        let data = cloud.data(forKey: key)
        let shared = data.flatMap { try? JSONDecoder().decode(HiddenSuggestions.self, from: $0) }
        let merged = mine.merged(with: shared ?? HiddenSuggestions()).trimmed()
        if merged != mine { local.store(merged, gateway.deviceID) }
        // A copy this version can't read came from a newer one: leave it for that one.
        if merged != shared, data == nil || shared != nil, let encoded = try? JSONEncoder().encode(merged) {
            cloud.set(encoded, forKey: key)
            cloud.synchronize()
        }
        return merged
    }
}

/// Whether hidden suggestions reach the person's other devices (`docs/setup.md` §4.22).
public enum HiddenSuggestionsSync: Hashable, Sendable {
    /// Through iCloud key-value storage.
    case syncing
    /// The build can sync, but iCloud is off or signed out here.
    case iCloudUnavailable
    /// This build has no iCloud key-value entitlement.
    case notInThisBuild

    public static let id = "device.hiddenSuggestions"

    public init(entitled: Bool, iCloudAvailable: Bool) {
        self = !entitled ? .notInThisBuild : iCloudAvailable ? .syncing : .iCloudUnavailable
    }

    public var setupStatus: SetupStatus {
        let title = String(localized: "Hidden Suggestions")
        let fallback = String(localized: "Plugins you hide stay hidden on this device only.")
        switch self {
        case .syncing:
            return SetupStatus(id: Self.id, state: .ready, title: title,
                               detail: String(localized: "Synced with your other devices through iCloud."))
        case .iCloudUnavailable:
            return SetupStatus(id: Self.id, state: .limited, title: title,
                               detail: String(localized: "iCloud is off or signed out on this device."),
                               fallback: fallback, steps: [SetupStep(Self.iCloudPath)])
        case .notInThisBuild:
            // Nothing the person can set up, so it doesn't count as something to set up.
            return SetupStatus(id: Self.id, state: .ready, title: title,
                               detail: String(localized: "This version of Hermes keeps them on this device."),
                               fallback: fallback)
        }
    }

    static var iCloudPath: String {
        #if os(macOS)
        String(localized: "In System Settings → your name → iCloud, sign in, then turn on Hermes under Saved to iCloud.")
        #else
        String(localized: "In Settings → your name → iCloud, sign in, then turn on Hermes under Saved to iCloud.")
        #endif
    }
}
