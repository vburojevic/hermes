import CryptoKit
import Foundation
import HermesKit
import HermesPush
import LocalAuthentication
import os

/// Signs answers that need it (`docs/widgets.md` §6, contract §6.3): Face ID or Touch ID first,
/// then the device key's signature over `WidgetAnswer.signingInput`.
@MainActor
protocol WidgetAnswerSigning: AnyObject {
    /// The key the gateway checks signatures with (P-256, X9.63, base64), or `nil` on a device
    /// without a Secure Enclave: there the check alone gates the answer.
    var publicKey: String? { get }
    /// Counts the keys this device has made: a new one has to reach the gateway.
    var generation: Int { get }
    /// Asks for Face ID, Touch ID or the device passcode, then signs. Throws when the person
    /// cancels or can't authenticate.
    func authorize(_ answer: WidgetAnswer, reason: String) async throws -> String?
}

/// A Secure Enclave P-256 key only this device holds, that only Face ID or Touch ID unlocks
/// (`.biometryCurrentSet`: enrolling another face makes a new key). A Mac without Touch ID uses
/// its password (`.userPresence`). The key's sealed blob is kept in the Keychain on this device.
@MainActor
final class DeviceWidgetSigner: WidgetAnswerSigning {
    static let shared = DeviceWidgetSigner()

    enum Failure: Error, Equatable {
        case cancelled
        /// No Face ID, Touch ID or passcode on this device.
        case unavailable
        case failed
    }

    private static let keychain = KeychainStore(service: "\(Bundle.main.bundleIdentifier ?? "co.caffeinatedcode.hermes").widgets")
    private static let account = "signing-key"
    private static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    private var key: SecureEnclave.P256.Signing.PrivateKey?
    /// Bumped when the key is made again, so gateways get the new one.
    private(set) var generation = 0

    var publicKey: String? {
        (try? currentKey())?.publicKey.x963Representation.base64EncodedString()
    }

    func authorize(_ answer: WidgetAnswer, reason: String) async throws -> String? {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel")
        let policy: LAPolicy = Self.hasBiometry ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { throw Failure.unavailable }
        // The reply comes on a private queue: only its outcome crosses back.
        let outcome: LAError.Code? = await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                continuation.resume(returning: success ? nil : (error as? LAError)?.code ?? .authenticationFailed)
            }
        }
        switch outcome {
        case nil: break
        case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: throw Failure.cancelled
        case .biometryNotEnrolled?, .biometryNotAvailable?, .passcodeNotSet?: throw Failure.unavailable
        default: throw Failure.failed
        }
        guard Self.hasSecureEnclave else { return nil }
        let input = Data(answer.signingInput.utf8)
        // The context just checked unlocks the key once, without asking again.
        if let signature = try? currentKey(context: context).signature(for: input) {
            return signature.derRepresentation.base64EncodedString()
        }
        // Faces or fingers changed since the key was made: it can never sign again. A new one signs,
        // and the gateway gets it before the answer goes (`WidgetStore`).
        discardKey()
        if let signature = try? currentKey(context: context).signature(for: input) {
            return signature.derRepresentation.base64EncodedString()
        }
        // No key works on this device: the person passed the check, so the answer goes without a
        // signature, as on a device with no Secure Enclave (the plugin decides what that's worth).
        Self.logger.notice("widgets: no signing key works on this device; answering with the check alone")
        return nil
    }

    /// A simulator reports a Secure Enclave but can't use a key bound to Face ID (LocalAuthentication
    /// −1020), so there the check alone gates the answer, as on a device without one.
    private static var hasSecureEnclave: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    private static var hasBiometry: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func currentKey(context: LAContext? = nil) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard Self.hasSecureEnclave else { throw Failure.unavailable }
        if let key, context == nil { return key }
        if let stored = try? Self.keychain.string(for: Self.account), let data = Data(base64Encoded: stored) {
            let loaded = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context)
            key = loaded
            return loaded
        }
        let flags: SecAccessControlCreateFlags = Self.hasBiometry ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage, .userPresence]
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw Failure.failed
        }
        let made = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
        try Self.keychain.setString(made.dataRepresentation.base64EncodedString(), for: Self.account)
        key = made
        generation += 1
        return made
    }

    private func discardKey() {
        key = nil
        try? Self.keychain.removeValue(for: Self.account)
        generation += 1
    }
}
