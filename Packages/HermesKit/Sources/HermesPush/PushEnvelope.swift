import CryptoKit
import Foundation

/// A notice sealed for one device by the gateway plugin (`Tools/hermes-app-push/crypto.py`).
///
/// X25519 with a fresh ephemeral key per notice, HKDF-SHA256 (salt = ephemeral public key ‖
/// device public key, info `hermes-app-push v1`, 32 bytes), then ChaCha20-Poly1305. `box` is
/// `ChaChaPoly.SealedBox.combined` (nonce ‖ ciphertext ‖ tag). The relay and Apple only ever
/// see this envelope.
public struct PushEnvelope: Codable, Sendable, Hashable {
    public var v: Int
    public var epk: String
    public var box: String

    public init(v: Int = 1, epk: String, box: String) {
        self.v = v
        self.epk = epk
        self.box = box
    }

    /// The envelope from a push payload's `hermes` value (a JSON object in `userInfo`).
    public init?(payload: Any?) {
        guard let object = payload as? [AnyHashable: Any],
              let epk = object["epk"] as? String, let box = object["box"] as? String
        else { return nil }
        self.init(v: (object["v"] as? Int) ?? (object["v"] as? NSNumber)?.intValue ?? 1, epk: epk, box: box)
    }
}

public enum PushCryptoError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformed
}

/// This device's notification key: the private half stays in the shared Keychain, the public
/// half goes to every gateway the app registers with.
public struct PushDeviceKey: Sendable {
    static let info = Data("hermes-app-push v1".utf8)

    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try .init(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// What the plugin's `register` command takes: 32 raw bytes, base64.
    public var publicKeyBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

    public func open(_ envelope: PushEnvelope) throws -> Data {
        guard envelope.v == 1 else { throw PushCryptoError.unsupportedVersion(envelope.v) }
        guard let ephemeralRaw = Data(base64Encoded: envelope.epk), let combined = Data(base64Encoded: envelope.box),
              combined.count > 28
        else { throw PushCryptoError.malformed }
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let key = try Self.key(
            shared: privateKey.sharedSecretFromKeyAgreement(with: ephemeral),
            ephemeral: ephemeralRaw, device: privateKey.publicKey.rawRepresentation
        )
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: key)
    }

    public func open<Value: Decodable>(_ type: Value.Type, from envelope: PushEnvelope) throws -> Value {
        try JSONDecoder().decode(type, from: open(envelope))
    }

    /// Seals for a device's public key exactly the way the plugin does (the mock, tests, and
    /// Live Activity states the app writes itself).
    public static func seal(_ plaintext: Data, to publicKey: Curve25519.KeyAgreement.PublicKey) throws -> PushEnvelope {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralRaw = ephemeral.publicKey.rawRepresentation
        let key = try key(
            shared: ephemeral.sharedSecretFromKeyAgreement(with: publicKey),
            ephemeral: ephemeralRaw, device: publicKey.rawRepresentation
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        return PushEnvelope(epk: ephemeralRaw.base64EncodedString(), box: sealed.combined.base64EncodedString())
    }

    public func seal<Value: Encodable>(_ value: Value) throws -> PushEnvelope {
        try Self.seal(JSONEncoder().encode(value), to: privateKey.publicKey)
    }

    private static func key(shared: SharedSecret, ephemeral: Data, device: Data) throws -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + device, sharedInfo: info, outputByteCount: 32)
    }
}
