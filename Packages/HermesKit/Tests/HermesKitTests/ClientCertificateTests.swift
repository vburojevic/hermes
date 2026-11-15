#if os(macOS)
import Foundation
import Security
import Testing
@testable import HermesKit

/// A proxy that asks for a client certificate (`docs/connecting-and-voice.md` §11.7): a .p12 opens
/// in memory into what the Access card shows, its identity is kept by fingerprint, every
/// transport's challenge gets the saved certificate or the one being tried, and a failed handshake
/// after a challenge reads as the proxy's refusal. The certificates are made here with openssl,
/// for this run only; none is added to a keychain on this Mac.
@Suite("Client certificates", .enabled(if: CertificateFixture.made != nil, "openssl couldn't make the test certificates"))
struct ClientCertificateTests {
    static let gateway = URL(string: "https://127.0.0.1:25642")!
    static let backend = URL(string: "https://127.0.0.1:25119")!

    static func opened() throws -> (ClientCertificate, ClientIdentity) {
        let fixture = try #require(CertificateFixture.made)
        return try ClientCertificate.open(fixture.p12, password: CertificateFixture.password, fileName: "client.p12")
    }

    static func credentials(_ certificate: ClientCertificate, _ identity: ClientIdentity) -> GatewayAccessRegistry.Credentials {
        GatewayAccessRegistry.Credentials(method: .none).presenting(identity, as: certificate)
    }

    static func isIdentity(_ credential: URLCredential?, _ identity: ClientIdentity) -> Bool {
        guard let presented = credential?.identity else { return false }
        return CFEqual(presented, identity.identity)
    }

    // MARK: Importing

    @Test func aP12OpensIntoWhatTheCardShows() throws {
        let (certificate, identity) = try Self.opened()
        #expect(certificate.fileName == "client.p12")
        #expect(certificate.subject == "Hermes Test Device")
        // The CA's name has no common name, so its organization stands in.
        #expect(certificate.issuer == "Hermes Tests")
        #expect(!certificate.isExpired())
        #expect(abs(certificate.notAfter.timeIntervalSinceNow - 10 * 86_400) < 2 * 86_400)
        #expect(certificate.fingerprint.count == 64)
        #expect(certificate.fingerprint.allSatisfy { $0.isHexDigit })
        #expect(identity.fingerprint == certificate.fingerprint)
        // The file's CA comes along for the handshake; the leaf isn't repeated in the chain.
        #expect(identity.chain.count == 1)
        #expect(identity.credential.persistence == .none)
    }

