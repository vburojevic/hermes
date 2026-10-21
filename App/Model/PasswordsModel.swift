import Foundation
import HermesKit
import Observation

/// Settings → Hermes on <gateway> → Passwords (`docs/web.md` §3): where Hermes finds logins, and
/// the logins, cards and addresses it can fill. One page's worth: made when the page (or its
/// Settings row) appears and dropped with it. It holds metadata only; a master password or a new
/// item's fields pass through `unlock` and `add` into one call and are never kept, logged or
/// retried.
@MainActor
@Observable
final class PasswordsModel {
    let workspace: BotWorkspace

    private(set) var sources: [VaultSource] = []
    private(set) var items: [VaultItem] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// `vault.*` answered "unknown method": a Hermes from before Passwords.
    private(set) var needsNewerHermes = false
    /// Sources with a lock or switch on its way, for their rows' spinners.
    private(set) var busySources: Set<String> = []
    /// An action that didn't work, in words.
    var message: String?
    var search = ""

    init(workspace: BotWorkspace) {
        self.workspace = workspace
    }

    private var roster: BotRoster? { workspace.roster }

    /// Passwords live in Bot Mode's backend (`vault.*` on its socket).
    var isOnline: Bool { roster?.isConnected ?? false }
    var needsBotMode: Bool { roster == nil }
    var gatewayName: String { workspace.bot.name }
    private var profile: String? { workspace.bot.profileName }

    private var client: VaultClient? {
        guard let roster, roster.isConnected else { return nil }
        return VaultClient(profile: profile) { [weak roster] method, params in
            guard let roster else { throw GatewaySocket.Failure.notConnected }
            return try await roster.request(method, params, timeout: .seconds(45))
        }
    }

    // MARK: Reading

    func source(named name: String) -> VaultSource? {
        sources.first { $0.name == name }
    }

    /// Where an item lives, as people say it: "1Password", "Hermes vault".
    func sourceName(of item: VaultItem) -> String {
        source(named: item.backend)?.displayName ?? (item.isInHermesVault ? String(localized: "Hermes vault") : item.backend)
    }

    func items(in source: VaultSource) -> [VaultItem] {
        items.filter { $0.backend == source.name }
    }

    private func matching(_ kind: VaultItem.Kind) -> [VaultItem] {
        items.filter { $0.kind == kind && $0.matches(search) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var logins: [VaultItem] { matching(.login) }
    var cards: [VaultItem] { matching(.payment) }
    var addresses: [VaultItem] { matching(.address) }
    var loginCount: Int { items.count { $0.kind == .login } }

    /// "Hermes vault and 1Password · 50 logins": the Settings row.
    var summary: String {
        guard !needsBotMode else { return String(localized: "Needs Bot Mode") }
        guard isOnline else { return String(localized: "Needs \(gatewayName) online") }
        guard hasLoaded else { return String(localized: "Logins Hermes can use") }
        if needsNewerHermes { return String(localized: "Needs a newer Hermes Agent") }
        let inUse = sources.filter { $0.state == .vault || $0.state == .unlocked || $0.state == .locked }.map(\.displayName)
        return [inUse.formatted(.list(type: .and)), VaultSummary.logins(loginCount)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Setup's status for a Hermes from before Passwords, from what this page found.
    var newerHermesStatus: SetupStatus {
        var facts = workspace.setup.facts
        facts.vaultMissing = true
        return GatewaySetup.passwords(facts)
    }

    /// Unlocked managers, for Lock All Password Managers.
    var hasUnlockedManagers: Bool { sources.contains { $0.state == .unlocked } }
    var hasManagers: Bool { sources.contains { $0.needsUnlock && $0.state != .notInstalled } }

    // MARK: Loading

    /// Sources and items together. A manager that locked (30 minutes idle) drops its logins here.
    func load() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        async let sources = client.sources()
        async let items = client.items()
        do {
            self.sources = try await sources
            self.items = try await items
            loadError = nil
            needsNewerHermes = false
            hasLoaded = true
        } catch {
            if HermesVersionGap.isMissing(error) {
                needsNewerHermes = true
                hasLoaded = true
            } else {
                loadError = String(localized: "Couldn't read Passwords from \(gatewayName).")
            }
        }
    }

    // MARK: Sources

    func setEnabled(_ source: VaultSource, _ enabled: Bool) async {
        await act(on: source) { try await $0.setSource(source.name, enabled: enabled) }
    }

    func lock(_ source: VaultSource) async {
        await act(on: source) { try await $0.lock(source.name) }
    }

    func lockAll() async {
        guard let client else { return }
        do {
            try await client.lock()
        } catch {
            message = String(localized: "Couldn't lock the password managers on \(gatewayName).")
        }
        await load()
    }

    /// Hands the master password to the manager on the gateway. Returns what went wrong, in
    /// words, or nil once it's unlocked. The caller clears its field before awaiting this.
    func unlock(_ source: VaultSource, masterPassword: String) async -> String? {
        guard let client else { return String(localized: "\(gatewayName) isn't connected.") }
        do {
            try await client.unlock(source.name, masterPassword: masterPassword)
        } catch {
            return VaultCopy.unlockFailure(error, manager: source.displayName, gatewayName: gatewayName)
        }
        await load()
        return nil
    }

    private func act(on source: VaultSource, _ work: (VaultClient) async throws -> Void) async {
        guard let client else { return }
        busySources.insert(source.name)
        defer { busySources.remove(source.name) }
        do {
            try await work(client)
        } catch {
            message = String(localized: "\(source.displayName) didn't change: \(error.localizedDescription)")
        }
        await load()
    }

    // MARK: Items

    /// Saves a new item to Hermes's vault. Returns what went wrong, in words, or nil. The draft
    /// passed in is the only copy: the sheet clears its fields as it calls this.
    func add(_ draft: VaultDraft) async -> String? {
        guard let client else { return String(localized: "\(gatewayName) isn't connected. Nothing was saved.") }
        if let problem = draft.problem { return VaultCopy.problem(problem, kind: draft.kind) }
        do {
            try await client.add(draft)
        } catch {
            return VaultCopy.addFailure(error, gatewayName: gatewayName)
        }
        await load()
        return nil
    }

    /// Removes an item from Hermes's vault (`vault.remove`).
    func remove(_ item: VaultItem) async -> Bool {
        guard item.isInHermesVault, let client else { return false }
        do {
            try await client.remove(item.id)
        } catch {
            message = String(localized: "Couldn't remove \(item.label) from Hermes's vault.")
            return false
        }
        items.removeAll { $0.id == item.id }
        await load()
        return true
    }
}

/// Counts as Passwords says them.
enum VaultSummary {
    static func logins(_ count: Int) -> String {
        count == 1 ? String(localized: "1 login") : String(localized: "\(count) logins")
    }

    static func items(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
    }
}
