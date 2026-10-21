import Foundation

/// Passwords over the gateway protocol (`docs/web.md` §1, `tui_gateway/methods_vault.py`). Every
/// call names the profile whose vault it means. A master password and a draft's fields go into
/// one request and nowhere else: nothing here keeps, logs or retries them.
public struct VaultClient: Sendable {
    public typealias Transport = @Sendable (_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue

    let profile: String?
    let transport: Transport

    public init(profile: String?, transport: @escaping Transport) {
        self.profile = profile
        self.transport = transport
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params = params
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        return try await transport(method, params)
    }

    public func sources() async throws -> [VaultSource] {
        VaultSource.list(from: try await call("vault.sources"))
    }

    /// Logins, cards and addresses from Hermes's vault and every unlocked manager.
    public func items() async throws -> [VaultItem] {
        VaultItem.list(from: try await call("vault.list"))
    }

    /// Turns a manager on or off. Hermes locks one it turns off.
    public func setSource(_ name: String, enabled: Bool) async throws {
        _ = try await call("vault.source.set", ["name": .string(name), "enabled": .bool(enabled)])
    }

    /// Hands the master password to the manager's CLI on the gateway; only a session token stays
    /// there, in memory.
    public func unlock(_ name: String, masterPassword: String) async throws {
        _ = try await call("vault.unlock", ["name": .string(name), "password": .string(masterPassword)])
    }

    /// Locks one manager, or every one when `name` is nil (Lock All Password Managers).
    public func lock(_ name: String? = nil) async throws {
        _ = try await call("vault.lock", name.map { ["name": .string($0)] } ?? [:])
    }

    /// Saves to Hermes's vault (the only one the app writes to). Returns the new handle.
    @discardableResult
    public func add(_ draft: VaultDraft) async throws -> String {
        guard let params = draft.params(profile: nil) else {
            throw GatewayRPCError(code: 5095, message: VaultCopy.problem(draft.problem ?? .website, kind: draft.kind))
        }
        let result = try await call("vault.add", params)
        return result["id"]?.stringValue ?? ""
    }

    /// Removes an item from Hermes's vault. False when it was already gone.
    @discardableResult
    public func remove(_ id: String) async throws -> Bool {
        try await call("vault.remove", ["id": .string(id)])["removed"]?.boolValue ?? false
    }
}

/// The words Passwords shows (`docs/web.md` §3, §4, §7): "logins" and "Hermes's vault", never
/// "credentials", "secrets" or "vault backend".
public enum VaultCopy {
    public static func problem(_ problem: VaultDraft.Problem, kind: VaultItem.Kind) -> String {
        switch problem {
        case .website:
            String(localized: "Add the website it's for, like github.com.")
        case .name:
            kind == .payment ? String(localized: "Give the card a name, like Personal Visa.") : String(localized: "Give the address a name, like Home.")
        case .username: String(localized: "Add the username or email you sign in with.")
        case .password: String(localized: "Add the password.")
        case .authenticatorKey: String(localized: "The authenticator key should be the setup key the site showed, or an otpauth:// link.")
        case .cardNumber: String(localized: "Check the card number.")
        case .expiry: String(localized: "Add the expiry month and year.")
        case .securityCode: String(localized: "Add the 3- or 4-digit security code.")
        case .address: String(localized: "Add the street, city, postal code and country.")
        }
    }

    /// An unlock that didn't work, in words. Hermes's own message (`<Manager> unlock failed: …`)
    /// is the manager CLI's, already scrubbed of the password.
    public static func unlockFailure(_ error: any Error, manager: String, gatewayName: String) -> String {
        guard let error = error as? GatewayRPCError else { return String(localized: "Couldn't reach \(gatewayName). Try again.") }
        let message = error.message.lowercased()
        if message.contains("not logged in") || message.contains("not signed in") || message.contains("bw login") {
            return String(localized: "\(manager) isn't signed in on \(gatewayName) yet. Sign in once there, then unlock it here.")
        }
        if message.contains("timed out") {
            return String(localized: "\(manager) took too long to answer on \(gatewayName). Try again.")
        }
        if message.contains("was locked while unlocking") {
            return String(localized: "\(manager) was locked while it unlocked. Try again.")
        }
        if message.contains("not an enabled password manager") {
            return String(localized: "\(manager) is off or isn't on \(gatewayName).")
        }
        return String(localized: "That password didn't unlock \(manager).")
    }

    /// A refused `vault.add`, in words where Hermes's reason is one the app knows.
    public static func addFailure(_ error: any Error, gatewayName: String) -> String {
        guard let error = error as? GatewayRPCError else {
            // Sent, but no answer: Hermes may have saved it.
            if case .timedOut? = error as? GatewaySocket.Failure {
                return String(localized: "\(gatewayName) didn't answer in time. It may have saved it: check the list before adding it again.")
            }
            if case .closed? = error as? GatewaySocket.Failure {
                return String(localized: "The connection to \(gatewayName) dropped. It may have saved it: check the list before adding it again.")
            }
            return String(localized: "Couldn't reach \(gatewayName). Nothing was saved.")
        }
        let message = error.message.lowercased()
        if message.contains("authenticator key") || message.contains("otpauth") {
            return problem(.authenticatorKey, kind: .login)
        }
        if message.contains("origin") { return problem(.website, kind: .login) }
        if message.contains("could not be decrypted") || message.contains("corrupted") {
            return String(localized: "Hermes's vault on \(gatewayName) can't be read, so nothing was saved.")
        }
        return String(localized: "Hermes didn't save it: \(error.message)")
    }
}
