import Foundation
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
