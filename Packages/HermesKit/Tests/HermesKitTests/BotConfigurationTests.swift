import Foundation
import Security
import Synchronization
import Testing
@testable import HermesKit

@Suite("Bot configuration")
struct BotConfigurationTests {
    @Test(arguments: [
        ("localhost", "http://localhost:8642"),
        ("localhost:9000", "http://localhost:9000"),
        ("mac-mini.local", "http://mac-mini.local:8642"),
        ("192.168.1.20", "http://192.168.1.20:8642"),
        ("100.101.102.103:8642", "http://100.101.102.103:8642"),
        ("hermes.example.com", "https://hermes.example.com"),
        ("https://hermes.example.com/p/research/", "https://hermes.example.com/p/research"),
        ("http://127.0.0.1:8642/v1", "http://127.0.0.1:8642"),
        ("http://127.0.0.1:8642/v1/chat/completions", "http://127.0.0.1:8642"),
        ("  HTTP://Box.lan  ", "http://box.lan:8642"),
    ])
    func normalizesTypedAddresses(input: String, expected: String) {
        #expect(BotConfiguration.normalizedURL(from: input)?.absoluteString.lowercased() == expected.lowercased())
    }

    @Test(arguments: ["", "   ", "ftp://x.y", "not a url", "http://"])
    func rejectsGarbage(_ input: String) {
        #expect(BotConfiguration.normalizedURL(from: input) == nil)
    }

    @Test func localNetworkDetection() {
        for host in ["localhost", "10.0.0.2", "172.20.1.1", "192.168.0.10", "100.88.1.2", "box.ts.net", "nas", "::1", "fd12::1"] {
            #expect(BotConfiguration.looksLocal(host), "\(host) should be local")
        }
        for host in ["8.8.8.8", "172.32.0.1", "hermes.example.com", "fdroid.org", "100.200.1.1"] {
            #expect(!BotConfiguration.looksLocal(host), "\(host) should be public")
        }
    }

    /// An address counts only when the whole host is one; IPv4 written as IPv6 is still IPv4.
    @Test func addressLiteralsAreReadWhole() {
        for host in ["10.0.0.1.attacker.example", "192.168.1.1.nip.io", "127.0.0.1x", "1.2.3.4.5", "010.0.0.1", "::ffff:8.8.8.8", "2001:db8::1", "64:ff9b::8.8.8.8"] {
            #expect(!BotConfiguration.looksLocal(host), "\(host) should be public")
        }
        for host in ["::ffff:192.168.1.1", "[::ffff:c0a8:101]", "::ffff:127.0.0.1", "0.0.0.0", "::", "[::1]", "fe80::1%en0", "febf::1", "0.0.0.0",
                     "64:ff9b::192.168.1.1", "[64:ff9b::a9fe:a9fe]"] {
            #expect(BotConfiguration.looksLocal(host), "\(host) should be local")
        }
        #expect(HostAddresses.literal("10.0.0.1.attacker.example") == nil)
        #expect(HostAddresses.literal("192.168.1.20") == .v4([192, 168, 1, 20]))
        #expect(HostAddresses.literal("256.1.1.1") == nil)
    }

    @Test func aNameIsJudgedByWhatItResolvesTo() async {
        #expect(await HostAddresses.resolvesLocal("localhost"))
        #expect(await HostAddresses.resolvesLocal("127.0.0.1"))
        #expect(!(await HostAddresses.resolvesLocal("8.8.8.8")))
        #expect(!(await HostAddresses.resolvesLocal("no-such-host.invalid")))
    }

