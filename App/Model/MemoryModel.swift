import Foundation
import HermesKit
import Observation

/// What Hermes, or one Bot, remembers on a gateway (`docs/memory.md`): About You and Hermes's
/// Notes, saves waiting for review, the switches and the provider. One page's worth: the model
/// is made when the page opens and dropped when it closes, so entries never outlive the screen
/// (never logged, never in Spotlight, never on disk). Every change re-reads what it touched.
@MainActor
@Observable
final class MemoryModel {
    /// Whose memory: Hermes on the gateway, or a Bot (its own profile).
    enum Scope: Hashable {
        case hermes
        case bot(String)
    }

    /// How an edit ended.
    enum EditOutcome: Equatable {
        case saved
        /// The gateway refused it (over the size cap, or the entry changed); the text stays.
        case refused(String)
    }

    let workspace: BotWorkspace
    let scope: Scope
    /// What the memory tool saved in the chat the person came from: those entries get "New in
    /// this chat".
    let newInChat: [String]

    var tab: MemoryStoreKind = .about

    private(set) var list: MemoryList?
    private(set) var settings: MemorySettings?
    private(set) var status: MemoryStatus?
    private(set) var pending: [MemoryPending] = []
    /// The review list couldn't be read (an older gateway, no session for a Bot).
    private(set) var pendingUnavailable = false
    private(set) var hasLoadedPending = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// A gateway message to show (an action that failed).
    var message: String?
    /// A passing note: what a save replaced, what was reset.
    var toast: String?

    init(workspace: BotWorkspace, scope: Scope = .hermes, newInChat: [String] = []) {
        self.workspace = workspace
        self.scope = scope
        self.newInChat = newInChat
    }

    // MARK: Gateway

    private var roster: BotRoster? { workspace.roster }

    /// Memory lives in Bot Mode's backend (`/api/learning`, `/api/memory`).
    var isOnline: Bool { roster?.isConnected ?? false }
    var needsBotMode: Bool { roster == nil }
    var gatewayName: String { workspace.bot.name }

    /// The profile every call names: the Bot's, or the gateway's own.
    var profile: String? {
        switch scope {
        case .hermes: workspace.bot.profileName
        case .bot(let name): name
        }
    }

    var bot: BotProfile? {
        if case .bot(let name) = scope { return roster?.bot(named: name) }
        return nil
    }

    /// "Hermes" or the Bot's name.
    var keeperName: String {
        bot?.title ?? (scope == .hermes ? "Hermes" : String(localized: "This Bot"))
    }

    /// "What Hermes on Studio Mac remembers", "What Research Buddy remembers".
    var headline: String {
        if let bot { return String(localized: "What \(bot.title) remembers") }
        return String(localized: "What Hermes on \(gatewayName) remembers")
    }

    // MARK: Reading

    func entries(in store: MemoryStoreKind) -> [MemoryEntry] {
        list?.entries(in: store) ?? []
    }

    func pending(in store: MemoryStoreKind) -> [MemoryPending] {
        // A record that doesn't name its store is about the notes (the memory tool's default).
        pending.filter { ($0.store ?? .notes) == store }
    }

    func limit(for store: MemoryStoreKind) -> Int {
        settings?.limit(for: store) ?? store.defaultLimit
    }

    /// Characters the store takes. The graph cuts entries at 1,200 characters, so a cut one
    /// counts the file's size instead.
    func used(in store: MemoryStoreKind) -> Int {
        let entries = entries(in: store)
        let counted = MemoryUsage.characters(entries.map(\.text))
        guard entries.contains(where: \.isTruncated), let bytes = status?.fileSizes[store.target] else { return counted }
        return max(counted, bytes)
    }

    func fraction(in store: MemoryStoreKind) -> Double {
        MemoryUsage.fraction(used: used(in: store), limit: limit(for: store))
    }

    func isNearlyFull(_ store: MemoryStoreKind) -> Bool {
        MemoryUsage.isNearlyFull(used: used(in: store), limit: limit(for: store))
    }

    /// Saved during the chat the person came from.
    func isNew(_ entry: MemoryEntry) -> Bool {
        let text = Self.normalized(entry.text)
        return newInChat.contains { saved in
            let wanted = Self.normalized(saved)
            return !wanted.isEmpty && (text == wanted || text.contains(wanted))
        }
    }

    var isEnabled: Bool { !(settings?.isOff ?? false) }

    var totalCount: Int { (list?.about.count ?? 0) + (list?.notes.count ?? 0) }

