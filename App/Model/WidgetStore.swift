import Foundation
import HermesKit
import HermesPush
import Observation
import os

/// One gateway's widgets (`docs/widgets.md` §4): the newest revision of each, what this device
/// sent and when, batches waiting to go, and each widget's view state. Answered, locked and
/// folded come from the chat's own rows (`WidgetChatFacts`), so they hold on every device.
@MainActor
@Observable
final class WidgetStore {
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "widgets")

    let gatewayID: UUID
    @ObservationIgnored weak var workspace: BotWorkspace?

    /// The gateway has the `hermes-app-widgets` plugin: the `widget` tool is in its tool list
    /// (`docs/widgets.md` §11).
    private(set) var isAvailable = false
    /// The tool list has answered once (`checkSupport`): until then a chat is marked anyway.
    @ObservationIgnored private var supportChecked = false

    /// The newest revision read of each widget, by id (stack children included).
    private(set) var results: [String: WidgetReader.Result] = [:]
    /// A tap not in the chat yet, by widget id.
    private(set) var local: [String: WidgetInteraction] = [:]
    /// Answers this device sent, by mid (kept, so a restart still knows which were its own).
    private(set) var mine: Set<String> = []
    /// When this device's answer entered a turn, by mid.
    private(set) var enteredTurn: [String: Date] = [:]
    /// Ticks not sent yet, or sent and not confirmed, by checklist id.
    private(set) var ticks: [String: ChecklistTicks] = [:]
    /// Ratings of a flashcard session in progress, by widget id.
    private(set) var ratings: [String: [(card: String, rating: WidgetAnswer.Rating)]] = [:]
    /// Local interactions (sort, filter, a guide's step…), by widget id.
    private(set) var views: [String: WidgetViewState] = [:]
    /// Widgets hidden on this device (the widget menu's Hide).
    private(set) var hidden: Set<String> = []

    /// Each card's last height, by id, revision and column width: a reopened chat holds the
    /// space until the card draws, so the transcript doesn't jump while scrolling back.
    @ObservationIgnored var heights: [String: Double] = [:]
    @ObservationIgnored private var flushes: [String: Task<Void, Never>] = [:]
    /// Who sends a batch when its timer fires.
    @ObservationIgnored private var batchOwners: [String: WeakConversation] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    /// Widgets a directive names that aren't on this device or in the chat's rows.
    private(set) var missing: Set<String> = []
    /// Chats told to the plugin as the app's this run (`docs/widgets.md` §11).
    @ObservationIgnored private var marked: Set<String> = []
    /// Widgets whose payload came from a reply's text (an inline block), not from the plugin.
    @ObservationIgnored private var fromText: Set<String> = []

    init(gatewayID: UUID) {
        self.gatewayID = gatewayID
        mine = WidgetCache.loadMine(gateway: gatewayID)
        views = WidgetCache.loadViews(gateway: gatewayID)
    }

    // MARK: - Payloads

    func result(_ id: String) -> WidgetReader.Result? {
        results[id]
    }

    func payload(_ id: String) -> WidgetPayload? {
        results[id]?.payload
    }

    /// A payload from a `widget` tool result, a stored row or an inline block (`fromText`). The
    /// newest revision wins and redraws in place; an older one arriving later is dropped. A reply's
    /// text can't rewrite what the plugin wrote, nor the same revision of what text wrote: a Bot's
    /// reply could otherwise swap the terms of another's request under its id, and the person would
    /// sign terms they never saw (security scan F11).
    @discardableResult
    func ingest(_ json: JSONValue, persist: Bool = true, fromText inline: Bool = false) -> WidgetReader.Result? {
        guard let id = json["id"]?.stringValue else { return nil }
        let rev = json["rev"]?.intValue ?? 1
        if let current = results[id], current.rev > rev { return current }
        if let current = results[id], current.rev == rev, current.payload?.json == json { return current }
        if inline, let current = results[id], !fromText.contains(id) || current.rev == rev { return current }
        if inline { fromText.insert(id) } else { fromText.remove(id) }
        let result = WidgetReader.read(json)
        let previous = results[id]?.payload
        missing.remove(id)
        results[id] = result
        // Widgets inside a stack are widgets of their own: an update to a child replaces just it.
        if case .stack(let stack)? = result.payload?.content {
            for child in stack.children {
                switch child {
                case .payload(let payload) where (results[payload.id]?.rev ?? 0) < payload.rev:
                    results[payload.id] = .ready(payload)
                case .unreadable(let json):
                    if let childID = json["id"]?.stringValue, results[childID] == nil { results[childID] = WidgetReader.read(json) }
                default:
                    break
                }
            }
        }
        if let previous, previous.rev < rev { revisionArrived(id, from: previous, to: result.payload) }
        if persist { WidgetCache.save(json, result: result, gateway: gatewayID) }
        return result
    }

    /// The payloads in a chat's stored rows (`docs/widgets.md` §2).
    func ingest(messages: [SessionMessage]) {
        for message in messages where message.role == "tool" && message.toolName == WidgetToolResult.widgetTool {
            if let json = WidgetToolResult.payload(fromText: message.content.text) { ingest(json) }
        }
    }

    /// A widget a directive names but this device hasn't read: the payloads kept on the device,
    /// then the chat's rows again with the ones compression set aside.
    func loadMissing(_ id: String, conversation: ConversationModel?) {
        guard results[id] == nil, !missing.contains(id), loading.insert(id).inserted else { return }
        Task {
            defer { loading.remove(id) }
            if let json = await WidgetCache.load(id, gateway: gatewayID) {
                ingest(json, persist: false)
                return
            }
            await conversation?.fetchWidgetRows(limit: 200)
            if results[id] == nil { missing.insert(id) }
        }
    }

    /// Try Again on "Couldn't load this widget": the chat's rows once more.
    func retryMissing(_ id: String, conversation: ConversationModel?) {
        missing.remove(id)
        loadMissing(id, conversation: conversation)
    }

    private func revisionArrived(_ id: String, from previous: WidgetPayload, to payload: WidgetPayload?) {
        // A newer revision settles what was waiting on the older one.
        local[id] = nil
        if let ticks = ticks[id], case .checklist(let old) = previous.content, case .checklist(let new)? = payload?.content {
            let rebased = ticks.rebased(from: old, to: new, rev: payload?.rev ?? previous.rev)
            self.ticks[id] = rebased.unsent.isEmpty ? nil : rebased
        }
        if payload?.envelope.resolution != nil { ratings[id] = nil }
    }

    // MARK: - Support

    /// Looks for the `widget` tool in the gateway's tool list.
    func checkSupport(client: HermesClient?, roster: BotRoster?) async {
        var found = false
        if let toolsets = try? await client?.toolsets() {
            found = toolsets.contains { $0.enabled != false && ($0.tools ?? []).contains(WidgetToolResult.widgetTool) }
        }
        if !found, let roster, roster.isConnected {
            let connections = ConnectionsClient(profile: workspace?.bot.profileName) { method, params in
                try await roster.request(method, params)
            }
            if let tools = try? await connections.toolsetTools() {
                found = tools.values.contains { $0.contains(WidgetToolResult.widgetTool) }
            }
        }
        // A Bot's own profile can have the plugin when Hermes itself doesn't.
        if !found, workspace?.plugins.survey?.profilesRunning(.widgets).isEmpty == false { found = true }
        supportChecked = true
        if found != isAvailable { isAvailable = found }
        if found {
            await registerKeyIfNeeded()
            markKnownChats()
        }
    }

    // MARK: - Signed answers (`docs/widgets.md` §6)

    @ObservationIgnored var signer: any WidgetAnswerSigning = DeviceWidgetSigner.shared
    /// The key generation this gateway has: a new key goes to it before a signed answer does.
    @ObservationIgnored private var registeredGeneration: Int?
    /// Widgets waiting on Face ID: their buttons stay as they are until it's done.
    private(set) var authorizing: Set<String> = []
    /// Why a widget's answer couldn't be confirmed, by widget id, for the card's alert.
    var authProblem: [String: AuthProblem] = [:]

    struct AuthProblem: Equatable {
        var message: String
        /// The device has no Face ID, Touch ID or passcode: Settings can fix it (`docs/setup.md`).
        var opensSettings = false
    }

    /// The plugin's commands that aren't about one chat (the signing key, marking known chats) go
    /// through a profile that runs it: Hermes itself, else a Bot that has it, through that Bot's open
    /// chat, since Hermes runs a command without a session in the profile it was launched in. Its
    /// data is the Hermes root's, so any profile's copy marks for all of them.
    private func pluginClient() -> AppWidgetsClient? {
        guard let roster = workspace?.roster, roster.isConnected else { return nil }
        let open = Set(roster.botConversations.filter { $0.value.runtimeSessionID != nil }.keys)
        let profile = workspace?.plugins.survey?.commandProfile(for: .widgets, open: open)
        let bot = profile == "default" ? nil : profile
        let session = bot.flatMap { roster.botConversations[$0]?.runtimeSessionID }
        return AppWidgetsClient(profile: bot, session: session) { method, params in try await roster.request(method, params) }
    }

    /// Gives the gateway this device's key, once per key (contract §6.3). Without a Secure
    /// Enclave there's no key, and the plugin's check is the app's Face ID alone.
    func registerKeyIfNeeded() async {
        guard isAvailable, registeredGeneration != signer.generation,
              let publicKey = signer.publicKey, let client = pluginClient() else { return }
        let generation = signer.generation
        do {
            try await client.registerKey(deviceID: PushShared.current.deviceID, publicKey: publicKey, name: ConversationModel.widgetDevice)
            registeredGeneration = generation
        } catch {
            WidgetStore.logger.notice("widgets: registering the signing key failed (\(BotRoster.describe(error), privacy: .public))")
        }
    }

    /// The gateway is being removed from the app: its plugin forgets this device's key.
    func forgetDevice() {
        guard registeredGeneration != nil, let client = pluginClient() else { return }
        let deviceID = PushShared.current.deviceID
        Task { try? await client.removeKey(deviceID: deviceID) }
    }

    /// An answer that needs Face ID or Touch ID and the device's signature: asked first, signed,
    /// then sent like any other. Offline, it isn't sent at all (approvals don't queue).
    func sendSigned(_ answer: WidgetAnswer, title: String, via conversation: any WidgetAnswerSender) {
        guard conversation.canSendWidgetAnswer else {
            noteNotSent(answer)
            return
        }
        guard authorizing.insert(answer.widgetID).inserted else { return }
        let reason = String(localized: "Confirm “\(title)”")
        Task {
            defer { authorizing.remove(answer.widgetID) }
            do {
                var signed = answer
                signed.sig = try await signer.authorize(answer, reason: reason)
                if signed.sig != nil { await registerKeyIfNeeded() }
                conversation.sendWidgetAnswer(signed)
            } catch DeviceWidgetSigner.Failure.cancelled {
                // Nothing was sent; the buttons are as they were.
            } catch DeviceWidgetSigner.Failure.unavailable {
                authProblem[answer.widgetID] = AuthProblem(
                    message: String(localized: "This needs Face ID, Touch ID or a passcode, and this device has none set up. Answer it on another device, or set one up.") + " " + DeviceSetup.passcodePath,
                    opensSettings: true)
            } catch {
                authProblem[answer.widgetID] = AuthProblem(message: String(localized: "Couldn’t confirm it’s you, so nothing was sent."))
            }
        }
    }

    /// Bot Mode's socket is up: what goes through it (the signing key, marking the chats this device
    /// knows) runs now, since the gateway's tool list is usually read before the socket opens.
    func socketConnected() {
        guard isAvailable else { return }
        Task { [weak self] in
            await self?.registerKeyIfNeeded()
            self?.markKnownChats()
        }
    }

    /// Chats told to the plugin in bulk this run, and the call on its way.
    @ObservationIgnored private var bulkMarked: Set<String> = []
    @ObservationIgnored private var bulkMarking: Task<Void, Never>?

    /// Tells the plugin that every chat this device knows is the app's (`docs/widgets.md` §11), so
    /// widgets reach chats it never opens: a Bot Chat a routine writes to, a chat on another
    /// device. On connect and as the lists move; new ids only, 500 to a call.
    func markKnownChats() {
        guard isAvailable, bulkMarking == nil, let workspace, let client = pluginClient() else { return }
        var seen: Set<String> = []
        let ids = (workspace.sessions.map(\.id) + (workspace.roster?.botChats.keys.sorted() ?? []))
            .filter { !$0.isEmpty && !bulkMarked.contains($0) && !marked.contains($0) && seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        bulkMarking = Task { [weak self] in
            defer { self?.bulkMarking = nil }
            for start in stride(from: 0, to: ids.count, by: 500) {
                let batch = Array(ids[start..<min(start + 500, ids.count)])
                do {
                    try await client.markSessions(batch)
                    self?.bulkMarked.formUnion(batch)
                } catch {
                    WidgetStore.logger.notice("widgets: marking known chats failed (\(BotRoster.describe(error), privacy: .public))")
                    return
                }
            }
        }
    }

    /// Whether a chat of `profile` can be marked: what the plugin survey read of that profile, else
    /// the gateway's tool list. A first message sent before either answered marks its chat anyway, so
    /// it isn't answered in plain text for being early (a gateway without the plugin says 4018).
    func reaches(profile: String?) -> Bool {
        if let runs = workspace?.plugins.survey?.runs(.widgets, in: profile ?? "default") { return runs }
        return isAvailable || !supportChecked
    }

    func needsMark(_ sessionID: String) -> Bool {
        !marked.contains(sessionID)
    }

    func noteMarked(_ sessionID: String) {
        marked.insert(sessionID)
    }

    // MARK: - Sending

    /// Marks a tap: this device sent `answer`, and it waits or goes now.
    func noteSent(_ answer: WidgetAnswer, queued: Bool) {
        mine.insert(answer.mid)
        WidgetCache.saveMine(mine, gateway: gatewayID)
        local[answer.widgetID] = .sending(action: answer.action, queued: queued)
    }

    func noteNotSent(_ answer: WidgetAnswer) {
        local[answer.widgetID] = .notSent(action: answer.action)
    }

    /// A message carrying an answer started a turn: the 60 s timer starts now.
    func noteEnteredTurn(_ text: String) {
        guard let answer = WidgetAnswer.parse(text), !answer.mid.isEmpty else { return }
        enteredTurn[answer.mid] = .now
        if case .sending? = local[answer.widgetID] { local[answer.widgetID] = nil }
    }

    // MARK: - Batches (contract §6.1)

    /// Ticks an item; the batch goes 5 s after the last tick, or when the chat closes.
    func tick(_ item: String, in payload: WidgetPayload, conversation: ConversationModel) {
        var batch = ticks[payload.id] ?? ChecklistTicks(rev: payload.rev)
        batch.toggle(item)
        ticks[payload.id] = batch
        batchOwners[payload.id] = WeakConversation(conversation)
        flushes[payload.id]?.cancel()
        flushes[payload.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.flush(payload.id)
        }
    }

    /// Rates a card; the ratings go as one message when the session ends.
    func rate(_ card: String, _ rating: WidgetAnswer.Rating, in payload: WidgetPayload, total: Int, conversation: ConversationModel) {
        var list = ratings[payload.id] ?? []
        list.removeAll { $0.card == card }
        list.append((card, rating))
        ratings[payload.id] = list
        batchOwners[payload.id] = WeakConversation(conversation)
        if list.count >= total { flush(payload.id) }
    }

    /// Sends what's waiting: one widget's batch, or every batch a chat holds (it closed).
    func flush(_ id: String) {
        flushes[id]?.cancel()
        flushes[id] = nil
        guard let conversation = batchOwners[id]?.conversation, let payload = payload(id) else { return }
        // Offline, batches wait for the gateway (`docs/widgets.md` §5).
        guard conversation.canSendWidgetAnswer else { return }
        switch payload.content {
        case .checklist(let list):
            guard var batch = ticks[id], let answer = batch.takeAnswer(payload, list) else { return }
            ticks[id] = batch
            conversation.sendWidgetAnswer(answer)
        case .flashcard:
            guard let list = ratings[id], !list.isEmpty else { return }
            ratings[id] = []
            conversation.sendWidgetAnswer(.flashcards(payload, ratings: list))
        default:
            break
        }
    }

    func flushAll(for conversation: ConversationModel) {
        for (id, owner) in batchOwners where owner.conversation === conversation { flush(id) }
    }

    /// The gateway is back: batches that waited go now.
    func flushWaiting() {
        for id in batchOwners.keys { flush(id) }
    }

    // MARK: - View state

    func view(_ id: String) -> WidgetViewState {
        views[id] ?? WidgetViewState()
    }

    func updateView(_ id: String, _ change: (inout WidgetViewState) -> Void) {
        var state = views[id] ?? WidgetViewState()
        change(&state)
        guard state != views[id] else { return }
        views[id] = state
        WidgetCache.saveViews(views, gateway: gatewayID)
    }

    /// A chat's cache was dropped: its widgets' view state goes with it.
    func forgetViews(_ ids: some Sequence<String>) {
        var changed = false
        for id in ids where views.removeValue(forKey: id) != nil { changed = true }
        if changed { WidgetCache.saveViews(views, gateway: gatewayID) }
    }

    func hide(_ id: String) {
        hidden.insert(id)
    }

    func tearDown() {
        bulkMarking?.cancel()
        bulkMarking = nil
        flushes.values.forEach { $0.cancel() }
        flushes.removeAll()
    }
}

/// What a widget shows on this device only, never sent (contract §6.1: local interactions).
struct WidgetViewState: Codable, Hashable, Sendable {
    var showsAll = false
    /// Open sections, nodes or groups.
    var expanded: Set<String> = []
    var sortKey: String?
    var sortAscending = true
    var filter: String?
    /// A log's hidden levels.
    var hiddenLevels: Set<String> = []
    /// A guide's step on screen.
    var step: String?
    /// When each guide timer ends, by step id.
    var timers: [String: Date] = [:]
    /// The person's own weights in `compare`.
    var weights: [String: Int]?
    /// The flashcard on screen, and whether it's turned over.
    var card = 0
    var revealed = false
    /// A question folded as Not Answered, opened again.
    var unfolded = false
    /// A multi-select's ticks and its Other text, before Send.
    var selected: Set<String> = []
    var other = ""
    /// A form's typed values before Send (kept across scrolling and relaunch, never sent until then).
    var draft: [String: JSONValue] = [:]
}

/// A chat a batch belongs to, without keeping it alive.
private struct WeakConversation {
    weak var conversation: ConversationModel?

    init(_ conversation: ConversationModel) {
        self.conversation = conversation
    }
}