    /// A Bot's key goes only where the app saved it for: an address changed in bots.json by
    /// something else is put back.
    @Test func bots_jsonCantSendTheKeyElsewhere() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bots-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)")
        let store = BotStore(fileURL: directory.appending(path: "bots.json"), keychain: keychain)
        let bot = BotConfiguration(
            name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold",
            backend: BackendLink(url: URL(string: "http://mac-mini.local:9119")!, signIn: .token)
        )
        defer {
            try? store.removeAPIKey(for: bot.id)
            try? FileManager.default.removeItem(at: directory)
        }
        try store.save([bot], edited: bot)
        #expect(try store.load() == [bot])

        var forged = bot
        forged.baseURL = URL(string: "https://attacker.example")!
        forged.backend = BackendLink(url: URL(string: "https://attacker.example")!, signIn: .token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode([forged]).write(to: store.fileURL)
        #expect(try store.load() == [bot])
        #expect(try BotStore(fileURL: store.fileURL, keychain: keychain).load() == [bot]) // and the file was put back

        // The app's own edit moves where the key may go.
        var moved = bot
        moved.baseURL = URL(string: "https://hermes.example.com")!
        try store.save([moved], edited: moved)
        #expect(try store.load() == [moved])
    }

    /// The Keychain is locked as the app loads, and bots.json then names other addresses: once it
    /// opens, the key and the sign-in still go only where they were saved for.
    @Test func aBotLoadedWhileTheKeychainIsLockedGetsNoSecretsForOtherAddresses() throws {
        let fixture = KeychainFixture()
        let bot = BotConfiguration(
            name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold",
            backend: BackendLink(url: URL(string: "http://mac-mini.local:9119")!, signIn: .token)
        )
        defer { fixture.tearDown([bot]) }
        let store = fixture.store
        try store.save([bot], edited: bot)
        try store.setAPIKey("gateway-key", for: bot.id)
        try store.setBackendCredential(.sessionToken("session-token"), for: bot.id)

        fixture.fail { _, _ in errSecInteractionNotAllowed }
        var other = bot
        other.baseURL = URL(string: "https://elsewhere.example")!
        other.backend = BackendLink(url: URL(string: "https://elsewhere.example")!, signIn: .token)
        try fixture.rewrite([other])
        #expect(try store.load() == [other])
        #expect(!store.isVerified(other))
        #expect(throws: BotStore.Refusal.unverified) { try store.apiKey(for: other) }
        #expect(throws: BotStore.Refusal.unverified) { try store.backendCredential(for: other) }

        fixture.fail(nil)
        #expect(throws: BotStore.Refusal.putBack(bot)) { try store.apiKey(for: other) }
        #expect(throws: BotStore.Refusal.putBack(bot)) { try store.backendCredential(for: other) }
        #expect(!store.isVerified(other))
        #expect(try BotStore(fileURL: store.fileURL, keychain: fixture.keychain).load() == [bot]) // the file too
        #expect(try store.apiKey(for: bot) == "gateway-key")
        #expect(try store.backendCredential(for: bot) == .sessionToken("session-token"))
        #expect(store.isVerified(bot))
    }

    /// A Bot saved before addresses were pinned, while the Keychain finds no pin and won't take
    /// one: it stays unverified, and none of its secrets is read until the pin is written.
    @Test func aBotWhosePinCantBeWrittenGetsNoSecrets() throws {
        let fixture = KeychainFixture()
        let bot = BotConfiguration(
            name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold",
            backend: BackendLink(url: URL(string: "http://mac-mini.local:9119")!, signIn: .token)
        )
        defer { fixture.tearDown([bot]) }
        let store = fixture.store
        try store.save([bot])
        try store.setAPIKey("gateway-key", for: bot.id)
        try store.setBackendCredential(.sessionToken("session-token"), for: bot.id)

        fixture.fail { account, writing in
            guard account.hasSuffix(".destinations") else { return nil }
            return writing ? errSecInteractionNotAllowed : errSecItemNotFound
        }
        #expect(try store.load() == [bot])
        #expect(!store.isVerified(bot))
        #expect(throws: BotStore.Refusal.unverified) { try store.apiKey(for: bot) }
        #expect(throws: BotStore.Refusal.unverified) { try store.backendCredential(for: bot) }
        #expect(!store.isVerified(bot))

        fixture.fail(nil)
        #expect(try store.apiKey(for: bot) == "gateway-key")
        #expect(try store.backendCredential(for: bot) == .sessionToken("session-token"))
        #expect(store.isVerified(bot))
    }

    /// A Bot with no key says so; one whose addresses can't be checked yet says the Keychain can't
    /// be read, and tries again by itself.
    @Test func aMissingKeyAndAnUnreadableKeychainAreToldApart() throws {
        let fixture = KeychainFixture()
        let bot = BotConfiguration(name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold")
        defer { fixture.tearDown([bot]) }
        let store = fixture.store
        try store.save([bot], edited: bot)
        #expect(try store.apiKey(for: bot) == nil)
        #expect(store.missingKey(for: bot) == .missingAPIKey)

        fixture.fail { _, _ in errSecInteractionNotAllowed }
        #expect(throws: BotStore.Refusal.unverified) { try store.apiKey(for: bot) }
        #expect(store.missingKey(for: bot) == .keychainUnavailable)
        #expect(HermesError.keychainUnavailable.isTransient)
        #expect(!HermesError.missingAPIKey.isTransient)
        #expect(BotStore.Refusal.unverified.errorDescription == HermesError.keychainUnavailable.errorDescription)
    }

    /// The person moves a Bot to a new address with a new key, and the new address can't be
    /// pinned: the edit fails, and the new key never goes to the old address.
    @Test func aNewKeyWaitsForItsAddressToBePinned() throws {
        let fixture = KeychainFixture()
        let bot = BotConfiguration(name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold")
        defer { fixture.tearDown([bot]) }
        let store = fixture.store
        try store.save([bot], edited: bot)
        try store.setAPIKey("old-key", for: bot.id)

        var moved = bot
        moved.baseURL = URL(string: "https://hermes.example.com")!
        fixture.fail { account, writing in writing && account.hasSuffix(".destinations") ? errSecInteractionNotAllowed : nil }
        #expect(throws: KeychainStore.Failure.unexpectedStatus(errSecInteractionNotAllowed)) {
            try store.save([moved], edited: moved, previous: [bot]) { try store.setAPIKey("new-key", for: bot.id) }
        }
        fixture.fail(nil)
        #expect(try store.apiKey(for: bot) == "old-key")
        #expect(throws: BotStore.Refusal.putBack(bot)) { try store.apiKey(for: moved) }

        // A key that can't be written undoes the edit, pin and all.
        fixture.fail { account, writing in writing && account == bot.id.uuidString ? errSecInteractionNotAllowed : nil }
        #expect(throws: KeychainStore.Failure.unexpectedStatus(errSecInteractionNotAllowed)) {
            try store.save([moved], edited: moved, previous: [bot]) { try store.setAPIKey("new-key", for: bot.id) }
        }
        fixture.fail(nil)
        #expect(try store.load() == [bot])
        #expect(try store.apiKey(for: bot) == "old-key")
    }

    /// Saving the list after the person edits one Bot moves that Bot's pin alone: another Bot's
    /// addresses, changed in bots.json while the Keychain was locked, stay unverified.
    @Test func theAppsOwnEditMovesThePinOfTheBotItEdited() throws {
        let fixture = KeychainFixture()
        let home = BotConfiguration(name: "Home", baseURL: URL(string: "http://mac-mini.local:8642")!, accent: "gold")
        let studio = BotConfiguration(name: "Studio", baseURL: URL(string: "http://studio.local:8642")!, accent: "ocean")
        defer { fixture.tearDown([home, studio]) }
        let store = fixture.store
        try store.save([home], edited: home)
        try store.save([home, studio], edited: studio)
        try store.setAPIKey("home-key", for: home.id)
        try store.setAPIKey("studio-key", for: studio.id)

        fixture.fail { _, _ in errSecInteractionNotAllowed }
        var other = home
        other.baseURL = URL(string: "https://elsewhere.example")!
        try fixture.rewrite([other, studio])
        #expect(try store.load() == [other, studio])
        fixture.fail(nil)

        var moved = studio
        moved.baseURL = URL(string: "https://studio.example.com")!
        try store.save([other, moved], edited: moved)
        #expect(try store.apiKey(for: moved) == "studio-key")
        #expect(throws: BotStore.Refusal.putBack(moved)) { try store.apiKey(for: studio) }
        #expect(throws: BotStore.Refusal.putBack(home)) { try store.apiKey(for: other) }
        #expect(try BotStore(fileURL: store.fileURL, keychain: fixture.keychain).load() == [home, moved])
    }

    @Test func insecureOverInternet() {
        let local = BotConfiguration(name: "a", baseURL: URL(string: "http://10.0.0.2:8642")!, accent: "gold")
        let remote = BotConfiguration(name: "b", baseURL: URL(string: "http://hermes.example.com")!, accent: "gold")
        let tls = BotConfiguration(name: "c", baseURL: URL(string: "https://hermes.example.com")!, accent: "gold")
        #expect(!local.isInsecureOverInternet)
        #expect(remote.isInsecureOverInternet)
        #expect(!tls.isInsecureOverInternet)
    }

    @Test func storeRoundTripsWithoutSecrets() throws {
        // A space in the path, like "Application Support", must survive percent-encoding.
        let directory = FileManager.default.temporaryDirectory.appending(path: "Hermes Store \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BotStore(fileURL: directory.appending(path: "bots.json"), keychain: KeychainStore(service: "test"))
        let bot = BotConfiguration(name: "Home", baseURL: URL(string: "http://localhost:8642")!, accent: "ocean")
        #expect(try store.load().isEmpty)
        try store.save([bot])
        #expect(try store.load() == [bot])
        #expect(try BotStore(fileURL: store.fileURL, keychain: store.keychain).load() == [bot])
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!json.localizedCaseInsensitiveContains("key"))
    }

    @Test func backendLinks() throws {
        #expect(BackendLink.normalizedURL(from: "127.0.0.1")?.absoluteString == "http://127.0.0.1:9119")
        #expect(BackendLink.normalizedURL(from: "https://hermes.example.com/")?.absoluteString == "https://hermes.example.com")
        #expect(BackendLink.suggestedURL(forGateway: URL(string: "http://mac-mini.local:8642")!)?.absoluteString == "http://mac-mini.local:9119")
        #expect(BackendLink(url: URL(string: "http://127.0.0.1:9119")!, signIn: .automatic).isLoopback)
        #expect(!BackendLink(url: URL(string: "http://mac-mini.local:9119")!, signIn: .token).isLoopback)

        // Older files have no `backend` key.
        let old = #"[{"id":"6F1C2C5E-8B1D-4C55-9E2A-1F2B3C4D5E6F","name":"Hermes","baseURL":"http://127.0.0.1:8642","accent":"gold","createdAt":0}]"#
        let bots = try JSONDecoder().decode([BotConfiguration].self, from: Data(old.utf8))
        #expect(bots.first?.backend == nil)
        var bot = try #require(bots.first)
        bot.backend = BackendLink(url: URL(string: "http://127.0.0.1:9119")!, signIn: .password, username: "admin")
        let decoded = try JSONDecoder().decode(BotConfiguration.self, from: JSONEncoder().encode(bot))
        #expect(decoded.backend == bot.backend)
    }
}

