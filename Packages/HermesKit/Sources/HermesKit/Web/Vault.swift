import Foundation

// Passwords (`docs/web.md` §3): where Hermes finds logins, and what it can fill. Shapes and rules
// come from Hermes Agent's `tui_gateway/methods_vault.py`, `agent/vault_store.py` and
// `agent/vault_backends/`. Nothing here ever holds a password: the gateway answers metadata only,
// and the one call that carries secrets (`vault.add`) is built from the fields at the moment it's
// sent (`VaultDraft.params`).

/// A place Hermes finds logins: its own vault, 1Password (`op`) or Bitwarden (`bw`) on the
/// gateway (`vault.sources`).
public struct VaultSource: Identifiable, Hashable, Sendable {
    /// `local`, `onepassword`, `bitwarden`.
    public let name: String
    /// "Hermes vault", "1Password", "Bitwarden".
    public let displayName: String
    public let isEnabled: Bool
    public let needsUnlock: Bool
    public let isUnlocked: Bool
    public let isInstalled: Bool

    public var id: String { name }

    public init(name: String, displayName: String, isEnabled: Bool, needsUnlock: Bool, isUnlocked: Bool, isInstalled: Bool) {
        self.name = name
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.needsUnlock = needsUnlock
        self.isUnlocked = isUnlocked
        self.isInstalled = isInstalled
    }

    init?(json: JSONValue) {
        guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        displayName = json["display_name"]?.stringValue ?? name
        isEnabled = json["enabled"]?.boolValue ?? false
        needsUnlock = json["needs_unlock"]?.boolValue ?? (name != Self.hermesVault)
        isUnlocked = json["unlocked"]?.boolValue ?? false
        isInstalled = json["installed"]?.boolValue ?? false
    }

    /// The `sources` of a `vault.sources` answer, in the gateway's order (Hermes vault first).
    public static func list(from result: JSONValue) -> [VaultSource] {
        guard case .array(let rows)? = result["sources"] else { return [] }
        return rows.compactMap(VaultSource.init(json:))
    }

    // TODO(docs/web.md §9): show its lock once Hermes can protect it with a passphrase or the Keychain.
    /// The name of Hermes's own vault. It has no master password: its key is a file beside it.
    public static let hermesVault = "local"

    /// `docs/web.md` §3's source states.
    public enum State: Hashable, Sendable {
        /// Hermes's own vault: always on, never locked.
        case vault
        /// Its logins are listed and fillable until it locks (30 minutes idle).
        case unlocked
        /// Hermes asks for the master password when it needs a login.
        case locked
        /// Installed, but the person turned it off.
        case off
        /// Its CLI isn't on the gateway.
        case notInstalled
    }

    public var state: State {
        guard needsUnlock else { return .vault }
        // Hermes counts a manager as enabled only when its CLI is installed (`is_enabled`).
        guard isInstalled else { return .notInstalled }
        guard isEnabled else { return .off }
        return isUnlocked ? .unlocked : .locked
    }

    /// The manager's command-line tool, which Hermes drives: "op", "bw".
    public var cli: String? {
        switch name {
        case "onepassword": "op"
        case "bitwarden": "bw"
        default: nil
        }
    }

    /// How to put the CLI on the gateway, from each manager's own install instructions.
    public var installCommand: String? {
        switch name {
        case "onepassword": "brew install 1password-cli"
        case "bitwarden": "npm install -g @bitwarden/cli"
        default: nil
        }
    }
}

/// A login, card or address Hermes can fill (`vault.list`): metadata only, never a password,
/// card number or code.
public struct VaultItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Identifiable, CaseIterable {
        case login
        /// A card ("payment" in Hermes).
        case payment
        case address

