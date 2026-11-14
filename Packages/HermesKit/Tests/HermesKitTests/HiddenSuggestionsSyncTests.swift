import Foundation
import Testing
@testable import HermesKit

/// iCloud key-value storage, in memory.
private final class FakeKeyValues: UbiquitousKeyValues {
    var values: [String: Data] = [:]
    var syncs = 0

    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool {
        syncs += 1
        return true
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func defaults() throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "hidden-suggestions-\(UUID().uuidString)"))
}

/// Hidden Suggestions merging across devices (`docs/plugins.md` §9.3, `docs/setup.md` §4.22).
@MainActor
struct HiddenSuggestionsSyncTests {
    let sharedKey = HiddenSuggestionKey.shared(hostname: "Studio-Mac.local")!

    /// The same gateway as each device knows it: its own id, the shared key.
    func gateway(_ deviceID: String) -> HiddenSuggestionsGateway {
        HiddenSuggestionsGateway(deviceID: deviceID, sharedKey: sharedKey)
    }

    // MARK: Merging

    @Test func theNewerAnswerWinsWhicheverSideMerges() {
        var phone = HiddenSuggestions(), mac = HiddenSuggestions()
        phone.hide("touchdesigner", on: t0)
        mac.hide("touchdesigner", on: t0)
        mac.showAgain("touchdesigner", on: t0 + 60)
        phone.hide("obsidian", on: t0 + 10)
        mac.hide("figma", on: t0 + 20)

        let one = phone.merged(with: mac), other = mac.merged(with: phone)
        #expect(one == other)
        #expect(one.hidden == ["obsidian": t0 + 10, "figma": t0 + 20])
        #expect(one.marks["touchdesigner"] == .init(isHidden: false, date: t0 + 60), "the Show Again is kept as a tombstone")
    }

    @Test func aHideAfterAShowAgainWins() {
        var phone = HiddenSuggestions(), mac = HiddenSuggestions()
        phone.showAgain("touchdesigner", on: t0)
        mac.hide("touchdesigner", on: t0 + 1)
        #expect(phone.merged(with: mac).hidden == ["touchdesigner": t0 + 1])
        #expect(mac.merged(with: phone).hidden == ["touchdesigner": t0 + 1])
    }

    @Test func equalDatesKeepItHiddenOnEveryDevice() {
        var phone = HiddenSuggestions(), mac = HiddenSuggestions()
        phone.hide("touchdesigner", on: t0)
        mac.showAgain("touchdesigner", on: t0)
        #expect(phone.merged(with: mac).hidden.keys.contains("touchdesigner"))
        #expect(mac.merged(with: phone).hidden.keys.contains("touchdesigner"))
    }

    @Test func aTapIsNewestEvenAfterAClockThatRanAhead() {
        var list = HiddenSuggestions(marks: ["touchdesigner": .init(isHidden: true, date: t0 + 3_600)])
        list.showAgain("touchdesigner", on: t0)
        #expect(list.hidden.isEmpty)
        #expect(list.marks["touchdesigner"]!.date > t0 + 3_600)
    }

    @Test func oldTombstonesAreTrimmedAndHiddenNamesStay() {
        var list = HiddenSuggestions()
        list.hide("obsidian", on: t0)
        list.showAgain("touchdesigner", on: t0)
        list.showAgain("figma", on: t0 + HiddenSuggestions.tombstoneLife)
        let later = list.trimmed(now: t0 + HiddenSuggestions.tombstoneLife + 1)
        #expect(Set(later.marks.keys) == ["obsidian", "figma"])
        #expect(later.hidden == ["obsidian": t0])
    }

    // MARK: This device

    @Test func aListFromBeforeTombstonesIsReadAsHidden() throws {
        let defaults = try defaults()
        defaults.set(["touchdesigner": t0], forKey: LocalHiddenSuggestions.legacyKey("gw"))
        let store = LocalHiddenSuggestions(defaults: defaults)
        #expect(store.suggestions(for: gateway("gw")).hidden == ["touchdesigner": t0])
        #expect(defaults.object(forKey: LocalHiddenSuggestions.legacyKey("gw")) == nil)
        #expect(store.suggestions(for: gateway("gw")).hidden == ["touchdesigner": t0], "rewritten, not lost")
    }

    @Test func savingMergesWithWhatsKept() throws {
        let store = LocalHiddenSuggestions(defaults: try defaults())
        var first = HiddenSuggestions()
        first.hide("obsidian", on: .now)
        store.save(first, for: gateway("gw"))
        var stale = HiddenSuggestions()
        stale.hide("figma", on: .now)
        #expect(Set(store.save(stale, for: gateway("gw")).hidden.keys) == ["obsidian", "figma"])
    }

    // MARK: iCloud

