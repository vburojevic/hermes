#if DEBUG
import Foundation
import Security
import Synchronization

/// Debug builds only: a certificate authority the app trusts besides the system's, so the Mac can
/// reach the mock mTLS proxy (`Tools/mock-hermes/mtls_proxy.py`) without adding its throwaway CA
/// to a keychain. Set by `-HERMES_TRUST_CA <path>` (docs/development.md); the simulator trusts it
/// through `simctl keychain add-root-cert` instead. Release builds trust only the system.
public enum DebugTrust {
    private static let anchors = Mutex<[Data]>([])

    /// Trusts the PEM or DER certificate at `path` too. False when it isn't one.
    @discardableResult
    public static func trust(certificateAt path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path), let der = der(from: data),
              SecCertificateCreateWithData(nil, der as CFData) != nil
        else { return false }
        anchors.withLock { $0.append(der) }
        return true
    }

    /// Whether `trust` holds with the added authorities as well as the system's. False with none.
    static func accepts(_ trust: SecTrust) -> Bool {
        let certificates = anchors.withLock { $0 }.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return false }
        SecTrustSetAnchorCertificates(trust, certificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func der(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") else { return data }
        let body = text.components(separatedBy: "-----BEGIN CERTIFICATE-----")[1]
            .components(separatedBy: "-----END CERTIFICATE-----")[0]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: body)
    }
}
#endif
