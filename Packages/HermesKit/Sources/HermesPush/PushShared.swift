import Foundation
import Security

/// What the app shares with its extensions through the App Group and the Keychain group named in
/// each target's Info.plist (`HermesAppGroup`, `HermesKeychainGroup`): the device key, the
/// gateways' names and badge counts, the preferences and the Bots' faces.
public final class PushShared: @unchecked Sendable {
    public struct Gateway: Codable, Sendable, Hashable {
        /// The app's id for the gateway (`BotConfiguration.id`).
        public var appID: UUID
        public var name: String
        /// Which per-gateway category set (`APPROVAL.3`) carries this gateway's hidden-preview text.
        public var slot: Int?

        public init(appID: UUID, name: String, slot: Int?) {
            self.appID = appID
            self.name = name
            self.slot = slot
        }
    }

    struct OpenCount: Codable {
        var count: Int
        var at: Date
    }

    public static let current = PushShared()

    public let groupID: String?
    public let keychainGroup: String?
    public let defaults: UserDefaults

    public init(bundle: Bundle = .main) {
        groupID = bundle.object(forInfoDictionaryKey: "HermesAppGroup") as? String
        keychainGroup = bundle.object(forInfoDictionaryKey: "HermesKeychainGroup") as? String
        defaults = groupID.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Tests: a private suite and no Keychain group.
    public init(suiteName: String) {
        groupID = nil
        keychainGroup = nil
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public var container: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    // MARK: Device

    /// This installation's id at every gateway; survives app updates, not reinstalls.
    public var deviceID: String {
        if let id = defaults.string(forKey: "push.deviceID") { return id }
        let id = "dev-" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: "push.deviceID")
        return id
    }

    public var preferences: PushPreferences {
        get { decode(PushPreferences.self, "push.preferences") ?? PushPreferences() }
        set { encode(newValue, "push.preferences") }
    }

    // MARK: Gateways

    /// Gateways that answered `register`, by the relay installation id their notices carry.
    public var gateways: [String: Gateway] {
        get { decode([String: Gateway].self, "push.gateways") ?? [:] }
        set { encode(newValue, "push.gateways") }
    }

    public func gateway(_ installationID: String?) -> Gateway? {
        installationID.flatMap { gateways[$0] }
    }

    /// Remembers a gateway, giving it the first free category slot.
    @discardableResult
    public func remember(installationID: String, appID: UUID, name: String) -> Gateway {
        var all = gateways
        for (key, value) in all where value.appID == appID && key != installationID {
            all[key] = nil  // the gateway's Hermes home changed (a new installation)
        }
        let taken = Set(all.filter { $0.key != installationID }.compactMap(\.value.slot))
        let slot = all[installationID]?.slot ?? (0..<NotificationCatalog.slotCount).first { !taken.contains($0) }
        let record = Gateway(appID: appID, name: name, slot: slot)
        all[installationID] = record
        gateways = all
        openCounts = openCounts.filter { all[$0.key] != nil }
        return record
    }

    /// The gateway was removed: its key goes too, so its notices stop opening.
    public func forget(appID: UUID) {
        removeDeviceKeys(appID: appID)
        gateways = gateways.filter { $0.value.appID != appID }
        unreadChats[appID.uuidString] = nil
        var counts = openCounts
        for key in counts.keys where gateways[key] == nil { counts[key] = nil }
        openCounts = counts
    }

    // MARK: Badge

    private var openCounts: [String: OpenCount] {
        get { decode([String: OpenCount].self, "push.open") ?? [:] }
        set { encode(newValue, "push.open") }
    }

    /// Records a gateway's open "needs you" requests; returns the new badge.
    @discardableResult
    public func recordOpen(_ count: Int, gateway: String, at date: Date = .now) -> Int {
        var counts = openCounts
        if let existing = counts[gateway], existing.at > date { return badge }
        counts[gateway] = OpenCount(count: max(0, count), at: date)
        openCounts = counts
        return badge
    }

    /// Settings → Notifications → App Icon Badge (`docs/notifications.md` §2, `docs/inbox.md` §5).
    public enum BadgeMode: String, Codable, Sendable, CaseIterable {
        /// Open requests across gateways (the default).
        case needsYou
        /// Those, plus unread chats; muted ones left out.
        case unreadChats
    }

    public var badgeMode: BadgeMode {
        get { decode(BadgeMode.self, "push.badgeMode") ?? .needsYou }
        set { encode(newValue, "push.badgeMode") }
    }

    /// Unread, unmuted chats per gateway (the app's id), as the app last counted them.
    private var unreadChats: [String: Int] {
        get { decode([String: Int].self, "push.unreadChats") ?? [:] }
        set { encode(newValue, "push.unreadChats") }
    }

    /// Records a gateway's unread chats; returns whether the badge changed.
    @discardableResult
    public func recordUnread(_ count: Int, gateway appID: UUID) -> Bool {
        var counts = unreadChats
        guard counts[appID.uuidString] != count else { return false }
        counts[appID.uuidString] = max(0, count)
        unreadChats = counts
        return badgeMode == .unreadChats
    }

    /// The badge: open requests across gateways, plus unread chats when the person chose so.
    public var badge: Int {
        let cutoff = Date.now.addingTimeInterval(-6 * 3600)
        let known = gateways
        let open = openCounts.filter { known[$0.key] != nil && $0.value.at > cutoff }.reduce(0) { $0 + $1.value.count }
        guard badgeMode == .unreadChats else { return open }
        return open + unreadChats.values.reduce(0, +)
    }

    // MARK: Mutes

    /// Muted chats and Bots by key (a session's stable key, `bot:<name>`, `group:<id>`) and when
    /// each mute ends, per gateway: the Notification Service delivers them quietly
    /// (`docs/inbox.md` §1 Muting).
    public func mutes(gateway appID: UUID) -> [String: Date] {
        decode([String: Date].self, "push.mutes.\(appID.uuidString)") ?? [:]
    }

    public func setMutes(_ ends: [String: Date], gateway appID: UUID) {
        encode(ends, "push.mutes.\(appID.uuidString)")
    }

    /// Whether a notice about this chat is delivered quietly now.
    public func isMuted(gateway appID: UUID, keys: [String], at date: Date = .now) -> Bool {
        let ends = mutes(gateway: appID)
        return keys.contains { (ends[$0] ?? .distantPast) > date }
    }

    // MARK: Faces

    /// A Bot's face, rendered by the app for communication notifications.
    public func faceURL(gateway appID: UUID, bot: String) -> URL? {
        let safe = bot.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        return container?.appending(path: "Faces/\(appID.uuidString)/\(safe).png")
    }

    /// The Bots' names by profile, so a notice that only knows the profile can say who's asking.
    public func botNames(gateway appID: UUID) -> [String: String] {
        decode([String: String].self, "push.bots.\(appID.uuidString)") ?? [:]
    }

    public func setBotNames(_ names: [String: String], gateway appID: UUID) {
        encode(names, "push.bots.\(appID.uuidString)")
    }

    /// Each Bot's own chat by session id (its first and its newest), to the Bot's profile: Hermes
    /// tags a Bot Chat's notice with its profile, except the primary Bot's, which only this knows.
    public func botChats(gateway appID: UUID) -> [String: String] {
        decode([String: String].self, "push.botChats.\(appID.uuidString)") ?? [:]
    }

    public func setBotChats(_ chats: [String: String], gateway appID: UUID) {
        encode(chats, "push.botChats.\(appID.uuidString)")
    }

    // MARK: Device keys

    // Each gateway's push plugin (one relay installation, shared by the profiles of one Hermes)
    // seals to a key of its own (`deviceKey(installation:)`), made when the app first registers
    // there and deleted when the gateway is removed. A notice opens with one key only, so it can
    // only be from that installation, whatever it says about itself, and a removed gateway's
    // notices no longer open at all (security scan F32, F34). Builds before this had one key for
    // every gateway (`legacyKey`); it stays until each gateway has registered with its own.

    private static let keyService = "co.caffeinatedcode.hermes.push"
    private static let keyAccount = "device-key"

    /// An installation's own key, made the first time the app registers there (the app only;
    /// extensions just read).
    public func deviceKey(installation: String, create: Bool = false) throws -> PushDeviceKey? {
        let account = "\(Self.keyAccount).\(installation)"
        if let data = try readKey(account: account) { return try PushDeviceKey(rawRepresentation: data) }
        guard create else { return nil }
        let key = PushDeviceKey()
        try storeKey(key.rawRepresentation, account: account)
        return key
    }

    /// The one key of builds before per-gateway keys, made here only while a gateway can't say
    /// which installation it is.
    public func legacyKey(create: Bool = false) throws -> PushDeviceKey? {
        if let data = try readKey(account: Self.keyAccount) { return try PushDeviceKey(rawRepresentation: data) }
        guard create else { return nil }
        let key = PushDeviceKey()
        try storeKey(key.rawRepresentation, account: Self.keyAccount)
        return key
    }

    /// The installation registered with its own key. Once every gateway has, the old shared key goes.
    public func registeredOwnKey(installation: String) {
        ownKeyInstallations.insert(installation)
        if Set(gateways.keys).isSubset(of: ownKeyInstallations) {
            SecItemDelete(keyQuery(account: Self.keyAccount) as CFDictionary)
        }
    }

    private var ownKeyInstallations: Set<String> {
        get { Set(decode([String].self, "push.ownKeys") ?? []) }
        set { encode(Array(newValue), "push.ownKeys") }
    }

    private func removeDeviceKeys(appID: UUID) {
        for (installation, gateway) in gateways where gateway.appID == appID {
            SecItemDelete(keyQuery(account: "\(Self.keyAccount).\(installation)") as CFDictionary)
            ownKeyInstallations.remove(installation)
        }
    }

    /// The keys a gateway's sealed content (a Live Activity state) may be sealed to: its
    /// installation's own, then the old shared one.
    public func keys(for appID: UUID?) -> [PushDeviceKey] {
        let own = gateways.filter { $0.value.appID == appID }.keys.compactMap { try? deviceKey(installation: $0) }
        return own + [try? legacyKey()].compactMap { $0 }
    }

    /// Opens a pushed notice and names the gateway it's really from: the installation whose own
    /// key opened it. Nil when no key opens it, when it names another installation than the one
    /// whose key opened it (forged), or when its gateway isn't one this device knows. Those show
    /// only the relay's kind-only alert, and nothing answers them.
    public func open(_ envelope: PushEnvelope) -> (notice: PushNotice, gateway: Gateway)? {
        let known = gateways
        let own = known.keys.compactMap { installation in (try? deviceKey(installation: installation)).map { (installation, $0) } }
        return Self.open(envelope, gateways: known, keys: Dictionary(own) { first, _ in first }, legacy: try? legacyKey())
    }

    static func open(_ envelope: PushEnvelope, gateways: [String: Gateway], keys: [String: PushDeviceKey],
                     legacy: PushDeviceKey?) -> (notice: PushNotice, gateway: Gateway)? {
        for (installation, key) in keys {
            guard let gateway = gateways[installation], let notice = try? key.open(PushNotice.self, from: envelope) else { continue }
            if let claimed = notice.gateway?.id, !claimed.isEmpty, claimed != installation { return nil }
            return (notice, gateway)
        }
        guard let legacy, let notice = try? legacy.open(PushNotice.self, from: envelope),
              let gateway = (notice.gateway?.id).flatMap({ gateways[$0] }) else { return nil }
        return (notice, gateway)
    }

    private func keyQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let keychainGroup { query[kSecAttrAccessGroup as String] = keychainGroup }
        return query
    }

    private func readKey(account: String) throws -> Data? {
        var query = keyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeyError(status: status)
        }
    }

    private func storeKey(_ data: Data, account: String) throws {
        var item = keyQuery(account: account)
        item[kSecValueData as String] = data
        // Extensions read it on the Lock Screen; it never leaves this device (no backup, no sync).
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError(status: status) }
    }

    public struct KeyError: Error, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? {
            "Keychain error: " + (SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")
        }
    }

    // MARK: Storage

    private func decode<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
