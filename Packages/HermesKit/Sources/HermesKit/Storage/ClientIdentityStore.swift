import Foundation
import Security
import Synchronization

/// Keeps the client certificates proxies ask for (`docs/connecting-and-voice.md` §11.9): each
/// identity, the certificate with its private key, in the Keychain on this device only, found
/// again by its certificate's fingerprint (`ClientCertificate.fingerprint`). Gateways behind one
/// proxy can share one identity, so it goes only when no gateway names it any more.
///
/// The Keychain keeps an identity without the intermediates its file carried, and a proxy that
/// trusts only its root refuses a certificate sent without them. So the intermediates are kept
/// beside it, a generic password named by the same fingerprint, and come back with it.
///
/// On the Mac only the data-protection keychain is used, never the login keychain: an identity
/// there would ask for the account password whenever it's used. A build without the entitlement
/// for it (an ad-hoc Mac Debug build) gets `errSecMissingEntitlement` and can't keep one.
public struct ClientIdentityStore: Sendable {
    private enum Backend: Sendable {
        case keychain
        case memory(Memory)
    }

    private let backend: Backend

    /// The Keychain's identities, the app's alone.
    public static let keychain = ClientIdentityStore(backend: .keychain)

    /// Identities kept for this process only: tests, and a Debug run on the Mac
    /// (`-HERMES_MEMORY_CERTIFICATES`), whose keychain no test may add a certificate to.
    public static func inMemory() -> ClientIdentityStore {
        ClientIdentityStore(backend: .memory(Memory()))
    }

    private init(backend: Backend) {
        self.backend = backend
    }

    /// The identity whose certificate has this fingerprint, or nil.
    public func identity(fingerprint: String) throws -> ClientIdentity? {
        switch backend {
        case .memory(let memory):
            guard let kept = memory.items.withLock({ $0[fingerprint] }) else { return nil }
            return ClientIdentity(identity: kept.identity, chain: Self.chain(from: kept.chain))
        case .keychain:
            guard let identity = try Self.keychainIdentities().first(where: { $0.fingerprint == fingerprint }) else { return nil }
            return ClientIdentity(identity: identity.identity, chain: Self.chain(from: try Self.keychainChain(fingerprint)))
        }
    }

    /// Keeps an identity; one that's there already stays as it is.
    public func save(_ identity: ClientIdentity) throws {
        switch backend {
        case .memory(let memory):
            guard let fingerprint = identity.fingerprint else { throw KeychainStore.Failure.unexpectedStatus(errSecParam) }
            // Kept the way the Keychain keeps it, so a reload here rebuilds the chain the same way.
            let kept = Memory.Kept(identity: identity.identity, chain: Self.encoded(identity.chain))
            memory.items.withLock { $0[fingerprint] = kept }
        case .keychain:
            guard let fingerprint = identity.fingerprint else { throw KeychainStore.Failure.unexpectedStatus(errSecParam) }
            try Self.saveKeychainChain(Self.encoded(identity.chain), fingerprint: fingerprint)
            var item = Self.scope
            item[kSecValueRef as String] = identity.identity
            item[kSecAttrAccessible as String] = KeychainStore.accessibility
            item[kSecAttrLabel as String] = "Hermes client certificate"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw KeychainStore.Failure.unexpectedStatus(status)
            }
        }
    }

    /// Removes the identity with this fingerprint; nothing happens when it isn't there.
    public func remove(fingerprint: String) throws {
        switch backend {
        case .memory(let memory):
            _ = memory.items.withLock { $0.removeValue(forKey: fingerprint) }
        case .keychain:
            let chain = SecItemDelete(Self.chainQuery(fingerprint) as CFDictionary)
            guard chain == errSecSuccess || chain == errSecItemNotFound else {
                throw KeychainStore.Failure.unexpectedStatus(chain)
            }
            guard let identity = try Self.keychainIdentities().first(where: { $0.fingerprint == fingerprint }) else { return }
            var query = Self.scope
            query[kSecValueRef as String] = identity.identity
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStore.Failure.unexpectedStatus(status)
            }
        }
    }

    /// Removes the identity `fingerprint` names unless one of `stillUsed` still needs it.
    public func release(_ fingerprint: String?, stillUsed: some Sequence<String>) throws {
        guard let fingerprint, !stillUsed.contains(fingerprint) else { return }
        try remove(fingerprint: fingerprint)
    }

    private static var scope: [String: Any] {
        var query: [String: Any] = [:]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private static func keychainIdentities() throws -> [ClientIdentity] {
        var query = scope
        query[kSecClass as String] = kSecClassIdentity
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let found = (result as? [Any]) ?? [result as Any]
            return found.compactMap { value in
                let object = value as CFTypeRef
                guard CFGetTypeID(object) == SecIdentityGetTypeID() else { return nil }
                return ClientIdentity(identity: object as! SecIdentity)
            }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainStore.Failure.unexpectedStatus(status)
        }
    }

    // MARK: The intermediates

    private static let chainService = "co.caffeinatedcode.hermes.client-certificate-chain"

    private static func chainQuery(_ fingerprint: String) -> [String: Any] {
        var query = scope
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = chainService
        query[kSecAttrAccount as String] = fingerprint
        return query
    }

    /// Replaces what's kept for this fingerprint: an identity saved again from a newer file of
    /// the same certificate brings its own intermediates.
    private static func saveKeychainChain(_ data: Data, fingerprint: String) throws {
        let query = chainQuery(fingerprint)
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw KeychainStore.Failure.unexpectedStatus(deleted)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = KeychainStore.accessibility
        item[kSecAttrLabel as String] = "Hermes client certificate chain"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.Failure.unexpectedStatus(status) }
    }

    private static func keychainChain(_ fingerprint: String) throws -> Data? {
        var query = chainQuery(fingerprint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainStore.Failure.unexpectedStatus(status)
        }
    }

    /// The intermediates as their DER, in order, as a property list.
    static func encoded(_ chain: [SecCertificate]) -> Data {
        let ders = chain.map { SecCertificateCopyData($0) as Data }
        return (try? PropertyListEncoder().encode(ders)) ?? Data()
    }

    /// The intermediates back from `encoded`; anything unreadable leaves them out, so the
    /// certificate still goes and the proxy says whether it needs more.
    static func chain(from data: Data?) -> [SecCertificate] {
        guard let data, let ders = try? PropertyListDecoder().decode([Data].self, from: data) else { return [] }
        return ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    private final class Memory: Sendable {
        struct Kept: @unchecked Sendable {
            let identity: SecIdentity
            let chain: Data
        }

        let items = Mutex<[String: Kept]>([:])
    }
}