    /// "6 things about you · 14 notes · 2 to review": the Settings row.
    var summary: String {
        guard let list else { return isOnline ? String(localized: "What Hermes knows about you") : String(localized: "Needs \(gatewayName) online") }
        var parts = [MemoryCopy.aboutCount(list.about.count), MemoryCopy.notesCount(list.notes.count)]
        if !pending.isEmpty { parts.append(String(localized: "\(pending.count) to review")) }
        return parts.joined(separator: " · ")
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // MARK: Loading

    /// Entries, switches, provider and the review list, all at once. A Bot's review list needs a
    /// session of the Bot's, so a summary row (Edit Bot) leaves it out.
    func load(includingPending: Bool = true) async {
        guard let roster, roster.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        let profile = profile
        async let entries = roster.memoryEntries(profile: profile)
        async let settings = roster.memorySettings(profile: profile)
        async let status = roster.memoryStatus(profile: profile)
        async let reviews: Void = includingPending ? loadPending() : ()
        do {
            list = try await entries
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        self.settings = try? await settings
        self.status = try? await status
        await reviews
    }

    /// A provider's settings, for setting it up from the app (`docs/setup.md` §4.4).
    func providerForm(_ name: String) async throws -> MemoryProviderForm {
        guard let roster, roster.isConnected else { throw HermesError.invalidResponse(String(localized: "\(gatewayName) isn't connected.")) }
        return try await roster.backendClient.memoryProviderForm(name, profile: profile)
    }

    /// Saves a provider's settings on the gateway, then reads its state again.
    func saveProvider(_ name: String, values: [String: JSONValue]) async throws {
        guard let roster, roster.isConnected else { throw HermesError.invalidResponse(String(localized: "\(gatewayName) isn't connected.")) }
        try await roster.backendClient.saveMemoryProvider(name, values: values, profile: profile)
        if let fresh = try? await roster.memoryStatus(profile: profile) { status = fresh }
    }

    enum ProviderInstallOutcome: Equatable {
        /// Installed; the provider's status after (`needs_config` wants its settings next).
        case installed(status: String?)
        /// Steps that failed, with Hermes's output.
        case failed([MemoryProviderInstall.Step])
        /// The request stopped waiting and the provider still isn't installed.
        case unknown
        case error(String)
    }

    /// Installs what a provider needs on the gateway (`docs/setup.md` §4.4). A proxy in front of
    /// the dashboard may stop waiting before Hermes is done, so a busy answer is followed by
    /// reading the provider again until it's installed, for up to six minutes.
    func installProvider(_ name: String) async -> ProviderInstallOutcome {
        guard let roster, roster.isConnected else { return .error(String(localized: "\(gatewayName) isn't connected.")) }
        let client = roster.backendClient
        do {
            let result = try await client.installMemoryProvider(name, profile: profile)
            if let fresh = try? await roster.memoryStatus(profile: profile) { status = fresh }
            return result.ok ? .installed(status: result.providerStatus) : .failed(result.steps.filter(\.failed))
        } catch let error where BackendClient.isSlowAnswer(error) {
            for _ in 0..<72 {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return .unknown }
                if let form = try? await client.memoryProviderForm(name, profile: profile), form.setup?.installed == true {
                    if let fresh = try? await roster.memoryStatus(profile: profile) { status = fresh }
                    return .installed(status: status?.providers.first { $0.name == name }?.status)
                }
            }
            return .unknown
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Just the entries (after an edit, a forget, a save from review).
    func reloadEntries() async {
        guard let roster, roster.isConnected else { return }
        if let fresh = try? await roster.memoryEntries(profile: profile) { list = fresh }
        if let fresh = try? await roster.memoryStatus(profile: profile) { status = fresh }
    }

    /// `/memory pending`. The gateway scopes `command.dispatch` by session: a Bot's review list
    /// needs a session of the Bot's; the gateway's own profile needs none.
    func loadPending() async {
        do {
            let text = try await memoryCommand("pending")
            // The gateway lists the oldest first; the newest leads here (`memoryNotes`).
            pending = MemoryPendingParser.parse(text).reversed()
            pendingUnavailable = false
            hasLoadedPending = true
        } catch {
            pendingUnavailable = true
        }
    }

    private func memoryCommand(_ argument: String) async throws -> String {
        guard let roster, roster.isConnected else { throw GatewaySocket.Failure.notConnected }
        var params: [String: JSONValue] = ["name": .string("memory"), "arg": .string(argument)]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        if case .bot(let name) = scope, roster.bot(named: name)?.isDefault != true {
            params["session_id"] = .string(try await roster.conversation(for: name).runtimeForCommands())
        }
        let reply = try await roster.request("command.dispatch", params, timeout: .seconds(30))
        return reply["output"]?.stringValue ?? reply["message"]?.stringValue ?? ""
    }

    // MARK: Entries

    /// The whole entry, for editing: the list carries only its first 1,200 characters.
    func fullText(of entry: MemoryEntry) async -> String {
        guard entry.isTruncated, let roster else { return entry.text }
        return (try? await roster.memoryEntryText(id: entry.id, profile: profile)) ?? entry.text
    }

    /// Rewrites an entry. A refusal keeps the person's text and shows the gateway's words; if the
    /// entry changed on the gateway meanwhile, the list reloads.
    func save(_ entry: MemoryEntry, text: String) async -> EditOutcome {
        guard let roster, roster.isConnected else { return .refused(String(localized: "\(gatewayName) is offline. Your text is still here.")) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(String(localized: "An entry can't be empty. Use Forget This to remove it.")) }
        do {
            try await roster.editMemoryEntry(id: entry.id, content: trimmed, profile: profile)
            await reloadEntries()
            return .saved
        } catch {
            let message = error.localizedDescription
            if Self.isStale(message) { await reloadEntries() }
            return .refused(message)
        }
    }

    /// The same entry after a reload (its id changes with its text): by store and position.
    func current(_ entry: MemoryEntry, at index: Int?) -> MemoryEntry? {
        let entries = entries(in: entry.store)
        if let match = entries.first(where: { $0.id == entry.id }) { return match }
        if let index, entries.indices.contains(index) { return entries[index] }
        return nil
    }

    static func isStale(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("stale") || message.localizedCaseInsensitiveContains("not found")
    }

    func forget(_ entry: MemoryEntry) async {
        guard let roster, roster.isConnected else { return }
        do {
            try await roster.forgetMemoryEntry(id: entry.id, profile: profile)
        } catch {
            message = error.localizedDescription
        }
        await reloadEntries()
    }

    // MARK: Review

    func approve(_ item: MemoryPending) async {
        do {
            let reply = MemoryPendingParser.approveReply(try await memoryCommand("approve \(item.id)"))
            if let failure = reply.failure {
                message = failure
            } else if let replaced = reply.overwritten.first {
                toast = String(localized: "Saved. It replaced: \(replaced)")
            }
        } catch {
            message = error.localizedDescription
        }
        await loadPending()
        await reloadEntries()
    }

    func discard(_ item: MemoryPending) async {
        do {
            _ = try await memoryCommand("reject \(item.id)")
        } catch {
            message = error.localizedDescription
        }
        await loadPending()
    }

    // MARK: Options

    func setEnabled(_ store: MemoryStoreKind, _ enabled: Bool) async {
        await setSetting(MemorySettings.enabledKey(for: store), enabled) { settings in
            switch store {
            case .about: settings.userProfileEnabled = enabled
            case .notes: settings.memoryEnabled = enabled
            }
        }
    }

    /// Ask Before Saving: `memory.write_approval`.
    func setAskBeforeSaving(_ on: Bool) async {
        await setSetting("write_approval", on) { $0.askBeforeSaving = on }
    }

    /// Turn On Memory (`memoryOff`): both stores.
    func turnOn() async {
        await setEnabled(.about, true)
        await setEnabled(.notes, true)
    }

    private func setSetting(_ key: String, _ value: Bool, apply: (inout MemorySettings) -> Void) async {
        guard let roster, roster.isConnected else { return }
        var optimistic = settings ?? MemorySettings()
        apply(&optimistic)
        settings = optimistic
        do {
            try await roster.setMemorySetting(key, to: value, profile: profile)
        } catch {
            message = error.localizedDescription
        }
        if let fresh = try? await roster.memorySettings(profile: profile) { settings = fresh }
    }

    func setProvider(_ provider: String) async {
        guard let roster, roster.isConnected else { return }
        do {
            try await roster.setMemoryProvider(provider, profile: profile)
        } catch {
            message = error.localizedDescription
        }
        if let fresh = try? await roster.memoryStatus(profile: profile) { status = fresh }
    }

    /// Reset Memory…: both files go. Destructive and not undoable; the page confirms first.
    func reset() async {
        guard let roster, roster.isConnected else { return }
        do {
            try await roster.resetMemory(target: "all", profile: profile)
            toast = String(localized: "\(keeperName)'s memory was reset.")
        } catch {
            message = error.localizedDescription
        }
        await reloadEntries()
    }

    // MARK: Telling

    /// Tell Hermes Something to Remember…: a new chat (or the Bot's) with "Remember that " typed.
    func tellSomething() {
        switch scope {
        case .hermes: workspace.startRememberChat(bot: nil)
        case .bot(let name): workspace.startRememberChat(bot: name)
        }
    }
}

/// The page's counts in words, shared by every platform.
enum MemoryCopy {
    static func aboutCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 thing about you") : String(localized: "\(count) things about you")
    }

    static func notesCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 note") : String(localized: "\(count) notes")
    }

    static func count(_ count: Int, in store: MemoryStoreKind) -> String {
        store == .about ? aboutCount(count) : notesCount(count)
    }

    /// An entry read aloud: its text with one full stop, then where it lives.
    static func spoken(_ entry: MemoryEntry) -> String {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = text.last.map { ".!?…".contains($0) } == true ? text : text + "."
        return "\(sentence) \(storeLabel(entry.store))"
    }

    static func storeTitle(_ store: MemoryStoreKind) -> String {
        store == .about ? String(localized: "About You") : String(localized: "Hermes's Notes")
    }

    /// "About you", "Hermes's notes": where an entry lives, mid-sentence.
    static func storeLabel(_ store: MemoryStoreKind) -> String {
        store == .about ? String(localized: "About you") : String(localized: "Hermes's notes")
    }

    /// Memory is read at the start of a chat: changes never reach the open one.
    static let appliesNext = String(localized: "Hermes reads this at the start of every chat, so changes apply from your next one.")
}
