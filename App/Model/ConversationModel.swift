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
    /// The chat's key in the inbox (`UnreadStore`): its Bot, or its session.
    var inboxKey: String? { botName.map(UnreadStore.botKey) ?? stableKey }
    /// ⌘↓ (Jump to Latest): bumped, the transcript goes to the end.
    var jumpToLatestRequests = 0
    /// The transcript is scrolled up from the end (⌘↓ is offered only then, so at the end it still
    /// moves the composer's cursor).
    var isReadingBack = false
    /// The live session id used for API calls; compression can change it.
    private(set) var sessionID: String?

    private(set) var items: [TranscriptItem] = [] {
        didSet {
            lastLineVersion &+= 1
            syncDerivedState()
            refreshWidgetFacts()
        }
    }
    /// Counts changes to what the chat list's last line is read from (`rowLastLine`): the rows,
    /// the message on its way and a turn that ended. It's worked out again only when they moved.
    @ObservationIgnored private(set) var lastLineVersion = 0
    @ObservationIgnored private var announcedLineVersion = 0
    @ObservationIgnored private var lineSawFinishedTurn = false
    private(set) var loadState: LoadState = .idle
    /// The user message of the turn in flight, shown until the server transcript has it.
    private(set) var pendingUser: UserEntry? { didSet { lastLineVersion &+= 1; syncDerivedState(); refreshWidgetFacts() } }
    /// What the chat's rows say about its widgets: answers, questions moved past (`docs/widgets.md` §5).
    private(set) var widgetFacts = WidgetChatFacts()
    @ObservationIgnored fileprivate var widgetHostStorage: WidgetHost?
    /// The turn in flight. Changes with every streamed token: only the transcript reads it
    /// directly; everything else reads the mirrors below. Observed by hand, so streamed words
    /// can go in without redrawing the transcript for each one (`applyToLive`).
    private(set) var live: LiveTurn? {
        get {
            access(keyPath: \.live)
            return liveStorage
        }
        set {
            withMutation(keyPath: \.live) { liveStorage = newValue }
            wordsRedraw?.cancel()
            wordsRedraw = nil
            liveVersion &+= 1
            syncDerivedState()
        }
    }
    @ObservationIgnored private var liveStorage: LiveTurn?
    /// Words that went into the turn since the transcript last heard of it.
    @ObservationIgnored private var wordsRedraw: Task<Void, Never>?
    @ObservationIgnored private var liveVersion = 0
    @ObservationIgnored private var liveSnapshot: (version: Int, row: AssistantTurn?)?

    /// The live turn as drawn. Its snapshot cleans the whole streamed text and relates its edits:
    /// made at most once per change to the turn, when something reads it, rather than on each of
    /// the many reads of `rows` (several events can change the turn between two frames, so it
    /// isn't made on every change either). Reading `live` keeps whoever reads this observing it.
    private var liveRow: AssistantTurn? {
        let current = live
        if let liveSnapshot, liveSnapshot.version == liveVersion { return liveSnapshot.row }
        let row = current?.snapshot
        liveSnapshot = (liveVersion, row)
        return row
    }
    /// A message whose answer was lost and that Hermes hasn't shown yet (`LostPrompt`): its card
    /// offers Send Again until the stored chat has it.
    @ObservationIgnored private var unconfirmed: LostPrompt?
    /// When the turn running at the last attach started (`turn_started_at`), to tell a turn Hermes
    /// took for a lost send from an older one.
    @ObservationIgnored private var attachedTurnStartedAt: Date?
    /// Why the last turn didn't finish, shown under the transcript.
    private(set) var turnError: TurnFailure? {
        didSet { if turnError != oldValue { workspace?.activity.conversationChanged() } }
    }
    private(set) var isStopping = false
    /// The turn has ended and its transcript is being fetched; sending waits for it.
    private(set) var isFinishing = false
    /// The message going out hasn't been taken by the gateway yet (`docs/chat.md` §4): its bubble
    /// says "Sending…", then after a moment "Waiting for <Mac>…", until Hermes has it. A busy or
    /// away Mac only makes it wait; it's never given back for that.
    enum Delivery: Equatable { case sending, waiting }
    @ObservationIgnored private var delivery: Delivery?
    /// What the bubble says of it: nothing for a quick gateway (its answer comes first), "Sending…"
    /// after half a second, "Waiting for <Mac>…" once it's away, busy or 10 s have gone.
    private(set) var deliveryNote: Delivery? {
        didSet { if deliveryNote != oldValue { syncDerivedState() } }
    }
    @ObservationIgnored private var deliveryWatch: Task<Void, Never>?
    /// The message going out, kept on the device once it waits (`OutboxItem`).
    @ObservationIgnored private var outgoing: OutboxItem?
    /// Messages a previous run of the app kept and never saw taken: looked for in the stored chat
    /// once it loads (`settleOutbox`).
    @ObservationIgnored private var keptFromBefore: [OutboxItem] = []
    /// "Reconnecting…" while a detached run's event stream is down.
    private(set) var connectionNote: String? { didSet { syncDerivedState() } }
    /// Increments whenever a turn completes, for haptics and scroll anchoring.
    private(set) var completedTurns = 0
    private(set) var sentTurns = 0

    var draft = "" {
        didSet {
            let has = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if has != hasDraftText {
                hasDraftText = has
                if has, isWorking { Task { await SteerTip.typedWhileWorking.donate() } }
            }
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
    /// The person is dictating into the composer (its face listens).
    var isDictating = false
    /// What the running turn is doing, for its Bot's face: thinking (`message.start`, reasoning),
    /// working while a tool runs, idle once it's done. Changes only when the mood does.
    private(set) var turnMood: BotMood = .idle
    /// The running turn's reply has words: what VoiceOver says once ("Replying"), never per word.
    private(set) var isReplying = false
    /// The gateway put this chat to sleep (`session.reclaimed`); the next message wakes it.
    private(set) var isResting = false
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
    /// The roster said the Bot Chat moved while a fetch was out: fetch once more after it, rather
    /// than throw away a fetch a busy Mac may be nearly done with (`botRosterChanged`).
    @ObservationIgnored private var fetchAgain = false
    /// Sent once the transcript has loaded (a branch made by Edit and Resend).
    @ObservationIgnored private var sendOnLoad: String?
    /// Editing an earlier message (`composerEditing`): sending branches from just before it.
    var editing: UserEntry?
    /// Reply with a quote (`replyBar`, `docs/inbox.md` §4): the passage and who said it, until
    /// the message goes or the bar is closed.
    var replyingTo: ReplyTarget?
    /// A row to flash in the transcript (the passage just quoted, or a quote's source): bumped
    /// each time.
    private(set) var flashRequest: FlashRequest?

    struct ReplyTarget: Equatable {
        var author: String
        var quote: String
        /// The transcript row the passage is in.
        var rowID: String
    }

    struct FlashRequest: Equatable {
        var rowID: String
        var count: Int
    }
    /// Emoji Hermes put on messages (`message.reaction`), by row id.
    private(set) var reactions: [String: [String]] = [:]
    /// Background processes Hermes started in this chat (`docs/background-processes.md`): output
    /// as it streams, the gateway's list for how each one is (exits come only from there), and the
    /// call that started each. The Terminal reads this one, live.
    private(set) var processTracker = ProcessTracker()
    /// What the steps and the composer chip show of them: the tracker, with output caught up at
    /// most twice a second (§4).
    private(set) var processes: [BackgroundProcess] = []
    /// A process that finished in the last 4 s: the chip shows its check (§5).
    @ObservationIgnored private var justFinishedProcess: String?
    /// The composer's chip (`processChip`), set when what it says changes.
    private(set) var processChip = ProcessChip.hidden
    /// What the chip's long-press offers to stop, set when it changes.
    private(set) var stoppableProcesses: [StoppableProcess] = []

    struct StoppableProcess: Identifiable, Equatable {
        let id: String
        let name: String
        let isStopping: Bool
    }
    @ObservationIgnored private var justFinishedReset: Task<Void, Never>?
    @ObservationIgnored private var processesPublishedAt = Date.distantPast
    @ObservationIgnored private var processesPublish: Task<Void, Never>?
    /// Looks for exits while something runs: every 5 s with the chat on screen, every 30 s
    /// otherwise (§1).
    @ObservationIgnored private var processWatch: Task<Void, Never>?
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var processWatchID = 0
    /// Fetches the chat again while its stored rows stop mid-turn (`watchMidTurn`).
    @ObservationIgnored private var midTurnWatch: Task<Void, Never>?
    /// Bumped by `cancelAll`: a look still on its way doesn't start watching again.
    @ObservationIgnored private var processGeneration = 0
    @ObservationIgnored private var processRefreshing = false
    @ObservationIgnored private var processRefreshAgain = false
    /// The stored chat has process steps the gateway hasn't been asked about yet.
    @ObservationIgnored private var needsProcessList = false
    /// Background prompts (`/bg`) by task id, for their result cards.
    @ObservationIgnored private var backgroundPrompts: [String: String] = [:]
    /// Finished background prompts by notice id: what was asked and the full answer.
    private(set) var backgroundResults: [String: (prompt: String, answer: String)] = [:]

    /// Terminal output not yet shown: chunks arrive tens of times a second, the Terminal redraws
    /// for them at most ten.
    @ObservationIgnored private var pendingOutput: [String: String] = [:]
    @ObservationIgnored private var outputFlush: Task<Void, Never>?

    private func flushOutput() {
        outputFlush?.cancel()
        outputFlush = nil
        guard !pendingOutput.isEmpty else { return }
        let pending = pendingOutput
        pendingOutput = [:]
        var tracker = processTracker
        for (id, text) in pending { tracker.receiveOutput(text, for: id) }
        processTracker = tracker
        publishProcesses()
        for id in pending.keys { inspector.processOutput(id) }
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
    /// The turn being sent was spoken in Talk (`docs/voice.md` §4.1).
    @ObservationIgnored private var turnVoice: VoiceTurn?
    /// `nil` means the gateway's configured default model.
    var model: ModelSelection?
    var reasoningEffort: ReasoningEffort?
    /// Hermes asked before switching to an expensive model (`confirm_required`): the chat keeps its
    /// model until the person confirms.
    var modelConfirmation: ModelConfirmation?

    struct ModelConfirmation: Identifiable, Equatable {
        let selection: ModelSelection
        let message: String
        var id: String { selection.model + "|" + selection.provider }
    }

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
    /// Hermes refused a message because another of its processes holds this chat (`waitForChat`):
    /// Up Next waits for it, and says so.
    private(set) var waitsForChat = false
    @ObservationIgnored private var chatWaitRetry: Task<Void, Never>?
    @ObservationIgnored private var chatWaitAttempts = 0
    /// The stored chat stopped mid-turn at the last look (`watchMidTurn`).
    @ObservationIgnored private var wasMidTurn = false
    /// Its last turn runs where no events reach the app (`TranscriptBuilder.markMidTurn`): another
    /// Bot's message being answered, or a turn whose stored rows stop mid-work. The jump pill
    /// follows it as it follows a live turn.
    private(set) var runsElsewhere = false
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
            if requests.isEmpty != oldValue.isEmpty { workspace?.activity.conversationChanged() }
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
    /// Answers given to Hermes's requests over the socket, by request id, until an attach shows
    /// Hermes has them (`AnswerLedger`, `docs/quick-actions.md` §3).
    @ObservationIgnored private var answers = AnswerLedger()

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

    /// The gateway was removed: what this chat kept on the device goes too (how sent messages
    /// were made, the goal, messages waiting to send).
    func forgetLocalData() {
        if let stableKey {
            UserDefaults.standard.removeObject(forKey: "parts.\(stableKey)")
            UserDefaults.standard.removeObject(forKey: "goal.\(stableKey)")
        }
        if let queueKey {
            FollowUpQueueStore.save([], key: queueKey)
            FollowUpQueueStore.saveOutbox([], key: queueKey)
        }
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

    /// Command mode waits for the argument before Send turns on (`composerCommand`); one that
    /// only waits for Send (`/update`) is ready at once.
    var canSendCommand: Bool {
        guard let draftCommand else { return false }
        let waitsOnlyForSend = SlashCommands.known(draftCommand)?.confirmsOnSend == true
        guard waitsOnlyForSend || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
    /// Settling only counts once Hermes has taken our prompt (creating a chat settles too, and so
    /// does building its agent: `TurnSettleGate`).
    @ObservationIgnored private var turnGate = TurnSettleGate()
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
    /// A pending check of which requests Hermes still waits on (`RequestSync`).
    @ObservationIgnored private var requestSyncTask: Task<Void, Never>?
    /// Fetching the chat again until it shows how a turn it lost track of ended (`recoverSoon`).
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    /// A send whose answer was lost is being looked into (`arrival`): it re-attaches the chat
    /// itself, and the socket coming back leaves the turn to it.
    @ObservationIgnored private var confirmingSend = false
    @ObservationIgnored private var replayRuntime: String?
    /// The newest event applied for the current runtime id (event seqs only grow).
    @ObservationIgnored private var lastAppliedSeq: Int?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Which folds are open in this chat (`DisclosureState`), kept here so a row's view can come
    /// and go without closing or opening them.
    @ObservationIgnored let disclosures = DisclosureState()
    /// Looking for what an opened notification announced (`notificationOpened`).
    @ObservationIgnored private var notifiedCatchUp: Task<Void, Never>?
    /// A load Hermes was too slow for, asked again (`retriesQuietly`).
    @ObservationIgnored private var quietRetry: Task<Void, Never>?
    @ObservationIgnored private var quietRetries = 0
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
            keptFromBefore = FollowUpQueueStore.loadOutbox(key: key)
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
        self.keptFromBefore = FollowUpQueueStore.loadOutbox(key: "bot-\(roster.botID.uuidString)-\(botName)")
    }

    /// Sent from elsewhere and never opened (setup's About You): nothing in it asks for
    /// notifications.
    var sentInBackground = false
    /// Setup's About You may save one memory without asking, during its first turn only.
    @ObservationIgnored var savesOneMemory = false
    @ObservationIgnored private var firstTurnStarted = false

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

    // MARK: Search (docs/search.md)

    /// A search result to land on once the chat is open: the transcript scrolls to the first
    /// message with its words (loading up to 5 older pages) and flashes it.
    var searchFocus: SearchFocus?

    /// In-chat find (⌘F): what's looked for in the loaded transcript (`nil`: the bar is closed),
    /// and which match is shown, counting from the oldest.
    var findText: String?
    var findIndex = 0

    /// Opens find with `text`, on the newest match.
    func find(_ text: String) {
        findText = text
        findIndex = max(0, findMatches.count - 1)
    }

    /// The rows that say the find text, oldest first.
    var findMatches: [TranscriptItem] {
        guard let findText else { return [] }
        return SearchFocus.rows(saying: findText, in: rows)
    }

    /// The previous or next match, wrapping around.
    func stepFind(_ step: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = ((findIndex + step) % count + count) % count
    }

    // MARK: Inspector (docs/inspector.md)

    @ObservationIgnored private var inspectorStore: InspectorModel?
    /// This chat's Inspector: its tabs and what's behind them.
    var inspector: InspectorModel {
        if let inspectorStore { return inspectorStore }
        let pins = workspace?.inspectorPins ?? InspectorPins(workspaceID: UUID())
        let model = InspectorModel(conversation: self, pins: pins)
        inspectorStore = model
        if let workspace { model.restore(chatKey: stableKey, workspaceID: workspace.id) }
        return model
    }

    /// The Inspector, only if this chat has made one.
    var inspectorIfLoaded: InspectorModel? { inspectorStore }

    /// How much of a background process's output the Terminal keeps (never logged).

    // MARK: Checkpoints (docs/checkpoints.md)

    @ObservationIgnored private var checkpointStore: CheckpointsModel?
    /// This chat's checkpoints: the undo bar, Review, Undo and the timeline.
    var checkpoints: CheckpointsModel {
        if let checkpointStore { return checkpointStore }
        let store = CheckpointsModel(conversation: self)
        checkpointStore = store
        return store
    }

    /// The socket checkpoint calls go over (`CheckpointsModel`).
    var gatewayRosterForCheckpoints: BotRoster? { gatewayRoster }

    /// After an undo, the message is back in the composer (`composerEditing`: "Undone · your
    /// message is back to edit").
    private(set) var hasUndoneMessage = false
    /// What the composer held before the undone message replaced it.
    @ObservationIgnored private var draftBeforeUndo: (text: String, references: [MessageReference])?
    /// What restores said, by notice id (`restoredNote`).
    private(set) var restoredNotes: [String: RestoredNote] = [:]
    /// /update's and /restart's cards, by command entry: the gateway job each one started
    /// (`docs/setup.md` §4.2a).
    private(set) var commandJobs: [String: GatewayJob.Ref] = [:]

    /// The job a command card follows: live while it runs, then as it ended.
    func job(forCommand id: String) -> GatewayJob? {
        commandJobs[id].flatMap { workspace?.setup.job($0) }
    }

    /// The runtime session checkpoint calls are scoped to, attaching the chat when it isn't yet.
    func runtimeForCheckpoints() async -> String? {
        if let runtimeSessionID { return runtimeSessionID }
        guard usesGateway, sessionID != nil else { return nil }
        _ = await attachGatewayChat()
        return runtimeSessionID
    }

    /// The gateway dropped turns from `userID` on (an undo or restore): take them out here, say
    /// what happened where they were, and load the stored chat again.
    func applyUndo(from userID: String?, note: RestoredNote, returning message: String?) {
        animateRows {
            if let userID, let index = items.firstIndex(where: { $0.id == userID }) {
                let gone = Set(items[index...].map(\.id))
                localItems.removeAll { gone.contains($0.item.id) }
                items.removeSubrange(index...)
            }
            let notice = Notice(id: "restored-\(UUID().uuidString)", kind: "restored", text: note.title)
            restoredNotes[notice.id] = note
            appendLocal(.notice(notice))
        }
        if let message {
            draftBeforeUndo = hasDraftText ? (draft, draftReferences) : nil
            draft = message
            hasUndoneMessage = true
        }
        reload()
    }

    /// Closes the "Undone" strip: the composer gets back what it had.
    func dismissUndoneMessage() {
        hasUndoneMessage = false
        draft = draftBeforeUndo?.text ?? ""
        draftReferences = draftBeforeUndo?.references ?? []
        draftBeforeUndo = nil
    }

    /// Ends this chat's live session on the gateway and resumes it, so Hermes builds its agent
    /// again and reads settings like `checkpoints.enabled`. The history stays. Only when idle.
    @discardableResult
    func reattachForSettings() async -> Bool {
        guard !isWorking, !isFinishing, let roster = gatewayRoster, let runtime = runtimeSessionID else { return false }
        _ = try? await CheckpointsClient { method, params in try await roster.request(method, params) }.closeSession(sessionID: runtime)
        runtimeSessionID = nil
        return await attachGatewayChat() != nil
    }

    /// The send-mode menu is open (the chip, or ⌥Return on an iPad's keyboard).
    var showsFollowUpMenu = false

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
    /// The profile whose config Turn On Checkpoints writes.
    var gatewayProfileForCheckpoints: String? { gatewayProfile }
    /// The backend this chat's audio goes to (the Bot's voice, Realtime), with its profile.
    var audioBackend: (client: BackendClient, profile: String?)? {
        guard let roster = gatewayRoster, roster.isConnected else { return nil }
        return (roster.backendClient, gatewayProfile)
    }

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
    /// A turn whose stored rows weren't written yet when it ended: what was on screen, to hand its
    /// identities over once a later load brings them (`after`: the newest message id before it).
    @ObservationIgnored private var heldOver: (shown: [TranscriptItem], after: Int?)?
    /// Reading the chat again for a turn kept as still working (`awaitStoredReply`).
    @ObservationIgnored private var storedReplyWait: Task<Void, Never>?
    /// Bumped by every `rebuild`: work that awaited before applying rows checks nobody rebuilt in
    /// between with newer ones.
    @ObservationIgnored private var rowsGeneration = 0
    /// What only a live turn knew, which Hermes doesn't store: its plan, usage, models, warning and
    /// that it was stopped (by stored turn id), and each call's diff, output and risk (by call id).
    /// Put back on every rebuild (`applyOverlays`): written into the rows once, the next reload (a
    /// roster poll, a reconnect, a page) took them away again.
    @ObservationIgnored private var turnOverlays: [String: TurnOverlay] = [:]
    @ObservationIgnored private var toolOverlays: [String: ToolOverlay] = [:]
    /// Call ids in the order their overlays came: past `maxToolOverlays` the oldest go, and with
    /// them a long day's build logs.
    @ObservationIgnored private var toolOverlayOrder: [String] = []
    private static let maxToolOverlays = 300
    /// A call's output is kept to its last 64 KB (what a step shows is its end).
    private static let maxOverlayOutput = 64 * 1024

    private struct TurnOverlay {
        var plan: [PlanItem] = []
        var usage: TokenUsage?
        var models: ModelsProgress?
        var warning: String?
        var stopped = false
    }

    private struct ToolOverlay {
        var diff: String?
        var output: String?
        var risk: ToolRisk?
    }

    /// Changes to the transcript's rows (a message sent, a reply settling into the stored one, a
    /// steer read, a redirect) go out as one animated transaction, so the scroll view keeps its
    /// bottom anchored along with the rows instead of jumping ahead of them.
    private func animateRows(_ change: () -> Void) {
        withAnimation(.smooth(duration: 0.36), change)
    }

    /// The cards above the composer (requests, approvals) come and go animated: they rise out of
    /// the composer and sink back into it. The change carries the animation; one the bar added
    /// itself missed changes made by a tap in the card, which then vanished in a frame.
    private func moveCards(_ change: () -> Void) {
        withAnimation(Theme.cardMotion, change)
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
        if let liveRow { rows.append(.assistant(liveRow)) }
        return rows
    }

    /// `rows` as the transcript lists them: the running reply is there by its outline
    /// (`liveOutline`), which holds still while its words stream in. The reply's own row reads
    /// `liveTurn`, so a streamed word redraws that row and not the whole transcript.
    var listRows: [TranscriptItem] {
        var rows = items
        if let pendingUser { rows.append(.user(pendingUser)) }
        rows += turnReceipts
        rows += redirectedParts
        if let liveOutline { rows.append(.assistant(liveOutline)) }
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
    /// The running turn's plan (the Inspector's Plan).
    private(set) var livePlan: [PlanItem] = []
    /// How many files the running turn has edited (checkpoints are read again as it changes).
    private(set) var liveEditedFiles = 0
    /// The live turn's id while it runs: views that only need to know which row is live read
    /// this, not `live`, which changes with every streamed word.
    private(set) var liveTurnID: String?
    /// The running (or just finished) reply without its words: what places and keys its row in
    /// the transcript (its id, start and state) and the helpers it started. It changes as steps
    /// start and the turn ends, not with every word.
    private(set) var liveOutline: AssistantTurn?
    /// What the transcript handed its rows last as what they can name (`ReferenceContext`).
    @ObservationIgnored private var lastReferences: ReferenceContext?

    /// The chat list's last line for this chat (`docs/inbox.md` §2): its rows, then what isn't
    /// stored yet, the message on its way and a reply that ended; with the activity it stands for.
    var rowLastLine: (line: LastLine?, asOf: Date) {
        var tail: [TranscriptItem] = []
        if let pendingUser { tail.append(.user(pendingUser)) }
        if let turn = liveStorage, turn.isFinished { tail.append(.assistant(turn.turn)) }
        return (LastLine.of(items, then: tail), LastLine.asOf(items, then: tail) ?? .now)
    }

    /// `fresh`, or the equal one handed out before. The environment tells values apart by their
    /// contents, not `==`: a fresh one, its sets just rebuilt, redrew every reply that reads it.
    func stableReferences(_ fresh: ReferenceContext) -> ReferenceContext {
        if let lastReferences, lastReferences == fresh { return lastReferences }
        lastReferences = fresh
        return fresh
    }

    private func syncDerivedState() {
        let wasWorking = isWorking
        let hadApproval = pendingApproval != nil
        let finished = liveStorage?.isFinished ?? false
        if finished != lineSawFinishedTurn {
            lineSawFinishedTurn = finished
            lastLineVersion &+= 1
            if finished { LoadTrace.mark(stableKey, "reply ended") }
        }
        defer {
            // The chat lists' activity line follows the turn, and their last line the chat
            // (`docs/inbox.md` §2).
            if isWorking != wasWorking || (pendingApproval != nil) != hadApproval {
                workspace?.activity.conversationChanged()
            } else if !isWorking, lastLineVersion != announcedLineVersion {
                workspace?.activity.lastLineMoved()
            }
            announcedLineVersion = lastLineVersion
        }
        let empty = items.isEmpty && pendingUser == nil && live == nil
        if empty != isEmpty { isEmpty = empty }
        let working = live.map { !$0.isFinished } ?? false
        // Not thinking before Hermes has the message (`delivery`).
        let mood: BotMood = working && deliveryNote == nil ? (live?.isUsingTool == true ? .working : .thinking) : .idle
        if mood != turnMood { turnMood = mood }
        let replying = working && live?.turn.answer.isEmpty == false
        if replying != isReplying { isReplying = replying }
        if working, isResting { isResting = false }
        if working != isWorking {
            isWorking = working
            // This Turn's base, and Hermes's ink dots going out when it's done.
            if working, usesGateway, !isBotChat { inspector.turnStarted() }
            if !working { inspectorStore?.turnFinished() }
            #if HERMES_PUSH
            PushCenter.shared.conversation(self, working: working)
            #endif
        }
        let approval = live?.approval
        if savesOneMemory {
            if live != nil { firstTurnStarted = true } else if firstTurnStarted { savesOneMemory = false }
        }
        if approval != pendingApproval {
            #if HERMES_PUSH
            PushCenter.shared.conversation(self, approval: approval, replacing: pendingApproval)
            #endif
            moveCards { pendingApproval = approval }
            // Setup's About You said Save to Memory: its one save goes through without a
            // second ask nobody would see (`docs/onboarding.md` §3).
            if savesOneMemory, let approval, approval.isTitledMemorySave {
                savesOneMemory = false
                respond(to: approval, with: .once, quietly: true)
            }
        }
        let status = connectionNote ?? live?.status
        if status != liveStatus { liveStatus = status }
        let edited = live.map { TurnFileEdits.paths(in: $0.turn).count } ?? 0
        if edited != liveEditedFiles { liveEditedFiles = edited }
        let runningID = working ? live?.turn.id : nil
        if runningID != liveTurnID { liveTurnID = runningID }
        let outline = live?.turn.outline
        if outline != liveOutline { liveOutline = outline }
        let plan = live?.turn.plan ?? []
        if plan != livePlan { livePlan = plan }
    }

    var canSend: Bool {
        if draftCommand != nil { return canSendCommand }
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || !files.isEmpty || !skills.isEmpty
        guard hasContent, !isWorking, !isFinishing, !isBotTurnOpen else { return false }
        // Not the connection: a message to a busy or away Mac shows at once and waits for it
        // (`delivery`). Only a sign-in it could never get past without the person stops it.
        if isBotChat {
            guard let roster else { return false }
            if case .signInRequired = roster.state { return false }
            return true
        }
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
        reload(attaching: true)
    }

    /// - Parameter attaching: over the gateway, attach the chat once loaded (turns started
    ///   elsewhere stream in); off for reads in the background (`readForSync`).
    func reload(attaching: Bool) {
        if isBotChat {
            reloadBotChat(attaching: attaching)
            return
        }
        LoadTrace.begin(stableKey ?? "?", "reload (client: \(workspace?.client != nil))")
        guard let sessionID, workspace?.client != nil else { return }
        loadTask?.cancel()
        let opening = items.isEmpty
        if opening { loadState = .loading }
        let token = UUID()
        fetchToken = token
        loadTask = Task {
            defer { if fetchToken == token { fetchToken = nil } }
            // What this device saw last shows at once; the gateway's copy is asked for meanwhile,
            // not once the kept one is on screen.
            let kept = opening ? await keptTranscript() : nil
            async let shown: Void = opening ? showKept(kept) : ()
            do {
                let page = try await fetchLatest(sessionID, holding: kept?.messages)
                await shown
                let transcript = try await latest(page, overKept: kept, id: sessionID)
                LoadTrace.mark(stableKey, "fetched \(transcript.messages.count) rows")
                guard !Task.isCancelled else { return }
                guard !isWorking, !isFinishing else {
                    await showHistoryUnderTurn(transcript)
                    return
                }
                await applyLoaded(transcript)
                LoadTrace.mark(stableKey, "applied \(items.count) items")
                loadState = .loaded
                settleOutbox()
                quietRetries = 0
                needsReconcile = false
                if let text = sendOnLoad {
                    sendOnLoad = nil
                    draft = text
                    send()
                }
                // The transcript now says how an uncertain turn really ended.
                settleUncertainTurn()
                // Over the gateway protocol, hear about turns started elsewhere and requests
                // still waiting for an answer.
                if attaching, usesGateway, runtimeSessionID == nil {
                    _ = await attachGatewayChat()
                    LoadTrace.mark(stableKey, "attached")
                }
            } catch is CancellationError {
            } catch {
                // Offline or refused: the kept copy still goes up.
                await shown
                guard !Task.isCancelled else { return }
                if retriesQuietly(after: error) { return }
                if items.isEmpty {
                    loadState = .failed(error as? HermesError ?? .invalidResponse(error.localizedDescription))
                } else {
                    banner = error as? HermesError
                }
            }
        }
    }

    /// A load that failed because Hermes was slow (a proxy's 502 or 504, a timeout:
    /// `BackendClient.isSlowAnswer`), not because something's wrong: what's on screen stays,
    /// nothing turns red, and it's asked again after 5, 10, 15… up to 60 s. The status line says
    /// the Mac is busy meanwhile.
    private func retriesQuietly(after error: any Error) -> Bool {
        guard BackendClient.isSlowAnswer(error) else { return false }
        quietRetries += 1
        let wait = min(60, 5 * Double(quietRetries))
        if items.isEmpty { loadState = .loading }
        quietRetry?.cancel()
        quietRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            // While a turn runs, only for the history nothing shows yet (`showHistoryUnderTurn`).
            guard let self, !Task.isCancelled, !self.isWorking || self.items.isEmpty, !self.isFinishing, !self.isFetching else { return }
            self.reload()
        }
        return true
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
        let generation = rowsGeneration
        let built = await Self.prepare(merged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil)
        await preloadImages(for: built)
        // A chat picked in the drawer lands once the drawer has slid away, not in the middle.
        await Settling.untilSettled()
        // Nor under a turn still on screen: one whose reply is in but that hasn't handed over to
        // its stored rows yet showed twice, live and stored, and the turn's end then took its own
        // rows for history and kept the live copy too. The turn's end fetches the chat itself.
        guard !Task.isCancelled, !isWorking, !isFinishing, live == nil else { return }
        // Rebuilt meanwhile (a turn ended, a page came): those rows are at least as new, and these
        // would take them away until the next load.
        guard generation == rowsGeneration else { return }
        rebuild(from: merged, built: built)
        saveCache()
    }

    /// Off the main thread: the turns, and answers parsed into the Markdown cache: the newest
    /// (`warming` 0), or the ones that many rows before the end (a page going in above).
    private static func prepare(_ messages: [SessionMessage], hasEarlier: Bool, hidesSilence: Bool, warming end: Int = 0) async -> [TranscriptItem] {
        let built = await Task.detached(priority: .userInitiated) {
            let items = TranscriptBuilder.build(fromTurnStart(messages, hasEarlier: hasEarlier), hidesSilence: hidesSilence)
            // Every finished reply's artifacts lifted here: the rows and the chat's artifacts
            // (`InspectorModel.artifacts`) read them on the main thread, where a chat of long code
            // replies took hundreds of milliseconds per pass.
            for case .assistant(let turn) in items where !turn.isWorking && !turn.answer.isEmpty {
                _ = ArtifactDetector.liftingArtifacts(from: turn.answer)
            }
            return items
        }.value
        await MarkdownCache.prewarm(Self.answers(in: built.dropLast(min(end, built.count)).suffix(24)))
        return built
    }

    /// The replies' text in these rows as they're drawn (a finished one without its artifacts),
    /// for `MarkdownCache.prewarm`.
    static func answers(in items: some Sequence<TranscriptItem>) -> [String] {
        items.compactMap { item -> String? in
            guard case .assistant(let turn) = item, !turn.answer.isEmpty else { return nil }
            return turn.isWorking ? turn.answer : ArtifactDetector.liftingArtifacts(from: turn.answer).text
        }
    }

    /// Builds `items` from stored rows (or takes them `built` already).
    private func rebuild(from messages: [SessionMessage], built prebuilt: [TranscriptItem]? = nil) {
        rowsGeneration += 1
        let existing = Set(items.map(\.id))
        rawMessages = messages
        workspace?.widgets.ingest(messages: messages)
        var built = prebuilt ?? TranscriptBuilder.build(Self.fromTurnStart(messages, hasEarlier: hasEarlierMessages), hidesSilence: botName != nil)
        if sentTurns == 0, completedTurns == 0, !built.isEmpty { openedWithHistory = true }
        let midTurn = live == nil && TranscriptBuilder.markMidTurn(&built, messages: messages)
        watchMidTurn(lastRowAt: midTurn ? messages.last?.timestamp : nil)
        // The other process's turn ended: what waited for the chat goes now.
        if wasMidTurn, !midTurn, waitsForChat { retryChat(after: 1) }
        wasMidTurn = midTurn
        if runsElsewhere != midTurn { runsElsewhere = midTurn }
        resolveImages(in: built)
        restoreParts(in: &built)
        if !turnReceipts.isEmpty, live?.isFinished ?? true {
            // The turn is over: its receipts stay after its message.
            let userCount = built.filter { if case .user = $0 { true } else { false } }.count
            localItems += turnReceipts.map { (.afterUser(userCount), $0) }
            turnReceipts = []
        }
        items = mergeLocalItems(into: built)
        applyOverlays()
        if let held = heldOver {
            if TranscriptBuilder.holdsTurn(messages, after: held.after) {
                heldOver = nil
                handOverIdentity(shown: held.shown, existing: existing)
                LoadTrace.mark(stableKey ?? "?", "held turn: \(held.shown.filter { id in items.contains { displayID(for: $0) == id.id } }.count)/\(held.shown.count) rows kept their identity")
            } else {
                // Not stored yet: what streamed in stays where it was until it is, rather than
                // vanishing with this rebuild and coming back with a later one. The person's own
                // message only while Hermes hasn't stored it either.
                let storedAsk = messages.contains { $0.role == "user" && ($0.id ?? .max) > (held.after ?? .min) }
                let shown = Set(items.map(\.id))
                items += held.shown.filter { row in
                    if case .user = row, storedAsk { return false }
                    return !shown.contains(row.id)
                }
            }
        }
        matchCaptions()
        linkStoredProcesses()
    }

    /// The stored rows stop mid-turn: Hermes is on it somewhere this app hears nothing from (a
    /// Bot's one-shot `hermes chat` after another Bot's message, a routine). The turn shows working
    /// (`TranscriptBuilder.markMidTurn`), and the chat is fetched again every 10 s while it shows
    /// until the reply is stored, or once the turn has gone quiet too long to be running.
    private func watchMidTurn(lastRowAt: Date?) {
        midTurnWatch?.cancel()
        midTurnWatch = nil
        guard let lastRowAt else { return }
        midTurnWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let stale = Date.now.timeIntervalSince(lastRowAt) > TranscriptBuilder.midTurnStaleAfter
                guard self.isOnScreen || stale, !self.isWorking, !self.isFinishing, !self.isFetching else { continue }
                // Its rebuild watches again while the turn is still going.
                self.reload()
                return
            }
        }
    }

    /// The stored rows end partway through a turn (`TranscriptBuilder.markMidTurn`): that turn, to
    /// carry on live when this device joins it running.
    private func storedTurnInProgress() -> (index: Int, turn: AssistantTurn)? {
        guard let index = items.indices.last, case .assistant(let turn) = items[index], turn.isWorking else { return nil }
        midTurnWatch?.cancel()
        midTurnWatch = nil
        return (index, turn)
    }

    /// Events for the chat's turn arrived after all (the app attached to it): the stored copy
    /// stops showing as working; the live turn carries on below.
    private func settleStoredTurn() {
        midTurnWatch?.cancel()
        midTurnWatch = nil
        guard let index = items.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
              case .assistant(var turn) = items[index], turn.isWorking else { return }
        turn.state = .complete
        turn.finishedAt = rawMessages.last?.timestamp
        items[index] = .assistant(turn)
    }

    /// The stored message the turn ending now follows (`TranscriptBuilder.newestBeforeTurn`).
    private var newestBeforeTurn: Int? {
        TranscriptBuilder.newestBeforeTurn(rawMessages, ask: pendingUser?.text, sentAt: pendingUser?.timestamp)
    }
    /// `newestBeforeTurn` as the turn started: at its end the stored rows may hold the turn itself.
    @ObservationIgnored private var turnBaseline: (turnID: String, newest: Int?)?

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
        guard let cacheKey, let sessionID, let gateway = workspace?.widgets.gatewayID ?? roster?.botID else { return }
        TranscriptCache.save(cacheKey, gateway: gateway, sessionID: sessionID, messages: rawMessages, hasEarlier: hasEarlierMessages)
    }

    /// The copy of this chat the device kept (`TranscriptCache`), read off the main thread.
    private func keptTranscript() async -> TranscriptCache.Entry? {
        guard let cacheKey else { return nil }
        return await TranscriptCache.load(cacheKey)
    }

    private func showCached() async {
        await showKept(await keptTranscript())
    }

    /// The transcript this device saw last, while the gateway's copy is on its way. Also under a
    /// message that went out before anything showed (`historyUnderTurn`).
    private func showKept(_ cached: TranscriptCache.Entry?) async {
        defer { cacheChecked = true }
        guard let cached else { return }
        let messages = turnInFlight ? historyUnderTurn(cached.messages) : cached.messages
        guard !messages.isEmpty else { return }
        let built = await Self.prepare(messages, hasEarlier: cached.hasEarlier, hidesSilence: botName != nil)
        await preloadImages(for: built)
        // Too late for the drawer's wait (`firstRows`): after its slide, not in the middle.
        await Settling.untilSettled()
        guard items.isEmpty, !isFinishing, !Task.isCancelled else { return }
        hasEarlierMessages = cached.hasEarlier
        rebuild(from: messages, built: built)
        loadState = .loaded
        LoadTrace.mark(stableKey, "showed cache (\(messages.count) rows\(turnInFlight ? ", under a turn" : ""))")
    }

    /// A message of yours is on its way or being answered.
    private var turnInFlight: Bool { pendingUser != nil || live != nil }

    /// The stored rows from before the turn in flight (`TranscriptBuilder.history`).
    private func historyUnderTurn(_ messages: [SessionMessage]) -> [SessionMessage] {
        TranscriptBuilder.history(messages, before: pendingUser?.text, sentAt: pendingUser?.timestamp ?? live?.turn.startedAt)
    }

    /// The chat's history came only after a message went out (a busy Mac answers slowly, and
    /// sending doesn't wait for it): it goes in above that message rather than being dropped, which
    /// left the chat showing nothing but the message. Only while nothing is shown; the turn's end
    /// brings its stored copy as it always does.
    private func showHistoryUnderTurn(_ transcript: SessionTranscript) async {
        guard items.isEmpty, turnInFlight, !isFinishing else { return }
        let history = historyUnderTurn(transcript.messages)
        guard !history.isEmpty,
              let merged = merge(SessionTranscript(sessionID: transcript.sessionID, messages: history, hasEarlier: transcript.hasEarlier))
        else { return }
        let built = await Self.prepare(merged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil)
        await preloadImages(for: built)
        await Settling.untilSettled()
        guard !Task.isCancelled, items.isEmpty, turnInFlight, !isFinishing else { return }
        rebuild(from: merged, built: built)
        loadState = .loaded
        LoadTrace.mark(stableKey, "history under a turn (\(merged.count) rows)")
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
    /// missing (a long turn can add more rows than a page). With rows held (shown, or cached),
    /// a short page first: what's new lands without the dashboard reading and sending 150 rows.
    private func fetchLatest(_ id: String, holding kept: [SessionMessage]? = nil) async throws -> SessionTranscript {
        let held = rawMessages.isEmpty ? kept ?? [] : rawMessages
        let size = held.isEmpty ? SessionTranscript.firstPage : SessionTranscript.catchUpPage
        var page = try await fetchPage(id, limit: size, offset: 0)
        var rounds = 0
        while page.hasEarlier, let newest = (rawMessages.last ?? held.last)?.id, let first = page.messages.first?.id, first > newest, rounds < 10 {
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

    /// A short page fetched while the kept copy went up (`fetchLatest(holding:)`) goes in below
    /// it. A kept copy that didn't go up after all (something else was shown first) gets a whole
    /// first page instead.
    private func latest(_ page: SessionTranscript, overKept kept: TranscriptCache.Entry?, id: String) async throws -> SessionTranscript {
        guard rawMessages.isEmpty, kept?.messages.isEmpty == false, page.hasEarlier else { return page }
        return try await fetchLatest(id)
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
        await preloadImages(for: built)
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
    /// - Parameter existing: the rows on screen before these stored rows came. One of them is older
    ///   than this turn and never takes its identity: a silent reply (dropped from the transcript)
    ///   would otherwise hand its key, and its open folds, to the reply before it.
    private func handOverIdentity(shown: [TranscriptItem], existing: Set<String>) {
        func isPersonsMessage(_ item: TranscriptItem) -> Bool {
            if case .user(let entry) = item { entry.sender == nil && entry.routineName == nil && !entry.isSteer } else { false }
        }
        let shownIDs = Set(shown.map(\.id))
        var index = items.count - 1
        for row in shown.reversed() {
            var match: Int?
            var probe = index
            while probe >= 0 {
                let stored = items[probe]
                if existing.contains(stored.id), !shownIDs.contains(stored.id) { break }
                if case .assistant = row {
                    if case .assistant = stored { match = probe; break }
                    if isPersonsMessage(stored) { break } // no stored reply (yet): the message still matches
                } else if isPersonsMessage(stored) {
                    match = probe
                    break
                }
                probe -= 1
            }
            guard let match else { continue }
            // Handed over once, it stays: a later turn never takes a row's identity away.
            if items[match].id != row.id, rowAliases[items[match].id] == nil { rowAliases[items[match].id] = row.id }
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

    /// The images `resolveImages` would read for these rows, read off the main thread first, so
    /// building the rows finds them in memory. (Rows aren't redrawn for images that arrive later.)
    private func preloadImages(for items: [TranscriptItem]) async {
        guard let store = workspace?.imageStore, let key = stableKey else { return }
        var wanted: [(entryID: String, slots: [SentImageStore.Slot])] = []
        var occurrences: [String: Int] = [:]
        for item in items {
            guard case .user(let entry) = item, entry.imagePlaceholderCount > 0 else { continue }
            let occurrence = occurrences[entry.text, default: 0]
            occurrences[entry.text] = occurrence + 1
            guard userImages[entry.id] == nil else { continue }
            let slots = store.slots(conversation: key, text: entry.text, occurrence: occurrence)
            if !slots.isEmpty { wanted.append((entry.id, slots)) }
        }
        let files = wanted.flatMap(\.slots).compactMap { slot -> URL? in
            if case .file(_, let url) = slot { url } else { nil }
        }
        guard !files.isEmpty else { return }
        let contents = await SentImageStore.read(files)
        for (entryID, slots) in wanted where userImages[entryID] == nil {
            let images = slots.compactMap { slot -> ImageAttachment? in
                switch slot {
                case .ready(let image): image
                case .file(let id, let url): contents[url].flatMap { ImageAttachment(jpegData: $0, id: id) }
                }
            }
            if !images.isEmpty { userImages[entryID] = images }
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

    /// Reply (swipe, menu, or chosen words): the bar goes in the composer and the passage
    /// flashes for a moment where it is (`chatReplyQuote`).
    func reply(to rowID: String, author: String, passage: String) {
        let quote = QuotedReply.trimmed(passage)
        guard !quote.isEmpty else { return }
        replyingTo = ReplyTarget(author: author, quote: quote, rowID: rowID)
        flash(rowID)
    }

    /// Flashes a row (a quote's source).
    func flash(_ rowID: String) {
        flashRequest = FlashRequest(rowID: rowID, count: (flashRequest?.count ?? 0) + 1)
    }

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
            runCommand(command, argument: argument.isEmpty ? nil : argument)
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
        if let target = replyingTo {
            // The passage goes first, as a block quote (`QuotedReply`); this device remembers
            // where it came from so the bubble can say whose it was and jump back to it.
            let reply = QuotedReply(quote: QuotedReply.trimmed(target.quote), message: parts.body)
            let shift = reply.text.utf16.count - parts.body.utf16.count
            parts.references = parts.references.map { var moved = $0; moved.location += shift; return moved }
            parts.body = reply.text
            if let chat = stableKey ?? botName.map(UnreadStore.botKey) {
                QuoteMemory.remember(reply.quote, author: target.author, rowID: target.rowID, chat: chat)
            }
            replyingTo = nil
        }
        let images = attachments
        let documents = files
        draft = ""
        draftReferences = []
        attachments = []
        files = []
        skills = []
        if waitsForChat {
            // Another Hermes process holds the chat: this waits behind what already does.
            animateRows {
                queue.append(QueuedFollowUp(text: parts.body, parts: parts.hasStructure ? parts : nil, skills: parts.skills,
                                            images: images, files: documents))
            }
            return
        }
        start(text: parts.body, images: images, files: documents, skills: parts.skills, parts: parts)
        ChatSounds.play(.sent)
    }

    /// Hermes refused the message because another of its processes holds the chat (a Bot answering
    /// another Bot's message in its one-shot `hermes chat`, a routine): it takes one writer per
    /// chat (4090 `SESSION_NOT_OWNED`). The message waits at the top of Up Next, nothing lost, and
    /// goes once the chat is free: when its stored turn is seen to end, else after 30 s, 1 and
    /// 2 minutes, then every 5.
    private func waitForChat(text: String, images: [ImageAttachment], files: [FileAttachment]) {
        endDelivery()
        pendingUser = nil
        live = nil
        isStopping = false
        animateRows { queue.insert(QueuedFollowUp(text: text, images: images, files: files), at: 0) }
        waitsForChat = true
        chatWaitAttempts += 1
        let delays: [Double] = [30, 60, 120]
        retryChat(after: chatWaitAttempts <= delays.count ? delays[chatWaitAttempts - 1] : 300)
    }

    private func retryChat(after seconds: Double) {
        chatWaitRetry?.cancel()
        chatWaitRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.waitsForChat else { return }
            self.waitsForChat = false
            self.drainQueueIfIdle()
        }
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
        case "update", "restart":
            // Hermes runs /update only from messaging platforms and both are terminal commands
            // on its desktop surface, so the app starts them on the dashboard, as Settings →
            // Setup does, and the card streams their lines (`docs/setup.md` §4.2a).
            let setup = workspace?.setup
            let ref = name == "update" ? setup?.updateHermes() : setup?.restartGateway()
            let entry = CommandEntry(name: name, argument: nil, outcome: ref == nil
                ? .failed(name == "update" ? SetupCenter.needsBotModeToUpdate : SetupCenter.needsBotModeToRestart)
                : .running(nil))
            if let ref { commandJobs[entry.id] = ref }
            appendLocal(.command(entry))
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
                // Hermes reroutes some commands (goal, plan, queue, steer, retry, undo, compress,
                // skills, bundles) to command.dispatch itself and answers with its directive.
                if result["type"]?.stringValue != nil {
                    apply(directive: result, to: entry, commandLine: commandLine)
                } else {
                    finishCommand(entry, output: result["output"]?.stringValue, warning: result["warning"]?.stringValue)
                }
                return
            } catch is GatewayRPCError {
                // Older gateways refuse those with an error instead: ask command.dispatch.
            }
            var params: [String: JSONValue] = ["name": .string(entry.name), "arg": .string(entry.argument ?? ""), "session_id": .string(runtime)]
            if let gatewayProfile { params["profile"] = .string(gatewayProfile) }
            let directive = try await roster.request("command.dispatch", params, timeout: .seconds(120))
            apply(directive: directive, to: entry, commandLine: commandLine)
        } catch {
            updateCommand(entry.id) { $0.outcome = .failed((error as? GatewayRPCError)?.message ?? HermesError.botMode(error).errorDescription ?? "") }
        }
    }

    /// What a dispatched command asks for: run another command (alias), send a message (send,
    /// skill), fill the composer (prefill), or show its output (exec, plugin).
    private func apply(directive: JSONValue, to entry: CommandEntry, commandLine: String) {
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

    /// The chat's processes as the gateway lists them (`process.list`): names, folders, and the
    /// only word on exits (most processes send no event when they end).
    func refreshProcesses() async {
        // One at a time, applied in order: a look asked for meanwhile runs once this one is in.
        guard !processRefreshing else {
            processRefreshAgain = true
            return
        }
        processRefreshing = true
        defer { processRefreshing = false }
        let generation = processGeneration
        repeat {
            processRefreshAgain = false
            await listProcesses()
        } while processRefreshAgain && generation == processGeneration
        // Not after `cancelAll`: the chat is going.
        if generation == processGeneration { watchProcesses() }
    }

    private func listProcesses() async {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID,
              let result = try? await roster.request("process.list", ["session_id": .string(runtime)]),
              case .array(let rows)? = result["processes"] else { return }
        flushOutput()
        needsProcessList = false
        var tracker = processTracker
        // Names again once the Bots' names are in ("Message to Ada").
        tracker.rename(botName: { self.botTitle($0) })
        let endings = tracker.apply(list: rows, ignoring: clearedProcesses, botName: { self.botTitle($0) })
        processTracker = tracker
        workspace?.noteDeliveries(tracker.processes)
        for ending in endings where ending.state == .finished { showJustFinished(ending.id) }
        if endings.contains(where: { $0.state == .failed }) { failureFeedback() }
        publishProcesses(force: true)
    }

    /// Stops one process (`process.kill`). Never `process.stop`: that stops every process on the
    /// gateway. "Stopping…" until the list says it exited.
    func stopProcess(_ id: String) {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID, processTracker[id]?.isRunning == true else { return }
        processTracker.stopRequested(id)
        publishProcesses(force: true)
        Task {
            let result = try? await roster.request("process.kill", ["session_id": .string(runtime), "process_id": .string(id)])
            if result == nil || result?["status"]?.stringValue == "error" {
                processTracker.stopFailed(id)
                publishProcesses(force: true)
            }
            await refreshProcesses()
        }
    }

    /// The chat came on screen or left it: process exits are looked for every 5 s while it shows,
    /// every 30 s while the app is in use elsewhere (`docs/background-processes.md` §1), and a turn
    /// going on elsewhere is fetched again every 10 s while it shows.
    func screenChanged(shown: Bool) {
        isOnScreen = shown
        guard shown, processTracker.processes.contains(where: \.isRunning) else { return }
        // Back at the 5 s pace, starting with a look now.
        processWatch?.cancel()
        processWatch = nil
        watchProcesses(lookingNow: true)
    }

    private func watchProcesses(lookingNow: Bool = false) {
        guard processWatch == nil, processTracker.processes.contains(where: \.isRunning) else { return }
        processWatchID += 1
        let id = processWatchID
        processWatch = Task { [weak self] in
            var looksNow = lookingNow
            while !Task.isCancelled {
                if !looksNow {
                    let interval: Double = self?.isOnScreen == true ? 5 : 30
                    try? await Task.sleep(for: .seconds(interval))
                }
                looksNow = false
                guard let self, !Task.isCancelled else { return }
                if Self.isInUse { await self.refreshProcesses() }
                guard self.processTracker.processes.contains(where: \.isRunning) else { break }
            }
            // A newer loop may have taken over meanwhile: leave it be.
            if self?.processWatchID == id { self?.processWatch = nil }
        }
    }

    /// The app is in use (not in the background on iPhone and iPad).
    private static var isInUse: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background
        #else
        true
        #endif
    }

    /// Steps and the chip catch up: at once for a change of state, at most twice a second for
    /// output (§4).
    private func publishProcesses(force: Bool = false) {
        let wait = 0.5 - Date.now.timeIntervalSince(processesPublishedAt)
        if force || wait <= 0 {
            processesPublish?.cancel()
            processesPublish = nil
            processesPublishedAt = .now
            if processes != processTracker.processes { processes = processTracker.processes }
            updateProcessChip()
            return
        }
        guard processesPublish == nil else { return }
        processesPublish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.processesPublish = nil
            self.publishProcesses(force: true)
        }
    }

    /// A finished process holds its check in the chip for 4 s (§5).
    private func showJustFinished(_ id: String) {
        justFinishedProcess = id
        updateProcessChip()
        justFinishedReset?.cancel()
        justFinishedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ProcessChip.finishedHold))
            guard !Task.isCancelled else { return }
            self?.justFinishedProcess = nil
            self?.updateProcessChip()
        }
    }

    /// The chip changes only when what it says does, so the composer doesn't redraw for output.
    private func updateProcessChip() {
        let chip = ProcessChip(processes: processes, justFinished: justFinishedProcess)
        if chip != processChip { processChip = chip }
        let stoppable = processes.filter(\.isRunning).map { StoppableProcess(id: $0.id, name: $0.name, isStopping: $0.isStopping) }
        if stoppable != stoppableProcesses { stoppableProcesses = stoppable }
    }

    /// A process failed: a haptic, only with the chat on screen (§8).
    private func failureFeedback() {
        #if os(iOS)
        guard isOnScreen else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    /// The Terminal showed a failed process: the chip stops counting it.
    func markProcessSeen(_ id: String) {
        guard processTracker[id]?.state == .failed, processTracker[id]?.seenFailure == false else { return }
        processTracker.markSeen(id)
        publishProcesses(force: true)
    }

    /// Clear (the Terminal's Finished): gone from this device; the gateway forgets them by itself.
    func clearFinishedProcesses() {
        let finished = Set(processTracker.processes.filter { !$0.isRunning }.map(\.id))
        guard !finished.isEmpty else { return }
        clearedProcesses.formUnion(finished)
        processTracker.remove(finished)
        publishProcesses(force: true)
    }

    /// Cleared on this device, kept with the chat so they don't come back from the gateway's list.
    private var clearedProcesses: Set<String> {
        get {
            guard let key = clearedProcessesKey else { return [] }
            return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }
        set {
            guard let key = clearedProcessesKey else { return }
            UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: key)
        }
    }

    /// The chat's stable key: compression gives it a new session id.
    private var clearedProcessesKey: String? {
        (stableKey ?? sessionID).map { "processes.cleared.\($0)" }
    }

    /// The Bot a profile is ("engineer" → "Engineer"), for names like "Message to Engineer".
    func botTitle(_ profile: String) -> String? {
        (roster ?? gatewayRoster)?.bot(named: profile)?.title
    }

    /// The `terminal` or `message_agent` call that started a process (`tool.complete`): its step
    /// shows the process, and it names it ("Message to Engineer").
    private func linkStartedProcess(_ payload: JSONValue) {
        let name = payload["name"]?.stringValue ?? ""
        let result = payload["result"].map { $0.stringValue ?? $0.displayText }
        let tool = ToolActivity(id: payload["tool_id"]?.stringValue ?? UUID().uuidString, callID: payload["tool_id"]?.stringValue,
                                name: name, arguments: payload["args"], result: result, status: .succeeded)
        guard let id = tool.startedProcessID else { return }
        processTracker.link(id, turnID: live?.turn.id, toolCallID: tool.callID, name: tool.startedProcessName,
                            command: tool.startedCommand, started: true, botName: { self.botTitle($0) })
        publishProcesses(force: true)
        Task { await refreshProcesses() }
    }

    /// Processes the stored chat started: linked to their steps, and how they are now (an old
    /// chat's steps say "Ended" once the gateway no longer lists them).
    private func linkStoredProcesses() {
        var found = false
        for item in items {
            guard case .assistant(let turn) = item else { continue }
            for step in turn.steps {
                guard case .tool(let tool) = step, let id = tool.startedProcessID else { continue }
                processTracker.link(id, turnID: turn.id, toolCallID: tool.callID, name: tool.startedProcessName,
                                    command: tool.startedCommand, botName: { self.botTitle($0) })
                found = true
            }
        }
        guard found else { return }
        publishProcesses(force: true)
        guard !processTracker.hasListed else { return }
        // Asked once the chat is attached (`attachGatewayChat`), or now if it already is.
        needsProcessList = true
        if runtimeSessionID != nil { Task { await refreshProcesses() } }
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

    /// Talk: a spoken message goes like a typed one, and steers a turn that's running. Over the
    /// gateway protocol it's a voice turn (`voice`, `docs/voice.md` §4.1). Returns `false` when it
    /// couldn't go (offline); the words are then kept as the draft.
    @discardableResult
    func sendSpoken(_ text: String, voice: VoiceTurn? = nil) -> Bool {
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
        start(text: text, images: [], files: [], voice: voice)
        return true
    }

    /// A voice message (`docs/voice.md` §2): the transcript is what Hermes reads. Over the gateway
    /// protocol the recording goes with it (`file.attach`, named `voice-<uuid>.m4a`), so every
    /// device can play it; the API server has no upload, so there it's the transcript alone. While
    /// Hermes works it waits for the next turn, like any message with a file (a recording can't
    /// steer).
    func sendVoiceMessage(transcript: String, recording: URL) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var files: [FileAttachment] = []
        if usesGateway, let data = try? Data(contentsOf: recording) {
            files = [FileAttachment(name: recording.lastPathComponent, data: data)]
        } else {
            try? FileManager.default.removeItem(at: recording)
        }
        guard !text.isEmpty || !files.isEmpty else { return }
        if isWorking || isFinishing || isBotTurnOpen || waitsForChat {
            animateRows { queue.append(QueuedFollowUp(text: text, files: files)) }
            return
        }
        start(text: text, images: [], files: files)
        ChatSounds.play(.sent)
    }

    /// The reply being written right now, if a turn is running or just finished.
    var liveTurn: AssistantTurn? { liveRow }

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
        // The message before it hasn't reached Hermes yet: there's no turn to steer, so it's next.
        if delivery != nil { picked = .sendNext }
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
        if turnUsesGateway, gatewayRoster != nil {
            Task { [weak self] in
                // Mid re-attach (the socket dropped): the note goes once the chat is attached again.
                let deadline = Date.now.addingTimeInterval(40)
                while self?.runtimeSessionID == nil, self?.isWorking == true, Date.now < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self else { return }
                guard let roster = gatewayRoster, let runtime = runtimeSessionID, isWorking else {
                    missSteer(record)
                    return
                }
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
        // Still one turn on screen: its stored rows start where they did.
        if let baseline = turnBaseline { turnBaseline = (next.turn.id, baseline.newest) }
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
        // A held message waits for its Send; the ones behind it go as usual.
        guard !queuePaused, !waitsForChat, expectedFromGateway.isEmpty, let first = queue.first(where: { !$0.isHeld }), !isWorking,
              !isFinishing, !isBotTurnOpen, isReachable, sendOnLoad == nil
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
    /// A chat opened from history has no message sent since launch: its last message from the
    /// person is sent again (as text; its pictures stay with the gateway's copy).
    func retryLastMessage() {
        guard !isWorking, !isFinishing, !isBotTurnOpen else { return }
        if !lastUserText.isEmpty || !lastUserImages.isEmpty || !lastUserFiles.isEmpty {
            start(text: lastUserText, images: lastUserImages, files: lastUserFiles)
        } else if let text = lastSentText {
            start(text: text, images: [], files: [])
        }
    }

    /// The person's last message in the transcript.
    private var lastSentText: String? {
        for item in items.reversed() {
            if case .user(let entry) = item {
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : entry.text
            }
        }
        return nil
    }

    /// Add Key… on a turn whose provider refused Hermes's key: the new key goes to the gateway
    /// (`model.save_key`, Bot Mode), for this chat's Bot. The key is never kept or logged here.
    func saveProviderKey(_ key: String, for problem: ProviderProblem) async throws {
        guard let roster = gatewayRoster, roster.isConnected, let slug = problem.provider else {
            throw HermesError.invalidResponse(String(localized: "Bot Mode isn't connected, so the key can't go to \(gatewayName) from here."))
        }
        var params: [String: JSONValue] = ["slug": .string(slug), "api_key": .string(key)]
        if let profile = gatewayProfile { params["profile"] = .string(profile) }
        _ = try await roster.request("model.save_key", params, timeout: .seconds(30))
    }

    /// Sign In… on a turn whose provider's sign-in expired: Hermes's device-code sign-in in the
    /// browser (`POST /api/providers/oauth/<provider>/start`, then its poll), as the setup flow
    /// does for Nous. True once Hermes says it's approved.
    func signInToProvider(_ problem: ProviderProblem) async throws -> Bool {
        guard let roster = gatewayRoster, roster.isConnected, let provider = problem.provider else {
            throw HermesError.invalidResponse(String(localized: "Bot Mode isn't connected, so the sign-in can't start from here."))
        }
        let flow = try await roster.startProviderSignIn(provider: provider, profile: gatewayProfile)
        Task { @MainActor in _ = await BrowserSignIn.shared.open(flow.url) }
        defer { BrowserSignIn.shared.cancel() }
        for _ in 0..<120 {
            try await Task.sleep(for: .seconds(max(flow.interval, 1)))
            let status = try await roster.pollProviderSignIn(provider: provider, sessionID: flow.sessionID, profile: gatewayProfile)
            if status == "approved" { return true }
            if status != "pending" { return false }
        }
        return false
    }

    /// Whether Add Key… can reach the gateway: `model.save_key` runs over Bot Mode.
    var canSaveProviderKey: Bool { gatewayRoster?.isConnected == true }

    func dismissTurnError() {
        turnError = nil
        unconfirmed = nil
    }

    /// The transcript just loaded says how an uncertain turn really ended. A message Hermes didn't
    /// confirm keeps its card (and Send Again) until it shows up in the stored chat (`unconfirmed`).
    private func settleUncertainTurn() {
        if let unconfirmed {
            guard unconfirmed.wasStored(in: rawMessages) else { return }
            self.unconfirmed = nil
        }
        if turnError?.canRetry == false { turnError = nil }
    }

    private func start(text: String, images: [ImageAttachment], files: [FileAttachment], skills: [String] = [], prompt: String? = nil, parts: MessageParts? = nil, queued: Bool = false, voice: VoiceTurn? = nil) {
        recoveryTask?.cancel() // a new turn: whatever an earlier one left uncertain shows with it
        settleBackgroundRuns()
        hasUndoneMessage = false
        draftBeforeUndo = nil
        banner = nil
        turnError = nil
        unconfirmed = nil
        lastUserText = text
        workspace?.widgets.noteEnteredTurn(text)
        lastUserImages = images
        lastUserFiles = files
        turnSkills = skills
        turnPrompt = prompt
        turnParts = parts
        turnVoice = voice
        failureIsRetryable = true
        // A voice message's recording is its bubble, not a file chip.
        let voice = files.first { VoiceMessageFile.isVoiceMessage($0.name) }
        var entry = UserEntry(id: "local-\(UUID().uuidString)", text: text, timestamp: .now,
                              fileNames: files.map(\.name).filter { !VoiceMessageFile.isVoiceMessage($0) }, skillNames: skills)
        entry.voicePath = voice?.name
        if let parts, parts.hasStructure, parts.command == nil { entry.parts = parts }
        userImages[entry.id] = images
        armedSteers = []
        queuePaused = false
        turnQueued = queued
        animateRows {
            pendingUser = entry
            redirectedParts = []
            live = LiveTurn(id: "live-\(UUID().uuidString)", sessionID: sessionID)
            if let live { turnBaseline = (live.turn.id, newestBeforeTurn) }
            sentTurns += 1
        }
        beginDelivery(QueuedFollowUp(text: text, parts: parts?.hasStructure == true ? parts : nil, skills: skills, images: images, files: files))
        turnGate = TurnSettleGate()
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

        let input: String
        do {
            input = try Self.inlined(text, files: files)
        } catch {
            restoreDraft(text: text, images: images, files: files, error: error)
            return
        }
        // A busy or away gateway makes the message wait, not fail: the session and the run are
        // asked for again until it answers, the run under one `Idempotency-Key`, so it starts once
        // (`SendFailure.overHTTP`). A picture goes over a stream Hermes doesn't dedupe: not again.
        let idempotencyKey = UUID().uuidString
        // The same body each time: Hermes dedupes on the key and the body together.
        let runModel = model
        let runEffort = reasoningEffort
        var attempt = 0
        var remembered = false
        do {
            while true {
                do {
                    let sessionID = try await ensureSession(client: client, workspace: workspace)
                    if !remembered, !images.isEmpty, let key = stableKey {
                        workspace.imageStore.remember(images, conversation: key, text: text)
                        remembered = true
                    }
                    if images.isEmpty {
                        let runID = try await client.startRun(
                            sessionID: sessionID,
                            input: input,
                            model: runModel,
                            reasoningEffort: runEffort,
                            idempotencyKey: idempotencyKey
                        )
                        endDelivery()
                        apply(.runStarted(runID: runID))
                        try await follow(runID: runID, client: client)
                    } else {
                        try await streamChat(sessionID: sessionID, text: input, images: images, client: client)
                    }
                    break
                } catch where live?.runID == nil && images.isEmpty && !Task.isCancelled && SendFailure.overHTTP(error) == .sendAgain
                    // A new chat's session isn't deduped: only one that never left goes again.
                    && (sessionID != nil || SendFailure.neverLeft(error)) {
                    attempt += 1
                    markWaiting()
                    try await Task.sleep(for: SendFailure.pause(before: attempt))
                }
            }
        } catch {
            if live?.runID == nil, SendFailure.overHTTP(error) != .mayHaveArrived {
                // Nothing started on the server; give the message back to the composer.
                restoreDraft(text: text, images: images, files: files, error: error)
                return
            }
            if error is CancellationError {
                live?.markStopped()
            } else if live?.runID == nil {
                // Hermes had a send with this key already: the chat says how it went, never a retry.
                failureIsRetryable = false
                live?.markFailed(String(localized: "Couldn't tell whether Hermes got this message. Reload to see."))
            } else {
                live?.markFailed((error as? HermesError)?.errorDescription ?? error.localizedDescription)
            }
        }
        endDelivery() // a stream that ended with no event never said
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
                endDelivery()
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

    /// A turn kept as still working after it ended with nothing in it (`finishTurn`): the chat is
    /// read again every 5 s until the stored reply takes its place. After 3 minutes without one,
    /// it says so, with Reload, and keeps looking a while longer (`recoverSoon`).
    private func awaitStoredReply() {
        storedReplyWait?.cancel()
        storedReplyWait = Task { [weak self] in
            for _ in 0..<36 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                // Handed over, or a turn runs here again (it took the waiting turn's place).
                guard self.heldOver != nil, self.live == nil else { return }
                if !self.isFetching, !self.isFinishing { self.reload() }
            }
            guard let self, !Task.isCancelled, self.heldOver != nil, self.live == nil else { return }
            self.stopWaitingForReply()
        }
    }

    private func stopWaitingForReply() {
        guard let held = heldOver, case .assistant(var turn)? = held.shown.last, turn.isWorking else { return }
        let message = String(localized: "Hermes hasn't answered this here yet. Reload to see whether it has.")
        turn.state = .failed(message)
        turn.finishedAt = .now
        heldOver = (Array(held.shown.dropLast()) + [.assistant(turn)], held.after)
        if let index = items.lastIndex(where: { $0.id == turn.id }) { items[index] = .assistant(turn) }
        failureIsRetryable = false
        turnError = TurnFailure(message: message, canRetry: false)
        recoverSoon()
    }

    /// A turn kept as still working gives its place to the turn now running here: the same one,
    /// come back, or the next.
    private func dropWaitingTurn() {
        storedReplyWait?.cancel()
        guard let held = heldOver, case .assistant(let turn)? = held.shown.last, turn.isWorking else { return }
        items.removeAll { $0.id == turn.id }
        heldOver = (Array(held.shown.dropLast()), held.after)
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
        // The card is the step: the widget tool's own steps never show (`docs/widgets.md` §2).
        if widgetToolEvent(event) { return }
        trackSteers(event)
        applyToLive(SequencedTurnEvent(seq: seq, event: event))
    }

    /// Streamed words go into the turn at once, but the transcript hears of them at most 15 times
    /// a second: a reply streams in tens of pieces a second, and redrawing it for each one was a
    /// tenth of the Mac's main thread while it wrote (`docs/chat.md` §3). The new words fade in
    /// along the line either way. Anything else that changes the turn redraws it at once.
    private func applyToLive(_ event: SequencedTurnEvent) {
        guard case .textDelta = event.event, liveStorage?.turn.state == .streaming else {
            live?.apply(event)
            return
        }
        liveStorage?.apply(event)
        liveVersion &+= 1
        syncDerivedState()
        guard wordsRedraw == nil else { return }
        wordsRedraw = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(66))
            guard let self, !Task.isCancelled else { return }
            wordsRedraw = nil
            withMutation(keyPath: \.live) {}
        }
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
            turnError = TurnFailure(message: message, canRetry: failureIsRetryable, provider: finished.turn.providerProblem)
        }
        let stoppedByUser = wasStopping || finished.turn.state == .stopped
        let waitsForReply = !stoppedByUser && finished.turn.endedEmpty
        heldOver = nil // a turn before this one that never got its stored rows: too late to match
        storedReplyWait?.cancel()
        // What was on screen, in order, to hand its identities to the stored rows.
        let shownRows = (pendingUser.map { [TranscriptItem.user($0)] } ?? []) + redirectedParts + [.assistant(finished.turn)]
        // Hermes can write the turn's rows a moment after it says the turn ended. A transcript
        // without them would swap your message for its stored copy as a new row (it left and came
        // back) and drop the reply: ask again for up to about 2 s, then keep what's on screen.
        let newestBefore = turnBaseline?.turnID == finished.turn.id ? turnBaseline?.newest : newestBeforeTurn
        turnBaseline = nil
        var transcript: SessionTranscript?
        // Folded off the main thread, the reply's Markdown parsed ahead: the swap below is then
        // only the swap, not a whole chat built in one frame as the reply ends.
        var prepared: (messages: [SessionMessage], items: [TranscriptItem])?
        if let sessionID {
            for wait in [0, 500, 1500] {
                if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
                guard live?.turn.id == finished.turn.id else { return }
                // Fetch in an unstructured task: a turn that ended by cancellation must still reconcile.
                guard let fetched = try? await Task(operation: { try await fetch(sessionID) }).value else { continue }
                guard TranscriptBuilder.holdsTurn(fetched.messages, after: newestBefore, stopped: stoppedByUser) else { continue }
                transcript = fetched
                if live?.turn.id == finished.turn.id, let merged = merge(fetched) {
                    let generation = rowsGeneration
                    let items = await Self.prepare(merged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil)
                    await preloadImages(for: items)
                    // A page loaded above meanwhile: put this page after it rather than drop it.
                    if generation == rowsGeneration {
                        prepared = (merged, items)
                    } else if let remerged = merge(fetched) {
                        prepared = (remerged, await Self.prepare(remerged, hasEarlier: hasEarlierMessages, hidesSilence: botName != nil))
                    }
                }
                break
            }
        }
        guard live?.turn.id == finished.turn.id else { return }
        // The stored rows take over from the live ones in place (same identities), in one
        // animated step: the reply's actions fade in where it ends instead of shoving it up.
        animateRows {
            if transcript != nil {
                // What was on screen before the stored rows came: older rows, never this turn's.
                var existing: Set<String> = []
                if let prepared {
                    existing = Set(items.map(\.id))
                    rebuild(from: prepared.messages, built: prepared.items)
                    saveCache()
                }
                handOverIdentity(shown: shownRows, existing: existing)
                needsReconcile = false
                carryOverExtras(from: finished.turn)
                if finished.turn.state == .stopped {
                    markLastTurnStopped()
                }
            } else {
                // Couldn't reach the server, or it hasn't written the turn yet: keep what streamed
                // in, and reload when we can. A turn that ended with nothing in it stays a turn
                // still working, never an empty space under the message, until its stored reply
                // takes its place (`awaitStoredReply`).
                var held = shownRows
                if waitsForReply, let last = held.indices.last, case .assistant(var turn) = held[last] {
                    turn.state = .streaming
                    turn.finishedAt = nil
                    held[last] = .assistant(turn)
                }
                items += held
                needsReconcile = true
                heldOver = (held, newestBefore)
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
        if workspace?.currentConversation === self { ChatSounds.play(.received) }
        LoadTrace.mark(stableKey ?? "?", "turn end: \(shownRows.filter { id in items.contains { displayID(for: $0) == id.id } }.count)/\(shownRows.count) rows kept their identity\(transcript == nil ? ", held for a later load" : "")")
        if transcript == nil, sessionID != nil {
            if waitsForReply {
                awaitStoredReply()
            } else {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.needsReconcile, !self.isWorking, !self.isFinishing else { return }
                    self.reload()
                }
            }
        }
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
              case .assistant(let turn) = items[index]
        else { return }
        var overlay = turnOverlays[turn.id] ?? TurnOverlay()
        if overlay.plan.isEmpty { overlay.plan = live.plan }
        overlay.usage = overlay.usage ?? live.usage
        overlay.models = overlay.models ?? live.models
        // A warning comes as the agent starts: it goes on the turn's first part when a steer split it.
        if let warning = live.warning, let first = firstPartOfLastTurn(), first != index,
           case .assistant(let opening) = items[first] {
            turnOverlays[opening.id, default: TurnOverlay()].warning = warning
        } else {
            overlay.warning = overlay.warning ?? live.warning
        }
        turnOverlays[turn.id] = overlay
        for step in live.steps {
            guard case .tool(let tool) = step, let id = tool.callID,
                  tool.diff != nil || tool.output != nil || tool.risk != nil else { continue }
            if toolOverlays[id] == nil { toolOverlayOrder.append(id) }
            let output = tool.output.map { $0.utf8.count > Self.maxOverlayOutput ? String($0.suffix(Self.maxOverlayOutput)) : $0 }
            toolOverlays[id] = ToolOverlay(diff: tool.diff, output: output, risk: tool.risk)
        }
        if toolOverlayOrder.count > Self.maxToolOverlays {
            for id in toolOverlayOrder.prefix(toolOverlayOrder.count - Self.maxToolOverlays) { toolOverlays[id] = nil }
            toolOverlayOrder.removeFirst(toolOverlayOrder.count - Self.maxToolOverlays)
        }
        applyOverlays()
    }

    /// Puts what only live turns knew back on the stored rows (`turnOverlays`, `toolOverlays`).
    private func applyOverlays() {
        guard !turnOverlays.isEmpty || !toolOverlays.isEmpty else { return }
        // Changed rows go in at once: each write to `items` works out everything derived from it.
        var updated = items
        var changed = false
        for index in updated.indices {
            guard case .assistant(var turn) = updated[index] else { continue }
            let original = turn
            if let overlay = turnOverlays[turn.id] {
                if turn.plan.isEmpty { turn.plan = overlay.plan }
                turn.usage = turn.usage ?? overlay.usage
                turn.models = turn.models ?? overlay.models
                turn.warning = turn.warning ?? overlay.warning
                if overlay.stopped {
                    turn.state = .stopped
                    turn.steps = turn.steps.map { step in
                        guard case .tool(var tool) = step, tool.result == nil else { return step }
                        tool.status = .failed
                        return .tool(tool)
                    }
                }
            }
            let overlaid = !toolOverlays.isEmpty && turn.steps.contains { step in
                if case .tool(let tool) = step, let id = tool.callID { toolOverlays[id] != nil } else { false }
            }
            if overlaid {
                turn.steps = turn.steps.map { step in
                    guard case .tool(var tool) = step, let id = tool.callID, let overlay = toolOverlays[id] else { return step }
                    tool.diff = tool.diff ?? overlay.diff
                    tool.output = tool.output ?? overlay.output
                    tool.risk = tool.risk ?? overlay.risk
                    return .tool(tool)
                }
            }
            if turn != original {
                updated[index] = .assistant(turn)
                changed = true
            }
        }
        if changed { items = updated }
    }

    /// The stored transcript can't say a turn was stopped; carry that over from the live turn,
    /// along with which tool call was cut off.
    private func markLastTurnStopped() {
        guard let index = items.lastIndex(where: { if case .assistant = $0 { true } else { false } }),
              case .assistant(let turn) = items[index],
              !items[index...].contains(where: { if case .user = $0 { true } else { false } })
        else { return }
        turnOverlays[turn.id, default: TurnOverlay()].stopped = true
        applyOverlays()
    }

    // MARK: Delivery (docs/chat.md §4)

    /// The message just shown sets off (`delivery`). A quick gateway takes it before anything
    /// shows; after half a second it says "Sending…" (a big upload to a healthy Mac stays there),
    /// and "Waiting for <Mac>…" once the gateway is away or busy, or 10 s have gone without it.
    private func beginDelivery(_ message: QueuedFollowUp) {
        deliveryWatch?.cancel()
        delivery = .sending
        outgoing = OutboxItem(message: message, sentAt: .now, knownNewestID: rawMessages.last?.id)
        deliveryWatch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.delivery == .sending else { return }
            self.deliveryNote = .sending
            var waited = 0.5
            while !Task.isCancelled, self.delivery == .sending {
                if self.gatewayAwayOrBusy || waited >= 10 {
                    self.markWaiting()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                waited += 1
            }
        }
    }

    /// The gateway this message goes to can't take it now: its socket is away, or it's busy.
    private var gatewayAwayOrBusy: Bool {
        if turnUsesGateway, let roster = gatewayRoster {
            return !roster.isConnected || roster.isBusy || workspace?.isBusy == true
        }
        return workspace?.isBusy == true || workspace?.connection.isFailed == true
    }

    /// Hermes can't take it yet: the gateway is busy, or away. Kept on the device from now on, so
    /// quitting the app loses nothing (`settleOutbox` looks for it after a relaunch).
    private func markWaiting() {
        guard delivery != nil, delivery != .waiting else { return }
        delivery = .waiting
        deliveryNote = .waiting
        saveOutbox()
        ConnectionLog.logger.notice("chat: a message waits for the gateway (away: \(self.gatewayRoster.map { !$0.isConnected } ?? false, privacy: .public), busy: \(self.gatewayAwayOrBusy, privacy: .public))")
    }

    /// Hermes has the message (`prompt.submit` answered, the run started, its turn's first event),
    /// or it went back to the person or the queue: either way it's no longer on its way.
    private func endDelivery() {
        guard delivery != nil || outgoing != nil else { return }
        deliveryWatch?.cancel()
        deliveryWatch = nil
        let wasKept = delivery == .waiting
        if let outgoing {
            ConnectionLog.logger.notice("chat: a message's delivery ended after \(Int(Date.now.timeIntervalSince(outgoing.sentAt) * 1000))ms\(wasKept ? ", having waited" : "", privacy: .public)")
        }
        delivery = nil
        deliveryNote = nil
        outgoing = nil
        if wasKept { saveOutbox() }
    }

    private func saveOutbox() {
        guard let queueKey else { return }
        FollowUpQueueStore.saveOutbox(keptFromBefore + (delivery == .waiting ? outgoing.map { [$0] } ?? [] : []), key: queueKey)
    }

    /// After a relaunch, messages the last run kept and never saw taken are looked for in the
    /// stored chat (`SubmitCheck`). One that's there arrived; one that isn't goes to the top of Up
    /// Next, held (`QueuedFollowUp.isHeld`) for the person to send or delete. Never sent again by
    /// itself: Hermes may have it stored in another form (mentions, files, skills), or later.
    private func settleOutbox() {
        guard !keptFromBefore.isEmpty else { return }
        let kept = keptFromBefore
        keptFromBefore = []
        let missing = kept.filter { item in
            !SubmitCheck.arrived(item.message.text, sentAt: item.sentAt, knownNewestID: item.knownNewestID, in: rawMessages)
        }
        if !missing.isEmpty {
            animateRows {
                queue.insert(contentsOf: missing.map { item in
                    var held = item.message
                    held.isHeld = true
                    return held
                }, at: 0)
            }
            ConnectionLog.logger.notice("chat: \(missing.count) message(s) kept from before a relaunch weren't in the chat; held in Up Next")
        }
        saveOutbox()
    }

    private func restoreDraft(text: String, images: [ImageAttachment], files: [FileAttachment], error: any Error) {
        endDelivery()
        pendingUser = nil
        live = nil
        isStopping = false
        if draft.isEmpty, attachments.isEmpty, self.files.isEmpty {
            draft = text
            attachments = images
            self.files = files
        } else {
            // Something new is in the field (typed while it waited): the message goes to the top
            // of Up Next, held for a Send, rather than being lost.
            animateRows { queue.insert(QueuedFollowUp(text: text, images: images, files: files, isHeld: true), at: 0) }
        }
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
        // The prompt already left: it may be with Hermes, so the turn is stopped there; the bubble
        // no longer says it waits. (Before it left, Stop gives the message back: `restoreDraft`.)
        if turnGate.sent || live.runID != nil { endDelivery() }
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
        // A card fill is answered once or not at all: Hermes remembers nothing for cards, and no
        // card offers more (`docs/web.md` §4).
        if approval.isPaymentFill, choice == .session || choice == .always { return }
        WelcomeProgress.shared.mark(.runCommand)
        if !quietly { addApprovalReceipt(for: approval, choice: choice) }
        defer { showNextApproval() }
        if approval.gatewayRequestID != nil {
            respondInBotChat(to: approval, with: choice)
            return
        }
        guard let runID = live?.runID, let client = workspace?.client else { return }
        apply(.approvalResolved(requestID: approval.requestID))
        Task {
            // A busy or unreachable gateway gets the answer when it can: asked again for up to four
            // minutes (Hermes waits five for it). A repeat that lands after the first is a 409.
            let began = Date.now
            for attempt in 0... {
                do {
                    try await client.respondToApproval(runID: runID, requestID: approval.requestID, choice: choice)
                    return
                } catch HermesError.server(409, _, _) {
                    // Already answered, timed out (a deny) or the run ended: nothing is waiting.
                    return
                } catch let error as HermesError where error.isTransient && Date.now.timeIntervalSince(began) < 240 && self.live?.runID == runID {
                    try? await Task.sleep(for: .seconds(min(30, 2 << min(attempt, 4))))
                } catch {
                    banner = error as? HermesError
                    if self.live?.runID == runID, self.isWorking {
                        self.apply(.approvalRequested(approval))
                    }
                    return
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

    /// A background push said this chat changed (`sync`): its stored rows are read now and kept on
    /// the device, so it shows as it is when the person comes back. Only read: attaching it would
    /// bring the socket back in the background. Returns once read.
    func readForSync() async {
        guard !isWorking, !isFinishing, sessionID != nil || isBotChat else { return }
        if !isFetching { reload(attaching: false) }
        await loadTask?.value
    }

    /// Back from the background: what happened meanwhile is read now, over HTTP, while the socket
    /// is still coming back (a connect, the Bots and a re-attach take seconds on a busy Mac).
    func catchUpOnReturn() {
        guard loadState == .loaded, sessionID != nil || isBotChat, isQuiet, !isFetching else { return }
        if let lastFetchedAt, Date.now.timeIntervalSince(lastFetchedAt) < 3 { return }
        reload()
    }

    func cancelAll() {
        deliveryWatch?.cancel()
        turnTask?.cancel()
        loadTask?.cancel()
        storedReplyWait?.cancel()
        reattachTask?.cancel()
        recoveryTask?.cancel()
        subscription?.cancel()
        backoff?.cancel()
        settleFallback?.cancel()
        processWatch?.cancel()
        processWatch = nil
        processGeneration += 1
        midTurnWatch?.cancel()
        notifiedCatchUp?.cancel()
        quietRetry?.cancel()
        chatWaitRetry?.cancel()
        processesPublish?.cancel()
        justFinishedReset?.cancel()
        outputFlush?.cancel()
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

    fileprivate func reloadBotChat(attaching: Bool = true) {
        guard let roster, let botName else { return }
        LoadTrace.begin(stableKey ?? "?", "bot reload (connected: \(roster.isConnected))")
        loadTask?.cancel()
        fetchAgain = false
        let opening = items.isEmpty
        if opening { loadState = .loading }
        let connected = roster.isConnected
        if !connected {
            roster.retryNow() // Reload means now, not after the backoff; the roster calls back once online
            // The stored chat is read all the same: it's plain HTTP, which a busy Mac answers long
            // before it gives a socket. Attaching waits for the roster's call back.
            guard opening || sessionID != nil || roster.bot(named: botName)?.canonicalSession != nil else { return }
        }
        let token = UUID()
        fetchToken = token
        loadTask = Task {
            defer { if fetchToken == token { fetchToken = nil } }
            // The kept copy goes up while the gateway's is asked for (`reload`).
            let kept = opening ? await keptTranscript() : nil
            async let shown: Void = opening ? showKept(kept) : ()
            do {
                let stored: String?
                if !roster.isConnected, roster.bot(named: botName)?.canonicalSession == nil {
                    // Opened before the roster came (a launch, from the device): the id the chat
                    // had, else the kept copy's. Without either, the roster calls back once online.
                    stored = sessionID ?? kept?.sessionID
                    guard stored != nil else {
                        await shown
                        return
                    }
                } else {
                    stored = try await roster.resolveBotChat(botName)
                }
                LoadTrace.mark(stableKey, "resolved \(stored ?? "nil")")
                if let stored {
                    if sessionID != stored {
                        sessionID = stored
                    }
                    let page = try await fetchLatest(stored, holding: kept?.messages)
                    await shown
                    let transcript = try await latest(page, overKept: kept, id: stored)
                    LoadTrace.mark(stableKey, "fetched \(transcript.messages.count) rows")
                    guard !Task.isCancelled else { return }
                    guard !isWorking, !isFinishing else {
                        await showHistoryUnderTurn(transcript)
                        return
                    }
                    await applyLoaded(transcript)
                    LoadTrace.mark(stableKey, "applied \(items.count) items")
                }
                await shown
                let bot = roster.bot(named: botName)
                seenActivity = bot?.activitySession?.lastActive
                seenChat = bot?.canonicalSession.map(BotChatMark.init)
                loadState = .loaded
                if stored != nil { settleOutbox() }
                quietRetries = 0
                needsReconcile = false
                settleUncertainTurn()
                if attaching, sessionID != nil, runtimeSessionID == nil, roster.isConnected {
                    _ = await attachGatewayChat()
                    LoadTrace.mark(stableKey, "attached")
                }
                if fetchAgain, !Task.isCancelled { reload() }
            } catch is CancellationError {
            } catch {
                // Offline: what the device kept stays up, and the roster reloads once it's back.
                await shown
                guard !Task.isCancelled, connected || roster.isConnected else { return }
                if retriesQuietly(after: error) { return }
                if items.isEmpty {
                    loadState = .failed(HermesError.botMode(error))
                } else {
                    banner = HermesError.botMode(error)
                }
            }
        }
    }

    /// Attaches this chat for a send. Hermes refuses a resume for a moment after a socket dropped
    /// mid-turn (4009 while that turn settles, 4007 once it's gone): a few quick tries over about
    /// 6 s while connected, then the send fails and its draft comes back.
    private func attachForSend() async throws -> String {
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            let began = Date.now
            if await attachGatewayChat(patient: true) != nil, let runtimeSessionID { return runtimeSessionID }
            // A slow refusal is a busy gateway, not a settling turn: trying again would only wait longer.
            guard gatewayRoster?.isConnected == true, Date.now.timeIntervalSince(began) < 5 else { break }
        }
        // Without a socket the send waits for one and goes again (`runGatewayTurn`); one that's
        // there and keeps refusing gives the message back.
        guard gatewayRoster?.isConnected == true else { throw GatewaySocket.Failure.notConnected }
        throw GatewayRPCError(code: -1, message: String(localized: "Hermes wouldn't open this chat just now. Try again in a moment."))
    }

    /// `session.resume`: registers this chat on the socket so its events reach us.
    /// Returns whether a turn is running on the backend, or `nil` if it failed.
    @discardableResult
    /// - Parameter patient: for a send, waits as long as an open socket does for a frozen backend
    ///   (`BotRoster.patientTimeout`): the person's message goes when Hermes wakes, not into an error.
    fileprivate func attachGatewayChat(patient: Bool = false) async -> Bool? {
        guard let roster = gatewayRoster, let stored = sessionID else { return nil }
        var params: [String: JSONValue] = ["session_id": .string(stored), "omit_messages": .bool(true)]
        if let profile = gatewayProfile { params["profile"] = .string(profile) }
        // As the desktop platform, so Hermes can open and use the Inspector (`desktop_ui`). The
        // stored row keeps its own source; Bot chats keep theirs.
        if !isBotChat { params["source"] = .string(PreviewBridge.sessionSource) }
        do {
            let snapshot = try await roster.request("session.resume", params, timeout: patient ? BotRoster.patientTimeout : .seconds(45))
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
            attachedTurnStartedAt = running ? HermesDate.fromEpoch(snapshot["turn_started_at"]?.doubleValue) : nil
            let inflight = running ? InflightTurn(snapshot: snapshot) : nil
            if running, live == nil {
                // Stored partway (Hermes stores as it goes): the stored part is this turn's when
                // its message is, and carries on live.
                beginRemoteTurn(startedAt: inflight?.startedAt, continuingStored: inflight?.isStored(in: items) ?? true)
            }
            if let inflight { adopt(inflight) }
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
            // Cards answered on another device, or past their deadline, while this one was away.
            if let open = RequestSync.openIDs(snapshot["open_requests"]) { takeDownEndedRequests(open: open) }
            if case .array(let requests)? = snapshot["open_requests"] {
                settleAnswers(open: requests.compactMap { $0["id"]?.stringValue }, roster: roster)
                for request in requests {
                    guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { continue }
                    // Answered here already (it goes again above): no card to answer twice.
                    guard !answers.holds(id) else { continue }
                    let serverRequest = GatewayServerRequest(id: id, method: method, params: request["params"] ?? .object([:]))
                    if let approval = GatewayTurnDecoder.approval(from: serverRequest) {
                        receive(approval)
                    } else if let other = HermesRequest.parse(serverRequest) {
                        receive(other)
                    }
                }
            }
            // The stored chat started processes: how they are now (an old chat's say "Ended").
            if needsProcessList { Task { await refreshProcesses() } }
            return running
        } catch {
            return nil
        }
    }

    /// The chat's runtime id, resuming the Bot Chat or creating it on first use.
    /// A session in this chat's profile, for commands the gateway scopes by session (`/memory`).
    func runtimeForCommands() async throws -> String {
        try await ensureRuntime()
    }

    /// What the memory tool saved or updated in this chat ("New in this chat" in Memory).
    var memorySaves: [String] {
        rows.flatMap { item -> [String] in
            guard case .assistant(let turn) = item else { return [] }
            return turn.memoryChanges.filter { $0.kind == .saved || $0.kind == .updated }.map(\.text)
        }
    }

    private func ensureRuntime() async throws -> String {
        if let runtimeSessionID { return runtimeSessionID }
        guard let botName else { return try await ensureChatRuntime() }
        guard let roster else { throw GatewaySocket.Failure.notConnected }
        if sessionID == nil {
            // Fails closed: a lookup error must never mint a second Bot Chat.
            sessionID = try await roster.resolveBotChat(botName)
        }
        if sessionID != nil {
            return try await attachForSend()
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
        var submitted: SentPrompt?
        var tries = 0
        // Until Hermes has the message, a busy or away gateway makes it wait, not fail: with no
        // socket it waits for the Bots (for as long as it takes; Stop gives it back) and goes again.
        // Nothing can run twice: it goes again only when the prompt never left (`SendFailure`).
        sending: while true {
            submitted = nil
            turnGate = TurnSettleGate()
            do {
                if !roster.isConnected {
                    markWaiting()
                    // A new socket when it's back: the chat attaches to it afresh.
                    runtimeSessionID = nil
                }
                guard await roster.untilConnected() else { throw CancellationError() }
                var runtime = try await ensureRuntime()
                if isBotChat, ["/new", "/reset", "/compact", "/compress"].contains(command) {
                    endDelivery()
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
                await markForWidgets(runtime: runtime, roster: roster)
                turnGate.send()
                submitted = SentPrompt(at: .now, knownNewestID: rawMessages.last?.id)
                var submit: [String: JSONValue] = ["session_id": .string(runtime), "text": .string(prompt)]
                if turnQueued { submit["queued"] = .bool(true) } // a queued message never becomes a steer
                if let voice = turnVoice { submit.merge(voice.submitParams) { $1 } }
                // Patient: on an open socket the answer comes when a frozen backend wakes; a socket that
                // dies fails it at once.
                var answer: JSONValue
                do {
                    answer = try await roster.request("prompt.submit", submit, timeout: BotRoster.patientTimeout)
                } catch let error as GatewayRPCError where error.isSessionNotFound {
                    // The backend forgot this runtime id (a restart); resume and send again.
                    runtimeSessionID = nil
                    runtime = try await ensureRuntime()
                    submit["session_id"] = .string(runtime)
                    answer = try await roster.request("prompt.submit", submit, timeout: BotRoster.patientTimeout)
                }
                endDelivery()
                if turnVoice != nil {
                    // Spoken turns are marked in the chat (`docs/voice.md` §4.3), by the row Hermes stored.
                    SpokenMessages.shared.markSent(localID: pendingUser?.id, rowID: answer["user_row_id"]?.truncatedIntValue, session: sessionID)
                }
                chatWaitAttempts = 0
                turnGate.take()
                if live?.runID == nil { apply(.runStarted(runID: runtime)) }
                break sending
            } catch {
                // Nothing reached Hermes (no socket, or one gone before the prompt left): a Bot's chat
                // waits for its Bots and sends again; a normal chat goes over the API server below.
                let failure = SendFailure.overSocket(error)
                if isBotChat, !Task.isCancelled, live?.runID == nil, (submitted == nil && failure != .refused) || failure == .notSent {
                    runtimeSessionID = nil
                    tries += 1
                    // "Reconnect to continue": this socket's backend is retiring.
                    if (error as? GatewayRPCError)?.code == 5035 { await roster.reconnectNow() }
                    // With a socket there, a pause before the next try: never a spin.
                    if roster.isConnected { try? await Task.sleep(for: SendFailure.pause(before: tries)) }
                    continue sending
                }
                // The message went out and the answer never came (the socket closed, or the answer was
                // too late): it may be with Hermes already. Sending it again, by hand or over the API
                // server, ran it twice (three "ok"s on 2026-10-15), so what became of it is asked first.
                if let submitted, Self.mayHaveArrived(error) {
                    let arrival = await arrival(of: submitted)
                    ConnectionLog.logger.notice("chat: a send's answer was lost (\(BotRoster.describe(error), privacy: .public)); it \(String(describing: arrival), privacy: .public)")
                    endDelivery()
                    switch arrival {
                    case .running:
                        // Attached again: the turn running is this message's.
                        turnGate.take()
                        if live?.runID == nil, let runtime = runtimeSessionID { apply(.runStarted(runID: runtime)) }
                        await waitForBotTurn()
                        await finishBotTurn()
                        return
                    case .answered:
                        // Done already: the stored chat has it, and its reply.
                        if live?.isFinished == false { apply(.completed(output: nil, usage: nil, runtime: nil)) }
                        await finishBotTurn()
                        return
                    case .unfollowed:
                        // Its turn may still be running where this chat can't follow it: the card offers
                        // a reload, not a retry, and the chat reloads by itself until it's attached again.
                        failureIsRetryable = false
                        live?.markFailed(String(localized: "Couldn't reconnect to this chat. Reload to see how it ended."))
                        await finishBotTurn()
                        recoverSoon()
                        return
                    case .unknown:
                        // Hermes may still take it, so it isn't sent again by itself: the card says so
                        // and offers Send Again, and goes once the message shows up (`unconfirmed`).
                        failureIsRetryable = false
                        live?.markFailed(String(localized: "Couldn't tell whether Hermes got this message. It may still show up; if it doesn't, send it again."))
                        await finishBotTurn()
                        unconfirmed = LostPrompt(knownNewestID: submitted.knownNewestID, sentAt: submitted.at)
                        turnError?.mayResend = true
                        recoverSoon()
                        return
                    }
                }
                if let refusal = error as? GatewayRPCError, refusal.isHeldElsewhere, live?.runID == nil,
                   !(live?.turn.steps.isEmpty == false) {
                    // Never around the hold (the API server would make a second writer): it waits.
                    isBotTurnOpen = false
                    waitForChat(text: text, images: images, files: files)
                    return
                }
                if !isBotChat, submitted == nil || error is GatewayRPCError || error is GatewaySocket.Failure {
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
                endDelivery()
                break sending
            }
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
        if workspace?.currentConversation === self { ChatSounds.play(.received) }
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
        endDelivery()
        if roster != nil || workspace?.client != nil || gatewayRoster != nil {
            await finishTurn { try await self.fetchLatest($0) }
        }
    }

    /// A normal chat's runtime id over the gateway: resume its stored session, or create one
    /// (with this chat's model and effort) and file it in the sidebar.
    private func ensureChatRuntime() async throws -> String {
        guard let roster = gatewayRoster else { throw GatewaySocket.Failure.notConnected }
        if sessionID != nil {
            return try await attachForSend()
        }
        var params: [String: JSONValue] = [
            // The desktop platform: Hermes gets its Inspector tools (`docs/inspector.md` §2).
            "source": .string(PreviewBridge.sessionSource),
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
        if let workspace { inspectorStore?.restore(chatKey: stored, workspaceID: workspace.id) }
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
        var applied = wanted
        if let model, model != previous?.model {
            let result = try? await roster.request("config.set", [
                "session_id": .string(runtime), "key": .string("model"),
                "value": .string("\(model.model) --provider \(model.provider)"),
            ])
            if result?["confirm_required"]?.boolValue == true {
                // Hermes held the switch back (an expensive model): this message goes with the model
                // the chat had, and the person decides about the new one.
                let message = result?["confirm_message"]?.stringValue ?? result?["warning"]?.stringValue ?? ""
                modelConfirmation = ModelConfirmation(selection: model, message: message)
                self.model = previous?.model
                applied.model = previous?.model
            }
        }
        if let reasoningEffort, reasoningEffort != previous?.effort {
            _ = try? await roster.request("config.set", [
                "session_id": .string(runtime), "key": .string("reasoning"), "value": .string(reasoningEffort.rawValue),
            ])
        }
        appliedRunSettings = applied
    }

    /// The person confirmed the model Hermes asked about: switch for the next message.
    func confirmModel(_ confirmation: ModelConfirmation) {
        modelConfirmation = nil
        model = confirmation.selection
        guard let runtime = runtimeSessionID, let roster = gatewayRoster else { return }
        Task {
            let result = try? await roster.request("config.set", [
                "session_id": .string(runtime), "key": .string("model"),
                "value": .string("\(confirmation.selection.model) --provider \(confirmation.selection.provider)"),
                "confirm_expensive_model": .bool(true),
            ])
            if result != nil { appliedRunSettings = RunSettings(model: confirmation.selection, effort: appliedRunSettings?.effort) }
        }
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
        // A widget was made or updated: its payload rides in the result (`docs/widgets.md` §2).
        if event.type == "tool.complete", event.payload["name"]?.stringValue == WidgetToolResult.widgetTool {
            receiveWidgetResult(event.payload["result"])
        }
        // A background process started: its step shows it.
        if event.type == "tool.complete", ["terminal", "message_agent"].contains(event.payload["name"]?.stringValue ?? "") {
            linkStartedProcess(event.payload)
        }
        // A file changed: localhost Previews reload, open files and Changes catch up.
        if event.type == "tool.complete", let raw = event.payload["inline_diff"]?.stringValue, let diff = InlineDiff.unified(raw) {
            inspectorStore?.filesChanged(paths: Self.diffPaths(diff))
        }
        // Hermes tells no one else when a device answers a request: while a card is up and the
        // chat moves on, ask which requests it still waits on (`RequestSync`).
        if !shownRequestCards.isEmpty, !["request.cancel", "connection.request", "connection.update"].contains(event.type) {
            scheduleRequestSync()
        }
        switch event.type {
        case "request.cancel":
            let id = event.payload["id"]?.stringValue
            // Only withdrawing the approval on the card clears it (the turn reads that as answered);
            // a withdrawn one still waiting its turn just leaves the queue.
            let isShownApproval = event.payload["method"]?.stringValue == "approval" && id != nil && pendingApproval?.gatewayRequestID == id
            withdrawRequest(id: id, method: event.payload["method"]?.stringValue, reason: event.payload["reason"]?.stringValue)
            if !isShownApproval { return }
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
            if let row = event.payload["row_id"].flatMap({ $0.stringValue ?? $0.truncatedIntValue.map(String.init) }),
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
            if processTracker[id] != nil {
                pendingOutput[id, default: ""] += chunk
                if outputFlush == nil {
                    outputFlush = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled else { return }
                        self?.flushOutput()
                    }
                }
            } else if !clearedProcesses.contains(id) {
                processTracker.receiveOutput(chunk, for: id)
                publishProcesses(force: true)
                inspector.processOutput(id)
                // Its name, folder and the call that started it.
                Task { await refreshProcesses() }
            }
            return
        case "terminal.close":
            // Hermes closed the Terminal tab (`close_terminal`). Not an exit: the process keeps
            // running, in the list and the chip (`docs/background-processes.md` §1).
            if let id = event.payload["process_id"]?.stringValue {
                processTracker.terminalClosed(id)
                inspector.terminalClosed(id)
            }
            return
        case "status.update" where event.payload["kind"]?.stringValue == "process":
            // A process Hermes watches ended or matched (`notify_on_complete`): look again. Its text
            // is for Hermes, which answers in its next turn, never a line here.
            Task { await refreshProcesses() }
            if GatewayTurnDecoder.isProcessNotice(event.payload["text"]?.stringValue ?? "") { return }
        // Hermes opens and closes the Inspector's Preview (`desktop_preview`) and reveals its panes.
        case "preview.open":
            if let url = event.payload["url"]?.stringValue, !url.isEmpty {
                inspector.previewOpen(url: url, label: event.payload["label"]?.stringValue)
            }
            return
        case "preview.close":
            inspector.previewClose(url: event.payload["url"]?.stringValue ?? "")
            return
        case "pane.reveal":
            if let pane = event.payload["pane"]?.stringValue { inspector.paneReveal(pane) }
            return
        case "preview.restart.complete":
            inspectorStore?.previewServerRestarted()
            return
        case "preview.restart.progress":
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
            isResting = true
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
            Task { await readRemoteTurn() }
        }
        connectionNote = nil
        if Self.turnEvents.contains(event.type) || event.type == "message.complete" {
            turnGate.take()
            endDelivery()
        }
        for item in decoded {
            switch item.event {
            case .settled:
                // Idle before Hermes took the prompt (it builds a chat's agent first): not the end.
                if turnGate.settles { settle() }
            case .titleChanged:
                if !isBotChat { workspace?.titleChanged(in: self) }
            default:
                trackSteers(item.event)
                applyToLive(item)
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

    /// The files a unified diff touches (`+++ b/path`).
    static func diffPaths(_ diff: String) -> [String] {
        diff.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("+++ ") else { return nil }
            var path = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if path == "/dev/null" { return nil }
            if path.hasPrefix("b/") { path.removeFirst(2) }
            return path
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
        moveCards { requests.append(request) }
    }

    /// Sends the card's answer. `receipt` is the line left in the chat; never put a secret in it.
    func answer(_ request: HermesRequest, with result: JSONValue, receipt: String?, symbol: String = "checkmark.circle") {
        // A double tap answers once.
        guard requests.contains(where: { $0.id == request.id }) else { return }
        moveCards { requests.removeAll { $0.id == request.id } }
        connectionStates[request.id] = nil
        if let receipt { addReceipt(receipt, symbol: symbol) }
        guard let roster = gatewayRoster else { return }
        switch request.kind {
        case .clarify, .choose:
            // Kept until Hermes has it, like an approval (`AnswerLedger`).
            sendAnswer(result, to: request.id, about: Self.title(of: request), roster: roster)
        case .secret, .sudo, .vaultUnlock, .vaultSaveLogin, .vaultCode:
            // A password or key is never kept for later: with no socket to take it now, the card
            // comes back to be answered again.
            Task {
                // Never sent to a request Hermes stopped waiting on.
                guard await stillWaitsOn(request.id) else {
                    addReceipt(String(localized: "Not sent · already answered on another device"), symbol: "info.circle")
                    return
                }
                guard await !roster.respond(to: request.id, result: result) else { return }
                if !requests.contains(where: { $0.id == request.id }) { moveCards { requests.append(request) } }
                banner = .invalidResponse(String(localized: "\(gatewayName) isn't connected, so that didn't go. Answer again when it's back."))
            }
        case .connection:
            Task {
                guard let runtime = runtimeSessionID else { return }
                _ = try? await roster.request("connection.respond", [
                    "owner": .object(["type": .string("session"), "session_id": .string(runtime)]),
                    "op_id": .string(request.id),
                    "result": result,
                ])
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

    /// Signs in through the browser for a connection card, then tells Hermes the browser came back
    /// (`connectors.operation.wake`): the same flow as Settings → Apps and Tools. The card keeps
    /// following `connection.update`.
    func signIn(_ request: HermesRequest, at url: URL) async {
        let back = await BrowserSignIn.shared.open(url)
        guard let roster = gatewayRoster, let runtime = runtimeSessionID else { return }
        _ = try? await roster.request("connectors.operation.wake", [
            "owner": .object(["type": .string("session"), "session_id": .string(runtime)]),
            "op_id": .string(back?.connectionDoneOperation ?? request.id),
        ])
    }

    func skip(_ request: HermesRequest) {
        answer(request, with: request.skipResult, receipt: String(localized: "Skipped · \(Self.title(of: request))"), symbol: "arrow.uturn.forward.circle")
    }

    /// Answers several approvals the same way (the batch card).
    /// Answers the approvals the card showed (`shown`, their ids): one that arrived after it drew
    /// waits for its own answer.
    func respondToAll(with choice: ApprovalChoice, shown: [String]) {
        let all = approvalQueue.filter { shown.contains($0.id) }
        waitingApprovals.removeAll { shown.contains($0.id) }
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
        answers.forget(id)
        let receipt: (String, String)? = switch reason {
        case "timeout": (String(localized: "Hermes stopped waiting · no answer in time"), "clock")
        case "resolved": (String(localized: "Answered on another device"), "checkmark.circle.fill")
        case "interrupted": (String(localized: "Cancelled · you stopped this reply"), "stop.circle")
        default: nil
        }
        var matched = false
        if requests.contains(where: { $0.id == id }) {
            moveCards { requests.removeAll { $0.id == id } }
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

    /// The request cards up in this chat that Hermes lists in `open_requests` (connection requests
    /// are tracked by their own operation, not here).
    private var shownRequestCards: [RequestSync.Card] {
        let cards = requests.filter { if case .connection = $0.kind { false } else { true } }
            .map { RequestSync.Card(id: $0.id, deadline: $0.deadline) }
        let approvals = ([pendingApproval].compactMap { $0 } + waitingApprovals).compactMap(\.gatewayRequestID)
        return cards + approvals.map { RequestSync.Card(id: $0) }
    }

    /// Takes down the cards for requests Hermes no longer waits on: answered on another device,
    /// or past their deadline (`docs/quick-actions.md` §1).
    private func takeDownEndedRequests(open: Set<String>) {
        let ended = RequestSync.ended(shown: shownRequestCards, open: open, answeredHere: Set(answers.entries.map(\.id)))
        for (id, ending) in ended {
            let isApproval = pendingApproval?.gatewayRequestID == id || waitingApprovals.contains { $0.gatewayRequestID == id }
            // The turn stops waiting for the approval on its card too.
            if let shown = pendingApproval, shown.gatewayRequestID == id { apply(.approvalResolved(requestID: shown.requestID)) }
            withdrawRequest(id: id, method: isApproval ? "approval" : nil, reason: ending == .timedOut ? "timeout" : "resolved")
        }
    }

    private func scheduleRequestSync() {
        guard requestSyncTask == nil else { return }
        requestSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            if let open = await self.openRequestIDs() { self.takeDownEndedRequests(open: open) }
            self.requestSyncTask = nil
        }
    }

    /// The requests Hermes still waits on in this chat (`session.events.since` lists them; it only
    /// reads), or nil when it can't be asked.
    private func openRequestIDs() async -> Set<String>? {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID,
              let result = try? await roster.request("session.events.since", [
                  "session_id": .string(runtime), "last_seen": .number(Double(lastAppliedSeq ?? 0)),
              ]) else { return nil }
        return RequestSync.openIDs(result["open_requests"])
    }

    /// Whether Hermes still waits on request `id`; true when it can't be asked (the answer then
    /// goes as before, kept until an attach shows how it went).
    private func stillWaitsOn(_ id: String) async -> Bool {
        guard let open = await openRequestIDs() else { return true }
        if !open.contains(id) { takeDownEndedRequests(open: open) }
        return open.contains(id)
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
            moveCards { requests.removeAll { $0.id == opID } }
            // Say what happened to each target (pending, initiated, connected, skipped, failed,
            // expired, not_connected), not "Connected" whatever the outcome.
            let states = connectionStates[opID] ?? [:]
            let connected = states.filter { $0.value == "connected" }.keys.sorted()
            let missed = states.filter { $0.value != "connected" && $0.value != "skipped" }.keys.sorted()
            if !connected.isEmpty, missed.isEmpty {
                addReceipt(String(localized: "Connected · \(connected.formatted(.list(type: .and)))"), symbol: "checkmark.seal.fill")
            } else if !connected.isEmpty {
                addReceipt(String(localized: "Connected \(connected.formatted(.list(type: .and))) · \(missed.formatted(.list(type: .and))) didn't connect"), symbol: "checkmark.seal")
            } else if !missed.isEmpty {
                addReceipt(String(localized: "Didn't connect · \(missed.formatted(.list(type: .and)))"), symbol: "xmark.seal")
            } else if states.isEmpty {
                addReceipt(String(localized: "Connected · \(Self.title(of: request))"), symbol: "checkmark.seal.fill")
            } else {
                addReceipt(String(localized: "Skipped · \(Self.title(of: request))"), symbol: "xmark.seal")
            }
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
        if approval.isMemorySave {
            // "Save to memory?" answered: no command was run, nothing to add to Chat Permissions.
            switch choice {
            case .deny: addReceipt(String(localized: "Not saved · \(approval.memoryText)"), symbol: "xmark.circle")
            case .session: addReceipt(String(localized: "Saving to memory in this chat · \(approval.memoryText)"), symbol: "brain")
            default: addReceipt(String(localized: "Saved to memory · \(approval.memoryText)"), symbol: "brain")
            }
            return
        }
        if let fill = approval.paymentFill {
            // "Filled your card on amazon.com" / "Not filled": the card's name, never its number.
            addReceipt(choice == .deny ? String(localized: "Not filled · \(fill.label) on \(fill.site)") : String(localized: "Fill allowed · \(fill.label) on \(fill.site)"),
                       symbol: choice == .deny ? "xmark.circle" : "creditcard")
            return
        }
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

    /// - Parameter continuingStored: the stored rows that stop partway are this turn's, so it carries
    ///   on from them as one turn instead of starting a second one below them.
    private func beginRemoteTurn(startedAt: Date? = nil, continuingStored: Bool = false) {
        // A turn running on the gateway answers "how did it end?": an uncertain-outcome card is moot.
        // A turn running on the gateway answers "how did it end?" (and "did Hermes get it?").
        unconfirmed = nil
        if turnError?.canRetry == false { turnError = nil }
        let stored = continuingStored ? storedTurnInProgress() : nil
        if stored == nil { settleStoredTurn() }
        dropWaitingTurn()
        animateRows {
            if let stored {
                items.remove(at: stored.index)
                live = LiveTurn(continuing: stored.turn, sessionID: sessionID, startedAt: startedAt)
            } else {
                live = LiveTurn(id: "live-\(UUID().uuidString)", sessionID: sessionID, startedAt: startedAt ?? .now)
            }
            redirectedParts = []
            takeExpectedFromGateway()
        }
        if let live { turnBaseline = (live.turn.id, newestBeforeTurn) }
        isRemoteTurn = true
        isBotTurnOpen = true
        turnGate.take()
    }

    /// A turn started elsewhere while this chat was open: another device, a routine, another Bot.
    /// Its events carry no message, so the live session is asked for it (`session.activate`, which
    /// keeps the other device attached too) and it shows at once (`docs/chat.md` §2).
    private func readRemoteTurn() async {
        guard let roster = gatewayRoster, let runtime = runtimeSessionID, let turnID = live?.turn.id else { return }
        let params: [String: JSONValue] = ["session_id": .string(runtime), "omit_messages": .bool(true)]
        guard let snapshot = try? await roster.request("session.activate", params, timeout: .seconds(20)),
              live?.turn.id == turnID, let inflight = InflightTurn(snapshot: snapshot)
        else { return }
        adopt(inflight)
    }

    /// What the live session says of a turn this device didn't start: the message it answers (until
    /// the stored chat has it, which under turn isolation is only once the turn's process starts)
    /// and the reply so far, for a device that joins partway (`docs/chat.md` §2).
    private func adopt(_ inflight: InflightTurn) {
        guard isRemoteTurn, live != nil, !isFinishing else { return }
        if pendingUser == nil, !inflight.isStored(in: items), let entry = inflight.userEntry(id: "local-\(UUID().uuidString)") {
            animateRows { pendingUser = entry }
        }
        if let live, !inflight.assistant.isEmpty, live.pendingText.isEmpty, live.turn.steps.isEmpty, live.turn.answer.isEmpty {
            apply(.textDelta(inflight.assistant))
        }
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
        guard let roster = gatewayRoster, let runtime = runtimeSessionID, turnGate.sent else {
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
        let result: JSONValue = .object(["choice": .string(choice.rawValue), "all": .bool(false)])
        sendAnswer(result, to: requestID, about: approval.summary, roster: roster)
    }

    /// Sends the person's answer to request `id` and keeps it until an attach shows Hermes has it
    /// (`AnswerLedger`): with no socket to send it on, it goes as soon as the chat is attached again,
    /// to that request only, if Hermes still waits for it.
    private func sendAnswer(_ result: JSONValue, to id: String, about summary: String, roster: BotRoster) {
        answers.record(id: id, result: result, summary: summary)
        Task {
            // Hermes drops an answer to a request it no longer waits on without a word.
            guard await stillWaitsOn(id) else {
                answers.forget(id)
                addReceipt(String(localized: "Not sent · already answered on another device"), symbol: "info.circle")
                return
            }
            let sent = await roster.respond(to: id, result: result)
            answers.finishSending(id, sent: sent)
            if !sent, answers.holds(id) {
                addReceipt(String(localized: "Your answer goes to \(gatewayName) when it's back"), symbol: "clock")
            }
        }
    }

    /// Hermes listed the requests still open on attaching (`open_requests`): answers it never got
    /// go again, by id, and answers that never went out to requests it stopped waiting for say so.
    private func settleAnswers(open: [String], roster: BotRoster) {
        let settled = answers.settle(openIDs: open)
        for entry in settled.resend {
            Task {
                let sent = await roster.respond(to: entry.id, result: entry.result)
                answers.finishSending(entry.id, sent: sent)
            }
        }
        for entry in settled.expired {
            addReceipt(String(localized: "Hermes stopped waiting before your answer got there · \(entry.summary)"), symbol: "clock")
        }
    }

    /// The roster's socket dropped.
    func botChatConnectionLost() {
        // A message not taken yet says it's waiting, on its bubble.
        if isWorking, delivery == nil { connectionNote = String(localized: "Reconnecting…") }
    }

    /// The roster's socket is back: re-attach and catch up on what was missed.
    /// Nothing running here and nothing waiting on the person.
    var isQuiet: Bool {
        !isWorking && !isFinishing && live == nil && pendingApproval == nil && requests.isEmpty && pendingUser == nil
            && queue.isEmpty && !helpers.hasLiveHelpers && !processTracker.processes.contains(where: \.isRunning)
    }

    /// The socket came back while this chat sat quiet and out of sight: it catches up when it's
    /// next opened (the ordinary open: fetch, then attach) rather than every chat ever opened
    /// resuming its session at once on a gateway that may only just have come back.
    func reconnectedOutOfSight() {
        guard !isBotChat, loadState == .loaded, sessionID != nil, isQuiet else {
            botChatReconnected()
            return
        }
        runtimeSessionID = nil
        loadState = .idle
    }

    func botChatReconnected() {
        // A send still on its way attaches the chat itself once the Bots are back (`runGatewayTurn`).
        guard !confirmingSend, delivery == nil else { return }
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
                        seq: frame["seq"]?.truncatedIntValue, payload: frame["payload"] ?? .object([:])
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
                // message again could run it twice, so the card offers a reload, not a retry, and
                // the chat reloads by itself until it shows how the turn ended.
                failureIsRetryable = false
                live?.markFailed(String(localized: "Couldn't reconnect to this chat. Reload to see how it ended."))
                settle()
                recoverSoon()
            } else if running == false, isWorking, turnGate.settles {
                // Not running yet is not over: a prompt Hermes hasn't taken (the send finds out
                // what became of it) or a chat's agent still being built.
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

    /// A turn's outcome is on the gateway and this chat lost track of it: it reloads by itself, every
    /// few seconds while connected, until the transcript shows how the turn ended (the uncertain
    /// card clears then) and the chat is attached again (a turn still running streams on here), as
    /// Reload would. Stops after two minutes, or when something else attached it.
    private func recoverSoon() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            for attempt in 0..<20 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 2 : 6))
                guard !Task.isCancelled, let self else { return }
                guard self.turnError?.canRetry == false || self.runtimeSessionID == nil else { return }
                guard !self.isWorking, !self.isFinishing, self.gatewayRoster?.isConnected == true else { continue }
                self.reload()
                await self.loadTask?.value
            }
        }
    }

    /// A prompt sent over the socket, to find it again if its answer never came.
    /// A prompt sent over the socket, to find it again if its answer never came: by where and
    /// when it went in, never by its words (`LostPrompt`).
    struct SentPrompt {
        let at: Date
        /// The newest stored message the chat knew when it was sent.
        let knownNewestID: Int?
    }

    enum Arrival {
        /// Attached again, and a turn runs: this message's (it was the last thing sent).
        case running
        /// Stored, and nothing runs: its turn is over and the stored chat has the reply.
        case answered
        /// Stored, but the chat couldn't attach again to follow its turn.
        case unfollowed
        /// No sign of it, which proves nothing: Hermes may still take it (`LostPrompt`). Never
        /// sent again by itself; the person can, from the card.
        case unknown
    }

    /// Whether a failed send may still have reached Hermes: it went out and the answer was lost.
    /// Hermes refusing it, or no socket to send it on, is a clear no.
    nonisolated static func mayHaveArrived(_ error: any Error) -> Bool {
        if error is GatewayRPCError || error is CancellationError { return false }
        if let failure = error as? GatewaySocket.Failure, failure == .notConnected { return false }
        return true
    }

    /// What became of a prompt whose answer never came: a turn running on the chat is its
    /// (it was the last thing sent); otherwise the stored chat has it or not. Not "not there"
    /// unless Hermes also says nothing runs: a busy gateway may not have stored it yet.
    private func arrival(of sent: SentPrompt) async -> Arrival {
        confirmingSend = true
        defer { confirmingSend = false }
        // Attached again, with what streamed meanwhile caught up first (as `botChatReconnected`).
        let previous = runtimeSessionID
        let lastSeq = lastAppliedSeq
        catchUpBuffer = []
        // Settled only by evidence, a turn Hermes took with or after it or a row it stored
        // (`LostPrompt`), looked for every 3 s for a minute and a half: Hermes can take a prompt
        // late (building the chat's agent it says idle; a starved Mac reads a dead socket's last
        // frames late), and a resend then ran the message twice. The socket usually died with the
        // answer, and the roster hears of it a moment after: each look waits for a live
        // connection, and a reply running streams on here.
        let key = LostPrompt(knownNewestID: sent.knownNewestID, sentAt: sent.at)
        let deadline = Date.now.addingTimeInterval(Self.lostAnswerPatience)
        var running: Bool?
        var finding = LostPrompt.Finding.nothingYet
        while !Task.isCancelled {
            while gatewayRoster?.isConnected != true, Date.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // One attach per look: the looks themselves are the retries.
            if let attached = await attachGatewayChat() { running = attached }
            var messages: [SessionMessage]?
            if !key.wasTaken(running: running == true, turnStartedAt: attachedTurnStartedAt), let stored = sessionID {
                messages = (try? await fetchLatest(stored))?.messages
            }
            finding = key.finding(running: running == true, turnStartedAt: attachedTurnStartedAt, messages: messages)
            guard finding == .nothingYet, Date.now < deadline, !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(3))
        }
        var frames: [GatewayEvent] = []
        if running == true, let roster = gatewayRoster, let runtime = runtimeSessionID, runtime == previous,
           let result = try? await roster.request("session.events.since", [
               "session_id": .string(runtime), "last_seen": .number(Double(lastSeq ?? 0)),
           ]), case .array(let replay)? = result["events"] {
            frames = replay.map { frame in
                GatewayEvent(
                    type: frame["type"]?.stringValue ?? "", sessionID: runtime,
                    seq: frame["seq"]?.truncatedIntValue, payload: frame["payload"] ?? .object([:])
                )
            }
        }
        let held = catchUpBuffer ?? []
        catchUpBuffer = nil
        for event in frames + held { receive(event) }
        // Not attached on this socket: the next reload attaches (`botChatReconnected` stood aside).
        if running == nil { runtimeSessionID = nil }
        switch finding {
        case .taken: return .running
        case .stored: return running == false ? .answered : .unfollowed
        case .nothingYet: return .unknown
        }
    }

    /// How long a send whose answer was lost is looked for before the person is asked.
    static let lostAnswerPatience: TimeInterval = 90

    /// The roster changed: pick up messages that arrived while nothing streamed here
    /// (routine results, other Bots' messages, turns on another device).
    /// A notification for this chat was opened: the reply it announced is fetched now, not when
    /// the roster next notices the chat moved (after the socket is back and a busy Mac has
    /// answered `profiles.list`). Not there yet, it's looked for again a few times over about
    /// 20 s: Hermes notifies as a turn ends, and a busy Mac can store the reply after that.
    func notificationOpened(sentAt: Date?) {
        guard sessionID != nil || isBotChat else { return }
        notifiedCatchUp?.cancel()
        let held = rawMessages.last?.id
        notifiedCatchUp = Task { [weak self] in
            for wait in [0.0, 2, 3, 5, 10] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self, !Task.isCancelled else { return }
                // Here, or streaming in: nothing to look for.
                if self.live != nil || self.isWorking { return }
                if SessionTranscript.showsAnnouncedReply(self.rawMessages, sentAt: sentAt, heldNewest: held) { return }
                if !self.isFetching { self.reload() }
                await self.loadTask?.value
            }
        }
    }

    func botRosterChanged(_ bot: BotProfile, previous: BotProfile?) {
        // A turn shown here, even one whose reply is in, ends with its own fetch (`applyLoaded`).
        guard loadState == .loaded, !isWorking, !isFinishing, live == nil else { return }
        // Shown from the device's copy while the first fetch is out (a launch): that fetch isn't
        // thrown away for the roster's news, it goes once more after (`fetchAgain`).
        func reloadAfterAnyFetch() {
            if isFetching { fetchAgain = true } else { reload() }
        }
        if sessionID == nil, bot.canonicalSession != nil {
            reloadAfterAnyFetch()
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
            if chatMoved { reloadAfterAnyFetch() }
            return
        }
        seenActivity = active
        if chatMoved || bot.canonicalSession?.lastActive == active {
            reloadAfterAnyFetch()
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
    /// The model provider's sign-in or key, or no provider at all (`docs/setup.md` §4.3).
    var provider: ProviderProblem?
    /// Hermes didn't confirm it got the message: the card offers Send Again, the person's choice
    /// (never automatic: it may still show up).
    var mayResend = false
}


// MARK: - Widgets (docs/widgets.md)

extension ConversationModel {
    /// The platform word an answer carries, so other devices can say where it was given.
    static var widgetDevice: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// The chat's facts follow its rows and the message on its way (§5). Only on gateways with
    /// widgets, or with inline widgets on: nothing to scan anywhere else.
    fileprivate func refreshWidgetFacts() {
        let inline = WidgetSettings.rendersDeliveryBlocks(pluginPresent: workspace?.widgets.isAvailable == true)
        guard let widgets = workspace?.widgets, widgets.isAvailable || inline || !widgetFacts.shown.isEmpty else { return }
        var rows = items
        if let pendingUser { rows.append(.user(pendingUser)) }
        let facts = WidgetChatFacts.build(rows) { entry in
            // A routine's delivery the plugin processed carries its widgets inline (§2).
            guard inline, entry.routineName != nil else { return [] }
            return ReplySplitter.split(entry.text, inlineWidgets: true).compactMap { segment in
                guard case .inline(let json) = segment else { return nil }
                return widgets.ingest(json, fromText: true)?.id
            }
        }
        if facts != widgetFacts { widgetFacts = facts }
    }

    /// How this chat's widgets reach the store and send their answers; one per chat.
    var widgetHost: WidgetHost? {
        guard let widgets = workspace?.widgets else { return nil }
        if let widgetHostStorage { return widgetHostStorage }
        let host = WidgetHost(conversation: self, store: widgets)
        widgetHostStorage = host
        return host
    }

    /// A message can go now, or wait for the gateway.
    var canSendWidgetAnswer: Bool { isReachable }

    /// Sends a widget's answer as Send Next, whatever the follow-up setting, and never through the
    /// composer: the draft stays as it was (§5). Offline it isn't sent at all (batches wait in the
    /// store instead).
    func sendWidgetAnswer(_ answer: WidgetAnswer) {
        var answer = answer
        if answer.device == nil { answer.device = Self.widgetDevice }
        guard isReachable else {
            workspace?.widgets.noteNotSent(answer)
            return
        }
        sendWidgetMessage(answer.message, answer: answer)
    }

    /// Try Again: the same message, mid and all, so the agent's `claim` answers it once.
    func resendWidgetAnswer(_ text: String) {
        guard let answer = WidgetAnswer.parse(text) else { return }
        guard isReachable else {
            workspace?.widgets.noteNotSent(answer)
            return
        }
        sendWidgetMessage(text, answer: answer)
    }

    private func sendWidgetMessage(_ text: String, answer: WidgetAnswer) {
        if isWorking || isFinishing || isBotTurnOpen || waitsForChat {
            // Behind the running turn: it never steers or redirects it.
            workspace?.widgets.noteSent(answer, queued: true)
            animateRows { queue.append(QueuedFollowUp(text: text)) }
        } else {
            workspace?.widgets.noteSent(answer, queued: false)
            start(text: text, images: [], files: [])
        }
    }

    /// A suggestion's words, sent as the person's own message (§7).
    func sendSuggestion(_ words: String) {
        guard isReachable, !isWorking, !isFinishing, !isBotTurnOpen else { return }
        start(text: words, images: [], files: [])
    }

    /// The widget tool's own steps never show: its run events are read here instead (§2).
    fileprivate func widgetToolEvent(_ event: TurnEvent) -> Bool {
        switch event {
        case .toolStarted(_, let name, _, _), .toolDetails(_, let name, _, _):
            return WidgetToolResult.toolNames.contains(name)
        case .toolFinished(_, let name, _, _, _, _):
            guard WidgetToolResult.toolNames.contains(name) else { return false }
            // A run's event carries only a preview; Hermes stored the row before saying so.
            if name == WidgetToolResult.widgetTool, !usesGateway { Task { await fetchWidgetRows() } }
            return true
        default:
            return false
        }
    }

    /// The socket's `tool.complete` carries the parsed result, when tool progress is on; without
    /// it, the stored row has it.
    fileprivate func receiveWidgetResult(_ result: JSONValue?) {
        if let result, let json = WidgetToolResult.payload(from: result) {
            workspace?.widgets.ingest(json)
        } else {
            Task { await fetchWidgetRows() }
        }
    }

    /// Reads the chat's newest rows again for widget payloads, with the ones compression set aside.
    func fetchWidgetRows(limit: Int = 30) async {
        guard let sessionID else { return }
        let page: SessionTranscript?
        if botName == nil, let client = workspace?.client, !usesGateway {
            page = try? await client.transcript(sessionID: sessionID, limit: limit, offset: 0, includeCompacted: true)
        } else {
            page = try? await fetchPage(sessionID, limit: limit, offset: 0)
        }
        if let page { workspace?.widgets.ingest(messages: page.messages) }
    }

    /// Tells the plugin this chat is the app's, before its first prompt: Hermes builds a chat's
    /// system prompt once, and only the app's chats keep their directives (§11).
    fileprivate func markForWidgets(runtime: String, roster: BotRoster) async {
        guard let widgets = workspace?.widgets, widgets.isAvailable, let stored = sessionID, widgets.needsMark(stored) else { return }
        // The agent runs under the stored id; the plugin marks every id it's given (§11).
        let client = AppWidgetsClient(profile: gatewayProfile) { method, params in try await roster.request(method, params) }
        if (try? await client.markSession(runtimeID: runtime, storedID: stored)) != nil { widgets.noteMarked(stored) }
    }
}
