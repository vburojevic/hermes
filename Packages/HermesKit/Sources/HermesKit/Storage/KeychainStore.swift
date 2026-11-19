import Foundation
import Security
import Synchronization

/// Stores small secrets (Hermes API keys) as generic passwords.
///
/// On macOS the data-protection keychain needs a provisioned application identifier; ad-hoc
/// signed development builds don't have one and get `errSecMissingEntitlement`. What happens then
/// is the store's `MacFallback`: a Debug build keeps the secret in memory for the life of the
/// process, and a Release build falls back to the login keychain.
public struct KeychainStore: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    /// Where a secret goes on macOS when the data-protection keychain answers
    /// `errSecMissingEntitlement`.
    enum MacFallback: Sendable {
        /// The login keychain, read, written and deleted as before.
        case legacyKeychain
        /// Memory, for the life of the process. The login keychain is never touched: each
        /// development build has its own bundle id and signature, so every item it left there
        /// made macOS ask for the login keychain password on the next launch.
        case processMemory

        /// Debug builds never reach the login keychain, so no development build can make macOS
        /// ask for its password; Release builds are entitled and keep the login keychain only as
        /// the fallback they always had.
        static var standard: MacFallback {
            #if DEBUG
            .processMemory
            #else
            .legacyKeychain
            #endif
        }
    }

    /// The four Keychain calls the store makes, so tests can answer them without a real Keychain.
    struct Calls: Sendable {
        var copyMatching: @Sendable (_ query: [String: Any]) -> (status: OSStatus, data: Data?)
        var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
        var add: @Sendable (_ item: [String: Any]) -> OSStatus
        var delete: @Sendable (_ query: [String: Any]) -> OSStatus

        static let system = Calls(
            copyMatching: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            update: { query, attributes in SecItemUpdate(query as CFDictionary, attributes as CFDictionary) },
            add: { item in SecItemAdd(item as CFDictionary, nil) },
            delete: { query in SecItemDelete(query as CFDictionary) }
        )
    }

    public let service: String
    let macFallback: MacFallback
    let calls: Calls
    /// Makes a read or write fail as a locked or refusing Keychain would, by account: the status
    /// to fail with, or nil to go ahead. Only tests set it (`BotConfigurationTests`).
    let fault: (@Sendable (_ account: String, _ writing: Bool) -> OSStatus?)?

    /// A gateway key runs commands on that machine: it stays on this device, readable after the
    /// first unlock (background refresh, notification answers), never restored onto another
    /// device from a backup. Moving to a new device means pairing again.
    static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    public init(service: String) {
        self.init(service: service, fault: nil)
    }

    init(service: String, fault: (@Sendable (_ account: String, _ writing: Bool) -> OSStatus?)?) {
        self.init(service: service, macFallback: .standard, calls: .system, fault: fault)
    }

    init(
        service: String,
        macFallback: MacFallback,
        calls: Calls,
        fault: (@Sendable (_ account: String, _ writing: Bool) -> OSStatus?)? = nil
    ) {
        self.service = service
        self.macFallback = macFallback
        self.calls = calls
        self.fault = fault
    }

    public func string(for account: String) throws -> String? {
        if let status = fault?(account, false) {
            if status == errSecItemNotFound { return nil }
            throw Failure.unexpectedStatus(status)
        }
        #if os(macOS)
        switch macFallback {
        case .legacyKeychain:
            // A development build may have written to either keychain; check both.
            do {
                if let value = try read(account: account, useDataProtection: true) { return value }
            } catch Failure.unexpectedStatus(errSecMissingEntitlement) {
            }
            return try read(account: account, useDataProtection: false)
        case .processMemory:
            // An unentitled process can get "not found" for a read the data-protection keychain
            // would refuse to write, so memory answers both. It only holds what a refused write
            // put there.
            do {
                if let value = try read(account: account, useDataProtection: true) { return value }
            } catch Failure.unexpectedStatus(errSecMissingEntitlement) {
            }
            return Self.memory.withLock { $0[memoryKey(account)] }
        }
        #else
        return try read(account: account, useDataProtection: true)
        #endif
    }

    private func read(account: String, useDataProtection: Bool) throws -> String? {
        var query = baseQuery(account: account, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = calls.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data else { return nil }
            if useDataProtection { keepOnThisDevice(baseQuery(account: account, useDataProtection: true)) }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    public func setString(_ value: String, for account: String) throws {
        if let status = fault?(account, true) { throw Failure.unexpectedStatus(status) }
        let data = Data(value.utf8)
        do {
            try write(data, account: account, useDataProtection: true)
        } catch Failure.unexpectedStatus(errSecMissingEntitlement) {
            #if os(macOS)
            switch macFallback {
            case .legacyKeychain:
                try write(data, account: account, useDataProtection: false)
            case .processMemory:
                Self.memory.withLock { $0[memoryKey(account)] = value }
            }
            #else
            throw Failure.unexpectedStatus(errSecMissingEntitlement)
            #endif
        }
    }

    private func write(_ data: Data, account: String, useDataProtection: Bool) throws {
        let query = baseQuery(account: account, useDataProtection: useDataProtection)
        var attributes: [String: Any] = [kSecValueData as String: data]
        // The login keychain on a development Mac has no protection classes.
        if useDataProtection { attributes[kSecAttrAccessible as String] = Self.accessibility }
        let updateStatus = calls.update(query, attributes)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            if useDataProtection { item[kSecAttrAccessible as String] = Self.accessibility }
            let addStatus = calls.add(item)
            guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
        default:
            throw Failure.unexpectedStatus(updateStatus)
        }
    }

    public func removeValue(for account: String) throws {
        #if os(macOS)
        let acceptable: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        let protected = calls.delete(baseQuery(account: account, useDataProtection: true))
        switch macFallback {
        case .legacyKeychain:
            let legacy = calls.delete(baseQuery(account: account, useDataProtection: false))
            if !acceptable.contains(protected) { throw Failure.unexpectedStatus(protected) }
            if !acceptable.contains(legacy) { throw Failure.unexpectedStatus(legacy) }
        case .processMemory:
            Self.memory.withLock { _ = $0.removeValue(forKey: memoryKey(account)) }
            if !acceptable.contains(protected) { throw Failure.unexpectedStatus(protected) }
        }
        #else
        let status = calls.delete(baseQuery(account: account, useDataProtection: true))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
        #endif
    }

    /// Secrets kept under `MacFallback.processMemory`, by service and account. Every store for a
    /// service shares them (`BotStore.standard` makes a new store on each call), and they end
    /// with the process.
    private static let memory = Mutex<[String: String]>([:])

    private func memoryKey(_ account: String) -> String { "\(service)/\(account)" }

    /// Items saved before this class was used move to it the first time they're read (once per
    /// launch); a failure leaves the item as it was.
    private static let migrated = Mutex<Set<String>>([])

    private func keepOnThisDevice(_ query: [String: Any]) {
        let key = "\(query[kSecAttrService as String] ?? "")/\(query[kSecAttrAccount as String] ?? "")"
        guard Self.migrated.withLock({ $0.insert(key).inserted }) else { return }
        _ = calls.update(query, [kSecAttrAccessible as String: Self.accessibility])
    }

    private func baseQuery(account: String, useDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}
