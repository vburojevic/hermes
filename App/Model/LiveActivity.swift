import Foundation
import HermesKit
#if os(macOS)
import AppKit
#endif

/// What each of a gateway's chats is doing right now (`docs/inbox.md` §2 The activity line): one
/// line per chat, for the rows, the jump pill and the Live Activity.
///
/// Chats the app is attached to (open, or recently opened and still subscribed) say exactly what
/// runs: the tool, the helpers, the words, what Hermes waits for. The others come from
/// `session.active_list` (Bot Mode), polled every 5 s while a list is on screen and after
/// `sessions.changed`. A gateway without Bot Mode has its list polled while it's on screen. A Mac
/// app behind other apps asks every 30 s and not on each change: its list stays on screen all day,
/// and the dashboard it asks is often the busy process on that Mac.
@Observable
final class LiveActivity {
    /// The line per chat key (as `UnreadStore`'s), only for chats with something to say.
    private(set) var lines: [String: ActivityLine] = [:] {
        didSet {
            for (key, slot) in slots where slot.line != lines[key] { slot.line = lines[key] }
            #if HERMES_PUSH
            // In front, the badge counts the chats whose row waits on the person (`docs/notifications.md` §2 Badge).
            if Set(lines.filter { $0.value.needsYou }.keys) != Set(oldValue.filter { $0.value.needsYou }.keys) {
                Task { await PushCenter.shared.applyBadge() }
            }
            #endif
        }
    }
    /// One chat's line, observed alone (`line(for:)`): a row follows its own chat, not every
    /// chat's line, which changes up to four times a second while one of them writes.
    @Observable final class Slot {
        fileprivate(set) var line: ActivityLine?
    }
    @ObservationIgnored private var slots: [String: Slot] = [:]
    /// Bots whose reply just landed: their face is happy for 2 s (`docs/bot-faces.md` §9).
    private(set) var justReplied: Set<String> = []

    @ObservationIgnored weak var workspace: BotWorkspace?
    @ObservationIgnored private var trackers: [String: ActivityTracker] = [:]
    @ObservationIgnored private var remote: [String: ActivityLine] = [:]
    /// The last turn stopped (an attached chat's error, or a `failed_turn` row), until opened.
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var visibleLists = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Which version of each attached chat's rows its last line was read from (`refresh`).
    @ObservationIgnored private var lastLineVersions: [String: Int] = [:]
    @ObservationIgnored private var lineRefresh: Task<Void, Never>?
    @ObservationIgnored private var pollSoon: Task<Void, Never>?
    @ObservationIgnored private var lastListRefresh = Date.distantPast
    #if os(macOS)
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    #endif

