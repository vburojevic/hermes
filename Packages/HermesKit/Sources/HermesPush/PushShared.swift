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
        return record
    }

    public func forget(appID: UUID) {
        gateways = gateways.filter { $0.value.appID != appID }
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

    /// The badge: open requests across gateways, nothing else (`docs/notifications.md` §2).
    public var badge: Int {
        let cutoff = Date.now.addingTimeInterval(-6 * 3600)
        return openCounts.values.filter { $0.at > cutoff }.reduce(0) { $0 + $1.count }
    }

    // MARK: Faces

    /// A Bot's face, rendered by the app for communication notifications.
    public func faceURL(gateway appID: UUID, bot: String) -> URL? {
        let safe = bot.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty else { return nil }
        return container?.appending(path: "Faces/\(appID.uuidString)/\(safe).png")
    }

    // MARK: Lock state

    private var probeURL: URL? { container?.appending(path: "unlock-probe") }

    /// Written by the app with complete protection: unreadable while the device is locked.
    public func writeUnlockProbe() {
        guard let probeURL else { return }
        #if os(iOS)
        try? Data("ok".utf8).write(to: probeURL, options: [.atomic, .completeFileProtection])
        #else
        try? Data("ok".utf8).write(to: probeURL, options: .atomic)
        #endif
    }

    /// Whether the device is unlocked right now, as far as an extension can tell.
    public var isUnlocked: Bool {
        guard let probeURL, FileManager.default.fileExists(atPath: probeURL.path) else { return true }
        return (try? Data(contentsOf: probeURL)) != nil
    }

    // MARK: Device key

    private static let keyService = "co.caffeinatedcode.hermes.push"
    private static let keyAccount = "device-key"

    /// The device key, creating it the first time (the app only; extensions just read it).
    public func deviceKey(create: Bool = false) throws -> PushDeviceKey? {
        if let data = try readKey() { return try PushDeviceKey(rawRepresentation: data) }
        guard create else { return nil }
        let key = PushDeviceKey()
        try storeKey(key.rawRepresentation)
        return key
    }

    private func keyQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyService,
            kSecAttrAccount as String: Self.keyAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let keychainGroup { query[kSecAttrAccessGroup as String] = keychainGroup }
        return query
    }

    private func readKey() throws -> Data? {
        var query = keyQuery()
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

    private func storeKey(_ data: Data) throws {
        var item = keyQuery()
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
