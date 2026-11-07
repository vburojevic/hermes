import Foundation
import Security
import Testing

/// Whether the tests that store real secrets can use this Mac's Keychain without a prompt.
///
/// The first use turns Keychain prompts off for the whole test process, so a keychain that is
/// locked answers `errSecInteractionNotAllowed` at once instead of waiting for a password nobody
/// types (a release on a build Mac). It then looks once for an item that doesn't exist, the way
/// `KeychainStore` reads: the data-protection keychain first, then the login keychain when the
/// test process isn't entitled to that one. Only "not found" means the tests can go ahead.
enum RealKeychain {
    /// Why the real Keychain can't be used, or nil when it can.
    static let unusableReason: String? = probe()

    static var isUsable: Bool { unusableReason == nil }

    /// What the lookup for a missing item answered, read as the tests' verdict.
    static func reason(forLookup status: OSStatus) -> String? {
        status == errSecItemNotFound ? nil : "The Keychain answered \(describe(status)) without a prompt"
    }

    #if os(macOS)
    /// The default keychain's state, read as the tests' verdict: it must be there and unlocked.
    static func reason(forDefaultKeychain status: OSStatus, state: SecKeychainStatus) -> String? {
        guard status == errSecSuccess else { return "The default keychain can't be read: \(describe(status))" }
        guard state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { return "The default keychain is locked" }
        return nil
    }
    #endif

    private static func probe() -> String? {
        #if os(macOS)
        // SecKeychain is deprecated; reaching it through a protocol keeps the warning out of the
        // build without silencing it anywhere else.
        let legacy: any LegacyKeychain = LegacyKeychainCalls()
        let off = legacy.turnOffPrompts()
        guard off == errSecSuccess else { return "Keychain prompts couldn't be turned off: \(describe(off))" }
        let keychain = legacy.defaultKeychainState()
        if let reason = reason(forDefaultKeychain: keychain.status, state: keychain.state) { return reason }
        #endif
        let service = "co.caffeinatedcode.hermes.tests.probe.\(UUID().uuidString)"
        #if os(macOS)
        let status = lookUp(service: service, useDataProtection: true)
        return reason(forLookup: status == errSecMissingEntitlement ? lookUp(service: service, useDataProtection: false) : status)
        #else
        return reason(forLookup: lookUp(service: service, useDataProtection: true))
        #endif
    }

    private static func lookUp(service: String, useDataProtection: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #if os(macOS)
        if useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private static func describe(_ status: OSStatus) -> String {
        "\(SecCopyErrorMessageString(status, nil) as String? ?? "an error") (OSStatus \(status))"
    }
}

#if os(macOS)
/// The two SecKeychain calls the probe needs. Calling a deprecated witness through its protocol
/// requirement doesn't warn, and these are the only deprecated calls in the tests.
private protocol LegacyKeychain {
    func turnOffPrompts() -> OSStatus
    func defaultKeychainState() -> (status: OSStatus, state: SecKeychainStatus)
}

private struct LegacyKeychainCalls: LegacyKeychain {
    @available(*, deprecated, message: "SecKeychain is deprecated; only the tests' probe calls it.")
    func turnOffPrompts() -> OSStatus {
        SecKeychainSetUserInteractionAllowed(false)
    }

    @available(*, deprecated, message: "SecKeychain is deprecated; only the tests' probe calls it.")
    func defaultKeychainState() -> (status: OSStatus, state: SecKeychainStatus) {
        var state: SecKeychainStatus = 0
        let status = SecKeychainGetStatus(nil, &state)
        return (status, state)
    }
}
#endif

extension Trait where Self == ConditionTrait {
    /// Runs a test that reaches the real Keychain only where it answers without a prompt, and
    /// says why it was skipped otherwise.
    static var realKeychain: Self {
        .enabled(if: RealKeychain.isUsable, Comment(rawValue: RealKeychain.unusableReason ?? ""))
    }
}

@Suite("Real Keychain")
struct RealKeychainTests {
    @Test func onlyAMissingItemMeansTheKeychainIsUsable() {
        #expect(RealKeychain.reason(forLookup: errSecItemNotFound) == nil)
        for status in [errSecInteractionNotAllowed, errSecNoDefaultKeychain, errSecAuthFailed, errSecMissingEntitlement] {
            let reason = RealKeychain.reason(forLookup: status)
            #expect(reason?.contains("OSStatus \(status)") == true, "\(status) should not be usable")
        }
    }

    #if os(macOS)
    @Test func theDefaultKeychainMustBeThereAndUnlocked() {
        let unlocked = SecKeychainStatus(kSecUnlockStateStatus | kSecReadPermStatus | kSecWritePermStatus)
        let locked = SecKeychainStatus(kSecReadPermStatus | kSecWritePermStatus)
        #expect(RealKeychain.reason(forDefaultKeychain: errSecSuccess, state: unlocked) == nil)
        #expect(RealKeychain.reason(forDefaultKeychain: errSecSuccess, state: locked) == "The default keychain is locked")
        #expect(RealKeychain.reason(forDefaultKeychain: errSecNoDefaultKeychain, state: 0)?.contains("OSStatus \(errSecNoDefaultKeychain)") == true)
    }
    #endif
}
