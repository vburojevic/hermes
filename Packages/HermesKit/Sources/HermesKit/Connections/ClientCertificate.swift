import CryptoKit
import Foundation
import Security

/// The client certificate a proxy in front of a gateway asks for (`docs/connecting-and-voice.md`
/// §11.9), as it's saved with the gateway in `bots.json`: what the Access card shows and the
/// fingerprint that finds its identity in the Keychain (`ClientIdentityStore`). The private key
/// never leaves the Keychain, and the password that opened the file is never kept.
public struct ClientCertificate: Hashable, Codable, Sendable {
    /// SHA-256 of the certificate, hex: names the identity in the Keychain.
    public var fingerprint: String
    /// The file it came from, for the card ("home-server.p12").
    public var fileName: String
    /// Who it was issued to: the subject's common name, or the system's summary of it.
    public var subject: String
    /// Who issued it: the issuer's common name, or its organization.
    public var issuer: String
    public var notAfter: Date

    public init(fingerprint: String, fileName: String, subject: String, issuer: String, notAfter: Date) {
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.subject = subject
        self.issuer = issuer
        self.notAfter = notAfter
    }

    public func isExpired(at date: Date = .now) -> Bool { notAfter <= date }

    /// Why a file couldn't be imported, in the words the import sheet shows.
    public enum ImportFailure: Error, Equatable, Sendable {
        /// The password didn't open the file.
        case wrongPassword
        /// It opened, but holds no certificate with its private key.
        case noIdentity
        /// It isn't a PKCS#12 file the system can read.
        case unreadable(OSStatus)
    }

    /// Opens a .p12 or .pfx file in memory with `password`. Nothing is added to a keychain here:
    /// on the Mac the system would otherwise put the identity in the login keychain, so the import
    /// is memory-only and `ClientIdentityStore.save` decides where it goes.
    public static func open(_ data: Data, password: String, fileName: String) throws(ImportFailure) -> (ClientCertificate, ClientIdentity) {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        options[kSecImportToMemoryOnly as String] = true
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw .wrongPassword
        default: throw .unreadable(status)
        }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { throw .noIdentity }
        let identity = value as! SecIdentity
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { throw .noIdentity }
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate]) ?? []
        let summary = ClientCertificate(leaf, fileName: fileName)
        return (summary, ClientIdentity(identity: identity, chain: chain.filter { !$0.isSame(as: leaf) }))
    }

    /// The summary of a certificate the system has already parsed.
    init(_ certificate: SecCertificate, fileName: String) {
        let der = SecCertificateCopyData(certificate) as Data
        let names = DERNames(der)
        fingerprint = Self.fingerprint(of: der)
        self.fileName = fileName
        subject = names?.subject ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        issuer = names?.issuer ?? ""
        notAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date? ?? .distantPast
    }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// A certificate and its private key, as the system holds them, with the intermediates the file
/// carried. Immutable Core Foundation objects, so safe to pass between threads.
public struct ClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let chain: [SecCertificate]

    public init(identity: SecIdentity, chain: [SecCertificate] = []) {
        self.identity = identity
        self.chain = chain
    }

    /// What a proxy's challenge is answered with, never saved by the URL system.
    public var credential: URLCredential {
        URLCredential(identity: identity, certificates: chain.isEmpty ? nil : chain, persistence: .none)
    }

    public var fingerprint: String? {
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { return nil }
        return ClientCertificate.fingerprint(of: SecCertificateCopyData(leaf) as Data)
    }
}

private extension SecCertificate {
    func isSame(as other: SecCertificate) -> Bool {
        (SecCertificateCopyData(self) as Data) == (SecCertificateCopyData(other) as Data)
    }
}

/// The subject's and issuer's common names, read from the certificate's DER: the system gives
/// the subject's summary on every platform, but the issuer's name only on the Mac. Falls back to
/// the organization when a name has no common name.
struct DERNames {
    let subject: String?
    let issuer: String?

    init?(_ der: Data) {
        let bytes = [UInt8](der)
        // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version?, serial, signature,
        // issuer, validity, subject, ... }, ... }
        guard let certificate = DERReader.element(bytes, at: 0), certificate.tag == 0x30,
              let tbs = DERReader.element(bytes, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }
        var fields: [DERReader.Element] = []
        var offset = tbs.contentStart
        while offset < tbs.end, fields.count < 6, let field = DERReader.element(bytes, at: offset) {
            fields.append(field)
            offset = field.end
        }
        let start = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= start + 5 else { return nil }
        issuer = Self.name(bytes, fields[start + 2])
        subject = Self.name(bytes, fields[start + 4])
    }

    private static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let organization: [UInt8] = [0x55, 0x04, 0x0A]

    /// Name ::= SEQUENCE OF SET OF SEQUENCE { type OID, value string }.
    private static func name(_ bytes: [UInt8], _ name: DERReader.Element) -> String? {
        var found: [[UInt8]: String] = [:]
        var offset = name.contentStart
        while offset < name.end, let set = DERReader.element(bytes, at: offset) {
            var inner = set.contentStart
            while inner < set.end, let pair = DERReader.element(bytes, at: inner) {
                if let type = DERReader.element(bytes, at: pair.contentStart), type.tag == 0x06,
                   let value = DERReader.element(bytes, at: type.end), value.end <= pair.end {
                    let oid = Array(bytes[type.contentStart..<type.end])
                    let text = Self.text(bytes[value.contentStart..<value.end], tag: value.tag)
                    if found[oid] == nil, !text.isEmpty { found[oid] = text }
                }
                inner = pair.end
            }
            offset = set.end
        }
        return found[commonName] ?? found[organization]
    }

    /// A name's value in its own string type: BMPString is UTF-16 big-endian, TeletexString is
    /// read as Latin-1 (what issuers put there in practice), and the rest (UTF8String,
    /// PrintableString, IA5String) read as UTF-8, which the ASCII ones are a part of.
    static func text(_ value: ArraySlice<UInt8>, tag: UInt8) -> String {
        switch tag {
        case 0x1E:
            let bytes = Array(value)
            guard bytes.count.isMultiple(of: 2) else { return "" }
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        case 0x14:
            return String(value.map { Character(Unicode.Scalar($0)) })
        default:
            return String(decoding: value, as: UTF8.self)
        }
    }
}

/// Reads one DER tag-length-value at a time, bounds-checked.
enum DERReader {
    struct Element {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    static func element(_ bytes: [UInt8], at offset: Int) -> Element? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        var start = offset + 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, start + count <= bytes.count else { return nil }
            length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard length >= 0, start + length <= bytes.count else { return nil }
        return Element(tag: tag, contentStart: start, end: start + length)
    }
}

extension ClientIdentity: Equatable {
    public static func == (lhs: ClientIdentity, rhs: ClientIdentity) -> Bool {
        CFEqual(lhs.identity, rhs.identity) && lhs.chain.count == rhs.chain.count
            && zip(lhs.chain, rhs.chain).allSatisfy { $0.isSame(as: $1) }
    }
}
