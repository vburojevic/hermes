import Foundation
import Security
import Synchronization
import Testing
@testable import HermesKit

/// A Keychain that answers the store's calls from a table and records each one, so these tests
/// never reach a real Keychain. `refuseDataProtection` answers data-protection calls as an
/// unentitled process gets answered: writes are refused, and reads are refused or find nothing
/// (`swift test` on a Mac gets "not found").
private final class FakeKeychain: Sendable {
    enum Operation: Equatable, Sendable { case read, update, add, delete }

    struct Call: Equatable, Sendable {
        let operation: Operation
        let account: String
        let dataProtection: Bool
    }

    private struct State {
        var items: [String: Data] = [:]
        var calls: [Call] = []
    }

    let refuseDataProtection: Bool
    let refusedReads: OSStatus
    private let state = Mutex(State())

    init(refuseDataProtection: Bool, refusedReads: OSStatus = errSecMissingEntitlement) {
        self.refuseDataProtection = refuseDataProtection
        self.refusedReads = refusedReads
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// The calls that would have reached the login keychain.
    var legacyCalls: [Call] { calls.filter { !$0.dataProtection } }

    func store(service: String, fallback: KeychainStore.MacFallback) -> KeychainStore {
        KeychainStore(
            service: service,
            macFallback: fallback,
            calls: KeychainStore.Calls(
                copyMatching: { query in
                    let (status, key) = self.record(.read, query)
                    guard status == errSecSuccess else { return (status, nil) }
                    let data = self.state.withLock { $0.items[key] }
                    return data.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
                },
                update: { query, attributes in
                    let (status, key) = self.record(.update, query)
                    guard status == errSecSuccess else { return status }
                    return self.state.withLock { state in
                        guard state.items[key] != nil else { return errSecItemNotFound }
                        if let data = attributes[kSecValueData as String] as? Data { state.items[key] = data }
                        return errSecSuccess
                    }
                },
                add: { item in
                    let (status, key) = self.record(.add, item)
                    guard status == errSecSuccess else { return status }
                    self.state.withLock { $0.items[key] = item[kSecValueData as String] as? Data }
                    return errSecSuccess
                },
                delete: { query in
                    let (status, key) = self.record(.delete, query)
                    guard status == errSecSuccess else { return status }
                    return self.state.withLock { $0.items.removeValue(forKey: key) } == nil ? errSecItemNotFound : errSecSuccess
                }
            )
        )
    }

    /// Records the call and answers whether the keychain it names may be used, with the item's key.
    private func record(_ operation: Operation, _ query: [String: Any]) -> (OSStatus, String) {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        let service = query[kSecAttrService as String] as? String ?? ""
        let dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
        state.withLock { $0.calls.append(Call(operation: operation, account: account, dataProtection: dataProtection)) }
        let refusal = operation == .read ? refusedReads : errSecMissingEntitlement
        let status = dataProtection && refuseDataProtection ? refusal : errSecSuccess
        return (status, "\(dataProtection ? "protected" : "legacy")/\(service)/\(account)")
    }
}

@Suite("Keychain store")
struct KeychainStoreTests {
    private let service = "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)"

    @Test func debugBuildsKeepSecretsInMemoryWhenTheyCantUseTheKeychain() {
        #if DEBUG
        #expect(KeychainStore.MacFallback.standard == .processMemory)
        #else
        #expect(KeychainStore.MacFallback.standard == .legacyKeychain)
        #endif
    }

    #if os(macOS)
    @Test(arguments: [errSecMissingEntitlement, errSecItemNotFound])
    func anUnentitledBuildKeepsTheKeyInMemoryAndNeverTouchesTheLoginKeychain(refusedReads: OSStatus) throws {
        let keychain = FakeKeychain(refuseDataProtection: true, refusedReads: refusedReads)
        let store = keychain.store(service: service, fallback: .processMemory)

        #expect(try store.string(for: "bot") == nil)
        try store.setString("first", for: "bot")
        #expect(try store.string(for: "bot") == "first")
        try store.setString("second", for: "bot")
        #expect(try store.string(for: "bot") == "second")
        try store.removeValue(for: "bot")
        #expect(try store.string(for: "bot") == nil)

        #expect(!keychain.calls.isEmpty)
        #expect(keychain.legacyCalls.isEmpty)
    }

