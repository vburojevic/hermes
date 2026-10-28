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

    /// How long what the app in front counted as shown caps the open requests (`recordShown`): it counts
    /// again at least every 50 s while it's there, so a cap left by an app that ended in front lapses.
    public static let shownLifetime: TimeInterval = 120

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
        unreadLists[appID.uuidString] = nil
        recentReads[appID.uuidString] = nil
        countableLists[appID.uuidString] = nil
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
        /// Open requests across gateways.
        case needsYou
        /// Those, plus unread chats; muted ones left out (the default).
        case unreadChats
    }

    public var badgeMode: BadgeMode {
        get { decode(BadgeMode.self, "push.badgeMode") ?? .unreadChats }
        set { encode(newValue, "push.badgeMode") }
    }

    /// The unread, unmuted chats the badge counts, per gateway (the app's id): the app's list as it
    /// last counted, plus chats the extension heard news for since, less chats read since.
    private var unreadLists: [String: [UnreadChat]] {
        get { decode([String: [UnreadChat]].self, "push.unread") ?? [:] }
        set { encode(newValue, "push.unread") }
    }

    public func unread(gateway appID: UUID) -> [UnreadChat] {
        unreadLists[appID.uuidString] ?? []
    }

    /// Chats read lately on any device, per gateway, kept six hours: an app counting from read
    /// marks that haven't caught up yet (woken by the push that says so) doesn't count them again.
    private var recentReads: [String: ReadMarks] {
        get { decode([String: ReadMarks].self, "push.reads") ?? [:] }
        set { encode(newValue, "push.reads") }
    }

    public func reads(gateway appID: UUID) -> ReadMarks {
        recentReads[appID.uuidString] ?? ReadMarks()
    }

    /// The chats each gateway's list shows (`UnreadStore`): only these may count in the badge. A
    /// notice for anything else (a routine's run, a Bot-to-Bot one-shot chat, a helper's session)
    /// is news the person can't see in the app, so it never counts.
    private var countableLists: [String: CountableChats] {
        get { decode([String: CountableChats].self, "push.countable") ?? [:] }
        set { encode(newValue, "push.countable") }
    }

    public func countable(gateway appID: UUID) -> CountableChats? {
        countableLists[appID.uuidString]
    }

    /// The app's list moved; returns whether the badge changed.
    @discardableResult
    public func recordCountable(_ chats: CountableChats, gateway appID: UUID) -> Bool {
        var lists = countableLists
        guard lists[appID.uuidString] != chats else { return false }
        lists[appID.uuidString] = chats
        countableLists = lists
        return badgeMode == .unreadChats
    }

    /// Lists and open counts for gateways the app no longer has go: they'd count for ever.
    @discardableResult
    public func keepUnread(gateways appIDs: Set<UUID>) -> Bool {
        let keep = Set(appIDs.map(\.uuidString))
        var unread = unreadLists, countable = countableLists
        let before = unread.count
        unread = unread.filter { keep.contains($0.key) }
        countable = countable.filter { keep.contains($0.key) }
        unreadLists = unread
        countableLists = countable
        let known = gateways
        let open = openCounts
        let kept = open.filter { known[$0.key].map { appIDs.contains($0.appID) } ?? false }
        if kept.count != open.count { openCounts = kept }
        return (unread.count != before && badgeMode == .unreadChats) || kept.count != open.count
    }

    /// The app counted a gateway's unread chats (`UnreadStore`); returns whether the badge changed.
    @discardableResult
    public func recordUnread(_ counted: [UnreadChat], gateway appID: UUID) -> Bool {
        let read = reads(gateway: appID)
        let chats = counted.filter { !$0.isRead(by: read) }
        var lists = unreadLists
        guard lists[appID.uuidString] ?? [] != chats else { return false }
        lists[appID.uuidString] = chats
        unreadLists = lists
        return badgeMode == .unreadChats
    }

    /// News for a chat arrived (the extension): it counts until it's read, unless it's muted or
    /// already counted. Returns whether the badge changed.
    @discardableResult
    public func noteUnread(_ notice: PushNotice, gateway appID: UUID, at date: Date = .now) -> Bool {
        guard let entry = UnreadChat(notice, at: notice.sentAt ?? date), let chat = ReadNotices.chat(of: notice),
              let countable = countable(gateway: appID), countable.contains(chat),
              !isMuted(gateway: appID, keys: notice.muteKeys + [entry.key], at: date)
        else { return false }
        // Hermes reads a chat it never marked as read, and so does the app's list (`UnreadStore`).
        if countable.isUnmarked(chat) { return false }
        if let read = notice.read, entry.isRead(by: read) { return false }
        if entry.isRead(by: reads(gateway: appID)) { return false }
        var lists = unreadLists
        var chats = lists[appID.uuidString] ?? []
        guard !chats.contains(where: { $0.matches(chat) }) else { return false }
        chats.append(entry)
        lists[appID.uuidString] = chats
        unreadLists = lists
        return badgeMode == .unreadChats
    }

    /// Chats read (on any device) come off the list. Returns whether the badge changed.
    @discardableResult
    public func noteRead(_ marks: ReadMarks, gateway appID: UUID, at date: Date = .now) -> Bool {
        guard !marks.isEmpty else { return false }
        var all = recentReads
        var known = all[appID.uuidString] ?? ReadMarks()
        let cutoff = date.addingTimeInterval(-6 * 3600)
        known.chats = known.chats.merging(marks.chats, uniquingKeysWith: max).filter { $0.value > cutoff }
        known.rooms = known.rooms.merging(marks.rooms, uniquingKeysWith: max).filter { $0.value > cutoff }
        all[appID.uuidString] = known
        recentReads = all
        // A chat read on any device has Hermes' mark now, so its next news counts.
        var countable = countableLists
        if countable[appID.uuidString]?.marked(marks.chats.keys) == true { countableLists = countable }
        var lists = unreadLists
        let chats = lists[appID.uuidString] ?? []
        let left = chats.filter { !$0.isRead(by: marks) }
        guard left.count != chats.count else { return false }
        lists[appID.uuidString] = left
        unreadLists = lists
        return badgeMode == .unreadChats
    }

    /// What the other gateways add to the badge: a gateway's plugin sets the whole badge while the
    /// app is away (`presence away` with `badge_others`).
    public func badge(besides appID: UUID, at date: Date = .now) -> Int {
        let open = openShares(at: date).filter { $0.appID == appID }.reduce(0) { $0 + $1.count }
        // Counted as the badge counts it: an entry the list doesn't show, or a second one for the same
        // chat, never took anything off another gateway's share.
        let unread = badgeMode == .unreadChats ? Self.counted(unread(gateway: appID), countable: countable(gateway: appID)) : 0
        return max(0, badge(at: date) - open - unread)
    }

    /// What the app in front shows waiting on the person, per gateway (`ShownRequests`), or nil as it
    /// leaves. While it's fresh, a gateway's open requests count no higher than this: the plugin's count
    /// is only a number, and one it kept for a request nobody can answer (an older plugin's, for a turn a
    /// restart ended) held the icon at 1 with every chat read and nothing waiting (#86). Away, the
    /// gateway's notices are what the person sees, and its count stands alone. Returns whether it changed.
    @discardableResult
    public func recordShown(_ counts: [UUID: Int]?, at date: Date = .now) -> Bool {
        let before = shownCounts
        guard let counts else {
            shownCounts = [:]
            return !before.isEmpty
        }
        shownCounts = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.uuidString, OpenCount(count: max(0, $0.value), at: date)) })
        // Back in front: what the app shows caps the counts again.
        staleOpen = [:]
        leftShown = [:]
        return before.mapValues(\.count) != shownCounts.mapValues(\.count)
    }

    private var shownCounts: [String: OpenCount] {
        get { decode([String: OpenCount].self, "push.shown") ?? [:] }
        set { encode(newValue, "push.shown") }
    }

    /// The app leaves. A plugin before 1.4.8 (`olderPlugins`, by installation) keeps counting requests
    /// nobody can answer, so what its open count held beyond what the app showed waiting as it left stays
    /// off the badge, here and in the service extension, until the app is back in front; a new request
    /// still adds to it. Returns those installations: the app asks their plugins for no badge pushes
    /// meanwhile, which would put the stale count back (#86).
    @discardableResult
    public func leave(olderPlugins: Set<String>, at date: Date = .now) -> Set<String> {
        let cutoff = date.addingTimeInterval(-6 * 3600)
        let known = gateways
        let shown = shownCounts.filter { $0.value.at > date.addingTimeInterval(-Self.shownLifetime) }
        var stale: [String: Int] = [:], left: [String: Int] = [:]
        for key in olderPlugins {
            guard let appID = known[key]?.appID, let cap = shown[appID.uuidString] else { continue }
            left[key] = cap.count
            if let open = openCounts[key], open.at > cutoff, open.count > cap.count { stale[key] = open.count - cap.count }
        }
        staleOpen = stale
        leftShown = left
        shownCounts = [:]
        return Set(stale.keys)
    }

    /// An older plugin's answer to the app leaving (`presence away`), its open count as the app left: what it
    /// holds beyond what the app showed is stale too, though the app hadn't heard of it in front.
    public func recordLeavingOpen(_ count: Int, gateway installation: String, at date: Date = .now) {
        recordOpen(count, gateway: installation, at: date)
        guard let shown = leftShown[installation] else { return }
        var stale = staleOpen
        stale[installation] = count > shown ? count - shown : nil
        staleOpen = stale
    }

    private var staleOpen: [String: Int] {
        get { decode([String: Int].self, "push.staleOpen") ?? [:] }
        set { encode(newValue, "push.staleOpen") }
    }

    /// What the app showed waiting as it left, by an older plugin's installation (`leave`).
    private var leftShown: [String: Int] {
        get { decode([String: Int].self, "push.leftShown") ?? [:] }
        set { encode(newValue, "push.leftShown") }
    }

    /// Each known gateway's open requests as the badge counts them: its latest count, ignoring counts
    /// older than six hours; in front no more than the app shows waiting there, and away less what an
    /// older plugin counted that the app didn't show (`leave`).
    private func openShares(at date: Date) -> [(appID: UUID, count: Int)] {
        let cutoff = date.addingTimeInterval(-6 * 3600)
        let known = gateways
        let shown = shownCounts.filter { $0.value.at > date.addingTimeInterval(-Self.shownLifetime) }
        let stale = staleOpen
        return openCounts.compactMap { key, open in
            guard let gateway = known[key], open.at > cutoff else { return nil }
            if let cap = shown[gateway.appID.uuidString] { return (gateway.appID, min(open.count, cap.count)) }
            return (gateway.appID, max(0, open.count - (stale[key] ?? 0)))
        }
    }

    /// A background push from a gateway's plugin (`withdraw`, `sync`, `read`): its open requests and the
    /// reads it carries, recorded before the app sets the badge from what this device knows, so a chat
    /// read on another device doesn't come back on an icon the plugin's badge push had set right
    /// (`docs/notifications.md` §2 Badge). Returns the reads, for clearing their notifications.
    @discardableResult
    public func noteBackground(_ notice: PushNotice, gateway appID: UUID?, at date: Date = .now) -> ReadMarks {
        if let installation = notice.gateway?.id, let open = notice.open {
            recordOpen(open, gateway: installation, at: notice.sentAt ?? date)
        }
        let marks = ReadMarks(carriedBy: notice)
        if let appID { noteRead(marks, gateway: appID, at: date) }
        return marks
    }

    /// The badge: open requests across gateways, plus unread chats when the person chose so.
    public var badge: Int { badge(at: .now) }

    public func badge(at date: Date) -> Int {
        let open = openShares(at: date).reduce(0) { $0 + $1.count }
        guard badgeMode == .unreadChats else { return open }
        // Every gateway's list: the Mac registers with none, and a removed gateway's list goes with it.
        let countable = countableLists
        return open + unreadLists.reduce(0) { total, list in
            total + Self.counted(list.value, countable: countable[list.key])
        }
    }

    /// The chats of a list the badge counts: those the app's list shows. A list from before the app
    /// shared what it shows keeps only its own entries, never one only a notice added (`push:`).
    static func counted(_ chats: [UnreadChat], countable: CountableChats?) -> Int {
        var seen: Set<String> = []
        return chats.reduce(0) { total, chat in
            let shown = countable.map { $0.contains(chat) } ?? !chat.key.hasPrefix("push:")
            return shown && seen.insert(chat.key).inserted ? total + 1 : total
        }
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

    // MARK: Live Activity

    /// Marks the activity states this app writes itself (`TurnActivityAttributes.ContentState`):
    /// random, in the shared Keychain, never sent anywhere. The app creates it; the widget only reads.
    public func activityToken(creating: Bool) -> String? {
        if let data = (try? readKey(account: Self.activityTokenAccount)) ?? nil { return String(decoding: data, as: UTF8.self) }
        guard creating else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = Data(bytes).base64EncodedString()
        do {
            try storeKey(Data(token.utf8), account: Self.activityTokenAccount)
        } catch {
            return nil
        }
        return token
    }

    static let activityTokenAccount = "activity.local-token"

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
