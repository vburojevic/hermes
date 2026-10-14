import Foundation
import Testing
@testable import HermesKit

@Suite("Pairing links")
struct PairingLinkTests {
    @Test func roundTripsAGatewayWithBotMode() throws {
        let link = PairingLink(
            name: "MacBook Pro",
            gateway: try #require(URL(string: "https://mac.tail0.ts.net:8642")),
            apiKey: "k3y+with&odd=chars/and spaces",
            backend: BackendLink(url: try #require(URL(string: "https://mac.tail0.ts.net")), signIn: .automatic)
        )
        let url = link.url
        #expect(url.scheme == "hermesapp")
        #expect(url.host() == "connect")
        #expect(PairingLink(url: url) == link)
        #expect(link.isReachableFromOtherDevices)
    }

    @Test func carriesOnlyTheCredentialItsSignInNeeds() throws {
        let gateway = try #require(URL(string: "http://192.168.1.20:8642"))
        let backend = try #require(URL(string: "http://192.168.1.20:9119"))
        let token = PairingLink(name: "Home", gateway: gateway, apiKey: "k", backend: BackendLink(url: backend, signIn: .token), backendToken: "t0k")
        #expect(PairingLink(url: token.url)?.backendToken == "t0k")
        let password = PairingLink(
            name: "Home", gateway: gateway, apiKey: "k",
            backend: BackendLink(url: backend, signIn: .password, username: "admin"), backendToken: "ignored"
        )
        let decoded = try #require(PairingLink(url: password.url))
        #expect(decoded.backendToken == nil)
        #expect(decoded.backend?.username == "admin")
        #expect(!password.url.absoluteString.contains("ignored"))
    }

    @Test func rejectsForeignOrIncompleteLinks() {
        #expect(PairingLink(url: URL(string: "https://hermesapp.dev/connect?v=1&gateway=x&key=y")!) == nil)
        #expect(PairingLink(url: URL(string: "hermesapp://connect?v=1&gateway=mac.local:8642")!) == nil)
        #expect(PairingLink(url: URL(string: "hermesapp://connect?v=2&gateway=mac.local:8642&key=k")!) == nil)
        #expect(PairingLink(url: URL(string: "hermesapp-dev://connect?v=1&gateway=mac.local:8642&key=k")!)?.gateway.port == 8642)
    }

    @Test func loopbackAddressesCannotPairAnotherDevice() throws {
        let local = PairingLink(name: "This Mac", gateway: try #require(URL(string: "http://127.0.0.1:8642")), apiKey: "k")
        #expect(!local.isReachableFromOtherDevices)
        // A local-only Bot Mode backend doesn't block pairing: the code just leaves it out.
        let mixed = PairingLink(
            name: "Mixed", gateway: try #require(URL(string: "https://mac.tail0.ts.net:8642")), apiKey: "k",
            backend: BackendLink(url: try #require(URL(string: "http://localhost:9119")), signIn: .automatic)
        )
        #expect(mixed.isReachableFromOtherDevices)
        #expect(mixed.forOtherDevices.backend == nil)
        #expect(mixed.forOtherDevices.apiKey == "k")
        let shared = PairingLink(
            name: "Shared", gateway: try #require(URL(string: "https://mac.tail0.ts.net:8642")), apiKey: "k",
            backend: BackendLink(url: try #require(URL(string: "https://mac.tail0.ts.net")), signIn: .automatic)
        )
        #expect(shared.forOtherDevices == shared)
    }
}