    init() {
        #if os(macOS)
        // Back in front: the lines as they are now, not at the next 30 s look.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pollTask != nil else { return }
                self.startPolling()
            }
        }
        #endif
    }

    // MARK: Reading

    func line(for key: String) -> ActivityLine? {
        if let slot = slots[key] { return slot.line }
        let slot = Slot()
        slot.line = lines[key]
        slots[key] = slot
        return slot.line
    }

    // MARK: Lists on screen

    /// A chat list came on screen: poll while it's there.
    func listAppeared() {
        visibleLists += 1
        guard pollTask == nil else { return }
        startPolling()
    }

    func listDisappeared() {
        visibleLists = max(0, visibleLists - 1)
        guard visibleLists == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    /// Now, then every 5 s (30 s while the Mac app is in the back).
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let interval: Double = AppPresence.isInBack ? 30 : 5
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
            }
        }
    }

    /// `sessions.changed`: a turn started or ended somewhere.
    func sessionsChanged() {
        guard pollSoon == nil, !AppPresence.isInBack else { return }
        pollSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, !Task.isCancelled else { return }
            self.pollSoon = nil
            await self.poll()
        }
    }

    func tearDown() {
        pollTask?.cancel()
        tickTask?.cancel()
        pollSoon?.cancel()
        lineRefresh?.cancel()
        pollTask = nil
        tickTask = nil
        pollSoon = nil
        lineRefresh = nil
        #if os(macOS)
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        #endif
    }

    private func poll() async {
        guard let workspace else { return }
        if workspace.projects?.client != nil, workspace.roster?.isConnected == true {
            guard let active = await workspace.projects.activeSessions() else { return }
            var seen: Set<String> = []
            var next: [String: ActivityLine] = [:]
            for row in active {
                let key = workspace.unreadKey(forStoredSession: row.sessionKey)
                seen.insert(key)
                var tracker = trackers[key] ?? ActivityTracker()
                tracker.update(status: row.status, preview: row.preview)
                trackers[key] = tracker
                if let line = tracker.line { next[key] = line }
            }
            trackers = trackers.filter { seen.contains($0.key) }
            if next != remote {
                remote = next
                refresh()
            }
        } else if visibleLists > 0, Date.now.timeIntervalSince(lastListRefresh) >= 15 {
            // No change events without Bot Mode: the list itself, now and then.
            lastListRefresh = .now
            await workspace.refreshSessions()
        }
    }

    // MARK: Attached chats

    /// An attached chat started, changed or finished a turn: follow it at most 4 times a second
    /// while it works (`docs/inbox.md` §3).
    func conversationChanged() {
        refresh()
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let busy = self.refresh()
                if !busy {
                    self.tickTask = nil
                    return
                }
            }
        }
    }

    /// An idle attached chat's last line moved: a reply stored, a message sent, a turn that ended.
    /// Once for everything that moved in the same pass (a reload sets the rows and the turn).
    func lastLineMoved() {
        guard lineRefresh == nil else { return }
        lineRefresh = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.lineRefresh = nil
            self.refresh()
        }
    }

    /// The roster found a Bot answering another Bot where no events reach the app, or that turn
    /// ended (`BotRoster.runningElsewhere`).
    func elsewhereChanged() {
        refresh()
    }

    /// A Bot's turn settled (`BotRoster.chatSettledTurn`, `settleOwnTurn`): the line the last
    /// `session.active_list` gave its Bot Chat goes now, not at the next poll (30 s with the Mac app in
    /// the back). A poll that still lists it running brings it back.
    func botTurnSettled(_ name: String) {
        let key = UnreadStore.botKey(name)
        guard remote[key] != nil else { return }
        remote[key] = nil
        trackers[key] = nil
        refresh()
    }

    /// A reply landed in a Bot Chat: its face is happy for 2 s.
    func botReplied(_ name: String) {
        justReplied.insert(name)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.justReplied.remove(name)
        }
    }

    /// The last turn of a chat counted in the list (`UnreadStore`): a `failed_turn` row, its text in
    /// `failed`, says it stopped.
    func lastTurn(of key: String, failed: String?) {
        guard failures[key] != failed else { return }
        failures[key] = failed
        refresh()
    }

    /// The chat was opened: a failure has been seen.
    func opened(_ key: String) {
        guard failures[key] != nil else { return }
        failures[key] = nil
        refresh()
    }

    /// Every line again. Returns whether an attached chat is still working.
    @discardableResult
    private func refresh() -> Bool {
        guard let workspace else { return false }
        var next = remote
        var busy = false
        for (key, message) in failures where next[key] == nil {
            next[key] = .failed(message)
        }
        let attached = workspace.attachedConversations
        let attachedKeys = Set(attached.map(\.0))
        lastLineVersions = lastLineVersions.filter { attachedKeys.contains($0.key) }
        for (key, conversation) in attached {
            // Four times a second while any chat works: an idle chat's last line only when what
            // it's read from moved, not flattened again from its last reply every time. The reply
            // that just ended counts before Hermes stores it (`rowLastLine`).
            if !conversation.isWorking, conversation.loadState == .loaded, lastLineVersions[key] != conversation.lastLineVersion {
                lastLineVersions[key] = conversation.lastLineVersion
                let (line, asOf) = conversation.rowLastLine
                workspace.unread.noteLastLine(key, line, asOf: asOf)
            }
            if let line = Self.line(for: conversation) {
                next[key] = line
                if conversation.isWorking { busy = true }
            } else if remote[key] != nil, !conversation.isWorking, conversation.loadState == .loaded {
                // Here it finished; the gateway's list may lag behind by a poll.
                next[key] = nil
            }
        }
        // A Bot answering another Bot in Hermes's one-shot process: no events, no `active_list`
        // row, only its stored rows (`ElsewhereTurn`). Its call when one is open, else thinking.
        for (name, turn) in workspace.roster?.runningElsewhere ?? [:] {
            let key = UnreadStore.botKey(name)
            guard next[key] == nil else { continue }
            if let tool = turn.runningTool {
                let descriptor = ToolDescriptor.describe(tool)
                next[key] = .tool(symbol: descriptor.symbol, title: descriptor.activeTitle, progress: nil)
            } else {
                next[key] = .thinking
            }
        }
        if next != lines {
            // A chat that stops running is counted now: `UnreadStore` waits out a running turn.
            let stopped = lines.contains { key, line in line.isLive && next[key]?.isLive != true }
            let liveBotsMoved = Set(lines.filter { $0.key.hasPrefix("bot:") && $0.value.isLive }.keys)
                != Set(next.filter { $0.key.hasPrefix("bot:") && $0.value.isLive }.keys)
            lines = next
            if stopped { workspace.unread.update() }
            // A Bot row stands at its activity while its turn runs (`RowTime`).
            if liveBotsMoved { workspace.roster?.reorder() }
        }
        return busy
    }

    /// An attached chat's line: what it waits for, else the tool, the helpers, the words.
    static func line(for conversation: ConversationModel) -> ActivityLine? {
        if conversation.pendingApproval != nil { return .waiting(.approval) }
        if let request = conversation.requests.first { return .waiting(needs(request)) }
        if !conversation.isWorking {
            return conversation.turnError.map { .failed($0.message) }
        }
        // The message hasn't reached the gateway: never "Thinking…" while it waits for it.
        if conversation.deliveryNote == .waiting { return .sending(gateway: conversation.gatewayName) }
        guard let live = conversation.live else { return .thinking }
        let progress = live.turn.plan.isEmpty ? nil : ActivityLine.PlanProgress(
            done: live.turn.plan.filter { $0.status == .completed }.count, total: live.turn.plan.count
        )
        if case .tool(let tool)? = live.turn.steps.last(where: { if case .tool(let tool) = $0 { tool.status == .running } else { false } }) {
            let descriptor = ToolDescriptor.describe(tool.name)
            return .tool(symbol: descriptor.symbol, title: toolTitle(descriptor, preview: tool.preview), progress: progress)
        }
        let helpers = conversation.helpers.tracker.orderedTeams.reduce(0) { $0 + $1.runningCount }
        if helpers > 0 { return .helpers(helpers) }
        let words = live.pendingText.isEmpty ? live.turn.answer : live.pendingText
        if !words.isEmpty { return .writing(ActivityLine.writingTail(words)) }
        return .thinking
    }

    /// "Running swift test": a command says what it runs, other tools what they do.
    private static func toolTitle(_ descriptor: ToolDescriptor, preview: String?) -> String {
        guard descriptor.symbol == "terminal", let preview, !preview.isEmpty else { return descriptor.activeTitle }
        let words = preview.split(separator: " ").prefix(3).joined(separator: " ")
        return String(localized: "Running \(words)")
    }

    private static func needs(_ request: HermesRequest) -> ActivityLine.NeedsYou {
        switch request.kind {
        case .clarify, .choose: .question
        case .secret, .sudo, .vaultUnlock, .vaultSaveLogin, .vaultCode, .connection: .key
        }
    }
}
