import Foundation
import Security

/// Stores small secrets (Hermes API keys) as generic passwords.
///
/// On macOS the data-protection keychain needs a provisioned application
/// identifier; ad-hoc signed development builds don't have one and get
/// `errSecMissingEntitlement`, so those fall back to the login keychain.
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

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func string(for account: String) throws -> String? {
        #if os(macOS)
        // A development build may have written to either keychain; check both.
        do {
            if let value = try read(account: account, useDataProtection: true) { return value }
        } catch Failure.unexpectedStatus(errSecMissingEntitlement) {
        }
        return try read(account: account, useDataProtection: false)
        #else
        return try read(account: account, useDataProtection: true)
        #endif
    }

    private func read(account: String, useDataProtection: Bool) throws -> String? {
        var query = baseQuery(account: account, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    public func setString(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        try withKeychainFallback { useDataProtection in
            let query = baseQuery(account: account, useDataProtection: useDataProtection)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
            default:
                throw Failure.unexpectedStatus(updateStatus)
            }
        }
    }

    public func removeValue(for account: String) throws {
        #if os(macOS)
        let protected = SecItemDelete(baseQuery(account: account, useDataProtection: true) as CFDictionary)
        let legacy = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
        let acceptable: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        if !acceptable.contains(protected) { throw Failure.unexpectedStatus(protected) }
        if !acceptable.contains(legacy) { throw Failure.unexpectedStatus(legacy) }
        #else
        let status = SecItemDelete(baseQuery(account: account, useDataProtection: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
        #endif
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

    private func withKeychainFallback<T>(_ body: (_ useDataProtection: Bool) throws -> T) throws -> T {
        #if os(macOS)
        do {
            return try body(true)
        } catch Failure.unexpectedStatus(errSecMissingEntitlement) {
            return try body(false)
        }
        #else
        return try body(true)
        #endif
    }
}