    @Test func twoDevicesMergeThroughICloud() throws {
        let cloud = FakeKeyValues()
        let phone = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        let mac = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)

        var list = phone.suggestions(for: gateway("phone-id"))
        list.hide("touchdesigner", on: .now)
        phone.save(list, for: gateway("phone-id"))
        #expect(mac.suggestions(for: gateway("mac-id")).hidden.keys.contains("touchdesigner"))

        // Both answer before either hears the other.
        var onMac = mac.suggestions(for: gateway("mac-id"))
        var onPhone = phone.suggestions(for: gateway("phone-id"))
        onMac.showAgain("touchdesigner", on: .now)
        onPhone.hide("obsidian", on: .now)
        mac.save(onMac, for: gateway("mac-id"))
        phone.save(onPhone, for: gateway("phone-id"))

        #expect(Set(phone.suggestions(for: gateway("phone-id")).hidden.keys) == ["obsidian"])
        #expect(Set(mac.suggestions(for: gateway("mac-id")).hidden.keys) == ["obsidian"])
    }

    @Test func itSynchronizesAtFirstUseAndAfterEachChange() throws {
        let cloud = FakeKeyValues()
        let store = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        #expect(cloud.syncs == 1)
        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        store.save(list, for: gateway("gw"))
        #expect(cloud.syncs == 2)
        _ = store.suggestions(for: gateway("gw"))
        #expect(cloud.syncs == 2, "nothing changed, nothing to send")
    }

    @Test func aChangeFromAnotherDeviceReachesTheHub() throws {
        let cloud = FakeKeyValues()
        let phone = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        let macLocal = LocalHiddenSuggestions(defaults: try defaults())
        let mac = CloudHiddenSuggestions(local: macLocal, cloud: cloud)
        var heard: [HiddenSuggestions] = []
        _ = mac.suggestions(for: gateway("mac-id"))
        mac.observe(gateway("mac-id")) { heard.append($0) }

        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        phone.save(list, for: gateway("phone-id"))
        mac.externalChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["unrelated", sharedKey])

        #expect(heard.count == 1)
        #expect(heard.first?.hidden.keys.contains("touchdesigner") == true)
        #expect(macLocal.list("mac-id").hidden.keys.contains("touchdesigner"), "merged into this device's copy")
    }

    @Test func theHubIsHeardUnderTheKeyItWasLastSeenWith() throws {
        let cloud = FakeKeyValues()
        let store = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        var heard = 0
        // Before the gateway answered: no key yet, so nothing to hear.
        store.observe(HiddenSuggestionsGateway(deviceID: "gw")) { _ in heard += 1 }
        store.externalChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: [sharedKey])
        #expect(heard == 0)
        store.observe(gateway("gw")) { _ in heard += 1 }
        store.externalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: [sharedKey])
        #expect(heard == 1)
    }

    @Test(arguments: [NSUbiquitousKeyValueStoreQuotaViolationChange, NSUbiquitousKeyValueStoreAccountChange])
    func overQuotaOrAnotherAccountKeepsThisDevicesCopy(reason: Int) throws {
        let cloud = FakeKeyValues()
        let local = LocalHiddenSuggestions(defaults: try defaults())
        let store = CloudHiddenSuggestions(local: local, cloud: cloud)
        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        store.save(list, for: gateway("gw"))
        var heard = 0
        store.observe(gateway("gw")) { _ in heard += 1 }

        cloud.values = [:]
        store.externalChange(reason: reason, keys: [sharedKey])
        #expect(heard == 0)
        #expect(local.list("gw").hidden.keys.contains("touchdesigner"), "never wiped")

        // The next read puts it back in iCloud.
        #expect(store.suggestions(for: gateway("gw")).hidden.keys.contains("touchdesigner"))
        #expect(cloud.values[sharedKey] != nil)
    }

    @Test func aCopyFromANewerVersionIsLeftAlone() throws {
        let cloud = FakeKeyValues()
        let future = Data(#"{"version":2}"#.utf8)
        cloud.values[sharedKey] = future
        let store = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        #expect(store.save(list, for: gateway("gw")).hidden.keys.contains("touchdesigner"))
        #expect(cloud.values[sharedKey] == future)
    }

    @Test func forgettingAGatewayLeavesTheOtherDevicesCopy() throws {
        let cloud = FakeKeyValues()
        let local = LocalHiddenSuggestions(defaults: try defaults())
        let store = CloudHiddenSuggestions(local: local, cloud: cloud)
        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        store.save(list, for: gateway("gw"))
        store.forget(HiddenSuggestionsGateway(deviceID: "gw"))
        #expect(local.list("gw").marks.isEmpty)
        #expect(cloud.values[sharedKey] != nil)
    }

    @Test func aGatewayWithoutANameStaysOnThisDevice() throws {
        let cloud = FakeKeyValues()
        let store = CloudHiddenSuggestions(local: LocalHiddenSuggestions(defaults: try defaults()), cloud: cloud)
        var list = HiddenSuggestions()
        list.hide("touchdesigner", on: .now)
        store.save(list, for: HiddenSuggestionsGateway(deviceID: "gw", sharedKey: HiddenSuggestionKey.shared(hostname: "  ")))
        #expect(cloud.values.isEmpty)
        #expect(store.suggestions(for: HiddenSuggestionsGateway(deviceID: "gw")).hidden.keys.contains("touchdesigner"))
    }

    // MARK: Keys

    @Test func everyDeviceReachesTheSameShortKey() throws {
        for name in ["Studio-Mac.local", "studio-mac", " STUDIO-MAC.local. ", "studio-mac."] {
            #expect(HiddenSuggestionKey.shared(hostname: name) == sharedKey)
        }
        #expect(HiddenSuggestionKey.shared(hostname: "nas") != sharedKey)
        #expect(HiddenSuggestionKey.shared(hostname: "") == nil)
        let long = try #require(HiddenSuggestionKey.shared(hostname: String(repeating: "très-long-hôte.", count: 40)))
        for key in [sharedKey, long] {
            #expect(key.utf8.count <= HiddenSuggestionKey.maxBytes)
            #expect(HiddenSuggestionKey.isShared(key))
        }
    }

    @Test func aKeyNamesNothingThePersonTyped() throws {
        let key = try #require(HiddenSuggestionKey.shared(hostname: "https://ada:hunter2@studio-mac.example:8642/?key=sk-abc"))
        for secret in ["ada", "hunter2", "studio", "example", "8642", "sk-abc"] {
            #expect(!key.contains(secret))
        }
        let digest = key.dropFirst(HiddenSuggestionKey.prefix.count)
        #expect(digest.count == 32 && digest.allSatisfy { $0.isHexDigit })
    }

    // MARK: Settings → Setup

    @Test func setupSaysWhichApplies() {
        let syncing = HiddenSuggestionsSync(entitled: true, iCloudAvailable: true).setupStatus
        #expect(syncing.id == "device.hiddenSuggestions")
        #expect(syncing.state == .ready)
        #expect(syncing.fallback == nil)

        let signedOut = HiddenSuggestionsSync(entitled: true, iCloudAvailable: false)
        #expect(signedOut == .iCloudUnavailable)
        #expect(signedOut.setupStatus.state == .limited)
        #expect(signedOut.setupStatus.fallback?.contains("this device only") == true)
        #expect(signedOut.setupStatus.steps.first?.text.contains("iCloud") == true)

        let notInBuild = HiddenSuggestionsSync(entitled: false, iCloudAvailable: true)
        #expect(notInBuild == .notInThisBuild)
        #expect(notInBuild.setupStatus.state == .ready)
        #expect(notInBuild.setupStatus.fallback?.contains("this device only") == true)
        #expect(notInBuild.setupStatus.steps.isEmpty)
    }

    /// Info.plist's `HermesICloudKeyValueSync` comes from a build setting, so it reads as text:
    /// "YES" where the build carries the entitlement, "NO" (the Mac's Debug builds) or nothing where not.
    @Test func theInfoPlistFlagReadsAsTextOrABoolean() {
        #expect(HiddenSuggestionsSync.entitled(infoValue: "YES"))
        #expect(HiddenSuggestionsSync.entitled(infoValue: "yes"))
        #expect(HiddenSuggestionsSync.entitled(infoValue: true))
        #expect(!HiddenSuggestionsSync.entitled(infoValue: "NO"))
        #expect(!HiddenSuggestionsSync.entitled(infoValue: ""))
        #expect(!HiddenSuggestionsSync.entitled(infoValue: "$(HERMES_ICLOUD_KEY_VALUE_SYNC)"))
        #expect(!HiddenSuggestionsSync.entitled(infoValue: false))
        #expect(!HiddenSuggestionsSync.entitled(infoValue: nil))
    }

    /// Settings → Setup's "N things to set up" counts only what the person can set up: a build
    /// without the entitlement never adds one, a device with iCloud off does.
    @Test func onlyICloudOffCountsAsSomethingToSetUp() {
        let notInBuild = [HiddenSuggestionsSync.notInThisBuild.setupStatus]
        #expect(notInBuild.needingAttention == 0)
        let signedOut = [HiddenSuggestionsSync.iCloudUnavailable.setupStatus]
        #expect(signedOut.needingAttention == 1)
        #expect([HiddenSuggestionsSync.syncing.setupStatus].needingAttention == 0)
    }
}