    @Test func aWrongPasswordOrAnotherFileSaysSo() throws {
        let fixture = try #require(CertificateFixture.made)
        #expect(throws: ClientCertificate.ImportFailure.wrongPassword) {
            try ClientCertificate.open(fixture.p12, password: "not-it", fileName: "client.p12")
        }
        let garbage = #expect(throws: ClientCertificate.ImportFailure.self) {
            try ClientCertificate.open(Data("<html>not a certificate</html>".utf8), password: "x", fileName: "page.p12")
        }
        guard case .unreadable = garbage else {
            Issue.record("A file that isn't PKCS #12 read as \(String(describing: garbage))")
            return
        }
    }

    @Test func savedSettingsKeepTheCertificateButNotItsKey() throws {
        let (certificate, _) = try Self.opened()
        let access = GatewayAccess(method: .serviceToken, clientID: "x", clientCertificate: certificate)
        let json = try JSONEncoder().encode(access)
        #expect(try JSONDecoder().decode(GatewayAccess.self, from: json) == access)
        let text = String(decoding: json, as: UTF8.self)
        #expect(!text.contains(CertificateFixture.password))
        #expect(!text.contains("PRIVATE KEY"))

        // A certificate a newer build saved in another shape is dropped, the gateway kept.
        let newer = try JSONDecoder().decode(GatewayAccess.self, from: Data(#"{"method":"serviceToken","clientID":"x","clientCertificate":7}"#.utf8))
        #expect(newer.method == .serviceToken)
        #expect(newer.clientCertificate == nil)
    }

    /// Names come in several string types; older CAs write BMPString (UTF-16) or TeletexString.
    @Test func namesReadInTheirOwnStringType() throws {
        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            precondition(content.count < 128)
            return [tag, UInt8(content.count)] + content
        }
        func name(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
            tlv(0x30, tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x03]) + tlv(tag, value))))
        }
        let bmp = Array("Zürich CA".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let latin1 = Array("Café".unicodeScalars.map { UInt8($0.value) })
        let tbs = tlv(0xA0, tlv(0x02, [2])) + tlv(0x02, [1]) + tlv(0x30, [])
            + name(0x1E, bmp) + tlv(0x30, []) + name(0x14, latin1)
        let names = try #require(DERNames(Data(tlv(0x30, tlv(0x30, tbs)))))
        #expect(names.issuer == "Zürich CA")
        #expect(names.subject == "Café")
        #expect(DERNames.text(ArraySlice(Array("Device é".utf8)), tag: 0x0C) == "Device é")
        #expect(DERNames.text([0x00, 0x41, 0x00], tag: 0x1E) == "")
    }

    // MARK: Keeping

    @Test func theStoreFindsAnIdentityByFingerprintAndKeepsOneStillInUse() throws {
        let (certificate, identity) = try Self.opened()
        let store = ClientIdentityStore.inMemory()
        #expect(try store.identity(fingerprint: certificate.fingerprint) == nil)

        try store.save(identity)
        try store.save(identity)
        #expect(try store.identity(fingerprint: certificate.fingerprint) == identity)

        // Another gateway behind the same proxy still names it.
        try store.release(certificate.fingerprint, stillUsed: [certificate.fingerprint])
        #expect(try store.identity(fingerprint: certificate.fingerprint) != nil)
        try store.release(nil, stillUsed: [String]())
        #expect(try store.identity(fingerprint: certificate.fingerprint) != nil)

        try store.release(certificate.fingerprint, stillUsed: ["another"])
        #expect(try store.identity(fingerprint: certificate.fingerprint) == nil)
        try store.remove(fingerprint: certificate.fingerprint)
    }

    /// A proxy that trusts only its root needs the intermediate the file carried, and the
    /// Keychain keeps an identity without it: it's kept beside it and comes back on load.
    @Test func aReloadedIdentityCarriesTheIntermediates() throws {
        let (certificate, identity) = try Self.opened()
        #expect(identity.chain.count == 1)
        let store = ClientIdentityStore.inMemory()
        try store.save(identity)
        let reloaded = try #require(try store.identity(fingerprint: certificate.fingerprint))
        #expect(reloaded.chain.count == 1)
        #expect(reloaded == identity)
        #expect(reloaded.credential.certificates.count == 1)

        // What's kept round-trips in order, and anything unreadable sends the certificate alone.
        let encoded = ClientIdentityStore.encoded(identity.chain)
        #expect(ClientIdentityStore.chain(from: encoded).map { SecCertificateCopyData($0) as Data }
            == identity.chain.map { SecCertificateCopyData($0) as Data })
        #expect(ClientIdentityStore.chain(from: nil).isEmpty)
        #expect(ClientIdentityStore.chain(from: Data("not a list".utf8)).isEmpty)
    }

    // MARK: Answering the proxy

    @Test func theSavedCertificateAnswersOnlyItsGatewaysOrigins() throws {
        let (certificate, identity) = try Self.opened()
        let registry = GatewayAccessRegistry()
        registry.set(Self.credentials(certificate, identity), for: UUID(), at: [Self.gateway, Self.backend])

        #expect(Self.isIdentity(registry.answerChallenge(for: nil, host: "127.0.0.1", port: 25642, isSecure: true), identity))
        #expect(Self.isIdentity(registry.answerChallenge(for: nil, host: "127.0.0.1", port: 25119, isSecure: true), identity))
        #expect(registry.answerChallenge(for: nil, host: "127.0.0.1", port: 9999, isSecure: true) == nil)
        #expect(registry.answerChallenge(for: nil, host: "proxy.example.com", port: 25642, isSecure: true) == nil)
        // A certificate alone adds no header or cookie to the requests themselves.
        var request = URLRequest(url: Self.gateway.appending(path: "v1/models"))
        registry.prepare(&request)
        #expect(!registry.carriesAccess(request))
    }

    @Test func aChallengeGetsTheSystemsHandlingUnlessItAsksForACertificate() throws {
        let (certificate, identity) = try Self.opened()
        let registry = GatewayAccessRegistry()
        registry.set(Self.credentials(certificate, identity), for: UUID(), at: [Self.gateway])

        let asked = SameOriginRedirects.answer(Self.challenge(port: 25642, NSURLAuthenticationMethodClientCertificate), for: nil, registry: registry)
        #expect(asked.0 == .useCredential)
        #expect(Self.isIdentity(asked.1, identity))

        let elsewhere = SameOriginRedirects.answer(Self.challenge(port: 443, NSURLAuthenticationMethodClientCertificate), for: nil, registry: registry)
        #expect(elsewhere.0 == .performDefaultHandling)
        #expect(elsewhere.1 == nil)

        // The server's own trust stays the system's.
        let trust = SameOriginRedirects.answer(Self.challenge(port: 25642, NSURLAuthenticationMethodServerTrust), for: nil, registry: registry)
        #expect(trust.0 == .performDefaultHandling)
        #expect(trust.1 == nil)
    }

    /// Settings being checked before they're saved answer only the requests made while checking:
    /// the request carries the mark into its task, since the challenge arrives outside the task.
    @Test func aCertificateBeingTriedAnswersOnlyTheRequestsThatTryIt() async throws {
        let (certificate, identity) = try Self.opened()
        let registry = GatewayAccessRegistry()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = Self.gateway.appending(path: "v1/models")

        // Nothing saved; the editor tries the certificate just imported.
        let tried = try await registry.trying(Self.credentials(certificate, identity), at: [Self.gateway]) {
            var request = URLRequest(url: url)
            registry.prepare(&request)
            let task = session.dataTask(with: request)
            defer { task.cancel() }
            let id = try #require(task.originalRequest.flatMap(GatewayAccessRegistry.trialID))
            #expect(GatewayAccessRegistry.trialID(request) == id)
            return registry.answerChallenge(for: task, host: "127.0.0.1", port: 25642, isSecure: true)
        }
        #expect(Self.isIdentity(tried, identity))

        // The live connection's requests, made outside the check, get what's saved: nothing.
        let live = session.dataTask(with: URLRequest(url: url))
        defer { live.cancel() }
        #expect(registry.answerChallenge(for: live, host: "127.0.0.1", port: 25642, isSecure: true) == nil)

        // Once saved, trying settings without it sends none, while the live connection keeps it.
        registry.set(Self.credentials(certificate, identity), for: UUID(), at: [Self.gateway])
        let without = await registry.trying(nil, at: [Self.gateway]) {
            var request = URLRequest(url: url)
            registry.prepare(&request)
            let task = session.dataTask(with: request)
            defer { task.cancel() }
            return registry.answerChallenge(for: task, host: "127.0.0.1", port: 25642, isSecure: true)
        }
        #expect(without == nil)
        #expect(Self.isIdentity(registry.answerChallenge(for: live, host: "127.0.0.1", port: 25642, isSecure: true), identity))
    }

    // MARK: Reading the refusal

    static func failure(_ code: URLError.Code, at url: URL = gateway.appending(path: "v1/models")) -> URLError {
        URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url])
    }

    /// TLS 1.3 proxies refuse after the handshake (a lost connection), TLS 1.2 ones inside it (a
    /// handshake failure); either way the challenge just before says which refusal it was.
    @Test(arguments: [URLError.Code.networkConnectionLost, .secureConnectionFailed])
    func aFailureRightAfterAChallengeIsTheProxysAnswer(code: URLError.Code) throws {
        let (certificate, identity) = try Self.opened()
        let start = Date.now

        let none = GatewayAccessRegistry()
        _ = none.answerChallenge(for: nil, host: "127.0.0.1", port: 25642, isSecure: true, at: start)
        #expect(AccessRefusal.classify(Self.failure(code), registry: none, now: start.addingTimeInterval(1)) == .certificateNeeded)
        // Long after the challenge, it's just a lost connection again.
        #expect(AccessRefusal.classify(Self.failure(code), registry: none, now: start.addingTimeInterval(31)) == nil)
        // At another origin, the challenge explains nothing.
        let other = Self.failure(code, at: URL(string: "https://127.0.0.1:9999/v1/models")!)
        #expect(AccessRefusal.classify(other, registry: none, now: start.addingTimeInterval(1)) == nil)

        let saved = GatewayAccessRegistry()
        saved.set(Self.credentials(certificate, identity), for: UUID(), at: [Self.gateway])
        _ = saved.answerChallenge(for: nil, host: "127.0.0.1", port: 25642, isSecure: true, at: start)
        #expect(AccessRefusal.classify(Self.failure(code), registry: saved, now: start.addingTimeInterval(1)) == .certificateRejected)

        // Once the origin answers over TLS, a later failure there isn't the handshake.
        saved.noteAnswered(Self.gateway.appending(path: "health"))
        #expect(AccessRefusal.classify(Self.failure(code), registry: saved, now: start.addingTimeInterval(2)) == nil)
    }

    /// Settings being tried go on a session of their own, never the live pool, whose open
    /// connection a proxy wouldn't ask for a certificate again.
    @Test func aCheckGetsASessionOfItsOwn() {
        let first = HermesClient.checkingSession()
        let second = HermesClient.checkingSession()
        defer { first.finishTasksAndInvalidate(); second.finishTasksAndInvalidate() }
        #expect(first !== second)
        #expect(first !== HermesClient.defaultSession)
        #expect(first.delegate is SameOriginRedirects)
        #expect(first.configuration.urlCache == nil)
        #expect(first.configuration.timeoutIntervalForRequest == HermesClient.defaultSession.configuration.timeoutIntervalForRequest)
    }

    /// A stream that drops after its answer got through the handshake, so it reconnects as any
    /// lost connection does, even moments after the proxy asked for the certificate it was sent.
    @Test func aDropAfterTheAnswerIsALostConnectionNotARefusal() throws {
        let (certificate, identity) = try Self.opened()
        let gateway = URL(string: "https://127.0.0.1:25643")!
        let registry = GatewayAccessRegistry.shared
        let id = UUID()
        registry.set(Self.credentials(certificate, identity), for: id, at: [gateway])
        defer { registry.forget(id) }
        _ = registry.answerChallenge(for: nil, host: "127.0.0.1", port: 25643, isSecure: true)
        let dropped = Self.failure(.networkConnectionLost, at: gateway.appending(path: "v1/runs/r1/events"))

        let before = HermesError.from(urlError: dropped, host: "127.0.0.1")
        #expect(before == .accessRefused(host: "127.0.0.1", .certificateRejected))
        #expect(!before.isTransient)
        #expect(before.keepsChecking)

        let after = HermesError.from(urlError: dropped, host: "127.0.0.1", afterAnswer: true)
        #expect(after == .unreachable(host: "127.0.0.1", reason: .connectionLost))
        #expect(after.isTransient)
    }

    /// A certificate refusal is read from a TLS failure, which a dropped connection can look like,
    /// so the connection keeps being checked in the background; a refusal Hermes or an access
    /// gateway answered over HTTP waits for the person.
    @Test func anInferredRefusalDoesNotEndKeepingTheConnection() throws {
        let (certificate, identity) = try Self.opened()
        let gateway = URL(string: "https://127.0.0.1:25644")!
        let registry = GatewayAccessRegistry.shared
        let id = UUID()
        registry.set(Self.credentials(certificate, identity), for: id, at: [gateway])
        defer { registry.forget(id) }
        _ = registry.answerChallenge(for: nil, host: "127.0.0.1", port: 25644, isSecure: true)
        let lost = Self.failure(.networkConnectionLost, at: gateway.appending(path: "health"))
        let handshake = Self.failure(.secureConnectionFailed, at: gateway.appending(path: "v1/capabilities"))

        for inferred in [HermesError.from(urlError: lost, host: "127.0.0.1"), .from(urlError: handshake, host: "127.0.0.1")] {
            #expect(inferred == .accessRefused(host: "127.0.0.1", .certificateRejected))
            #expect(inferred.keepsChecking)
        }
        #expect(HermesError.accessRefused(host: "h", .certificateNeeded).keepsChecking)
        #expect(HermesError.accessRefused(host: "h", .certificateExpired(.now)).keepsChecking)
        #expect(HermesError.unreachable(host: "h", reason: .connectionLost).keepsChecking)

        #expect(!HermesError.accessRefused(host: "h", .signInNeeded).keepsChecking)
        #expect(!HermesError.accessRefused(host: "h", .tokenRejected).keepsChecking)
        #expect(!HermesError.missingAPIKey.keepsChecking)
    }

    @Test func aRefusedCertificateThatRanOutSaysSo() throws {
        let (certificate, identity) = try Self.opened()
        var ranOut = certificate
        ranOut.notAfter = Date.now.addingTimeInterval(-2 * 86_400)
        let registry = GatewayAccessRegistry()
        registry.set(Self.credentials(ranOut, identity), for: UUID(), at: [Self.gateway])
        let now = Date.now
        _ = registry.answerChallenge(for: nil, host: "127.0.0.1", port: 25642, isSecure: true, at: now)

        #expect(AccessRefusal.classify(Self.failure(.networkConnectionLost), registry: registry, now: now) == .certificateExpired(ranOut.notAfter))
        #expect(AccessRefusal.classify(Self.failure(.serverCertificateUntrusted), registry: registry, now: now) == nil)
        #expect(AccessRefusal.certificateExpired(ranOut.notAfter).isCertificate)
        // A TLS 1.2 "bad certificate" names it with or without a challenge.
        #expect(AccessRefusal.classify(Self.failure(.clientCertificateRejected), registry: registry, now: now) == .certificateExpired(ranOut.notAfter))
        #expect(AccessRefusal.classify(Self.failure(.clientCertificateRejected), registry: GatewayAccessRegistry(), now: now) == .certificateRejected)
    }

    // MARK: Settings

    @Test func theDraftSendsTheCertificateWithOrWithoutAToken() throws {
        let (certificate, identity) = try Self.opened()
        var draft = GatewayAccessDraft()
        draft.useCertificate(certificate, identity: identity)
        #expect(draft.summary == "Certificate")
        #expect(draft.access == GatewayAccess(method: .none, clientCertificate: certificate))
        let alone = try #require(draft.credentials(savedSecret: nil))
        #expect(alone.headers.isEmpty)
        #expect(Self.isIdentity(alone.clientCertificate, identity))
        #expect(alone.certificate == certificate)

        draft.method = .serviceToken
        draft.clientID = "client.access"
        draft.secret = "secret-0123"
        #expect(draft.summary == "Service token, certificate")
        let both = try #require(draft.credentials(savedSecret: nil))
        #expect(both.headers["CF-Access-Client-Secret"] == "secret-0123")
        #expect(Self.isIdentity(both.clientCertificate, identity))

        // A certificate listed for the gateway but missing from this device's Keychain sends nothing.
        let elsewhere = GatewayAccessDraft(GatewayAccess(method: .none, clientCertificate: certificate), identity: nil)
        #expect(elsewhere.certificate == certificate)
        #expect(elsewhere.credentials(savedSecret: nil) == nil)

        draft.method = .none
        draft.removeCertificate()
        #expect(draft.summary == "None")
        #expect(draft.access == nil)
        #expect(draft.identity == nil)
    }

    @Test func eachCertificateRefusalHasItsFixAndSteps() throws {
        var facts = GatewaySetupFacts(gatewayName: "Studio", gatewayOnline: true, botMode: .notLinked)
        for refusal in [AccessRefusal.certificateNeeded, .certificateRejected, .certificateExpired(.distantPast)] {
            facts.accessRefusal = refusal
            let status = try #require(GatewaySetup.access(facts))
            #expect(status.state == .notSetUp)
            #expect(status.fix?.action == .editAccess)
            #expect(status.steps.count == 2)
            #expect(status.detail?.hasPrefix(refusal.title) == true)
        }
        let (certificate, _) = try Self.opened()
        facts.accessRefusal = nil
        facts.access = GatewayAccess(method: .none, clientCertificate: certificate)
        #expect(try #require(GatewaySetup.access(facts)).detail == "Certificate")
    }

    static func challenge(port: Int, _ method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "127.0.0.1", port: port, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
            sender: NoSender()
        )
    }
}

