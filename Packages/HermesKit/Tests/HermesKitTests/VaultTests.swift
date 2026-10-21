import Foundation
import Testing
@testable import HermesKit

@Suite("Passwords")
struct VaultTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Sources

    @Test func readsEachSourceState() throws {
        // `vault.sources` as Hermes answers it: the local vault first, then each manager class.
        let sources = VaultSource.list(from: try json("""
        {"sources": [
          {"name": "local", "display_name": "Hermes vault", "enabled": true, "needs_unlock": false, "unlocked": true, "installed": true},
          {"name": "onepassword", "display_name": "1Password", "enabled": true, "needs_unlock": true, "unlocked": true, "installed": true},
          {"name": "bitwarden", "display_name": "Bitwarden", "enabled": true, "needs_unlock": true, "unlocked": false, "installed": true}
        ]}
        """))
        #expect(sources.map(\.state) == [.vault, .unlocked, .locked])
        #expect(sources.map(\.displayName) == ["Hermes vault", "1Password", "Bitwarden"])
        #expect(sources[1].cli == "op")
        #expect(sources[2].cli == "bw")
    }

    @Test func tellsOffFromNotInstalled() throws {
        // Hermes reports a manager without its CLI as not enabled, so `installed` decides first.
        let missing = VaultSource(name: "onepassword", displayName: "1Password", isEnabled: false, needsUnlock: true, isUnlocked: false, isInstalled: false)
        let off = VaultSource(name: "bitwarden", displayName: "Bitwarden", isEnabled: false, needsUnlock: true, isUnlocked: false, isInstalled: true)
        #expect(missing.state == .notInstalled)
        #expect(missing.installCommand == "brew install 1password-cli")
        #expect(off.state == .off)
    }

    // MARK: Items

    @Test func readsMetadataOnly() throws {
        let items = VaultItem.list(from: try json("""
        {"items": [
          {"id": "op:abc", "kind": "login", "label": "GitHub", "origin": "https://github.com", "created_at": "2025-03-04T10:00:00.123456+00:00",
           "identifier": "sam-k", "identifier_type": "username", "has_otp": true, "backend": "onepassword"},
          {"id": "vault_1", "kind": "payment", "label": "Personal Visa", "origin": "https://www.amazon.com", "created_at": "2025-01-02T00:00:00Z", "backend": "local"},
          {"id": "vault_2", "kind": "address", "label": "Home", "origin": null, "created_at": "", "backend": "local"},
          {"id": "vault_3", "kind": "secret_note", "label": "Unknown kind"}
        ]}
        """))
        #expect(items.map(\.id) == ["op:abc", "vault_1", "vault_2"])
        let github = items[0]
        #expect(github.site == "github.com")
        #expect(github.fillsOn == "github.com only")
        #expect(github.hasOneTimeCodes)
        #expect(github.identifier == "sam-k")
        #expect(!github.isInHermesVault)
        #expect(github.createdAt != nil)
        #expect(items[1].kind == .payment)
        #expect(items[1].isInHermesVault)
        #expect(items[2].fillsOn == nil)
    }

    @Test func managerItemsFillOnEveryListedSite() throws {
        let item = VaultItem.list(from: try json("""
        {"items": [{"id": "bw:1", "kind": "login", "label": "Amazon", "origin": "https://amazon.co.uk",
          "allowed_origins": ["https://amazon.co.uk", "https://www.amazon.co.uk"], "backend": "bitwarden"}]}
        """))[0]
        #expect(item.origins.count == 2)
        #expect(item.fillsOn == "amazon.co.uk and www.amazon.co.uk only")
    }

    @Test func searchGoesOverNamesAndSitesOnly() {
        let item = VaultItem(id: "vault_1", kind: .login, label: "Linear", origin: "https://linear.app", identifier: "sam@example.com")
        #expect(item.matches("lin"))
        #expect(item.matches("linear.app"))
        #expect(item.matches(""))
        #expect(!item.matches("sam@"))
    }

    // MARK: Origins

    @Test func normalizesOriginsLikeHermes() {
        #expect(VaultOrigin.normalize("github.com") == "https://github.com")
        #expect(VaultOrigin.normalize("https://GitHub.com/login?next=/") == "https://github.com")
        #expect(VaultOrigin.normalize("https://example.com:443") == "https://example.com")
        #expect(VaultOrigin.normalize("http://localhost:3000/x") == "http://localhost:3000")
        #expect(VaultOrigin.normalize("ftp://example.com") == nil)
        #expect(VaultOrigin.normalize("") == nil)
        #expect(VaultOrigin.normalize("not a site") == nil)
        #expect(VaultOrigin.site("http://intranet.lan:8080") == "http://intranet.lan:8080")
        #expect(VaultOrigin.site("https://accounts.example.com") == "accounts.example.com")
    }

    // MARK: Adding

    @Test func aLoginNeedsSiteUsernameAndPassword() {
        var draft = VaultDraft(kind: .login)
        #expect(draft.problem == .website)
        draft.website = "accounts.example.com"
        #expect(draft.problem == .username)
        draft.username = "ops@example.com"
        #expect(draft.problem == .password)
        draft.password = "correct horse battery staple"
        #expect(draft.problem == nil)
        draft.authenticatorKey = "not base32!"
        #expect(draft.problem == .authenticatorKey)
        draft.authenticatorKey = "otpauth://totp/Example:ops?secret=JBSWY3DPEHPK3PXP&issuer=Example"
        #expect(draft.problem == nil)
        draft.authenticatorKey = "jbsw y3dp ehpk 3pxp"
        #expect(draft.problem == nil)
    }

    @Test func aLoginSendsHermesFieldNamesAndTheSiteAsItsName() throws {
        var draft = VaultDraft(kind: .login)
        draft.website = "linear.app"
        draft.username = " sam@example.com "
        draft.password = "hunter2"
        let params = try #require(draft.params(profile: "research"))
        #expect(params["kind"] == .string("login"))
        #expect(params["label"] == .string("linear.app"))
        #expect(params["origin"] == .string("https://linear.app"))
        #expect(params["profile"] == .string("research"))
        let secret = try #require(params["secret"])
        #expect(secret["identifier"] == .string("sam@example.com"))
        #expect(secret["identifier_type"] == .string("email"))
        #expect(secret["password"] == .string("hunter2"))
        #expect(secret["otp_secret"] == nil)
    }

    @Test func tellsUsernamesFromPhones() {
        var draft = VaultDraft(kind: .login)
        draft.username = "sam-k"
        #expect(draft.identifierType == "username")
        draft.username = "+1 (415) 555-0100"
        #expect(draft.identifierType == "phone")
        draft.username = "1234"
        #expect(draft.identifierType == "username")
    }

    @Test func aCardNeedsANameNumberExpiryAndCode() throws {
        var draft = VaultDraft(kind: .payment)
        draft.website = "https://www.amazon.com/checkout"
        #expect(draft.problem == .name)
        draft.label = "Personal Visa"
        draft.cardNumber = "4242 4242"
        #expect(draft.problem == .cardNumber)
        draft.cardNumber = "4242 4242 4242 4242"
        draft.expiryMonth = "13"
        draft.expiryYear = "28"
        #expect(draft.problem == .expiry)
        draft.expiryMonth = "8"
        #expect(draft.problem == .securityCode)
        draft.securityCode = "123"
        #expect(draft.problem == nil)
        let secret = try #require(draft.params(profile: nil)?["secret"])
        // Hermes's PAYMENT_FIELDS names; empty optional fields are left out.
        #expect(secret == .object([
            "card_number": .string("4242424242424242"), "exp_month": .string("08"),
            "exp_year": .string("2028"), "cvc": .string("123"),
        ]))
    }

    @Test func anAddressSendsHermesFieldNames() throws {
        var draft = VaultDraft(kind: .address)
        draft.website = "store.example.com"
        draft.label = "Home"
        draft.addressLine1 = "12 Orchard Street"
        draft.city = "Portland"
        draft.state = "OR"
        draft.postalCode = "97201"
        #expect(draft.problem == .address)
        draft.country = "United States"
        let secret = try #require(draft.params(profile: nil)?["secret"])
        #expect(secret == .object([
            "address_line1": .string("12 Orchard Street"), "city": .string("Portland"), "state": .string("OR"),
            "postal_code": .string("97201"), "country": .string("United States"),
        ]))
    }

    // MARK: Calls

    @Test func callsCarryTheProfileAndOnlyDocumentedKeys() async throws {
        let calls = CallLog()
        let client = VaultClient(profile: "research") { method, params in
            await calls.append(method, params)
            switch method {
            case "vault.remove": return .object(["removed": .bool(true)])
            case "vault.add": return .object(["id": .string("vault_9")])
            default: return .object([:])
            }
        }
        try await client.lock()
        try await client.lock("bitwarden")
        try await client.setSource("onepassword", enabled: false)
        #expect(try await client.remove("vault_1"))
        var draft = VaultDraft(kind: .login)
        draft.website = "example.com"
        draft.username = "sam"
        draft.password = "pw"
        #expect(try await client.add(draft) == "vault_9")
        let log = await calls.entries
        #expect(log.map(\.method) == ["vault.lock", "vault.lock", "vault.source.set", "vault.remove", "vault.add"])
        #expect(log.allSatisfy { $0.params["profile"] == .string("research") })
        #expect(log[0].params["name"] == nil)
        #expect(log[1].params["name"] == .string("bitwarden"))
        #expect(log[2].params["enabled"] == .bool(false))
        #expect(Set(log[4].params.keys) == ["kind", "label", "origin", "secret", "profile"])
    }

    @Test func refusesADraftBeforeSendingIt() async throws {
        let calls = CallLog()
        let client = VaultClient(profile: nil) { method, params in
            await calls.append(method, params)
            return .object([:])
        }
        await #expect(throws: GatewayRPCError.self) { try await client.add(VaultDraft(kind: .payment)) }
        #expect(await calls.entries.isEmpty)
    }

    @Test func saysUnlockFailuresInWords() {
        let wrong = GatewayRPCError(code: 5095, message: "1Password unlock failed: [ERROR] authentication: Unauthorized")
        #expect(VaultCopy.unlockFailure(wrong, manager: "1Password", gatewayName: "Studio Mac") == "That password didn't unlock 1Password.")
        let notLoggedIn = GatewayRPCError(code: 5095, message: "Bitwarden unlock failed: not logged in — run `bw login` once in a terminal first")
        #expect(VaultCopy.unlockFailure(notLoggedIn, manager: "Bitwarden", gatewayName: "Studio Mac").contains("isn't signed in on Studio Mac"))
    }
}

