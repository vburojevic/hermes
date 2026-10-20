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

    /// A request from outside the app (a Shortcut, a control) to call a Bot; the root view opens
    /// that chat and starts the call there.
    var pendingStart: TalkStart?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private static let recordsKey = "talk.calls"
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "talk")
    /// The Mac's call window.
    static let windowID = "talk"

    struct TalkStart: Equatable {
        /// The Bot to call; `nil` is Hermes.
        var botName: String?
    }

    private init() {
        if let data = defaults.data(forKey: Self.recordsKey), let saved = try? JSONDecoder().decode([CallRecord].self, from: data) {
            records = saved
        }
    }

    var isActive: Bool { session != nil }

    /// Calls the chat, or brings the call back if it's already this chat's.
    func start(conversation: ConversationModel, workspace: BotWorkspace) {
        if let session, session.conversation === conversation {
            isExpanded = true
            return
        }
        end()
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
