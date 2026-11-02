import Foundation
import FoundationModels
import HermesKit
import HermesMarkdown
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// The one call at a time (`docs/voice.md` §4): started from the composer's waveform, ⌥⌘V,
/// Shortcuts, Control Center or the Action button; shown full screen, minimised to a pill, as
/// an iPad panel or a Mac window; kept when the chat changes or the app goes to the background.
@MainActor
@Observable
final class TalkCenter {
    static let shared = TalkCenter()

    private(set) var session: TalkSession?
    /// Shown (full screen, the iPad panel, the Mac window), or minimised to the call pill.
    var isExpanded = true
    /// Calls that ended, by chat: each folds its turns into a `callSummary` card.
    private(set) var records: [CallRecord] = []

    /// Type: the call's composer takes the cursor (`ChatScreen` follows this).
    var typeRequests = 0

    /// A call asked for from outside the app (a Shortcut, the control, Hey Hermes) that can't start
    /// yet (`docs/voice.md` §4.4): it shows as waiting, ends by itself after a minute, and says why
    /// when it can't start. Kept in memory only, so it never outlives the app.
    private(set) var pending = PendingCallSlot()
    /// A fix the pending call's screen asked for; the window's root view opens its sheet.
    var setupRequest: SetupRequest?
    /// What the app knows about where a call to this callee would go; `TalkEntry` sets it and
    /// calls `factsChanged()` when the answer changes.
    @ObservationIgnored var readFacts: ((PendingCall.Callee) -> PendingCall.Facts)?
    /// Opens the callee's chat and calls it; `TalkEntry` sets it.
    @ObservationIgnored var startCall: ((PendingCall.Callee) -> Void)?
    /// Asks Bot Mode to connect now, quietly; `TalkEntry` sets it.
    @ObservationIgnored var connectBotMode: (() -> Void)?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var retries: Task<Void, Never>?
    @ObservationIgnored private var retriesFor: UUID?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private static let recordsKey = "talk.calls"
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "talk")
    /// The Mac's call window.
    static let windowID = "talk"

    enum SetupRequest: Equatable {
        case addGateway
        case setUpBotMode
    }

    private init() {
        if let data = defaults.data(forKey: Self.recordsKey), let saved = try? JSONDecoder().decode([CallRecord].self, from: data) {
            records = saved
        }
        // No call has started in this process yet: any call's Live Activity is a leftover.
        TalkActivity.shared.endLeftovers()
    }

    var isActive: Bool { session != nil }

    var pendingCall: PendingCall? { pending.call }

    /// A call from outside the app is waiting for Bot Mode (Hey Hermes stays paused meanwhile).
    var isWaitingToStart: Bool { pending.call?.state == .waitingForBotMode }

    // MARK: A call from outside the app

    /// Calls `botName` (`nil` is Hermes) as soon as it can, within `PendingCall.timeLimit`.
    func request(botName: String?) {
        isExpanded = true
        let callee = PendingCall.Callee(botName: botName)
        let ready = pending.request(callee, now: .now, facts: facts(for: callee))
        Self.logger.info("call requested from outside the chat")
        settle(ready)
    }

    /// Try Again after a time-out: the same call, another minute.
    func retryPending() {
        guard let call = pending.call else { return }
        settle(pending.retry(now: .now, facts: facts(for: call.callee)))
    }

    func cancelPending() {
        guard pending.call != nil else { return }
        pending.cancel()
        stopWaiting()
        isExpanded = true
        Self.logger.info("waiting call cancelled")
    }

    /// Cancels the waiting call and opens the fix its screen offered.
    func fixPending(_ request: SetupRequest) {
        cancelPending()
        setupRequest = request
    }

    /// The gateway, Bot Mode or the Bots changed: a waiting call may start or settle.
    func factsChanged() {
        evaluatePending()
    }

    private func facts(for callee: PendingCall.Callee) -> PendingCall.Facts {
        readFacts?(callee) ?? .unknown
    }

    private func evaluatePending() {
        guard let call = pending.call, !isBehindOtherApps else { return }
        settle(pending.update(facts(for: call.callee), now: .now))
    }

    /// On iPhone and iPad a call that started behind another app would open the microphone out
    /// of sight: the wait stands still there and is judged again when the app is back.
    private var isBehindOtherApps: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// Starts the call that's ready, or keeps a timer for the waiting one's limit.
    private func settle(_ callee: PendingCall.Callee?) {
        if let callee {
            stopWaiting()
            startCall?(callee)
            return
        }
        guard let call = pending.call else { return }
        switch call.state {
        case .waitingForBotMode:
            scheduleDeadline(for: call)
            keepConnecting(for: call)
        case .timedOut:
            Self.logger.info("waiting call timed out")
            stopWaiting()
        case .cantStart, .ready:
            stopWaiting()
        }
    }

    private func isWaiting(for id: UUID) -> Bool {
        pending.call?.id == id && isWaitingToStart
    }

    private func stopWaiting() {
        deadline?.cancel()
        deadline = nil
        retries?.cancel()
        retries = nil
        retriesFor = nil
    }

    /// Someone is holding on for this call: Bot Mode tries now and every few seconds, where its
    /// backoff (up to a minute behind other apps on the Mac) would outlast the wait.
    private func keepConnecting(for call: PendingCall) {
        guard retriesFor != call.id else { return }
        retries?.cancel()
        retriesFor = call.id
        let id = call.id
        retries = Task { [weak self] in
            while !Task.isCancelled, self?.isWaiting(for: id) == true {
                // Behind other apps nothing reconnects, as with Bot Mode's own retries.
                if self?.isBehindOtherApps == false { self?.connectBotMode?() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func scheduleDeadline(for call: PendingCall) {
        deadline?.cancel()
        let id = call.id
        let wait = max(0, call.deadline.timeIntervalSinceNow)
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            // A newer request, a cancel or a start replaced this one: its timer has nothing to do.
            guard !Task.isCancelled, let self, self.pending.call?.id == id else { return }
            self.evaluatePending()
        }
    }

    /// Calls the chat, or brings the call back if it's already this chat's.
    func start(conversation: ConversationModel, workspace: BotWorkspace) {
        if let session, session.conversation === conversation {
            isExpanded = true
            return
        }
        end()
        // A call started here replaces one still waiting to start.
        if pending.call != nil {
            pending.cancel()
            stopWaiting()
        }
        let session = TalkSession(conversation: conversation, workspace: workspace)
        self.session = session
        isExpanded = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        session.begin()
        TalkActivity.shared.start(for: session)
        Self.logger.info("call started")
    }

    func end() {
        guard let session else { return }
        self.session = nil
        isExpanded = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        TalkActivity.shared.end()
        guard let record = session.end() else { return }
        Self.logger.info("call ended after \(Int(record.duration)) s, \(record.turns) turns")
        guard record.turns > 0 else { return }
        save(record)
        Task { await summarise(record, conversation: session.conversation) }
    }

    func toggleMute() {
        session?.toggleMute()
    }

    /// The session's state changed: the Live Activity follows.
    func sessionChanged(_ session: TalkSession) {
        guard session === self.session else { return }
        TalkActivity.shared.update(for: session)
    }

    func records(for chat: String?) -> [CallRecord] {
        guard let chat else { return [] }
        return records.filter { $0.session == chat }
    }

    // MARK: Summary

    /// What the call did: Hermes's last reply when it summed up (short), otherwise the device's
    /// own summary from the transcript with the Foundation Models framework, labelled as such
    /// (`docs/voice.md` §4.3). No audio is kept, only the text.
    private func summarise(_ record: CallRecord, conversation: ConversationModel) async {
        let lines = conversation.rows.compactMap { item -> (isUser: Bool, text: String)? in
            switch item {
            case .user(let entry):
                guard let at = entry.timestamp, at >= record.startedAt.addingTimeInterval(-2) else { return nil }
                return (true, entry.text)
            case .assistant(let turn):
                guard let at = turn.startedAt, at >= record.startedAt.addingTimeInterval(-2) else { return nil }
                return (false, MarkdownDocument(parsing: turn.answer).spokenScript(detail: .skip).text)
            default:
                return nil
            }
        }
        var updated = record
        if let last = lines.last(where: { !$0.isUser })?.text, Self.isSummary(last) {
            updated.summary = last
        } else if case .available = SystemLanguageModel.default.availability {
            let transcript = VoiceTurn.context(lines)
            // The model's context is 4K tokens: the last 3,000 or so (about 12,000 characters).
            let session = LanguageModelSession(instructions: """
                Summarise a spoken conversation between a person and their assistant in two or three \
                plain sentences: what was asked and what was done. No preamble, no lists.
                """)
            if let response = try? await session.respond(to: String(transcript.suffix(12_000))) {
                updated.summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.summaryByDevice = true
            }
        }
        save(updated)
    }

    /// A short last reply sums the call up well enough.
    static func isSummary(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 360
    }

    private func save(_ record: CallRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        // A month of calls is plenty.
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        records = Array(records.filter { $0.endedAt > cutoff }.suffix(200))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.recordsKey) }
    }
}