/// A challenge's sender, never called: the answer goes back through the completion handler.
private final class NoSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A throwaway CA and client certificate, made with the system's openssl in a temporary folder
/// that is deleted at once: only the .p12's bytes stay, in memory.
struct CertificateFixture: Sendable {
    static let password = "test-password-0123"
    static let made: CertificateFixture? = try? make()

    let p12: Data

    private static func make() throws -> CertificateFixture {
        let openssl = URL(filePath: "/usr/bin/openssl")
        let folder = FileManager.default.temporaryDirectory.appending(path: "hermes-certs-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func path(_ name: String) -> String { folder.appending(path: name).path(percentEncoded: false) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = openssl
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("ca.key"), "-out", path("ca.pem"),
                 "-subj", "/O=Hermes Tests", "-days", "30"])
        try run(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", path("client.key"), "-out", path("client.csr"),
                 "-subj", "/O=Hermes Tests/CN=Hermes Test Device"])
        try run(["x509", "-req", "-in", path("client.csr"), "-CA", path("ca.pem"), "-CAkey", path("ca.key"),
                 "-set_serial", "4242", "-days", "10", "-out", path("client.pem")])
        try run(["pkcs12", "-export", "-inkey", path("client.key"), "-in", path("client.pem"), "-certfile", path("ca.pem"),
                 "-name", "Hermes Test Device", "-out", path("client.p12"), "-passout", "pass:\(password)",
                 "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        return CertificateFixture(p12: try Data(contentsOf: folder.appending(path: "client.p12")))
    }
}
#endif
