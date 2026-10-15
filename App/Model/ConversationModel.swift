import Foundation
import HermesKit
import Observation
import SwiftUI

/// One conversation: its transcript, the turn in flight and the composer draft.
@MainActor
@Observable
final class ConversationModel: Identifiable {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(HermesError)
    }

    let id = UUID()
    /// Identity that survives compression rotations (lineage root, or the first session id).
    private(set) var stableKey: String?
    /// The live session id used for API calls; compression can change it.
    private(set) var sessionID: String?

    private(set) var items: [TranscriptItem] = [] { didSet { syncDerivedState() } }
    private(set) var loadState: LoadState = .idle
    /// The user message of the turn in flight, shown until the server transcript has it.
    private(set) var pendingUser: UserEntry? { didSet { syncDerivedState() } }
    /// The turn in flight. Changes with every streamed token: only the transcript reads it
    /// directly; everything else reads the mirrors below.
    private(set) var live: LiveTurn? { didSet { syncDerivedState() } }
    /// Why the last turn didn't finish, shown under the transcript.
    private(set) var turnError: TurnFailure?
    private(set) var isStopping = false
    /// The turn has ended and its transcript is being fetched; sending waits for it.
    private(set) var isFinishing = false
    /// "Reconnecting…" while a detached run's event stream is down.
    private(set) var connectionNote: String? { didSet { syncDerivedState() } }
    /// Increments whenever a turn completes, for haptics and scroll anchoring.
    private(set) var completedTurns = 0
    private(set) var sentTurns = 0

    var draft = "" {
        didSet {
            let has = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if has != hasDraftText { hasDraftText = has }
            // A pill whose text was edited away goes with it.
            if !draftReferences.isEmpty {
                let valid = MessageParts.valid(draftReferences, in: draft)
                if valid != draftReferences { draftReferences = valid }
            }
        }
    }
    /// Bots and gateway files picked into the draft, where their plain form sits in it
    /// (`composerReferences`). The composer draws each as one atomic pill.
    var draftReferences: [MessageReference] = []
    /// A command waiting for its argument (`composerCommand`): the pill starts the field and
    /// the draft is the argument.
    var draftCommand: String?
    /// Changes only when the draft goes from empty to not, so views can react cheaply.
    private(set) var hasDraftText = false
    var attachments: [ImageAttachment] = []
    /// Documents going with the next message.
    var files: [FileAttachment] = []
    /// Skills chosen from the "/" menu for the next message, up to five (`composerSkills`).
    var skills: [String] = []
    /// The standing goal set with `/goal`, pinned above the composer until cleared.
    var goal: String? {
        didSet {
            guard goal != oldValue, let key = stableKey else { return }
            UserDefaults.standard.set(goal, forKey: "goal.\(key)")
        }
    }
    /// Command cards and notes made here: the server doesn't keep them, so they're put back
    /// after the item they followed whenever the transcript reloads.
    @ObservationIgnored private var localItems: [(anchor: LocalAnchor, item: TranscriptItem)] = []
    /// Receipts from the running turn: shown between its message and its reply.
    private var turnReceipts: [TranscriptItem] = []
    /// The stored rows behind `items` (the newest pages; see `hasEarlierMessages`).
    @ObservationIgnored private var rawMessages: [SessionMessage] = []
    /// Older messages exist on the gateway beyond `rawMessages`; scrolling up fetches them
    /// (`loadEarlier`). Chats open on their newest page only.
    private(set) var hasEarlierMessages = false
    private(set) var isLoadingEarlier = false
    /// When the transcript last arrived from the gateway: a reconnect right after needn't fetch it again.
    @ObservationIgnored private var lastFetchedAt: Date?
    /// The transcript load under way, if any.
    @ObservationIgnored private var fetchToken: UUID?
    private var isFetching: Bool { fetchToken != nil }
    /// Sent once the transcript has loaded (a branch made by Edit and Resend).
    @ObservationIgnored private var sendOnLoad: String?
    /// Editing an earlier message (`composerEditing`): sending branches from just before it.
    var editing: UserEntry?
    /// Emoji Hermes put on messages (`message.reaction`), by row id.
    private(set) var reactions: [String: [String]] = [:]
    /// Background processes the agent started (`agent.terminal.output`), newest last.
    private(set) var processes: [BackgroundProcess] = []
    /// Background prompts (`/bg`) by task id, for their result cards.
    @ObservationIgnored private var backgroundPrompts: [String: String] = [:]
    /// Finished background prompts by notice id: what was asked and the full answer.
    private(set) var backgroundResults: [String: (prompt: String, answer: String)] = [:]

    struct BackgroundProcess: Identifiable, Equatable {
        let id: String
        var command: String
        var output: String
        var isRunning: Bool
        var startedAt: Date
    }

    private enum LocalAnchor {
        /// After this item (or at the end).
        case after(String?)
        /// After the n-th message from the person: a receipt from that turn.
        case afterUser(Int)
    }
    /// What the running turn sends besides its text: skills, or the model-facing message a
    /// command produced.
    @ObservationIgnored private var turnSkills: [String] = []
    @ObservationIgnored private var turnPrompt: String?
    /// What the turn's message was made of, kept with it once the gateway has it.
    @ObservationIgnored private var turnParts: MessageParts?
    /// `nil` means the gateway's configured default model.
    var model: ModelSelection?
    var reasoningEffort: ReasoningEffort?
    /// Where this chat starts (Run In, `docs/projects.md` §3); `nil` follows the active project.
    var placement: ChatPlacement?
    /// Where the gateway says the chat runs (`session.info`): folder, branch and project.
    private(set) var liveWorkspace: LiveWorkspace?
    /// A transient error shown above the composer.
    var banner: HermesError?

    // MARK: Sending while Hermes works (docs/follow-ups.md)

    /// This message's mode, picked on the chip; `nil` uses the default from Settings. It applies
    /// to one message: sending resets it.
    var followUpPick: FollowUpMode?

    /// Messages waiting for the turn to end (Send Next), oldest first. Kept on the device per chat.
    private(set) var queue: [QueuedFollowUp] = [] {
        didSet {
            guard queue != oldValue, let queueKey else { return }
            FollowUpQueueStore.save(queue, key: queueKey)
        }
    }

    /// Messages the gateway holds itself (with images or files, or a fall-back while it compacts):
    /// shown in the tray, read-only, until it sends them.
    private(set) var gatewayQueued: [String] = []

    /// Mid-turn messages and what became of them: steers (waiting, read, carried over, missed),
    /// redirects and background runs.
    private(set) var followUps: [FollowUpRecord] = []

    /// The work of the running turn before a redirect, the mark where it changed course, and the
    /// redirect itself; the stored transcript replaces them when the turn ends.
    private(set) var redirectedParts: [TranscriptItem] = []

    /// The queued message being edited in the field: where it goes back, and how it was.
    private(set) var editingQueued: EditingQueued?

    struct EditingQueued: Equatable {
        let original: QueuedFollowUp
        let index: Int
    }

    /// What the gateway holds for the next turn, read-only in the tray ("on Studio Mac").
    var gatewayName: String {
        workspace?.bot.name ?? "Hermes"
    }

    /// How stored messages were sent (the queue, a redirect, a steer sent after the reply), by row.
    @ObservationIgnored private var userCaptions: [String: FollowUpCaption] = [:]
    /// Captions for messages not stored yet, by their text (matched when the transcript reloads).
    @ObservationIgnored private var captionsByText: [String: FollowUpCaption] = [:]
    /// Stop was pressed: the queue waits for a Send instead of draining.
    private(set) var queuePaused = false
    /// Steers waiting when a step finished. Hermes has no event for a steer being read: it goes
    /// in with the result of the step that was running, so the next step after it means they were.
    @ObservationIgnored private var armedSteers: [String] = []
    /// What the gateway is about to send as a turn of its own (a steer it carried over, a message
    /// it queued), so that turn shows the message as it starts.
    @ObservationIgnored private var expectedFromGateway: [(text: String, caption: FollowUpCaption)] = []
    @ObservationIgnored private var carryOverTimeout: Task<Void, Never>?
    /// The draft set aside while a queued message is edited in the field.
    @ObservationIgnored private var stashedDraft: (text: String, references: [MessageReference])?

    /// Side answers (Ask Aside), shown apart from the turn and not part of the history.
    private(set) var asides: [Aside] = []

    // Requests (docs/quick-actions.md)

    /// What Hermes is waiting on besides approvals, oldest first; one card shows at a time.
    private(set) var requests: [HermesRequest] = [] {
        didSet {
            #if HERMES_PUSH
            PushCenter.shared.conversation(self, requests: requests, old: oldValue)
            #endif
        }
    }
    /// Approvals behind the one on the card (several commands at once).
    private(set) var waitingApprovals: [ApprovalRequest] = []
    /// Live states from `connection.update`, by op id then target name.
    private(set) var connectionStates: [String: [String: String]] = [:]
    /// "Allow everything in this chat" (the gateway's session `yolo`).
    private(set) var allowsEverything = false
    /// What was allowed in this chat from approval cards, for the permissions sheet.
    private(set) var sessionGrants: [String] = []

    struct Aside: Identifiable, Equatable {
        let id: String
        var question: String
        var answer: String?
    }

    /// The modes this chat's transport can do: all five over the gateway protocol; the API server
    /// can steer a run and the app can hold a message.
    var availableFollowUpModes: [FollowUpMode] {
        usesGateway ? FollowUpMode.allCases : [.steer, .sendNext]
    }

    /// What Send does with the text while a turn runs.
    var followUpMode: FollowUpMode {
        // A queued message being edited goes back in the queue unless another mode is picked.
        if editingQueued != nil { return isWorking ? followUpPick ?? .sendNext : .sendNext }
        let mode = followUpPick ?? FollowUpMode.preferredDefault
        return availableFollowUpModes.contains(mode) ? mode : .steer
    }

    /// Something typed while a turn runs can go out now.
    var canSendFollowUp: Bool {
        isWorking && (hasDraftText || !attachments.isEmpty || !files.isEmpty) && !isStopping && draftCommand == nil
            && helperSteerTarget == nil
    }

    /// With the field empty and nothing running, Send sends the first queued message.
    var canSendQueued: Bool {
        !queue.isEmpty && !isWorking && !isFinishing && !isBotTurnOpen && !hasDraftText && attachments.isEmpty && files.isEmpty
            && editingQueued == nil && isReachable
    }

    /// The caption of a stored message that was sent mid-turn (queue, redirect, carried-over steer).
    func caption(for entry: UserEntry) -> FollowUpCaption? {
        userCaptions[entry.id] ?? userCaptions[displayID(for: .user(entry))]
    }

    /// Where this chat's queue is kept.
    private var queueKey: String? {
        if let botName, let roster { return "bot-\(roster.botID.uuidString)-\(botName)" }
        return stableKey
    }

    /// The gateway or API server is there to send to.
    private var isReachable: Bool {
        isBotChat ? roster?.isConnected == true : (usesGateway ? gatewayRoster?.isConnected == true : workspace?.client != nil)
    }

    /// What Send would send: the command and its argument, or skills and the text with its pills.
    var draftParts: MessageParts {
        if let draftCommand {
            return MessageParts(command: MessageParts.Command(name: draftCommand, argument: draft))
        }
        return MessageParts(body: draft, references: draftReferences, skills: skills).trimmed()
    }

    /// Command mode waits for the argument before Send turns on (`composerCommand`).
    var canSendCommand: Bool {
        guard draftCommand != nil else { return false }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isBotChat { return roster?.isConnected == true }
        return usesGateway || workspace?.client != nil
    }

    @ObservationIgnored private(set) weak var workspace: BotWorkspace?
    /// Bot Mode: the Bot whose forever "Bot Chat" this is. `nil` for gateway sessions.
    let botName: String?
    @ObservationIgnored private(set) weak var roster: BotRoster?
    /// The Bot Chat's id on the backend socket; a new one comes with every resume.
    @ObservationIgnored private(set) var runtimeSessionID: String?
    @ObservationIgnored private var botTurnDone: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var settleFallback: Task<Void, Never>?
    /// Settling only counts once our prompt is on its way (creating a chat settles too).
    @ObservationIgnored private var promptSent = false
    /// A turn the backend started on its own (a routine, another device, a Bot's message).
    @ObservationIgnored private var isRemoteTurn = false
    @ObservationIgnored private var seenActivity: Date?
    /// The Bot Chat's message count and preview as the roster last showed them; `nil` after our own turn.
    @ObservationIgnored private var seenChat: BotChatMark?
    /// A Bot Chat turn is open on the backend until it settles; nothing new can start.
    private(set) var isBotTurnOpen = false
    /// Events that arrive while catching up after a reconnect wait here.
    @ObservationIgnored private var catchUpBuffer: [GatewayEvent]?
    /// The re-attach after a reconnect, and the runtime id it can replay missed events from.
    @ObservationIgnored private var reattachTask: Task<Void, Never>?
    @ObservationIgnored private var replayRuntime: String?
    /// The newest event applied for the current runtime id (event seqs only grow).
    @ObservationIgnored private var lastAppliedSeq: Int?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var lastUserText = ""
    @ObservationIgnored private var lastUserImages: [ImageAttachment] = []
    @ObservationIgnored private var lastUserFiles: [FileAttachment] = []
    /// The last turn ended without reaching the server; reload when we can.
    @ObservationIgnored private var needsReconcile = false
    /// False when the turn's fate on the gateway is unknown, so a retry could run it twice.
    @ObservationIgnored private var failureIsRetryable = true
    @ObservationIgnored private var userImages: [String: [ImageAttachment]] = [:]
    @ObservationIgnored private let backgroundActivity = BackgroundActivity()
    @ObservationIgnored private var subscription: Task<Void, any Error>?
    @ObservationIgnored private var backoff: Task<Void, any Error>?
    @ObservationIgnored private var skipBackoff = false
    /// The turn in flight runs over the gateway socket (decided when it starts).
    @ObservationIgnored private var turnUsesGateway = false
    /// The turn in flight was a queued message: it goes as `prompt.submit {queued: true}`.
    @ObservationIgnored private var turnQueued = false

    init(workspace: BotWorkspace, session: HermesSession? = nil) {
        self.workspace = workspace
        self.botName = nil
        self.sessionID = session?.id
        self.stableKey = session?.stableID
        self.model = workspace.preferredModel
        self.reasoningEffort = workspace.preferredEffort
        if let key = session?.stableID {
            goal = UserDefaults.standard.string(forKey: "goal.\(key)")
            queue = FollowUpQueueStore.load(key: key)
        }
    }

    /// A Bot's Bot Chat, served by the Hermes backend.
    init(roster: BotRoster, botName: String, workspace: BotWorkspace?) {
        self.workspace = workspace
        self.roster = roster
        self.botName = botName
        self.stableKey = "bot:\(botName)"
        self.goal = UserDefaults.standard.string(forKey: "goal.bot:\(botName)")
        self.queue = FollowUpQueueStore.load(key: "bot-\(roster.botID.uuidString)-\(botName)")
    }

    var isBotChat: Bool { botName != nil }

    // MARK: - Transport

    /// The socket that carries this chat over the gateway protocol: the Bot's roster, or for a
    /// normal chat the gateway's Bot Mode backend (`nil` without one).
    private var gatewayRoster: BotRoster? { roster ?? workspace?.roster }
    /// The socket helper calls go over (`HelperStore`).
    var gatewayRosterForHelpers: BotRoster? { gatewayRoster }

    // MARK: Helpers (docs/helpers.md)

    @ObservationIgnored private var helperStore: HelperStore?
    /// This chat's helpers: live teams, saved runs, notes sent to them.
    var helpers: HelperStore {
        if let helperStore { return helperStore }
        let store = HelperStore(conversation: self)
        helperStore = store
        return store
    }

    /// The composer is writing to one helper (Steer): Send goes to it with `subagent.steer`.
    var helperSteerTarget: HelperSteerTarget?

    /// A note for the helper being steered is ready to go.
    var canSteerHelper: Bool { helperSteerTarget != nil && hasDraftText }

    /// A message from elsewhere in the app (Ask Hermes to Retry, a helper's missed note): a steer
    /// into the running turn, held for after it, or a new message.
    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isWorking, !isStopping, turnUsesGateway {
            steer(trimmed)
        } else if isWorking || isFinishing || isBotTurnOpen {
            queue.insert(QueuedFollowUp(text: trimmed), at: 0)
        } else {
            start(text: trimmed, images: [], files: [])
        }
    }

    /// The profile gateway calls are scoped to: the Bot, or the gateway's own profile.
    private var gatewayProfile: String? { botName ?? workspace?.bot.profileName }

    /// New turns run over the backend's gateway protocol whenever it's connected: commands,
    /// questions, follow-ups, plans and the rest only exist there. Otherwise the API server.
    var usesGateway: Bool { isBotChat || gatewayRoster?.isConnected == true }

    /// The model and effort last applied to the gateway session, so they're set only on change.
    @ObservationIgnored private var appliedRunSettings: RunSettings?

    private struct RunSettings: Equatable {
        var model: ModelSelection?
        var effort: ReasoningEffort?
    }

    /// Forks this chat into a new session (gateway chats only).
    func branch() {
        guard !isBotChat, let workspace, let key = stableKey, let session = workspace.session(forKey: key) else { return }
        Task {
            do {
                try await workspace.fork(session)
            } catch {
                banner = error as? HermesError
            }
        }
    }

    // MARK: - Derived state

    /// Stored rows that took over from what was on screen while their turn ran (the message you
    /// sent, the live reply), mapped to the identity they keep. The swap then redraws those rows
    /// in place; as new rows they were laid out from scratch, which on long chats with heavy
    /// replies showed blank frames before the content came back.
    @ObservationIgnored private var rowAliases: [String: String] = [:]

    /// Changes to the transcript's rows (a message sent, a reply settling into the stored one, a
    /// steer read, a redirect) go out as one animated transaction, so the scroll view keeps its
    /// bottom anchored along with the rows instead of jumping ahead of them.
    private func animateRows(_ change: () -> Void) {
        withAnimation(.smooth(duration: 0.36), change)
    }

    /// The identity a row is drawn under (see `rowAliases`).
    func displayID(for item: TranscriptItem) -> String {
        rowAliases[item.id] ?? item.id
    }

    /// Nothing to show and nothing on its way: a new chat, or a Bot with no Bot Chat yet. A stored
    /// chat whose transcript is still loading isn't empty, so it doesn't get the empty layout
    /// (the centred composer) only to drop it when the messages arrive.
    var isKnownEmpty: Bool {
        guard isEmpty, sessionID == nil else { return false }
        switch loadState {
        case .loaded, .failed:
            return true
        case .idle, .loading:
            guard let botName else { return true } // a new chat has nothing to load
            return roster?.hasLoaded == true && roster?.bot(named: botName)?.canonicalSession == nil
        }
    }

    /// Everything to render, in order.
    var rows: [TranscriptItem] {
        var rows = items
        if let pendingUser { rows.append(.user(pendingUser)) }
        rows += turnReceipts
        rows += redirectedParts
        if let live { rows.append(.assistant(live.snapshot)) }
        return rows
    }

    /// The chat had messages when it was opened (not started here): its first message gets a
    /// date line from the start, rather than one appearing above it later.
    private(set) var openedWithHistory = false

    // Mirrors of `live` that change only when their value does, so the sidebar, composer and
    // chat chrome don't re-render for every streamed token.
    private(set) var isEmpty = true
    private(set) var isWorking = false
    private(set) var pendingApproval: ApprovalRequest?
    private(set) var liveStatus: String?

    private func syncDerivedState() {
        let empty = items.isEmpty && pendingUser == nil && live == nil
        if empty != isEmpty { isEmpty = empty }
        let working = live.map { !$0.isFinished } ?? false
        if working != isWorking {
            isWorking = working
            #if HERMES_PUSH
            PushCenter.shared.conversation(self, working: working)
            #endif
        }
        let approval = live?.approval
        if approval != pendingApproval {
            #if HERMES_PUSH
            PushCenter.shared.conversation(self, approval: approval, replacing: pendingApproval)
            #endif
            pendingApproval = approval
        }
        let status = connectionNote ?? live?.status
        if status != liveStatus { liveStatus = status }
    }

    var canSend: Bool {
        if draftCommand != nil { return canSendCommand }
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !files.isEmpty || !skills.isEmpty
        guard hasContent, !isWorking, !isFinishing, !isBotTurnOpen else { return false }
        if isBotChat { return roster?.isConnected == true }
        return usesGateway || workspace?.client != nil
    }

    var supportsImages: Bool {
        usesGateway || (workspace?.capabilities?.features.sessionChatStreaming ?? false)
    }

    func images(for entry: UserEntry) -> [ImageAttachment] {
        userImages[entry.id] ?? []
    }

    // MARK: - Loading

    /// Starts loading if it hasn't, and returns once the rows this device kept are showing (or
    /// it has none), or after `limit`. Never waits on the gateway. The drawer waits on this
    /// before it slides, so a chat slides in with its rows instead of getting them mid-slide.
    func firstRows(within limit: Duration) async {
        loadIfNeeded()
        let deadline = ContinuousClock.now + limit
        while loadState == .loading, items.isEmpty, !cacheChecked, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// The device's copy has been looked at (`showCached`), shown or not there.
    @ObservationIgnored private var cacheChecked = false

    func loadIfNeeded() {
        LoadTrace.mark(stableKey, "loadIfNeeded state=\(loadState) client=\(workspace?.client != nil)")
        guard loadState == .idle, sessionID != nil || isBotChat else { return }
        reload()
    }

    func reload() {
        if isBotChat {
            reloadBotChat()
            return
        }
        LoadTrace.begin(stableKey ?? "?", "reload (client: \(workspace?.client != nil))")
        guard let sessionID, let client = workspace?.client else { return }
        loadTask?.cancel()
        let opening = items.isEmpty
        if opening { loadState = .loading }
        let token = UUID()
        fetchToken = token
        loadTask = Task {
            defer { if fetchToken == token { fetchToken = nil } }
            // What this device saw last shows at once; the gateway's copy follows.
            if opening { await showCached() }
            do {
                let transcript = try await fetchLatest(sessionID)
                LoadTrace.mark(stableKey, "fetched \(transcript.messages.count) rows")
                guard !Task.isCancelled, !isWorking, !isFinishing else { return }
                await applyLoaded(transcript)
                LoadTrace.mark(stableKey, "applied \(items.count) items")
                loadState = .loaded
                needsReconcile = false
                if let text = sendOnLoad {
                    sendOnLoad = nil
                    draft = text
                    send()
                }
                // The transcript now says how an uncertain turn really ended.
                if turnError?.canRetry == false { turnError = nil }
                // Over the gateway protocol, hear about turns started elsewhere and requests
                // still waiting for an answer.
                if usesGateway, runtimeSessionID == nil {
                    _ = await attachGatewayChat()
                    LoadTrace.mark(stableKey, "attached")
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if items.isEmpty {
                    loadState = .failed(error as? HermesError ?? .invalidResponse(error.localizedDescription))
                } else {
                    banner = error as? HermesError
                }
            }
        }
    }

    /// Adopts the session's latest live id (after a compression rotation elsewhere).
    func adoptSessionID(_ id: String) {
        guard !isWorking, !isFinishing, id != sessionID else { return }
        sessionID = id
    }

    /// The newest page from the gateway, put after the earlier rows already held (when they
    /// meet; otherwise the page alone, with earlier rows still to fetch). A page that changes
    /// nothing leaves the transcript as it is: no rebuild, no redraw.
    private func apply(_ transcript: SessionTranscript) {
        guard let merged = merge(transcript) else { return }
        rebuild(from: merged)
        saveCache()
    }

    /// The page put together with the rows held (see `apply`); `nil` when nothing changed.
    private func merge(_ transcript: SessionTranscript) -> [SessionMessage]? {
        lastFetchedAt = .now
        if transcript.sessionID != sessionID {
            sessionID = transcript.sessionID
        }
        var merged = transcript.messages
        var earlier = transcript.hasEarlier
        if transcript.hasEarlier, let first = transcript.messages.first?.id, let newest = rawMessages.last?.id, first <= newest {
            merged = transcript.appending(toEarlier: rawMessages)
            earlier = hasEarlierMessages
        }
        if earlier != hasEarlierMessages { hasEarlierMessages = earlier }
        if merged == rawMessages, !items.isEmpty, turnReceipts.isEmpty { return nil }
        return merged
    }

    /// `apply` for a transcript being opened: the rows are folded into turns and the newest
    /// replies' Markdown parsed off the main thread, so the main thread (and the drawer or window
    /// animating meanwhile) only takes the result.
    private func applyLoaded(_ transcript: SessionTranscript) async {
        guard let merged = merge(transcript) else { return }
        let built = await Self.prepare(merged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil)
        // A chat picked in the drawer lands once the drawer has slid away, not in the middle.
        await Settling.untilSettled()
        guard !Task.isCancelled, !isWorking, !isFinishing else { return }
        rebuild(from: merged, built: built)
        saveCache()
    }

    /// Off the main thread: the turns, and answers parsed into the Markdown cache: the newest
    /// (`warming` 0), or the ones that many rows before the end (a page going in above).
    private static func prepare(_ messages: [SessionMessage], hasEarlier: Bool, hidesSilence: Bool, warming end: Int = 0) async -> [TranscriptItem] {
        let built = await Task.detached(priority: .userInitiated) {
            TranscriptBuilder.build(fromTurnStart(messages, hasEarlier: hasEarlier), hidesSilence: hidesSilence)
        }.value
        await MarkdownCache.prewarm(Self.answers(in: built.dropLast(min(end, built.count)).suffix(24)))
        return built
    }

    /// The replies' text in these rows, for `MarkdownCache.prewarm`.
    static func answers(in items: some Sequence<TranscriptItem>) -> [String] {
        items.compactMap { item -> String? in
            if case .assistant(let turn) = item, !turn.answer.isEmpty { return turn.answer }
            return nil
        }
    }

    /// Builds `items` from stored rows (or takes them `built` already).
    private func rebuild(from messages: [SessionMessage], built prebuilt: [TranscriptItem]? = nil) {
        rawMessages = messages
        var built = prebuilt ?? TranscriptBuilder.build(Self.fromTurnStart(messages, hasEarlier: hasEarlierMessages), hidesSilence: botName != nil)
        if sentTurns == 0, completedTurns == 0, !built.isEmpty { openedWithHistory = true }
        resolveImages(in: built)
        restoreParts(in: &built)
        if !turnReceipts.isEmpty, live?.isFinished ?? true {
            // The turn is over: its receipts stay after its message.
            let userCount = built.filter { if case .user = $0 { true } else { false } }.count
            localItems += turnReceipts.map { (.afterUser(userCount), $0) }
            turnReceipts = []
        }
        items = mergeLocalItems(into: built)
        matchCaptions()
    }

    /// A page that starts partway through a turn starts at its next message from the person
    /// instead (the rest of that turn comes with the earlier page).
    nonisolated private static func fromTurnStart(_ messages: [SessionMessage], hasEarlier: Bool) -> [SessionMessage] {
        guard hasEarlier, let start = messages.firstIndex(where: { $0.role == "user" && $0.displayKind != "hidden" }) else { return messages }
        return Array(messages[start...])
    }

    // MARK: Transcript cache and pages

    /// Where this chat's transcript is kept on the device: per gateway, per chat.
    private var cacheKey: String? {
        if let botName, let roster { return "bot-\(roster.botID.uuidString)-\(botName)" }
        guard let workspace, let stableKey else { return nil }
        return "\(workspace.bot.id.uuidString)-\(stableKey)"
    }

    private func saveCache() {
        guard let cacheKey, let sessionID else { return }
        TranscriptCache.save(cacheKey, sessionID: sessionID, messages: rawMessages, hasEarlier: hasEarlierMessages)
    }

    /// The transcript this device saw last, while the gateway's copy is on its way.
    private func showCached() async {
        defer { cacheChecked = true }
        guard let cacheKey, let cached = await TranscriptCache.load(cacheKey) else { return }
        let built = await Self.prepare(cached.messages, hasEarlier: cached.hasEarlier, hidesSilence: botName != nil)
        // Too late for the drawer's wait (`firstRows`): after its slide, not in the middle.
        await Settling.untilSettled()
        guard items.isEmpty, live == nil, !Task.isCancelled else { return }
        hasEarlierMessages = cached.hasEarlier
        rebuild(from: cached.messages, built: built)
        loadState = .loaded
        LoadTrace.mark(stableKey, "showed cache (\(cached.messages.count) rows)")
    }

    /// A page of the stored transcript, from wherever this chat is served.
    private func fetchPage(_ id: String, limit: Int, offset: Int) async throws -> SessionTranscript {
        if let botName, let roster {
            return try await roster.transcript(storedSessionID: id, profile: botName, limit: limit, offset: offset)
        }
        if let client = workspace?.client {
            return try await client.transcript(sessionID: id, limit: limit, offset: offset)
        }
        if let roster = gatewayRoster {
            return try await roster.transcript(storedSessionID: id, profile: gatewayProfile ?? "default", limit: limit, offset: offset)
        }
        throw GatewaySocket.Failure.notConnected
    }

    /// The newest page, reaching back to the rows already held so nothing between them goes
    /// missing (a long turn can add more rows than a page).
    private func fetchLatest(_ id: String) async throws -> SessionTranscript {
        var page = try await fetchPage(id, limit: SessionTranscript.firstPage, offset: 0)
        var rounds = 0
        while page.hasEarlier, let newest = rawMessages.last?.id, let first = page.messages.first?.id, first > newest, rounds < 10 {
            let more = try await fetchPage(id, limit: 200, offset: page.messages.count)
            page = SessionTranscript(
                sessionID: page.sessionID,
                messages: SessionTranscript.merge(earlier: more.messages, before: page.messages),
                hasEarlier: more.hasEarlier
            )
            rounds += 1
        }
        return page
    }

    /// The page before the earliest message held (scrolling up).
    func loadEarlier() async {
        guard hasEarlierMessages, !isLoadingEarlier, let sessionID else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        guard let page = try? await fetchPage(sessionID, limit: 200, offset: rawMessages.count),
              self.sessionID == sessionID, !isFinishing else { return }
        hasEarlierMessages = page.hasEarlier
        // Folded off the main thread, with the replies that go in just above what's on screen
        // parsed ahead (scrolling up shows them next).
        let base = rawMessages
        let merged = SessionTranscript.merge(earlier: page.messages, before: base)
        let built = await Self.prepare(merged, hasEarlier: page.hasEarlier, hidesSilence: botName != nil, warming: items.count)
        guard self.sessionID == sessionID else { return }
        if rawMessages == base {
            rebuild(from: merged, built: built)
        } else {
            // A turn ended meanwhile: fold the page in with what it brought.
            rebuild(from: SessionTranscript.merge(earlier: page.messages, before: rawMessages))
        }
        saveCache()
    }

    /// Everything from the start (branching counts the rows before its point).
    private func loadAllEarlier() async {
        var pages = 0
        while hasEarlierMessages, pages < 50 {
            let before = rawMessages.count
            await loadEarlier()
            pages += 1
            if rawMessages.count == before { break }
        }
    }

    /// Captions kept by text find their stored rows: the newest message with that text.
    private func matchCaptions() {
        guard !captionsByText.isEmpty else { return }
        for (text, caption) in captionsByText {
            let row = items.last { if case .user(let entry) = $0 { entry.text == text && entry.sender == nil } else { false } }
            if let row {
                userCaptions[row.id] = caption
                captionsByText[text] = nil
            }
        }
    }

    /// The stored rows that replace the ones shown while the turn ran (your message, the reply, and
    /// around a redirect the work before it and the redirect) keep their on-screen identities.
    /// Matched from the end; a reply never matches across the person's message, so an older reply
    /// never takes a live turn's place (a turn that stored nothing).
    private func handOverIdentity(shown: [TranscriptItem]) {
        func isPersonsMessage(_ item: TranscriptItem) -> Bool {
            if case .user(let entry) = item { entry.sender == nil && entry.routineName == nil && !entry.isSteer } else { false }
        }
        var index = items.count - 1
        for row in shown.reversed() {
            var match: Int?
            while index >= 0 {
                let stored = items[index]
                if case .assistant = row {
                    if case .assistant = stored { match = index; break }
                    if isPersonsMessage(stored) { return }
                } else if isPersonsMessage(stored) {
                    match = index
                    break
                }
                index -= 1
            }
            guard let match else { return }
            if items[match].id != row.id { rowAliases[items[match].id] = row.id }
            index = match - 1
        }
    }

    /// Puts command cards and notes back after the items they followed.
    private func mergeLocalItems(into built: [TranscriptItem]) -> [TranscriptItem] {
        guard !localItems.isEmpty else { return built }
        var merged = built
        let ids = Set(built.map(\.id))
        for (anchor, item) in localItems where !ids.contains(item.id) {
            var anchorIndex: Int?
            switch anchor {
            case .after(let id):
                anchorIndex = id.flatMap { id in merged.firstIndex { $0.id == id } }
            case .afterUser(let count):
                var seen = 0
                for (index, row) in merged.enumerated() {
                    guard case .user = row else { continue }
                    seen += 1
                    if seen == count {
                        anchorIndex = index
                        break
                    }
                }
            }
            if let index = anchorIndex {
                var insertAt = index + 1
                // Keep several local items after the same anchor in the order they were made.
                while insertAt < merged.count, localItems.contains(where: { $0.item.id == merged[insertAt].id }) { insertAt += 1 }
                merged.insert(item, at: insertAt)
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    private func appendLocal(_ item: TranscriptItem) {
        localItems.append((.after(items.last?.id), item))
        items.append(item)
    }

    private func updateCommand(_ id: String, _ change: (inout CommandEntry) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }), case .command(var entry) = items[index] {
            change(&entry)
            items[index] = .command(entry)
            if let local = localItems.firstIndex(where: { $0.item.id == id }) {
                localItems[local].item = .command(entry)
            }
        }
    }

    private func removeLocal(_ id: String) {
        items.removeAll { $0.id == id }
        localItems.removeAll { $0.item.id == id }
    }

    // MARK: Sent parts

    /// A skill's model-facing message replaces what the person typed in the stored history; this
    /// remembers what they typed (and the skills) so a reload shows it the same way.
    private struct SentParts: Codable {
        var text: String
        var skills: [String]
        var references: [MessageReference]?
        var command: MessageParts.Command?
    }

    private static func partsKey(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }

    /// Keeps what the message was made of (skills, Bots and files inline) under both what the
    /// gateway stores and what was typed, so a reload draws it the same way.
    private func rememberParts(prompt: String, text: String, skills: [String]) {
        guard let key = stableKey else { return }
        let defaultsKey = "parts.\(key)"
        var stored = (UserDefaults.standard.data(forKey: defaultsKey)).flatMap { try? JSONDecoder().decode([String: SentParts].self, from: $0) } ?? [:]
        let references = turnParts.map { MessageParts.valid($0.references, in: text) } ?? []
        let parts = SentParts(text: text, skills: skills, references: references)
        stored[Self.partsKey(prompt)] = parts
        if !text.isEmpty { stored[Self.partsKey(text)] = parts }
        if stored.count > 60 { stored = Dictionary(uniqueKeysWithValues: stored.suffix(60).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: defaultsKey)
    }

    private func restoreParts(in items: inout [TranscriptItem]) {
        guard let key = stableKey,
              let data = UserDefaults.standard.data(forKey: "parts.\(key)"),
              let stored = try? JSONDecoder().decode([String: SentParts].self, from: data), !stored.isEmpty else { return }
        for index in items.indices {
            guard case .user(var entry) = items[index], let parts = stored[Self.partsKey(entry.text)] else { continue }
            entry.text = parts.text
            entry.skillNames = parts.skills
            entry.parts = MessageParts(body: parts.text, references: parts.references ?? [], skills: parts.skills, command: parts.command)
            items[index] = .user(entry)
        }
    }

    /// Re-attaches locally kept images to user messages the server stored as `[screenshot]`.
    private func resolveImages(in items: [TranscriptItem]) {
        guard let store = workspace?.imageStore, let key = stableKey else { return }
        var occurrences: [String: Int] = [:]
        for item in items {
            guard case .user(let entry) = item, entry.imagePlaceholderCount > 0 else { continue }
            let occurrence = occurrences[entry.text, default: 0]
            occurrences[entry.text] = occurrence + 1
            if userImages[entry.id] == nil {
                let images = store.images(conversation: key, text: entry.text, occurrence: occurrence)
                if !images.isEmpty { userImages[entry.id] = images }
            }
        }
    }

    // MARK: - Sending

    func send() {
        if let target = helperSteerTarget {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            draft = ""
            helperSteerTarget = nil
            if let helper = helpers.helper(target.helperID) { helpers.steer(helper, text: text) }
            return
        }
        if let command = draftCommand {
            let argument = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canSendCommand else { return }
            draftCommand = nil
            runCommand(command, argument: argument)
            return
        }
        if let editing, !isWorking {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.editing = nil
            draft = ""
            branch(at: .before(editing.id), thenSend: text)
            return
        }
        if editingQueued != nil || canSendFollowUp {
            sendFollowUp()
            return
        }
        if canSendQueued, let first = queue.first {
            sendQueued(first)
            return
        }
        guard canSend else { return }
        var parts = draftParts
        // A typed "/skill …" is the same as one chosen from the menu.
        if let catalog = slashCatalog, catalog.isLoaded, usesGateway {
            let leading = SlashCommands.leadingSkills(in: parts.body, skills: catalog.skillNames)
            if !leading.skills.isEmpty {
                let removed = parts.body.utf16.count - leading.body.utf16.count
                parts.skills = Array((parts.skills + leading.skills).prefix(MessageParts.maxSkills))
                parts.references = MessageParts.valid(parts.references.map { var moved = $0; moved.location -= removed; return moved }, in: leading.body)
                parts.body = leading.body
            }
        }
        // A command runs; it isn't sent to the model as text.
        if parts.skills.isEmpty, parts.references.isEmpty, attachments.isEmpty, files.isEmpty, let command = SlashCommands.parse(parts.body) {
            runCommand(command.name, argument: command.argument)
            return
        }
        addTypedReferences(to: &parts)
        let images = attachments
        let documents = files
        draft = ""
        draftReferences = []
        attachments = []
        files = []
        skills = []
        start(text: parts.body, images: images, files: documents, skills: parts.skills, parts: parts)
    }

    /// `@handle`s and `@file:` paths typed by hand look the same once sent as picked ones.
    private func addTypedReferences(to parts: inout MessageParts) {
        let typed = referenceVocabulary.references(in: parts.body).filter { found in
            !parts.references.contains { NSIntersectionRange($0.range, found.range).length > 0 }
        }
        if !typed.isEmpty { parts.references = MessageParts.valid(parts.references + typed, in: parts.body) }
    }

    /// The names typed text can refer to in this chat.
    var referenceVocabulary: ReferenceVocabulary {
        var handles = Set<String>()
        if let roster = workspace?.roster {
            for bot in roster.visibleBots + roster.hiddenBots {
                for form in [bot.mentionTag, bot.handle, bot.name] where !form.isEmpty { handles.insert(form.lowercased()) }
            }
        }
        let catalog = slashCatalog
        return ReferenceVocabulary(
            handles: handles,
            commands: ReferenceVocabulary.knownCommands.union(catalog?.commands.map { $0.name.lowercased() } ?? []),
            skills: catalog?.skillNames ?? []
        )
    }

    // MARK: Commands (docs/commands-and-references.md)

    /// The "/" menu's entries for this chat's profile.
    var slashCatalog: SlashCatalog? {
        workspace?.slashCatalog(profile: gatewayProfile)
    }

    /// Loads skills and commands over the gateway protocol, when it's there.
    func loadSlashCatalog() {
        guard usesGateway, let roster = gatewayRoster, let catalog = slashCatalog else { return }
        catalog.load(roster: roster, profile: gatewayProfile)
    }

    /// Runs a slash command. The app handles its own (new chat, rename, model, reasoning, retry,
    /// stop, steer, queue…); the rest run on the gateway (`slash.exec`, then
    /// `command.dispatch`), and the chat shows a command card with what came of it.
    func runCommand(_ rawName: String, argument rawArgument: String?) {
        let name = SlashCommands.canonical(rawName)
        let argument = rawArgument?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasArgument = !(argument ?? "").isEmpty
        draftCommand = nil
        draft = ""
        switch name {
        case "new":
            if isBotChat {
                // Bot Chats don't reset: they compact.
                start(text: "/compact", images: [], files: [])
            } else {
                workspace?.startNewChat()
            }
            return
        case "compress" where isBotChat:
            start(text: "/compact", images: [], files: [])
            return
        case "retry":
            retryLastMessage()
            return
        case "stop":
            stop()
            return
        case "branch" where !isBotChat:
            branch()
            return
        case "steer" where hasArgument:
            if isWorking { steer(argument!) } else { start(text: argument!, images: [], files: []) }
            return
        case "queue" where hasArgument:
            if isWorking || isFinishing || isBotTurnOpen { queue.append(QueuedFollowUp(text: argument!)) } else { start(text: argument!, images: [], files: []) }
            return
        case "btw" where hasArgument && isWorking && usesGateway:
            askAside(argument!)
            return
        case "bg" where hasArgument && usesGateway:
            runInBackground(argument!)
            return
        case "model":
            guard hasArgument else { draft = "/model "; return }
            if let selection = modelSelection(for: argument!) {
                model = selection
                appendLocal(.command(CommandEntry(name: name, argument: argument, outcome: .note(String(localized: "Model changed to \(ModelNames.display(selection.model))")))))
            } else {
                appendLocal(.command(CommandEntry(name: name, argument: argument, outcome: .failed(String(localized: "No model called “\(argument!)” on this gateway.")))))
            }
            return
        case "reasoning":
            guard hasArgument else { draft = "/reasoning "; return }
            let wanted = argument!.lowercased()
            if let level = ReasoningEffort(rawValue: wanted) ?? ReasoningEffort.allCases.first(where: { ReasoningNames.title(for: $0).lowercased() == wanted }) ?? (wanted == "off" ? .off : nil) {
                reasoningEffort = level
                appendLocal(.command(CommandEntry(name: name, argument: argument, outcome: .note(String(localized: "Reasoning set to \(ReasoningNames.title(for: level))")))))
            } else if wanted == "auto" {
                reasoningEffort = nil
                appendLocal(.command(CommandEntry(name: name, argument: argument, outcome: .note(String(localized: "Reasoning set to Auto")))))
            }
            return
        case "title" where !isBotChat:
            guard hasArgument else { draft = "/title "; return }
            let entry = CommandEntry(name: name, argument: argument, outcome: .running(nil))
            appendLocal(.command(entry))
            Task {
                do {
                    guard let workspace, let key = stableKey, let session = workspace.session(forKey: key) else { throw HermesError.notFound(message: nil) }
                    try await workspace.rename(session, to: argument!)
                    updateCommand(entry.id) { $0.outcome = .note(String(localized: "Renamed to “\(argument!)”")) }
                } catch {
                    updateCommand(entry.id) { $0.outcome = .failed(String(localized: "Send a message first, then rename the chat.")) }
                }
            }
            return
        case "goal":
            if hasArgument, !["clear", "stop", "off", "done"].contains(argument!.lowercased()) {
                goal = argument
            } else if hasArgument {
                goal = nil
            }
        default:
            break
        }
        guard usesGateway, let roster = gatewayRoster else {
            appendLocal(.command(CommandEntry(name: name, argument: argument, outcome: .failed(
                String(localized: "/\(name) runs over Bot Mode. Link this gateway's Hermes backend to use commands.")
            ))))
            return
        }
        let entry = CommandEntry(name: name, argument: hasArgument ? argument : nil, outcome: .running(nil))
        appendLocal(.command(entry))
        Task { await executeOnGateway(entry, roster: roster) }
    }

    private func executeOnGateway(_ entry: CommandEntry, roster: BotRoster) async {
        let commandLine = entry.argument.map { "\(entry.name) \($0)" } ?? entry.name
        do {
            let runtime = try await ensureRuntime()
            do {
                let result = try await roster.request("slash.exec", ["session_id": .string(runtime), "command": .string(commandLine)], timeout: .seconds(120))
                finishCommand(entry, output: result["output"]?.stringValue, warning: result["warning"]?.stringValue)
                return
            } catch is GatewayRPCError {
                // Skills, bundles and turn-taking built-ins go through command.dispatch.
            }
            var params: [String: JSONValue] = ["name": .string(entry.name), "arg": .string(entry.argument ?? ""), "session_id": .string(runtime)]
            if let gatewayProfile { params["profile"] = .string(gatewayProfile) }
            let directive = try await roster.request("command.dispatch", params, timeout: .seconds(120))
            switch directive["type"]?.stringValue {
            case "alias":
                removeLocal(entry.id)
                if let target = directive["target"]?.stringValue, let parsed = SlashCommands.parse(target.hasPrefix("/") ? target : "/" + target) {
                    runCommand(parsed.name, argument: parsed.argument ?? entry.argument)
                }
            case "send", "skill":
                removeLocal(entry.id)
                let typed = "/" + commandLine
                let message = directive["message"]?.stringValue ?? typed
                if directive["type"]?.stringValue == "skill" {
                    // Up to five stacked skills: "/one /two the request".
                    let known = slashCatalog?.isLoaded == true ? slashCatalog!.skillNames : Set(Self.leadingTokens(entry.argument ?? "").filter { SlashCommands.known($0) == nil })
                    let stacked = SlashCommands.leadingSkills(in: entry.argument ?? "", skills: known)
                    start(text: stacked.body, images: [], files: [], skills: Array(([entry.name] + stacked.skills).prefix(5)), prompt: message)
                } else {
                    start(text: typed, images: [], files: [], prompt: message)
                }
            case "prefill":
                removeLocal(entry.id)
                draft = directive["message"]?.stringValue ?? ""
            default:
                finishCommand(entry, output: directive["output"]?.stringValue ?? directive["notice"]?.stringValue, warning: nil)
            }
        } catch {
            updateCommand(entry.id) { $0.outcome = .failed((error as? GatewayRPCError)?.message ?? HermesError.botMode(error).errorDescription ?? "") }
        }
    }

    /// The leading "/word" tokens of a text, without their slashes.
    private static func leadingTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for word in text.split(separator: " ") {
            guard word.hasPrefix("/"), word.count > 1 else { break }
            tokens.append(String(word.dropFirst()))
        }
        return tokens
    }

    private func finishCommand(_ entry: CommandEntry, output: String?, warning: String?) {
        let text = [output, warning].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        updateCommand(entry.id) { $0.outcome = text.isEmpty ? .note(String(localized: "Done")) : CommandEntry.outcome(fromOutput: text) }
    }

    /// "claude-opus-4.6", "anthropic/claude-opus-4.6 --provider openrouter" or a display name.
    private func modelSelection(for argument: String) -> ModelSelection? {
        let parts = argument.components(separatedBy: " --provider ")
        let wanted = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let provider = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        for option in workspace?.modelOptions?.usableProviders ?? [] where provider == nil || option.matches(provider: provider) {
            if let model = option.models.first(where: { $0.lowercased() == wanted || ModelSelection(provider: option.slug, model: $0).shortName.lowercased() == wanted || ModelNames.display($0).lowercased() == wanted }) {
                return ModelSelection(provider: option.slug, model: model)
            }
        }
        return nil
    }

    /// Files and folders on the gateway for an `@path` being typed (`complete.path`).
    func completePath(_ word: String) async -> [PathCompletion] {
        guard usesGateway, let roster = gatewayRoster else { return [] }
        var params: [String: JSONValue] = ["word": .string(word)]
        if let runtimeSessionID { params["session_id"] = .string(runtimeSessionID) }
        if let gatewayProfile { params["profile"] = .string(gatewayProfile) }
        guard let result = try? await roster.request("complete.path", params, timeout: .seconds(10)),
              case .array(let items)? = result["items"] else { return [] }
        return items.prefix(12).compactMap { item in
            guard let text = item["text"]?.stringValue else { return nil }
            return PathCompletion(text: text, display: item["display"]?.stringValue ?? text, meta: item["meta"]?.stringValue)
        }
    }

    /// The commands behind background processes (`process.list`).
    private func nameProcesses() async {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID,
              let result = try? await roster.request("process.list", ["session_id": .string(runtime)]),
              case .array(let rows)? = result["processes"] else { return }
        for row in rows {
            guard let id = row["id"]?.stringValue ?? row["process_id"]?.stringValue,
                  let index = processes.firstIndex(where: { $0.id == id }) else { continue }
            if let command = row["command"]?.stringValue ?? row["cmd"]?.stringValue { processes[index].command = command }
            if let started = row["started_at"]?.doubleValue { processes[index].startedAt = Date(timeIntervalSince1970: started) }
        }
    }

    /// Stops one background process (`process.kill`).
    func stopProcess(_ process: BackgroundProcess) {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID else { return }
        Task {
            _ = try? await roster.request("process.kill", ["session_id": .string(runtime), "process_id": .string(process.id)])
            if let index = processes.firstIndex(where: { $0.id == process.id }) { processes[index].isRunning = false }
        }
    }

    func dismissProcess(_ process: BackgroundProcess) {
        processes.removeAll { $0.id == process.id }
    }

    /// Clears the goal bar (and the gateway's goal, quietly).
    func clearGoal() {
        goal = nil
        guard usesGateway, let roster = gatewayRoster else { return }
        Task {
            guard let runtime = try? await ensureRuntime() else { return }
            _ = try? await roster.request("slash.exec", ["session_id": .string(runtime), "command": .string("goal clear")])
        }
    }

    // MARK: Branching and editing (docs/chat.md §4)

    enum BranchPoint {
        /// Everything before this message (Edit and Resend).
        case before(String)
        /// Up to the end of this message's exchange (Branch from Here).
        case through(String)
    }

    /// Edit and Resend works where the gateway can branch from a point.
    var canBranchFromPoint: Bool { usesGateway && !isBotChat && !rawMessages.isEmpty }

    func beginEditing(_ entry: UserEntry) {
        editing = entry
        draftCommand = nil
        draftReferences = MessageParts.valid(entry.parts?.references ?? referenceVocabulary.references(in: entry.text), in: entry.text)
        draft = entry.text
    }

    func cancelEditing() {
        editing = nil
        draft = ""
    }

    /// Send Again: the same message as a new turn.
    func sendAgain(_ entry: UserEntry) {
        guard !isWorking, !isFinishing, !isBotTurnOpen else {
            queue.append(QueuedFollowUp(text: entry.text, parts: entry.parts, skills: entry.skillNames, images: images(for: entry)))
            return
        }
        start(text: entry.text, images: images(for: entry), files: [], skills: entry.skillNames, parts: entry.parts)
    }

    func sendWhenLoaded(_ text: String) {
        sendOnLoad = text
    }

    /// A new chat with this one's history up to a point (`session.branch` with `count`).
    func branch(at point: BranchPoint, thenSend text: String? = nil) {
        guard canBranchFromPoint, let roster = gatewayRoster else {
            branch()
            return
        }
        Task {
            do {
                // The count is from the start of the chat.
                await loadAllEarlier()
                guard let count = visibleCount(at: point) else { return }
                let runtime = try await ensureRuntime()
                let result = try await roster.request("session.branch", [
                    "session_id": .string(runtime),
                    "count": .number(Double(count)),
                    "idempotency_key": .string(UUID().uuidString),
                    "omit_messages": .bool(true),
                ])
                guard let stored = result["stored_session_id"]?.stringValue else { throw HermesError.invalidResponse("session.branch") }
                let parent = stableKey.flatMap { workspace?.session(forKey: $0) }
                workspace?.openBranch(storedID: stored, title: result["title"]?.stringValue, from: parent, thenSend: text)
            } catch {
                banner = (error as? GatewayRPCError).map { HermesError.invalidResponse($0.message) } ?? HermesError.botMode(error)
                if let text { draft = text }
            }
        }
    }

    /// How many stored user / assistant rows with text the branch keeps (what `session.branch`
    /// counts).
    private func visibleCount(at point: BranchPoint) -> Int? {
        func rowID(_ index: Int) -> String { rawMessages[index].id.map { "m\($0)" } ?? "i\(index)" }
        func isVisible(_ message: SessionMessage) -> Bool {
            (message.role == "user" || message.role == "assistant") && !message.content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let target: String
        switch point {
        case .before(let id), .through(let id): target = id.hasPrefix("t") ? String(id.dropFirst()) : id
        }
        guard let start = rawMessages.indices.first(where: { rowID($0) == target }) else { return nil }
        var end = start
        if case .through = point {
            // The whole exchange: up to the next message from the person.
            end = start + 1
            while end < rawMessages.count, rawMessages[end].role != "user" || rawMessages[end].displayKind == "hidden" { end += 1 }
        }
        return rawMessages[..<end].filter(isVisible).count
    }

    /// Voice mode: a spoken message goes like a typed one, and steers a turn that's running.
    /// Returns `false` when it couldn't go (offline); the words are then kept as the draft.
    @discardableResult
    func sendSpoken(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        if isWorking {
            if !isStopping { steer(text) } else { queue.append(QueuedFollowUp(text: text)) }
            return true
        }
        if isFinishing || isBotTurnOpen {
            queue.append(QueuedFollowUp(text: text))
            return true
        }
        let reachable = isBotChat ? roster?.isConnected == true : usesGateway || workspace?.client != nil
        guard reachable else {
            draft = draft.isEmpty ? text : draft + " " + text
            return false
        }
        start(text: text, images: [], files: [])
        return true
    }

    /// The reply being written right now, if a turn is running or just finished.
    var liveTurn: AssistantTurn? { live?.snapshot }

    /// The newest reply in the chat.
    var latestAssistantTurn: AssistantTurn? {
        for item in rows.reversed() {
            if case .assistant(let turn) = item { return turn }
        }
        return nil
    }

    func dismissAside(_ aside: Aside) {
        asides.removeAll { $0.id == aside.id }
    }

    // MARK: Sending while Hermes works (docs/follow-ups.md)

    /// Sends what's in the field while a turn runs, the way `mode` says (the chip's pick, or the
    /// default). Editing a queued message, Send puts it back in its place.
    func sendFollowUp(_ mode: FollowUpMode? = nil) {
        guard editingQueued != nil || canSendFollowUp else { return }
        var parts = draftParts
        addTypedReferences(to: &parts)
        let images = attachments
        let documents = files
        guard !parts.body.isEmpty || !images.isEmpty || !documents.isEmpty else { return }
        var picked = mode.flatMap { availableFollowUpModes.contains($0) ? $0 : nil } ?? followUpMode
        if !isWorking { picked = .sendNext } // only a queued message being edited gets here idle
        draft = ""
        draftReferences = []
        attachments = []
        files = []
        skills = []
        followUpPick = nil
        let item = QueuedFollowUp(
            id: editingQueued?.original.id ?? UUID(), text: parts.body, parts: parts.hasStructure ? parts : nil,
            skills: parts.skills, images: images, files: documents
        )
        if let editing = editingQueued {
            editingQueued = nil
            restoreStashedDraft()
            if picked == .sendNext {
                queue.insert(item, at: min(editing.index, queue.count))
                drainQueueIfIdle()
                return
            }
            // Picked another mode while editing: it goes now, that way, instead.
        }
        switch picked {
        case .sendNext:
            queue.append(item)
        case .steer, .redirect:
            if item.hasAttachments || !item.skills.isEmpty {
                // Hermes can only steer with text: anything else waits for the next turn.
                holdForNextTurn(item)
            } else if picked == .steer {
                steer(item.text)
            } else {
                redirect(item.text)
            }
        case .askAside:
            askAside(item.text)
        case .background:
            runInBackground(item.text)
        }
    }

    /// Steer: Hermes reads the note after the step it's on and keeps going (`session.steer`).
    private func steer(_ text: String) {
        let record = addSteer(text)
        if turnUsesGateway, let roster = gatewayRoster, let runtime = runtimeSessionID {
            Task {
                let result = try? await roster.request("session.steer", ["session_id": .string(runtime), "text": .string(text)])
                switch FollowUpStatus(result: result) {
                case .queued?, .steered?:
                    break // accepted; the next step after this one reads it
                default:
                    missSteer(record) // too late, or it never got there: never lost quietly
                }
            }
        } else if let runID = live?.runID, let client = workspace?.client {
            Task {
                do {
                    try await client.steerRun(runID: runID, text: text)
                } catch {
                    missSteer(record)
                }
            }
        } else {
            missSteer(record)
        }
    }

    @discardableResult
    private func addSteer(_ text: String, wasRedirect: Bool = false) -> String {
        let record = FollowUpRecord(text: text, state: isWorking ? .steerWaiting : .steerMissed, turnID: live?.turn.id, wasRedirect: wasRedirect)
        animateRows { followUps.append(record) }
        return record.id
    }

    private func missSteer(_ id: String) {
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].isPending else { return }
        animateRows { followUps[index].state = .steerMissed }
        armedSteers.removeAll { $0 == id }
    }

    /// Fallback for a steer being read (Hermes has no event for it): a step finishing arms the
    /// steers waiting then, and whatever Hermes does next shows it has read them.
    private func trackSteers(_ event: TurnEvent) {
        guard let live else { return }
        switch event {
        case .toolFinished:
            for record in followUps where record.state == .steerWaiting && record.turnID == live.turn.id && !armedSteers.contains(record.id) {
                armedSteers.append(record.id)
            }
        case .toolStarted, .textDelta, .reasoning, .subagentStarted:
            readArmedSteers() // the final text isn't a step: a stop ends with it too
        case .commentary(_, let alreadyStreamed) where !alreadyStreamed:
            readArmedSteers()
        default:
            break
        }
    }

    /// The armed steers move into the turn, read after the steps so far (`steerStep`).
    private func readArmedSteers() {
        guard !armedSteers.isEmpty, live != nil else { return }
        let read = armedSteers.compactMap { id in followUps.first { $0.id == id && $0.state == .steerWaiting } }
        armedSteers = []
        guard !read.isEmpty else { return }
        let afterStep = live?.turn.steps.count ?? 0
        let ids = Set(read.map(\.id))
        animateRows {
            for record in read {
                live?.turn.steers.append(SteerNote(id: record.id, text: record.text, afterStep: afterStep, timestamp: .now))
            }
            followUps.removeAll { ids.contains($0.id) }
        }
    }

    /// Redirect: stops what Hermes is doing and changes course (`session.redirect`).
    private func redirect(_ text: String) {
        guard turnUsesGateway, let roster = gatewayRoster, let runtime = runtimeSessionID else {
            steer(text)
            return
        }
        Task {
            let result = try? await roster.request("session.redirect", ["session_id": .string(runtime), "text": .string(text)])
            switch FollowUpStatus(result: result) {
            case .redirected?, .steered?:
                if live?.turn.steps.contains(where: { if case .tool(let tool) = $0 { tool.status == .running } else { false } }) == true {
                    // Hermes never stops a tool for a redirect: it goes in with the tool's result.
                    addSteer(text, wasRedirect: true)
                } else {
                    changeCourse(text)
                }
            case .queued?:
                // The agent was still starting, or the chat is being compacted: next turn.
                animateRows { holdOnGateway(text) }
            case .rejected?, .streaming?:
                // The reply ended first: it goes as the next message.
                animateRows { queue.insert(QueuedFollowUp(text: text), at: 0) }
                drainQueueIfIdle()
            case nil:
                if draft.isEmpty { draft = text }
                banner = HermesError.invalidResponse(String(localized: "Couldn't redirect Hermes. Your message is back in the field."))
            }
        }
    }

    /// What Hermes was doing, for "Stopped while …".
    private var currentActivity: String? {
        guard let live else { return nil }
        if case .tool(let tool)? = live.turn.steps.last, tool.status == .running {
            return ToolDescriptor.describe(tool.name).activeTitle.lowercased()
        }
        return live.pendingText.isEmpty ? String(localized: "thinking") : String(localized: "writing")
    }

    /// A redirect landed: the work so far stays as it was, a mark says where it changed course,
    /// then the redirect and the work that follows it (Hermes keeps them as these rows too).
    private func changeCourse(_ text: String) {
        guard let current = live, !current.isFinished else {
            queue.insert(QueuedFollowUp(text: text), at: 0)
            drainQueueIfIdle()
            return
        }
        let caption = FollowUpCaption.redirect(stoppedWhile: currentActivity)
        var part = current.snapshot
        part.state = .complete
        part.finishedAt = .now
        let entry = UserEntry(id: "local-\(UUID().uuidString)", text: text, timestamp: .now)
        userCaptions[entry.id] = caption
        captionsByText[text] = caption
        var next = LiveTurn(id: "live-\(UUID().uuidString)", sessionID: current.sessionID)
        if let runID = current.runID { next.apply(SequencedTurnEvent(seq: nil, event: .runStarted(runID: runID))) }
        armedSteers = []
        animateRows {
            redirectedParts += [.assistant(part), .user(entry)]
            live = next
            for index in followUps.indices where followUps[index].turnID == current.turn.id {
                followUps[index].turnID = next.turn.id
            }
        }
    }

    /// Images, files and skills can't be steered: the gateway holds the message for the next turn
    /// (`prompt.submit {queued: true}`); over the API server it waits in the app's queue.
    private func holdForNextTurn(_ item: QueuedFollowUp) {
        guard turnUsesGateway, item.skills.isEmpty, let roster = gatewayRoster else {
            queue.append(item)
            return
        }
        holdOnGateway(item.line)
        Task {
            do {
                let runtime = try await ensureRuntime()
                for (index, image) in item.images.enumerated() {
                    _ = try await roster.request("image.attach_bytes", [
                        "session_id": .string(runtime),
                        "content_base64": .string(image.jpegData.base64EncodedString()),
                        "filename": .string("image-\(index + 1).jpg"),
                    ])
                }
                if !item.images.isEmpty, let key = stableKey {
                    workspace?.imageStore.remember(item.images, conversation: key, text: item.text)
                }
                var references: [String] = []
                for file in item.files {
                    references.append(try await attach(file, runtime: runtime, roster: roster))
                }
                let prompt = ([item.text] + references).filter { !$0.isEmpty }.joined(separator: "\n")
                let result = try await roster.request("prompt.submit", ["session_id": .string(runtime), "text": .string(prompt), "queued": .bool(true)])
                if FollowUpStatus(result: result) == .streaming {
                    // The reply had ended: it started a turn of its own.
                    animateRows { gatewayQueued.removeAll { $0 == item.line } }
                }
            } catch {
                // It stays on this device and goes when the reply is done.
                expectedFromGateway.removeAll { $0.text == item.line }
                animateRows {
                    gatewayQueued.removeAll { $0 == item.line }
                    queue.append(item)
                }
            }
        }
    }

    /// A message the gateway holds: shown in the tray until its turn starts.
    private func holdOnGateway(_ text: String) {
        gatewayQueued.append(text)
        captionsByText[text] = .fromQueue
        expectedFromGateway.append((text, .fromQueue))
    }

    /// Ask Aside: a side question answered while the turn keeps going (`prompt.btw`).
    private func askAside(_ text: String) {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID else {
            queue.append(QueuedFollowUp(text: text))
            return
        }
        Task {
            do {
                let result = try await roster.request("prompt.btw", ["session_id": .string(runtime), "text": .string(text)])
                let id = result["task_id"]?.stringValue ?? UUID().uuidString
                asides.append(Aside(id: id, question: text, answer: nil))
            } catch {
                banner = HermesError.botMode(error)
                if draft.isEmpty { draft = text }
            }
        }
    }

    /// Run in Background: another Hermes works on it (`prompt.background`); the answer lands here.
    private func runInBackground(_ prompt: String) {
        guard let roster = gatewayRoster else { return }
        var record = FollowUpRecord(text: prompt, state: .background(answer: nil), turnID: nil)
        followUps.append(record)
        Task {
            do {
                let runtime = try await ensureRuntime()
                let result = try await roster.request("prompt.background", ["session_id": .string(runtime), "text": .string(prompt)])
                record.taskID = result["task_id"]?.stringValue
                if let index = followUps.firstIndex(where: { $0.id == record.id }) { followUps[index].taskID = record.taskID }
                if let id = record.taskID { backgroundPrompts[id] = prompt }
            } catch {
                followUps.removeAll { $0.id == record.id }
                banner = HermesError.botMode(error)
                if draft.isEmpty { draft = prompt }
            }
        }
    }

    /// `background.complete`: the started line becomes the answer's card.
    private func finishBackground(taskID: String, answer: String) -> Bool {
        guard let index = followUps.firstIndex(where: { $0.taskID == taskID }) else { return false }
        followUps[index].state = .background(answer: answer)
        backgroundResults["background-\(taskID)"] = (followUps[index].text, answer)
        return true
    }

    /// Finished background runs settle into the transcript before the next turn, so they stay
    /// where they happened.
    private func settleBackgroundRuns() {
        for record in followUps {
            guard case .background(let answer?) = record.state, let taskID = record.taskID else { continue }
            appendLocal(.notice(Notice(id: "background-sent-\(taskID)", kind: "background-sent", text: record.text)))
            appendLocal(.notice(Notice(id: "background-\(taskID)", kind: "background", text: answer)))
        }
        followUps.removeAll { if case .background(_?) = $0.state { true } else { false } }
    }

    // Missed steers (`steerMissed`)

    /// Send as Message: a missed steer goes as a message of its own.
    func sendMissed(_ record: FollowUpRecord) {
        followUps.removeAll { $0.id == record.id }
        if isWorking || isFinishing || isBotTurnOpen {
            queue.insert(QueuedFollowUp(text: record.text), at: 0)
        } else {
            start(text: record.text, images: [], files: [])
        }
    }

    func discardMissed(_ record: FollowUpRecord) {
        followUps.removeAll { $0.id == record.id }
    }

    /// Unread steers when the turn ends. Hermes sends one it never read as the next turn by
    /// itself, right away, as it does what it holds in its queue; if that turn doesn't come, or
    /// the turn was stopped (Stop drops unread steers), the steer is missed.
    private func settleSteers(stopped: Bool, readLive: [SteerNote]) {
        armedSteers = []
        // The steers the stored reply has (the last few rows: a redirect splits it).
        let storedSteers = Set(items.suffix(8).flatMap { item -> [String] in
            if case .assistant(let turn) = item { turn.steers.map(\.text) } else { [] }
        })
        // Shown as read but not in what Hermes stored: it never got there. Never lose one quietly.
        for note in readLive where !storedSteers.contains(note.text) {
            followUps.append(FollowUpRecord(text: note.text, state: .steerWaiting, turnID: nil))
        }
        // Read after all, by the stored transcript: the reply shows it in place.
        followUps.removeAll { $0.isPending && storedSteers.contains($0.text) }
        for index in followUps.indices where followUps[index].isPending {
            if stopped || !turnUsesGateway {
                followUps[index].state = .steerMissed
            } else {
                followUps[index].state = .steerCarriedOver
                captionsByText[followUps[index].text] = .steerAfterReply
                expectedFromGateway.append((followUps[index].text, .steerAfterReply))
            }
        }
        guard !expectedFromGateway.isEmpty else { return }
        carryOverTimeout?.cancel()
        carryOverTimeout = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !isWorking else { return }
            // Nothing came: the steer is missed, and what the gateway held has gone some other way.
            animateRows {
                for index in followUps.indices where followUps[index].state == .steerCarriedOver {
                    followUps[index].state = .steerMissed
                }
            }
            expectedFromGateway = []
            animateRows { gatewayQueued = [] }
            drainQueueIfIdle()
        }
    }

    /// A turn the gateway started by itself: the carried-over steer or held message it sends.
    private func takeExpectedFromGateway() {
        guard !expectedFromGateway.isEmpty else { return }
        carryOverTimeout?.cancel()
        // Hermes runs its held messages as one turn.
        let texts = expectedFromGateway.map(\.text)
        let caption = expectedFromGateway[0].caption
        expectedFromGateway = []
        followUps.removeAll { $0.state == .steerCarriedOver }
        gatewayQueued = []
        let text = texts.joined(separator: "\n\n")
        let lastUser = items.last { if case .user = $0 { true } else { false } }
        if case .user(let entry)? = lastUser, texts.contains(entry.text) { return } // already stored (Hermes keeps it at once)
        let entry = UserEntry(id: "local-\(UUID().uuidString)", text: text, timestamp: .now)
        userCaptions[entry.id] = caption
        captionsByText[text] = caption
        pendingUser = entry
    }

    // The queue (Send Next)

    /// When a turn ends: the first queued message goes next, one per turn, unless Stop paused the
    /// queue, a queued message is being edited into the first place, or the gateway is away.
    private func drainQueueIfIdle() {
        guard !queuePaused, expectedFromGateway.isEmpty, let first = queue.first, !isWorking, !isFinishing, !isBotTurnOpen,
              isReachable, sendOnLoad == nil
        else { return }
        sendQueued(first)
    }

    /// Sends a queued message now, as the next turn (`prompt.submit {queued: true}`: the gateway
    /// never makes it a steer).
    func sendQueued(_ item: QueuedFollowUp) {
        guard !isWorking, !isFinishing, !isBotTurnOpen else { return }
        captionsByText[item.text] = .fromQueue
        // The tray gives up the message as it appears in the chat, in one movement.
        animateRows {
            queue.removeAll { $0.id == item.id }
            start(text: item.text, images: item.images, files: item.files, skills: item.skills, parts: item.parts, queued: true)
            if let pendingUser { userCaptions[pendingUser.id] = .fromQueue }
        }
    }

    func moveQueued(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    /// VoiceOver's "Move up" / "Move down".
    func moveQueued(_ item: QueuedFollowUp, by offset: Int) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard queue.indices.contains(target) else { return }
        queue.swapAt(index, target)
    }

    func moveQueuedToTop(_ item: QueuedFollowUp) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        queue.insert(queue.remove(at: index), at: 0)
    }

    func removeQueued(_ item: QueuedFollowUp) {
        queue.removeAll { $0.id == item.id }
    }

    func clearQueue() {
        queue = []
    }

    /// Steer Now: a queued message goes into the running turn as a steer.
    func steerNow(_ item: QueuedFollowUp) {
        guard isWorking else {
            sendQueued(item)
            return
        }
        queue.removeAll { $0.id == item.id }
        if item.hasAttachments || !item.skills.isEmpty {
            holdForNextTurn(item)
        } else {
            steer(item.text)
        }
    }

    /// Tapping a queued message puts it in the field; it leaves the queue until Send puts it back.
    func editQueued(_ item: QueuedFollowUp) {
        if editingQueued != nil { cancelEditingQueued() }
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        if hasDraftText { stashedDraft = (draft, draftReferences) }
        queue.remove(at: index)
        editingQueued = EditingQueued(original: item, index: index)
        draftCommand = nil
        draft = item.text
        draftReferences = MessageParts.valid(item.parts?.references ?? [], in: item.text)
        attachments = item.images
        files = item.files
        skills = item.skills
    }

    /// The strip's close button: the message goes back as it was.
    func cancelEditingQueued() {
        guard let editing = editingQueued else { return }
        editingQueued = nil
        queue.insert(editing.original, at: min(editing.index, queue.count))
        draft = ""
        draftReferences = []
        attachments = []
        files = []
        skills = []
        restoreStashedDraft()
    }

    private func restoreStashedDraft() {
        guard let stashed = stashedDraft else { return }
        stashedDraft = nil
        draft = stashed.text
        draftReferences = MessageParts.valid(stashed.references, in: stashed.text)
    }

    /// Sends the last user message again after a failed turn, images included.
    func retryLastMessage() {
        guard !isWorking, !isFinishing, !isBotTurnOpen, !lastUserText.isEmpty || !lastUserImages.isEmpty || !lastUserFiles.isEmpty else { return }
        start(text: lastUserText, images: lastUserImages, files: lastUserFiles)
    }

    func dismissTurnError() {
        turnError = nil
    }

    private func start(text: String, images: [ImageAttachment], files: [FileAttachment], skills: [String] = [], prompt: String? = nil, parts: MessageParts? = nil, queued: Bool = false) {
        settleBackgroundRuns()
        banner = nil
        turnError = nil
        lastUserText = text
        lastUserImages = images
        lastUserFiles = files
        turnSkills = skills
        turnPrompt = prompt
        turnParts = parts
        failureIsRetryable = true
        var entry = UserEntry(id: "local-\(UUID().uuidString)", text: text, timestamp: .now, fileNames: files.map(\.name), skillNames: skills)
        if let parts, parts.hasStructure, parts.command == nil { entry.parts = parts }
        userImages[entry.id] = images
        armedSteers = []
        queuePaused = false
        turnQueued = queued
        animateRows {
            pendingUser = entry
            redirectedParts = []
            live = LiveTurn(id: "live-\(UUID().uuidString)", sessionID: sessionID)
            sentTurns += 1
        }
        promptSent = false
        isRemoteTurn = false
        if !isBotChat {
            workspace?.rememberModelChoice(model, effort: reasoningEffort)
        }
        turnUsesGateway = usesGateway
        if turnUsesGateway {
            isBotTurnOpen = true
            turnTask = Task { await runGatewayTurn(text: text, images: images, files: files) }
            return
        }
        turnTask = Task { await runTurn(text: text, images: images, files: files, entryID: entry.id) }
    }

    /// The API server has no upload: readable files go inline after the message.
    private static func inlined(_ text: String, files: [FileAttachment]) throws -> String {
        guard !files.isEmpty else { return text }
        var parts = text.isEmpty ? [] : [text]
        for file in files {
            guard let contents = file.inlineText else {
                throw HermesError.invalidResponse(String(localized: "“\(file.name)” isn't text. Turn on Bot Mode to send other files"))
            }
            parts.append(AttachedFiles.inline(name: file.name, contents: contents))
        }
        return parts.joined(separator: "\n\n")
    }

    private func runTurn(text: String, images: [ImageAttachment], files: [FileAttachment], entryID: String) async {
        guard let workspace, let client = workspace.client else { return }
        backgroundActivity.begin("Hermes reply")
        defer { backgroundActivity.end() }

        let sessionID: String
        let input: String
        do {
            input = try Self.inlined(text, files: files)
            sessionID = try await ensureSession(client: client, workspace: workspace)
        } catch {
            restoreDraft(text: text, images: images, files: files, error: error)
            return
        }
        if !images.isEmpty, let key = stableKey {
            workspace.imageStore.remember(images, conversation: key, text: text)
        }

        do {
            if images.isEmpty {
                let runID = try await client.startRun(
                    sessionID: sessionID,
                    input: input,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    idempotencyKey: UUID().uuidString
                )
                apply(.runStarted(runID: runID))
                try await follow(runID: runID, client: client)
            } else {
                try await streamChat(sessionID: sessionID, text: input, images: images, client: client)
            }
        } catch {
            if live?.runID == nil {
                // Nothing started on the server; give the message back to the composer.
                restoreDraft(text: text, images: images, files: files, error: error)
                return
            }
            if error is CancellationError {
                live?.markStopped()
            } else {
                live?.markFailed((error as? HermesError)?.errorDescription ?? error.localizedDescription)
            }
        }
        await finishTurn { try await self.fetchLatest($0) }
    }

    private func ensureSession(client: HermesClient, workspace: BotWorkspace) async throws -> String {
        if let sessionID { return sessionID }
        let session = try await client.createSession()
        sessionID = session.id
        stableKey = session.stableID
        apply(.sessionChanged(session.id))
        workspace.adopt(self, session: session)
        return session.id
    }

    /// Follows a detached run, re-attaching to its event stream whenever it drops.
    ///
    /// A lost connection never fails the turn: the run keeps executing on the gateway,
    /// so this keeps trying (and says "Reconnecting…") until it learns the outcome.
    private func follow(runID: String, client: HermesClient) async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            let seqBefore = live?.lastSeq
            let subscription = Task { @MainActor [weak self] in
                for try await event in client.runEvents(runID: runID, after: self?.live?.lastSeq) {
                    guard let self else { return }
                    self.connectionNote = nil
                    self.apply(event.event, seq: event.seq)
                    if self.live?.isFinished == true { return }
                }
            }
            self.subscription = subscription
            do {
                try await withTaskCancellationHandler {
                    try await subscription.value
                } onCancel: {
                    subscription.cancel()
                }
            } catch {
                // Transport errors are handled below by asking for the run's status.
            }
            self.subscription = nil
            try Task.checkCancellation() // the whole turn was cancelled
            if live?.isFinished == true { return }
            if live?.lastSeq != seqBefore { failures = 0 }

            // The stream ended early. Reconcile with the run's status.
            do {
                let status = try await client.runStatus(runID: runID)
                if status.isTerminal {
                    applyTerminal(status)
                    return
                }
                if let approval = status.approval, live?.approval == nil {
                    apply(.approvalRequested(approval))
                }
            } catch HermesError.notFound {
                // Run status is kept for about an hour; past that the outcome is in the transcript.
                failureIsRetryable = false
                live?.markFailed(String(localized: "Lost track of this reply. It may have finished on the gateway."))
                return
            } catch {
                try Task.checkCancellation()
            }

            // A deliberate re-attach (app came back to the foreground) isn't a failure.
            if skipBackoff {
                skipBackoff = false
                continue
            }
            failures += 1
            if failures >= 2 {
                connectionNote = String(localized: "Reconnecting…")
            }
            let delay = min(15, 0.5 * pow(2, Double(failures)))
            let backoff = Task { try await Task.sleep(for: .seconds(delay)) }
            self.backoff = backoff
            try? await withTaskCancellationHandler {
                try await backoff.value
            } onCancel: {
                backoff.cancel()
            }
            self.backoff = nil
        }
    }

    /// Streams a multimodal turn. On this transport a dropped connection ends the turn.
    private func streamChat(sessionID: String, text: String, images: [ImageAttachment], client: HermesClient) async throws {
        let stream = client.streamChat(
            sessionID: sessionID,
            text: text,
            imageDataURLs: images.map(\.dataURL),
            model: model,
            reasoningEffort: reasoningEffort
        )
        do {
            for try await event in stream {
                apply(event.event, seq: event.seq)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The connection dropped; the run may still have finished. Ask before giving up.
            guard let runID = live?.runID, let status = try? await client.runStatus(runID: runID), status.isTerminal else {
                throw error
            }
            applyTerminal(status)
        }
        // A cancelled consumer ends the loop without throwing.
        if Task.isCancelled {
            live?.markStopped()
            return
        }
        if live?.isFinished == false, let runID = live?.runID, let status = try? await client.runStatus(runID: runID), status.isTerminal {
            applyTerminal(status)
        }
        if live?.isFinished == false {
            live?.markFailed(String(localized: "The connection closed before Hermes finished."))
        }
    }

    private func applyTerminal(_ status: RunStatus) {
        switch status.status {
        case "completed":
            apply(.completed(output: status.output, usage: status.usage, runtime: status.runtime))
        case "cancelled":
            apply(.cancelled)
        case "interrupted":
            apply(.interrupted(status.error))
        default:
            apply(.failed(status.error))
        }
    }

    private func apply(_ event: TurnEvent, seq: Int? = nil) {
        trackSteers(event)
        live?.apply(SequencedTurnEvent(seq: seq, event: event))
    }

    private func finishTurn(fetch: @escaping (String) async throws -> SessionTranscript) async {
        let wasStopping = isStopping
        isStopping = false
        connectionNote = nil
        settleFallback?.cancel()
        guard let finished = live else { return }
        isFinishing = true
        defer { isFinishing = false }
        if let newID = finished.sessionID, newID != sessionID {
            sessionID = newID
        }
        if case .failed(let message) = finished.turn.state {
            turnError = TurnFailure(message: message, canRetry: failureIsRetryable)
        }
        let stoppedByUser = wasStopping || finished.turn.state == .stopped
        // What was on screen, in order, to hand its identities to the stored rows.
        let shownRows = (pendingUser.map { [TranscriptItem.user($0)] } ?? []) + redirectedParts + [.assistant(finished.turn)]
        // Fetch in an unstructured task: a turn that ended by cancellation must still reconcile.
        var transcript: SessionTranscript?
        if let sessionID {
            transcript = try? await Task { try await fetch(sessionID) }.value
        }
        // Folded off the main thread, the reply's Markdown parsed ahead: the swap below is then
        // only the swap, not a whole chat built in one frame as the reply ends.
        var prepared: (messages: [SessionMessage], items: [TranscriptItem])?
        if let transcript, live?.turn.id == finished.turn.id, let merged = merge(transcript) {
            prepared = (merged, await Self.prepare(merged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil))
        }
        guard live?.turn.id == finished.turn.id else { return }
        // The stored rows take over from the live ones in place (same identities), in one
        // animated step: the reply's actions fade in where it ends instead of shoving it up.
        animateRows {
            if transcript != nil {
                if let prepared {
                    rebuild(from: prepared.messages, built: prepared.items)
                    saveCache()
                }
                handOverIdentity(shown: shownRows)
                needsReconcile = false
                carryOverExtras(from: finished.turn)
                if finished.turn.state == .stopped {
                    markLastTurnStopped()
                }
            } else {
                // Couldn't reach the server: keep what streamed in, and reload when we can.
                items += shownRows
                needsReconcile = true
            }
            pendingUser = nil
            redirectedParts = []
            live = nil
            settleSteers(stopped: stoppedByUser, readLive: transcript == nil ? [] : (shownRows.flatMap { row -> [SteerNote] in
                if case .assistant(let turn) = row { turn.steers } else { [] }
            }))
        }
        loadState = .loaded
        completedTurns += 1
        if let botName {
            seenActivity = .now
            seenChat = nil // the next roster read describes this turn
            roster?.turnFinished(in: botName)
        } else {
            workspace?.turnFinished(in: self)
        }
        if !queue.isEmpty {
            if stoppedByUser { queuePaused = true } // Stop leaves the queue for a Send
            Task { @MainActor in
                // After the gateway has settled the turn.
                try? await Task.sleep(for: .milliseconds(300))
                self.drainQueueIfIdle()
            }
        }
    }

    /// The stored transcript keeps no inline diffs, full outputs, plan updates, usage or
    /// warnings; carry them over from the live turn that just finished.
    /// The first reply after your last message (steers don't count): where a split turn starts.
    private func firstPartOfLastTurn() -> Int? {
        guard let sent = items.lastIndex(where: {
            if case .user(let entry) = $0 { !entry.isSteer && entry.sender == nil && entry.routineName == nil } else { false }
        }) else { return nil }
        return items[(sent + 1)...].firstIndex { if case .assistant = $0 { true } else { false } }
    }

    private func carryOverExtras(from live: AssistantTurn) {
        guard let index = items.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
              case .assistant(var turn) = items[index]
        else { return }
        if turn.plan.isEmpty { turn.plan = live.plan }
        turn.usage = turn.usage ?? live.usage
        turn.models = turn.models ?? live.models
        // A warning comes as the agent starts: it goes on the turn's first part when a steer split it.
        if let warning = live.warning, let first = firstPartOfLastTurn(), first != index,
           case .assistant(var opening) = items[first] {
            opening.warning = opening.warning ?? warning
            items[first] = .assistant(opening)
        } else {
            turn.warning = turn.warning ?? live.warning
        }
        var liveTools: [String: ToolActivity] = [:]
        for step in live.steps {
            if case .tool(let tool) = step, let id = tool.callID { liveTools[id] = tool }
        }
        turn.steps = turn.steps.map { step in
            guard case .tool(var tool) = step, let id = tool.callID, let liveTool = liveTools[id] else { return step }
            tool.diff = tool.diff ?? liveTool.diff
            tool.output = tool.output ?? liveTool.output
            tool.risk = tool.risk ?? liveTool.risk
            return .tool(tool)
        }
        items[index] = .assistant(turn)
    }

    /// The stored transcript can't say a turn was stopped; carry that over from the live turn,
    /// along with which tool call was cut off.
    private func markLastTurnStopped() {
        guard let index = items.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
              case .assistant(var turn) = items[index],
              !items[index...].contains(where: { if case .user = $0 { true } else { false } })
        else { return }
        turn.state = .stopped
        turn.steps = turn.steps.map { step in
            guard case .tool(var tool) = step, tool.result == nil else { return step }
            tool.status = .failed
            return .tool(tool)
        }
        items[index] = .assistant(turn)
    }

    private func restoreDraft(text: String, images: [ImageAttachment], files: [FileAttachment], error: any Error) {
        pendingUser = nil
        live = nil
        isStopping = false
        if draft.isEmpty { draft = text }
        if attachments.isEmpty { attachments = images }
        if self.files.isEmpty { self.files = files }
        // A stop pressed before the run started is not an error.
        if !(error is CancellationError) {
            banner = error as? HermesError ?? .invalidResponse(error.localizedDescription)
        }
    }

    // MARK: - Control

    func stop() {
        guard let live, !live.isFinished, !isStopping else { return }
        isStopping = true
        queuePaused = true
        if turnUsesGateway || isBotChat {
            stopBotTurn()
            return
        }
        guard let runID = live.runID, let client = workspace?.client else {
            turnTask?.cancel()
            return
        }
        Task {
            // A queued run has no live agent yet and answers 409; keep asking until it stops.
            for _ in 0..<12 {
                guard self.live?.runID == runID, self.isWorking else { return }
                do {
                    try await client.stopRun(runID: runID)
                    break
                } catch {
                    if let status = try? await client.runStatus(runID: runID), status.isTerminal { break }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // The event stream delivers the cancellation. If it never does, stop waiting.
            try? await Task.sleep(for: .seconds(15))
            if self.live?.runID == runID, self.isWorking {
                self.turnTask?.cancel()
            }
        }
    }

    func respond(to approval: ApprovalRequest, with choice: ApprovalChoice, quietly: Bool = false) {
        if !quietly { addApprovalReceipt(for: approval, choice: choice) }
        defer { showNextApproval() }
        if approval.gatewayRequestID != nil {
            respondInBotChat(to: approval, with: choice)
            return
        }
        guard let runID = live?.runID, let client = workspace?.client else { return }
        apply(.approvalResolved(requestID: approval.requestID))
        Task {
            do {
                try await client.respondToApproval(runID: runID, requestID: approval.requestID, choice: choice)
            } catch HermesError.server(409, _, _) {
                // Already answered, timed out (a deny) or the run ended: nothing is waiting.
            } catch {
                banner = error as? HermesError
                if self.live?.runID == runID, self.isWorking {
                    self.apply(.approvalRequested(approval))
                }
            }
        }
    }

    /// Called when the app returns to the foreground. The socket may have died while
    /// suspended, so re-attach to the run at once; or reload a turn that ended offline.
    func resumeIfNeeded() {
        // The roster reconnects chats that run over its socket.
        guard !isBotChat, !(turnUsesGateway && isWorking) else { return }
        if isWorking, live?.runID != nil {
            skipBackoff = true
            subscription?.cancel()
            backoff?.cancel()
        } else if needsReconcile, !isFinishing {
            reload()
        }
    }

    func cancelAll() {
        turnTask?.cancel()
        loadTask?.cancel()
        reattachTask?.cancel()
        subscription?.cancel()
        backoff?.cancel()
        settleFallback?.cancel()
        botTurnDone?.resume()
        botTurnDone = nil
    }
}

// MARK: - Bot Chat

/// A Bot Chat runs over the backend's gateway socket instead of the API server: the
/// chat is resumed by its stored id, prompts go to `prompt.submit`, events stream in
/// through the roster, and `session.info {running: false}` says the turn has settled.
extension ConversationModel {
    static let kickoffText = "Hey, tell me about yourself!"

    /// Events that mean a turn is under way, even one this device didn't start.
    private static let turnEvents: Set<String> = [
        "message.start", "message.delta", "message.interim", "reasoning.delta", "reasoning.available",
        "tool.start", "subagent.start",
    ]

    /// The person's first hello to a brand-new Bot, so it introduces itself.
    func sendKickoff() {
        guard isEmpty, !isWorking, !isBotTurnOpen else { return }
        start(text: Self.kickoffText, images: [], files: [])
    }

    fileprivate func reloadBotChat() {
        guard let roster, let botName else { return }
        LoadTrace.begin(stableKey ?? "?", "bot reload (connected: \(roster.isConnected))")
        loadTask?.cancel()
        let opening = items.isEmpty
        if opening { loadState = .loading }
        guard roster.isConnected else {
            if opening { Task { await showCached() } }
            roster.retryNow() // Reload means now, not after the backoff; the roster calls back once online
            return
        }
        let token = UUID()
        fetchToken = token
        loadTask = Task {
            defer { if fetchToken == token { fetchToken = nil } }
            if opening { await showCached() }
            do {
                let stored = try await roster.resolveBotChat(botName)
                LoadTrace.mark(stableKey, "resolved \(stored ?? "nil")")
                if let stored {
                    if sessionID != stored {
                        sessionID = stored
                    }
                    let transcript = try await fetchLatest(stored)
                    guard !Task.isCancelled, !isWorking, !isFinishing else { return }
                    await applyLoaded(transcript)
                }
                let bot = roster.bot(named: botName)
                seenActivity = bot?.activitySession?.lastActive
                seenChat = bot?.canonicalSession.map(BotChatMark.init)
                loadState = .loaded
                needsReconcile = false
                if turnError?.canRetry == false { turnError = nil }
                if sessionID != nil, runtimeSessionID == nil {
                    _ = await attachGatewayChat()
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if items.isEmpty {
                    loadState = .failed(HermesError.botMode(error))
                } else {
                    banner = HermesError.botMode(error)
                }
            }
        }
    }

    /// `session.resume`: registers this chat on the socket so its events reach us.
    /// Returns whether a turn is running on the backend, or `nil` if it failed.
    @discardableResult
    fileprivate func attachGatewayChat() async -> Bool? {
        guard let roster = gatewayRoster, let stored = sessionID else { return nil }
        var params: [String: JSONValue] = ["session_id": .string(stored), "omit_messages": .bool(true)]
        if let profile = gatewayProfile { params["profile"] = .string(profile) }
        do {
            let snapshot = try await roster.request("session.resume", params, timeout: .seconds(45))
            guard let runtime = snapshot["session_id"]?.stringValue else { return nil }
            if runtime != runtimeSessionID {
                lastAppliedSeq = nil
                appliedRunSettings = nil
            }
            runtimeSessionID = runtime
            if !isBotChat { roster.attach(self) }
            if let info = LiveWorkspace(info: snapshot["info"]) { liveWorkspace = info }
            // Helpers that ran on while nobody watched (`subagent.list`).
            if !isBotChat { Task { await helpers.reconcile() } }
            let running = snapshot["running"]?.boolValue ?? false
            if running, live == nil {
                beginRemoteTurn()
            }
            // What Hermes holds for the next turn (`queued`): in the tray, read-only.
            if let held = GatewayQueue.queuedPrompt(in: snapshot) {
                if !gatewayQueued.contains(held) {
                    gatewayQueued = [held]
                    captionsByText[held] = .fromQueue
                    expectedFromGateway = [(held, .fromQueue)]
                }
            } else if !gatewayQueued.isEmpty {
                gatewayQueued = []
                expectedFromGateway.removeAll { $0.caption == .fromQueue }
            }
            if let pending = snapshot["pending_connection"], let connection = HermesRequest.connection(from: pending) {
                receive(connection)
            }
            if case .array(let requests)? = snapshot["open_requests"] {
                for request in requests {
                    guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { continue }
                    let serverRequest = GatewayServerRequest(id: id, method: method, params: request["params"] ?? .object([:]))
                    if let approval = GatewayTurnDecoder.approval(from: serverRequest) {
                        receive(approval)
                    } else if let other = HermesRequest.parse(serverRequest) {
                        receive(other)
                    }
                }
            }
            return running
        } catch {
            return nil
        }
    }

    /// The chat's runtime id, resuming the Bot Chat or creating it on first use.
    private func ensureRuntime() async throws -> String {
        if let runtimeSessionID { return runtimeSessionID }
        guard let botName else { return try await ensureChatRuntime() }
        guard let roster else { throw GatewaySocket.Failure.notConnected }
        if sessionID == nil {
            // Fails closed: a lookup error must never mint a second Bot Chat.
            sessionID = try await roster.resolveBotChat(botName)
        }
        if sessionID != nil {
            _ = await attachGatewayChat()
            guard let runtimeSessionID else { throw GatewaySocket.Failure.notConnected }
            return runtimeSessionID
        }
        let created = try await roster.request("session.create", [
            "profile": .string(botName), "title": .string(botChatTitle),
            "hidden": .bool(true), "follow_profile_config": .bool(true),
        ])
        guard let runtime = created["session_id"]?.stringValue else {
            throw HermesError.invalidResponse("session.create")
        }
        runtimeSessionID = runtime
        lastAppliedSeq = nil
        sessionID = created["stored_session_id"]?.stringValue
        _ = try await roster.request("session.title", ["session_id": .string(runtime), "title": .string(botChatTitle)])
        return runtime
    }

    fileprivate func runGatewayTurn(text: String, images: [ImageAttachment], files: [FileAttachment]) async {
        guard let roster = gatewayRoster else { return }
        backgroundActivity.begin("Hermes reply")
        defer { backgroundActivity.end() }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            var runtime = try await ensureRuntime()
            if isBotChat, ["/new", "/reset", "/compact", "/compress"].contains(command) {
                try await compactBotChat(runtime: runtime, wasReset: command == "/new" || command == "/reset")
                isBotTurnOpen = false
                return
            }
            if !isBotChat {
                await applyRunSettings(runtime: runtime, roster: roster)
            }
            for (index, image) in images.enumerated() {
                _ = try await roster.request("image.attach_bytes", [
                    "session_id": .string(runtime),
                    "content_base64": .string(image.jpegData.base64EncodedString()),
                    "filename": .string("image-\(index + 1).jpg"),
                ])
            }
            if !images.isEmpty, let key = stableKey {
                workspace?.imageStore.remember(images, conversation: key, text: text)
            }
            var references: [String] = []
            for file in files {
                references.append(try await attach(file, runtime: runtime, roster: roster))
            }
            var prompt = botName.map { BotMentions.prompt(for: text, roster: roster.profiles, activeBot: $0) } ?? text
            if !references.isEmpty {
                prompt = ([prompt] + references).filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if let override = turnPrompt {
                // A command's model-facing message (`command.dispatch` → send / skill).
                prompt = override
                rememberParts(prompt: prompt, text: text, skills: turnSkills)
            } else if let first = turnSkills.first {
                // Skills go as `/skill` prefixes; the gateway expands them into the message.
                var params: [String: JSONValue] = [
                    "name": .string(first),
                    "arg": .string((turnSkills.dropFirst().map { "/\($0)" } + [prompt]).joined(separator: " ")),
                    "session_id": .string(runtime),
                ]
                if let gatewayProfile { params["profile"] = .string(gatewayProfile) }
                let expanded = try await roster.request("command.dispatch", params)
                if let message = expanded["message"]?.stringValue, !message.isEmpty {
                    prompt = message
                }
                rememberParts(prompt: prompt, text: text, skills: turnSkills)
            } else if turnParts?.references.isEmpty == false {
                rememberParts(prompt: prompt, text: text, skills: [])
            }
            promptSent = true
            var submit: [String: JSONValue] = ["session_id": .string(runtime), "text": .string(prompt)]
            if turnQueued { submit["queued"] = .bool(true) } // a queued message never becomes a steer
            do {
                _ = try await roster.request("prompt.submit", submit)
            } catch let error as GatewayRPCError where error.isSessionNotFound {
                // The backend forgot this runtime id (a restart); resume and send again.
                runtimeSessionID = nil
                runtime = try await ensureRuntime()
                submit["session_id"] = .string(runtime)
                _ = try await roster.request("prompt.submit", submit)
            }
            if live?.runID == nil { apply(.runStarted(runID: runtime)) }
        } catch {
            if !isBotChat, error is GatewayRPCError || error is GatewaySocket.Failure {
                // The socket couldn't take it; the API server still can, if nothing started.
                if live?.runID == nil, workspace?.client != nil, !(error is CancellationError) {
                    isBotTurnOpen = false
                    turnUsesGateway = false
                    runtimeSessionID = nil
                    await runTurn(text: text, images: images, files: files, entryID: pendingUser?.id ?? "")
                    return
                }
            }
            if live?.runID == nil, !(live?.turn.steps.isEmpty == false) {
                isBotTurnOpen = false
                restoreDraft(text: text, images: images, files: files, error: error is CancellationError ? error : HermesError.botMode(error))
                return
            }
            live?.markFailed(HermesError.botMode(error).errorDescription ?? "")
        }
        await waitForBotTurn()
        await finishBotTurn()
    }

    /// Uploads a file for the next prompt and returns what goes into the prompt for it: a PDF's
    /// pages go as images (`pdf.attach`, which needs pdftoppm on the gateway), anything else, or
    /// a PDF the gateway can't render, as an `@file:` reference (`file.attach`).
    private func attach(_ file: FileAttachment, runtime: String, roster: BotRoster) async throws -> String {
        if file.isPDF {
            if let result = try? await roster.request("pdf.attach", [
                "session_id": .string(runtime),
                "content_base64": .string(file.data.base64EncodedString()),
                "filename": .string(file.name),
            ], timeout: .seconds(120)), result["attached"]?.boolValue != false {
                return AttachedFiles.pdfNote(name: file.name)
            }
        }
        let result = try await roster.request("file.attach", [
            "session_id": .string(runtime),
            "data_url": .string(file.dataURL),
            "name": .string(file.name),
        ], timeout: .seconds(120))
        return result["ref_text"]?.stringValue ?? "@file:\(result["path"]?.stringValue ?? file.name)"
    }

    /// Bot Chats never reset: `/new` compacts the conversation instead, like Desktop.
    private func compactBotChat(runtime: String, wasReset: Bool) async throws {
        guard let roster else { return }
        pendingUser = nil
        apply(.status(String(localized: "Compacting context…")))
        let result = try await roster.request("session.compress", ["session_id": .string(runtime)], timeout: .seconds(300))
        let headline = result["summary"]?["headline"]?.stringValue ?? String(localized: "Compacted the conversation.")
        live = nil
        if let botName, let stored = sessionID, let transcript = try? await roster.transcript(storedSessionID: stored, profile: botName) {
            apply(transcript)
        }
        let note = wasReset
            ? String(localized: "Bot Chats are one continuous conversation, so this one was compacted instead. \(headline)")
            : headline
        appendLocal(.notice(Notice(id: "compact-\(UUID().uuidString)", kind: "compaction", text: note)))
        completedTurns += 1
    }

    private func waitForBotTurn() async {
        guard live != nil, live?.isFinished == false || settleFallback != nil else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Never strand an earlier waiter.
                botTurnDone?.resume()
                botTurnDone = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.settle() }
        }
    }

    private func finishBotTurn() async {
        defer { isBotTurnOpen = false }
        if roster != nil || workspace?.client != nil || gatewayRoster != nil {
            await finishTurn { try await self.fetchLatest($0) }
        }
    }

    /// A normal chat's runtime id over the gateway: resume its stored session, or create one
    /// (with this chat's model and effort) and file it in the sidebar.
    private func ensureChatRuntime() async throws -> String {
        guard let roster = gatewayRoster else { throw GatewaySocket.Failure.notConnected }
        if sessionID != nil {
            _ = await attachGatewayChat()
            guard let runtimeSessionID else { throw GatewaySocket.Failure.notConnected }
            return runtimeSessionID
        }
        var params: [String: JSONValue] = [
            "source": .string("hermes_app"),
            "idempotency_key": .string(UUID().uuidString),
        ]
        if let profile = gatewayProfile { params["profile"] = .string(profile) }
        if let model {
            params["model"] = .string(model.model)
            params["provider"] = .string(model.provider)
        }
        if let reasoningEffort { params["reasoning_effort"] = .string(reasoningEffort.rawValue) }
        // A project's folder; without one the gateway uses its default (No Project).
        let placement = placement ?? workspace?.projects.defaultPlacement
        if let placement, let cwd = try await workspace?.projects.resolveFolder(for: placement) {
            params["cwd"] = .string(cwd)
        }
        let created = try await roster.request("session.create", params)
        guard let runtime = created["session_id"]?.stringValue, let stored = created["stored_session_id"]?.stringValue else {
            throw HermesError.invalidResponse("session.create")
        }
        runtimeSessionID = runtime
        lastAppliedSeq = nil
        appliedRunSettings = RunSettings(model: model, effort: reasoningEffort)
        roster.attach(self)
        sessionID = stored
        stableKey = stored
        if let info = LiveWorkspace(info: created["info"]) { liveWorkspace = info }
        workspace?.projects.placed(storedID: stored, in: placement?.projectID)
        apply(.sessionChanged(stored))
        workspace?.adopt(self, session: HermesSession(id: stored))
        return runtime
    }

    /// The chat's model and reasoning effort, set on its gateway session when they change.
    private func applyRunSettings(runtime: String, roster: BotRoster) async {
        let wanted = RunSettings(model: model, effort: reasoningEffort)
        guard wanted != appliedRunSettings else { return }
        let previous = appliedRunSettings
        if let model, model != previous?.model {
            _ = try? await roster.request("config.set", [
                "session_id": .string(runtime), "key": .string("model"),
                "value": .string("\(model.model) --provider \(model.provider)"),
            ])
        }
        if let reasoningEffort, reasoningEffort != previous?.effort {
            _ = try? await roster.request("config.set", [
                "session_id": .string(runtime), "key": .string("reasoning"), "value": .string(reasoningEffort.rawValue),
            ])
        }
        appliedRunSettings = wanted
    }

    /// Events for this chat, routed by the roster.
    func receive(_ event: GatewayEvent) {
        // Helpers report on this session, during the turn and after it (background delegation):
        // their team card keeps its own state and never reopens the turn.
        if event.type.hasPrefix("subagent.") {
            helpers.receive(event)
            return
        }
        if event.type == "tool.start" || event.type == "tool.complete", event.payload["name"]?.stringValue == "delegate_task" {
            helpers.delegationEvent(event)
        }
        switch event.type {
        case "request.cancel":
            withdrawRequest(id: event.payload["id"]?.stringValue, method: event.payload["method"]?.stringValue, reason: event.payload["reason"]?.stringValue)
            if event.payload["method"]?.stringValue != "approval" { return }
        case "connection.request":
            if let request = HermesRequest.connection(from: event.payload) { receive(request) }
            return
        case "connection.update":
            updateConnection(event.payload)
            return
        case "session.info":
            if let yolo = event.payload["yolo"]?.boolValue, yolo != allowsEverything { allowsEverything = yolo }
            // A move (`session.workspace.move`) or `session.cwd.set` names the new folder.
            if let info = LiveWorkspace(info: event.payload), info != liveWorkspace { liveWorkspace = info }
        case "review.summary":
            if let text = event.payload["text"]?.stringValue, !text.isEmpty {
                addReceipt(String(localized: "Reviewed the last reply · \(text)"), symbol: "checkmark.seal.fill")
            }
            return
        case "message.reaction":
            if let row = event.payload["row_id"].flatMap({ $0.stringValue ?? $0.doubleValue.map { String(Int($0)) } }),
               case .array(let list)? = event.payload["reactions"] {
                reactions["m\(row)"] = list.compactMap { $0["emoji"]?.stringValue }
            }
            return
        case "background.complete":
            let id = event.payload["task_id"]?.stringValue ?? UUID().uuidString
            let answer = event.payload["text"]?.stringValue ?? ""
            if finishBackground(taskID: id, answer: answer) { return }
            let noticeID = "background-\(id)"
            backgroundResults[noticeID] = (backgroundPrompts[id] ?? "", answer)
            appendLocal(.notice(Notice(id: noticeID, kind: "background", text: answer)))
            return
        case "agent.terminal.output":
            guard let id = event.payload["process_id"]?.stringValue else { return }
            let chunk = event.payload["chunk"]?.stringValue ?? ""
            if let index = processes.firstIndex(where: { $0.id == id }) {
                processes[index].output = String((processes[index].output + chunk).suffix(4000))
            } else {
                processes.append(BackgroundProcess(id: id, command: String(localized: "Background process"), output: chunk, isRunning: true, startedAt: .now))
                Task { await nameProcesses() }
            }
            return
        case "terminal.close":
            if let id = event.payload["process_id"]?.stringValue, let index = processes.firstIndex(where: { $0.id == id }) {
                processes[index].isRunning = false
            }
            return
        default:
            break
        }
        if event.type == "btw.complete" {
            let id = event.payload["task_id"]?.stringValue ?? ""
            let answer = event.payload["text"]?.stringValue ?? ""
            if let index = asides.firstIndex(where: { $0.id == id }) {
                asides[index].answer = answer
            } else {
                asides.append(Aside(id: id, question: event.payload["question"]?.stringValue ?? "", answer: answer))
            }
            return
        }
        if event.type == "session.reclaimed" {
            // The gateway put this idle chat to sleep; the next message resumes it.
            runtimeSessionID = nil
            lastAppliedSeq = nil
            appliedRunSettings = nil
            if !items.isEmpty {
                addReceipt(String(localized: "This chat was resting · it picks up where you left off"), symbol: "moon.zzz")
            }
            return
        }
        if catchUpBuffer != nil {
            catchUpBuffer?.append(event)
            return
        }
        // Replays and live delivery can overlap after a reconnect: apply each seq once.
        if let seq = event.seq {
            if let last = lastAppliedSeq, seq <= last { return }
            lastAppliedSeq = seq
        }
        let decoded = GatewayTurnDecoder.decode(event)
        if live == nil {
            guard Self.turnEvents.contains(event.type), !isFinishing else { return }
            beginRemoteTurn()
        }
        connectionNote = nil
        if Self.turnEvents.contains(event.type) || event.type == "message.complete" { promptSent = true }
        for item in decoded {
            switch item.event {
            case .settled:
                if promptSent { settle() }
            case .titleChanged:
                if !isBotChat { workspace?.titleChanged(in: self) }
            default:
                trackSteers(item.event)
                live?.apply(item)
            }
        }
        if live?.isFinished == true, settleFallback == nil {
            // Older backends may not send the settle; don't wait forever for it.
            settleFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.settle()
            }
        }
    }

    /// An approval the backend asked for (a server→client request).
    func receive(_ approval: ApprovalRequest) {
        if live == nil { beginRemoteTurn() }
        // Parallel tool calls ask at once: keep the others waiting behind the card.
        if let current = pendingApproval, current.id != approval.id {
            if !waitingApprovals.contains(where: { $0.id == approval.id }) { waitingApprovals.append(approval) }
            return
        }
        apply(.approvalRequested(approval))
    }

    // MARK: Requests (docs/quick-actions.md)


    /// Turns "allow everything in this chat" on or off (`config.set yolo`, session scope).
    func setAllowsEverything(_ on: Bool) {
        allowsEverything = on
        guard let roster = gatewayRoster else { return }
        Task {
            guard let runtime = try? await ensureRuntime() else { return }
            _ = try? await roster.request("config.set", ["key": .string("yolo"), "value": .string(on ? "on" : "off"), "session_id": .string(runtime), "scope": .string("session")])
        }
        addReceipt(on ? String(localized: "Everything is allowed in this chat") : String(localized: "Commands ask again in this chat"), symbol: on ? "bolt.shield" : "shield")
    }

    /// Deny, then tell Hermes why (a Steer Now while the turn runs).
    func deny(_ approval: ApprovalRequest, saying note: String) {
        respond(to: approval, with: .deny)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runCommand("steer", argument: text)
    }

    /// Every approval waiting, the card's first.
    var approvalQueue: [ApprovalRequest] {
        (pendingApproval.map { [$0] } ?? []) + waitingApprovals
    }

    /// Who's asking, for card headers: "Hermes", or the Bot.
    var askerName: String {
        if let botName { return roster?.bot(named: botName)?.title ?? botName }
        return "Hermes"
    }

    func receive(_ request: HermesRequest) {
        guard !requests.contains(where: { $0.id == request.id }) else { return }
        requests.append(request)
    }

    /// Sends the card's answer. `receipt` is the line left in the chat; never put a secret in it.
    func answer(_ request: HermesRequest, with result: JSONValue, receipt: String?, symbol: String = "checkmark.circle") {
        // A double tap answers once.
        guard requests.contains(where: { $0.id == request.id }) else { return }
        requests.removeAll { $0.id == request.id }
        connectionStates[request.id] = nil
        if let receipt { addReceipt(receipt, symbol: symbol) }
        guard let roster = gatewayRoster else { return }
        Task {
            if case .connection = request.kind {
                guard let runtime = runtimeSessionID else { return }
                _ = try? await roster.request("connection.respond", [
                    "owner": .object(["type": .string("session"), "session_id": .string(runtime)]),
                    "op_id": .string(request.id),
                    "result": result,
                ])
            } else {
                await roster.respond(to: request.id, result: result)
            }
        }
    }

    /// `connection.respond`'s result: a status (and values) per target.
    static func connectionResult(_ answers: [String: (String, [String: JSONValue])]) -> JSONValue {
        .object(["targets": .array(answers.sorted { $0.key < $1.key }.map { name, answer in
            var target: [String: JSONValue] = ["name": .string(name), "status": .string(answer.0)]
            if !answer.1.isEmpty { target["env"] = .object(answer.1) }
            return .object(target)
        })])
    }

    /// Answers a connection but keeps its card, which then follows `connection.update` (OAuth).
    func respondToConnection(_ request: HermesRequest, targets: [String: (String, [String: JSONValue])]) async {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID else { return }
        _ = try? await roster.request("connection.respond", [
            "owner": .object(["type": .string("session"), "session_id": .string(runtime)]),
            "op_id": .string(request.id),
            "result": Self.connectionResult(targets),
        ])
    }

    func skip(_ request: HermesRequest) {
        answer(request, with: request.skipResult, receipt: String(localized: "Skipped · \(Self.title(of: request))"), symbol: "arrow.uturn.forward.circle")
    }

    /// Answers several approvals the same way (the batch card).
    func respondToAll(with choice: ApprovalChoice) {
        let all = approvalQueue
        waitingApprovals = []
        for approval in all {
            respond(to: approval, with: choice, quietly: true)
        }
        if let first = all.first {
            addApprovalReceipt(for: first, choice: choice, count: all.count)
        }
    }

    private func showNextApproval() {
        guard pendingApproval == nil, !waitingApprovals.isEmpty else { return }
        let next = waitingApprovals.removeFirst()
        apply(.approvalRequested(next))
    }

    /// Hermes withdrew a request (`request.cancel`): clear only its card, and say why.
    private func withdrawRequest(id: String?, method: String?, reason: String?) {
        guard let id else { return }
        let receipt: (String, String)? = switch reason {
        case "timeout": (String(localized: "Hermes stopped waiting · no answer in time"), "clock")
        case "resolved": (String(localized: "Answered on another device"), "checkmark.circle.fill")
        case "interrupted": (String(localized: "Cancelled · you stopped this reply"), "stop.circle")
        default: nil
        }
        var matched = false
        if requests.contains(where: { $0.id == id }) {
            requests.removeAll { $0.id == id }
            connectionStates[id] = nil
            matched = true
        }
        if waitingApprovals.contains(where: { $0.gatewayRequestID == id }) {
            waitingApprovals.removeAll { $0.gatewayRequestID == id }
            matched = true
        }
        if method == "approval", pendingApproval?.gatewayRequestID == id {
            matched = true
            DispatchQueue.main.async { [weak self] in self?.showNextApproval() }
        }
        if matched, let receipt { addReceipt(receipt.0, symbol: receipt.1) }
    }

    private func updateConnection(_ payload: JSONValue) {
        guard let opID = payload["op_id"]?.stringValue else { return }
        if case .array(let targets)? = payload["targets"] {
            for target in targets {
                guard let name = target["name"]?.stringValue, let state = target["state"]?.stringValue ?? target["status"]?.stringValue else { continue }
                connectionStates[opID, default: [:]][name] = state
            }
        }
        if payload["settled"]?.boolValue == true, let request = requests.first(where: { $0.id == opID }) {
            requests.removeAll { $0.id == opID }
            addReceipt(String(localized: "Connected · \(Self.title(of: request))"), symbol: "checkmark.seal.fill")
        }
    }

    private func addReceipt(_ text: String, symbol: String) {
        addReceipt(Notice(id: "receipt-\(UUID().uuidString)", kind: "receipt:\(symbol)", text: text))
    }

    private func addReceipt(_ notice: Notice) {
        if live.map({ !$0.isFinished }) ?? false {
            turnReceipts.append(.notice(notice))
        } else {
            appendLocal(.notice(notice))
        }
    }

    private func addApprovalReceipt(for approval: ApprovalRequest, choice: ApprovalChoice, count: Int = 1) {
        let subject = count > 1 ? String(localized: "\(count) commands") : approval.summary
        switch choice {
        case .once:
            addReceipt(String(localized: "Allowed once · \(subject)"), symbol: "checkmark.circle")
        case .session:
            let scope = approval.description ?? approval.patternKeys.first?.replacingOccurrences(of: "_", with: " ") ?? subject
            if !sessionGrants.contains(scope) { sessionGrants.append(scope) }
            addReceipt(Notice(id: "receipt-\(UUID().uuidString)", kind: "receipt:session", text: String(localized: "Allowed in this chat · \(scope.lowercased())")))
        case .always:
            addReceipt(String(localized: "Always allowed · \(subject)"), symbol: "checkmark.shield")
        case .deny:
            addReceipt(String(localized: "Denied · \(subject)"), symbol: "xmark.circle")
        }
    }

    /// The card's title, for receipts.
    static func title(of request: HermesRequest) -> String {
        switch request.kind {
        case .clarify(let questions): questions.first?.question ?? String(localized: "Question")
        case .secret(let envVar, _): envVar
        case .sudo: String(localized: "Administrator password")
        case .vaultUnlock(_, let name): String(localized: "Unlock \(name ?? "password manager")")
        case .vaultSaveLogin(_, let site): String(localized: "Save a login for \(site ?? "this site")")
        case .vaultCode(let site, _): String(localized: "Code for \(site ?? "sign-in")")
        case .choose(let choice): choice.question
        case .connection(let connection): connection.targets.map(\.name).formatted(.list(type: .and))
        }
    }

    private func beginRemoteTurn() {
        // A turn running on the gateway answers "how did it end?": an uncertain-outcome card is moot.
        if turnError?.canRetry == false { turnError = nil }
        animateRows {
            live = LiveTurn(id: "live-\(UUID().uuidString)", sessionID: sessionID)
            redirectedParts = []
            takeExpectedFromGateway()
        }
        isRemoteTurn = true
        isBotTurnOpen = true
        promptSent = true
    }

    /// The turn is over on the backend.
    private func settle() {
        settleFallback?.cancel()
        settleFallback = nil
        guard let live else { return }
        if !live.isFinished {
            if isStopping {
                self.live?.markStopped()
            } else {
                apply(.completed(output: nil, usage: nil, runtime: nil))
            }
        }
        if let botTurnDone {
            self.botTurnDone = nil
            botTurnDone.resume()
        } else if isRemoteTurn {
            isRemoteTurn = false
            Task { await finishBotTurn() }
        }
    }

    private func stopBotTurn() {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID, promptSent else {
            turnTask?.cancel()
            return
        }
        let turnID = live?.turn.id
        Task {
            _ = try? await roster.request("session.interrupt", ["session_id": .string(runtime)])
            try? await Task.sleep(for: .seconds(12))
            if self.live?.turn.id == turnID, self.isWorking {
                self.live?.markStopped()
                self.settle()
            }
        }
    }

    private func respondInBotChat(to approval: ApprovalRequest, with choice: ApprovalChoice) {
        guard let roster = gatewayRoster, let requestID = approval.gatewayRequestID else { return }
        apply(.approvalResolved(requestID: approval.requestID))
        Task {
            await roster.respond(to: requestID, result: .object(["choice": .string(choice.rawValue), "all": .bool(false)]))
        }
    }

    /// The roster's socket dropped.
    func botChatConnectionLost() {
        if isWorking { connectionNote = String(localized: "Reconnecting…") }
    }

    /// The roster's socket is back: re-attach and catch up on what was missed.
    func botChatReconnected() {
        switch loadState {
        case .idle:
            return // not opened yet
        case .loading, .failed:
            if !isWorking {
                // A load already under way carries on; starting it again would fetch twice.
                if !isFetching { reload() }
                return
            }
        case .loaded:
            break
        }
        guard sessionID != nil else { return }
        // A second drop mid re-attach keeps the first runtime id: that's the one with our events.
        let previous = runtimeSessionID ?? replayRuntime
        replayRuntime = previous
        let lastSeq = lastAppliedSeq
        runtimeSessionID = nil
        // Hold live events until the missed ones have been replayed, then apply both in order.
        catchUpBuffer = []
        reattachTask?.cancel()
        reattachTask = Task {
            let running = await attachRetrying()
            guard !Task.isCancelled else { return }
            replayRuntime = nil
            var frames: [GatewayEvent] = []
            if live != nil, let roster = gatewayRoster, let runtime = runtimeSessionID, runtime == previous,
               let result = try? await roster.request("session.events.since", [
                   "session_id": .string(runtime), "last_seen": .number(Double(lastSeq ?? 0)),
               ]), case .array(let replay)? = result["events"] {
                frames = replay.map { frame in
                    GatewayEvent(
                        type: frame["type"]?.stringValue ?? "", sessionID: runtime,
                        seq: frame["seq"]?.doubleValue.map { Int($0) }, payload: frame["payload"] ?? .object([:])
                    )
                }
            }
            let held = catchUpBuffer ?? []
            catchUpBuffer = nil
            connectionNote = nil
            guard live != nil else {
                // A transcript fetched moments ago (the socket connecting as the app starts) is
                // current: only a real outage needs catching up.
                if let lastFetchedAt, Date.now.timeIntervalSince(lastFetchedAt) < 5 { return }
                reload()
                return
            }
            for event in frames + held {
                receive(event)
            }
            if running == nil, isWorking {
                // Half a minute of refusals: the turn's outcome is on the gateway. Sending the
                // message again could run it twice, so the card offers a reload, not a retry.
                failureIsRetryable = false
                live?.markFailed(String(localized: "Couldn't reconnect to this chat. Reload to see how it ended."))
                settle()
            } else if running == false, isWorking {
                settle()
            } else if running == false {
                drainQueueIfIdle() // what waited while offline goes now
            }
        }
    }

    /// `session.resume`, retried while a turn is open. Right after a drop Hermes is often still
    /// settling the old connection ("session disconnect interrupt settling", "retry resume") while
    /// the turn keeps running, so one refusal says nothing about the turn. Idle chats attach again
    /// with their next message.
    private func attachRetrying() async -> Bool? {
        var delay = 0.5
        for attempt in 0..<8 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 8)
            }
            guard !Task.isCancelled, gatewayRoster?.isConnected == true else { return nil }
            if let running = await attachGatewayChat() { return running }
            guard live != nil else { return nil }
        }
        return nil
    }

    /// The roster changed: pick up messages that arrived while nothing streamed here
    /// (routine results, other Bots' messages, turns on another device).
    func botRosterChanged(_ bot: BotProfile, previous: BotProfile?) {
        guard loadState == .loaded, !isWorking, !isFinishing else { return }
        if sessionID == nil, bot.canonicalSession != nil {
            reload()
            return
        }
        // New messages can come without a newer activity time: Hermes' one-shot `hermes chat` (a
        // Bot's message delivered while no app held the chat) answers its own background process
        // without touching `last_activity_at`.
        let chat = bot.canonicalSession.map(BotChatMark.init)
        let chatMoved = chat != nil && seenChat != nil && chat != seenChat
        seenChat = chat
        guard let active = bot.activitySession?.lastActive else { return }
        if let seen = seenActivity, active <= seen.addingTimeInterval(0.5) {
            if chatMoved { reload() }
            return
        }
        seenActivity = active
        if chatMoved || bot.canonicalSession?.lastActive == active {
            reload()
        }
    }
}

extension HermesError {
    /// Bot Mode failures (socket, RPC and backend errors) as an app error.
    nonisolated static func botMode(_ error: any Error) -> HermesError {
        if let error = error as? HermesError { return error }
        return .server(status: 0, code: nil, message: BotRoster.describe(error))
    }
}

/// What the roster says about a Bot Chat's newest message, to notice turns that didn't stream here.
struct BotChatMark: Equatable {
    var count: Int?
    var preview: String?

    init(_ session: BotSessionRef) {
        count = session.messageCount
        preview = session.preview
    }
}

/// A turn that ended badly, as shown under the transcript.
struct TurnFailure: Equatable {
    let message: String
    /// Whether sending the message again is safe (the failed run definitely stopped).
    let canRetry: Bool
}