/// A Bot store on a Keychain whose reads and writes a test can make fail, as a locked or refusing
/// one does.
private struct KeychainFixture {
    typealias Rule = @Sendable (_ account: String, _ writing: Bool) -> OSStatus?

    private final class Faults: Sendable {
        let rule = Mutex<Rule?>(nil)
    }

    private let faults = Faults()
    let directory = FileManager.default.temporaryDirectory.appending(path: "bots-\(UUID().uuidString)")
    let keychain: KeychainStore
    let store: BotStore

    init() {
        let faults = faults
        keychain = KeychainStore(service: "co.caffeinatedcode.hermes.tests.\(UUID().uuidString)") { account, writing in
            faults.rule.withLock { $0 }?(account, writing)
        }
        store = BotStore(fileURL: directory.appending(path: "bots.json"), keychain: keychain)
    }

    /// Nil lets every read and write through again.
    func fail(_ rule: Rule?) {
        faults.rule.withLock { $0 = rule }
    }

    /// bots.json as something other than the app writes it.
    func rewrite(_ bots: [BotConfiguration]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(bots).write(to: store.fileURL)
    }

    func tearDown(_ bots: [BotConfiguration]) {
        fail(nil)
        for bot in bots {
            try? store.setBackendCredential(nil, for: bot.id)
            try? store.removeAPIKey(for: bot.id)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