@Suite("Passwords setup")
struct PasswordsSetupTests {
    private func facts(_ botMode: GatewaySetupFacts.BotMode = .online) -> GatewaySetupFacts {
        GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: botMode)
    }

    @Test func readyWithAStepForEachMissingManager() {
        var facts = facts()
        facts.vaultSources = [
            VaultSource(name: "local", displayName: "Hermes vault", isEnabled: true, needsUnlock: false, isUnlocked: true, isInstalled: true),
            VaultSource(name: "onepassword", displayName: "1Password", isEnabled: true, needsUnlock: true, isUnlocked: false, isInstalled: true),
            VaultSource(name: "bitwarden", displayName: "Bitwarden", isEnabled: false, needsUnlock: true, isUnlocked: false, isInstalled: false),
        ]
        let status = GatewaySetup.passwords(facts)
        #expect(status.state == .ready)
        #expect(status.detail == "Hermes vault and 1Password")
        #expect(status.steps.map(\.command) == ["npm install -g @bitwarden/cli"])
        #expect(!status.state.needsAttention)
    }

    @Test func anOlderHermesNeedsAnUpdate() {
        var facts = facts()
        facts.vaultMissing = true
        let status = GatewaySetup.passwords(facts)
        #expect(status.state == .notSetUp)
        #expect(status.steps.map(\.command) == ["hermes update"])
    }

    @Test func needsBotMode() {
        #expect(GatewaySetup.passwords(facts(.notLinked)).fix == .linkBotMode)
        #expect(GatewaySetup.passwords(facts()).state == .unknown)
    }
}

private actor CallLog {
    struct Entry: Sendable {
        let method: String
        let params: [String: JSONValue]
    }

    private(set) var entries: [Entry] = []

    func append(_ method: String, _ params: [String: JSONValue]) {
        entries.append(Entry(method: method, params: params))
    }
}