    @Test func aKeyMissingFromTheDataProtectionKeychainIsntLookedForInTheLoginKeychain() throws {
        let keychain = FakeKeychain(refuseDataProtection: false)
        let store = keychain.store(service: service, fallback: .processMemory)

        #expect(try store.string(for: "bot") == nil)
        try store.setString("key", for: "bot")
        #expect(try store.string(for: "bot") == "key")
        try store.removeValue(for: "bot")
        #expect(try store.string(for: "bot") == nil)

        #expect(keychain.legacyCalls.isEmpty)
    }

    @Test func storesForTheSameServiceShareWhatTheyKeepInMemory() throws {
        let keychain = FakeKeychain(refuseDataProtection: true)
        try keychain.store(service: service, fallback: .processMemory).setString("key", for: "bot")

        #expect(try keychain.store(service: service, fallback: .processMemory).string(for: "bot") == "key")
        #expect(try keychain.store(service: "\(service).other", fallback: .processMemory).string(for: "bot") == nil)

        try keychain.store(service: service, fallback: .processMemory).removeValue(for: "bot")
        #expect(try keychain.store(service: service, fallback: .processMemory).string(for: "bot") == nil)
        #expect(keychain.legacyCalls.isEmpty)
    }

    @Test func aFaultStillComesBeforeMemory() throws {
        let keychain = FakeKeychain(refuseDataProtection: true)
        try keychain.store(service: service, fallback: .processMemory).setString("key", for: "bot")
        let locked = KeychainStore(
            service: service,
            macFallback: .processMemory,
            calls: keychain.store(service: service, fallback: .processMemory).calls
        ) { _, _ in errSecInteractionNotAllowed }

        #expect(throws: KeychainStore.Failure.unexpectedStatus(errSecInteractionNotAllowed)) {
            try locked.string(for: "bot")
        }
        #expect(throws: KeychainStore.Failure.unexpectedStatus(errSecInteractionNotAllowed)) {
            try locked.setString("other", for: "bot")
        }
        #expect(try keychain.store(service: service, fallback: .processMemory).string(for: "bot") == "key")
    }

    @Test func releaseBuildsStillFallBackToTheLoginKeychain() throws {
        let keychain = FakeKeychain(refuseDataProtection: true)
        let store = keychain.store(service: service, fallback: .legacyKeychain)

        try store.setString("key", for: "bot")
        #expect(try store.string(for: "bot") == "key")
        try store.removeValue(for: "bot")

        typealias Call = FakeKeychain.Call
        #expect(keychain.calls == [
            Call(operation: .update, account: "bot", dataProtection: true),
            Call(operation: .update, account: "bot", dataProtection: false),
            Call(operation: .add, account: "bot", dataProtection: false),
            Call(operation: .read, account: "bot", dataProtection: true),
            Call(operation: .read, account: "bot", dataProtection: false),
            Call(operation: .delete, account: "bot", dataProtection: true),
            Call(operation: .delete, account: "bot", dataProtection: false),
        ])
    }

    @Test func releaseBuildsStillReadTheLoginKeychainWhenTheDataProtectionOneHasNothing() throws {
        let keychain = FakeKeychain(refuseDataProtection: false)
        let store = keychain.store(service: service, fallback: .legacyKeychain)

        #expect(try store.string(for: "bot") == nil)
        #expect(keychain.calls == [
            FakeKeychain.Call(operation: .read, account: "bot", dataProtection: true),
            FakeKeychain.Call(operation: .read, account: "bot", dataProtection: false),
        ])
    }
    #endif
}