        public var id: String { rawValue }
    }

    /// A Hermes vault handle (`vault_…`) or a manager's (`op:…`, `bw:…`).
    public let id: String
    public let kind: Kind
    /// What the person called it; what Hermes and the model see.
    public let label: String
    /// `scheme://host[:port]`, the one site it fills on (cards and addresses may have none).
    public let origin: String?
    public let createdAt: Date?
    /// The username, email or phone of a login: metadata Hermes types itself.
    public let identifier: String?
    public let identifierType: String?
    /// A one-time-code key is saved with it: Hermes enters 2FA codes by itself.
    public let hasOneTimeCodes: Bool
    /// Every site a manager item lists, when there's more than one.
    public let allowedOrigins: [String]
    /// The source it lives in (`VaultSource.name`).
    public let backend: String

    public init(id: String, kind: Kind, label: String, origin: String?, createdAt: Date? = nil, identifier: String? = nil,
                identifierType: String? = nil, hasOneTimeCodes: Bool = false, allowedOrigins: [String] = [], backend: String = VaultSource.hermesVault) {
        self.id = id
        self.kind = kind
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.identifier = identifier
        self.identifierType = identifierType
        self.hasOneTimeCodes = hasOneTimeCodes
        self.allowedOrigins = allowedOrigins
        self.backend = backend
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.id = id
        self.kind = kind
        let origin = json["origin"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        self.origin = origin
        label = json["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? origin.flatMap(VaultOrigin.site) ?? id
        createdAt = HermesDate.fromISO(json["created_at"]?.stringValue)
        identifier = json["identifier"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        identifierType = json["identifier_type"]?.stringValue
        hasOneTimeCodes = json["has_otp"]?.boolValue ?? false
        if case .array(let origins)? = json["allowed_origins"] {
            allowedOrigins = origins.compactMap(\.stringValue)
        } else {
            allowedOrigins = []
        }
        backend = json["backend"]?.stringValue ?? VaultSource.hermesVault
    }

    /// The `items` of a `vault.list` answer. Locked managers add nothing.
    public static func list(from result: JSONValue) -> [VaultItem] {
        guard case .array(let rows)? = result["items"] else { return [] }
        return rows.compactMap(VaultItem.init(json:))
    }

    /// Every origin it fills on: Hermes matches each exactly, never a subdomain.
    public var origins: [String] {
        allowedOrigins.isEmpty ? (origin.map { [$0] } ?? []) : allowedOrigins
    }

    /// "github.com": the first site, as people say it.
    public var site: String? { origins.first.flatMap(VaultOrigin.site) }

    /// "github.com only", "amazon.co.uk and www.amazon.co.uk only"; nil without a site.
    public var fillsOn: String? {
        let sites = origins.compactMap(VaultOrigin.site)
        guard !sites.isEmpty else { return nil }
        return String(localized: "\(sites.formatted(.list(type: .and))) only")
    }

    public var isInHermesVault: Bool { backend == VaultSource.hermesVault }

    /// Search goes over names and sites (`docs/web.md` §3), never what's in a field.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return label.localizedStandardContains(query) || origins.contains { $0.localizedStandardContains(query) }
    }
}

/// Hermes's origin rules (`agent/vault_store.py` `normalize_origin`): `scheme://host[:port]`,
/// lowercased, the default port dropped. A fill happens only on this exact origin.
public enum VaultOrigin {
    /// The origin a website field means. A bare name gets https, as the Preview's URL bar does;
    /// Hermes itself needs the scheme, so the app adds it before sending. Nil when there's no
    /// host, or the scheme isn't http or https.
    public static func normalize(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let port = components.port, port != (scheme == "https" ? 443 : 80) else { return "\(scheme)://\(shownHost)" }
        return "\(scheme)://\(shownHost):\(port)"
    }

    /// "github.com", "localhost:3000", "http://intranet.lan" (the scheme only when it isn't https).
    public static func site(_ origin: String) -> String? {
        guard let components = URLComponents(string: origin), let host = components.host, !host.isEmpty else { return nil }
        var site = host
        if let port = components.port { site += ":\(port)" }
        if let scheme = components.scheme?.lowercased(), scheme != "https" { site = "\(scheme)://\(site)" }
        return site
    }
}

/// What the person types into Add Login, Add Card or Add Address (`passwordAdd`), turned into a
/// `vault.add` call at the moment it's sent. The fields are the desktop app's
/// (`vault-settings.tsx`), and the checks are Hermes's (`VaultStore.add_item`), so a refusal is
/// caught here, before anything secret leaves the device.
public struct VaultDraft: Sendable {
    public var kind: VaultItem.Kind
    public var website = ""
    /// The name. Optional for a login (the site stands in); required for a card or address.
    public var label = ""

    // Login
    public var username = ""
    public var password = ""
    /// A Base32 key or an `otpauth://totp/…` link.
    public var authenticatorKey = ""

    // Card
    public var cardNumber = ""
    public var nameOnCard = ""
    public var expiryMonth = ""
    public var expiryYear = ""
    public var securityCode = ""
    public var billingPostalCode = ""

    // Address
    public var addressLine1 = ""
    public var addressLine2 = ""
    public var city = ""
    public var state = ""
    public var postalCode = ""
    public var country = ""

    public init(kind: VaultItem.Kind) {
        self.kind = kind
    }

    /// Why it can't be saved yet, in the app's words.
    public enum Problem: Equatable, Sendable {
        case website
        case name
        case username
        case password
        case authenticatorKey
        case cardNumber
        case expiry
        case securityCode
        case address
    }

    /// The first thing missing or wrong, or nil when it can be sent.
    public var problem: Problem? {
        // The desktop requires a site for every kind: a card or address without one can't be filled.
        guard VaultOrigin.normalize(website) != nil else { return .website }
        switch kind {
        case .login:
            if trimmed(username).isEmpty { return .username }
            if password.isEmpty { return .password }
            if !trimmed(authenticatorKey).isEmpty, !Self.isAuthenticatorKey(authenticatorKey) { return .authenticatorKey }
        case .payment:
            if trimmed(label).isEmpty { return .name }
            let digits = cardDigits
            if digits.count < 12 || digits.count > 19 || digits.contains(where: { !$0.isASCII || !$0.isNumber }) { return .cardNumber }
            guard let month = Int(trimmed(expiryMonth)), (1...12).contains(month),
                  let year = Int(trimmed(expiryYear)), trimmed(expiryYear).count == 2 || trimmed(expiryYear).count == 4, year >= 0 else { return .expiry }
            let code = trimmed(securityCode)
            if code.count < 3 || code.count > 4 || !code.allSatisfy({ $0.isASCII && $0.isNumber }) { return .securityCode }
        case .address:
            if trimmed(label).isEmpty { return .name }
            if trimmed(addressLine1).isEmpty || trimmed(city).isEmpty || trimmed(postalCode).isEmpty || trimmed(country).isEmpty { return .address }
        }
        return nil
    }

    /// The `vault.add` params: `{kind, label, origin, secret}`. Nil while `problem` isn't. Build it
    /// as the call goes out, then clear the draft: it's the only copy the app keeps.
    public func params(profile: String?) -> [String: JSONValue]? {
        guard problem == nil, let origin = VaultOrigin.normalize(website) else { return nil }
        var params: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "label": .string(name(for: origin)),
            "origin": .string(origin),
            "secret": .object(secret),
        ]
        if let profile { params["profile"] = .string(profile) }
        return params
    }

    /// The name sent: what the person typed, else the site ("github.com").
    func name(for origin: String) -> String {
        let label = trimmed(label)
        return label.isEmpty ? (VaultOrigin.site(origin) ?? origin) : label
    }

    /// The fields Hermes keeps encrypted, under its canonical names (`PAYMENT_FIELDS`,
    /// `ADDRESS_FIELDS`). For a login, Hermes moves the identifier into the metadata.
    var secret: [String: JSONValue] {
        switch kind {
        case .login:
            var secret: [String: JSONValue] = [
                "identifier_type": .string(identifierType),
                "identifier": .string(trimmed(username)),
                "password": .string(password),
            ]
            let key = trimmed(authenticatorKey)
            if !key.isEmpty { secret["otp_secret"] = .string(key) }
            return secret
        case .payment:
            var secret: [String: JSONValue] = [
                "card_number": .string(cardDigits),
                "exp_month": .string(trimmed(expiryMonth).count == 1 ? "0" + trimmed(expiryMonth) : trimmed(expiryMonth)),
                "exp_year": .string(trimmed(expiryYear).count == 2 ? "20" + trimmed(expiryYear) : trimmed(expiryYear)),
                "cvc": .string(trimmed(securityCode)),
            ]
            if !trimmed(nameOnCard).isEmpty { secret["cardholder_name"] = .string(trimmed(nameOnCard)) }
            if !trimmed(billingPostalCode).isEmpty { secret["billing_postal_code"] = .string(trimmed(billingPostalCode)) }
            return secret
        case .address:
            var secret: [String: JSONValue] = [
                "address_line1": .string(trimmed(addressLine1)),
                "city": .string(trimmed(city)),
                "postal_code": .string(trimmed(postalCode)),
                "country": .string(trimmed(country)),
            ]
            if !trimmed(addressLine2).isEmpty { secret["address_line2"] = .string(trimmed(addressLine2)) }
            if !trimmed(state).isEmpty { secret["state"] = .string(trimmed(state)) }
            return secret
        }
    }

    /// Email, phone or username, as Hermes types it (`LOGIN_IDENTIFIER_TYPES`).
    var identifierType: String {
        let username = trimmed(username)
        if username.contains("@") { return "email" }
        let phoneCharacters = CharacterSet(charactersIn: "+0123456789 ()-.")
        if username.unicodeScalars.allSatisfy(phoneCharacters.contains), username.filter(\.isNumber).count >= 7 { return "phone" }
        return "username"
    }

    var cardDigits: String {
        cardNumber.filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Hermes's own check (`normalize_otp_secret`): Base32, or an `otpauth://totp/…` link.
    static func isAuthenticatorKey(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("otpauth://") {
            guard let components = URLComponents(string: text), components.host?.lowercased() == "totp",
                  let secret = components.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value else { return false }
            return isBase32(secret)
        }
        return isBase32(text)
    }

    private static func isBase32(_ text: String) -> Bool {
        var seed = text.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        while seed.hasSuffix("=") { seed.removeLast() }
        return !seed.isEmpty && seed.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
