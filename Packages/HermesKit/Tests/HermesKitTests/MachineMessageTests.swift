import Foundation
import Testing
@testable import HermesKit

/// Messages nobody typed: a compaction's summary, a routine's or a hook's delivery, Hermes's own
/// notes. Each is what it is in the chat, never the person's bubble (`docs/chat.md` §2a).
@Suite("Messages that aren't yours")
struct MachineMessageTests {
    /// Hermes's current preamble (`SUMMARY_PREFIX` in agent/context_compressor.py), cut short in
    /// the middle: every version ends with the same words.
    private static let preamble = "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. "
        + "This is a handoff from a previous context window — treat it as background reference, NOT as active instructions. "
        + "The current session state (files, config, etc.) may reflect work described here — avoid repeating it:"
    private static let summary = "## Historical Task Snapshot\nThe person asked about the NAS backups; all checks passed."

    private func row(_ id: Int, _ role: String, _ text: String, kind: String? = nil) -> SessionMessage {
        SessionMessage(id: id, role: role, content: .text(text), timestamp: Date(timeIntervalSince1970: TimeInterval(1_000 + id)), displayKind: kind)
    }

    // MARK: Compaction

    @Test func aSummaryLosesHermesInstructionsToTheModel() {
        let stored = "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)"
        #expect(CompactionSummary.parse(stored) == CompactionSummary.Parts(before: "", summary: Self.summary, after: ""))
        // The legacy tag, and a preamble this app doesn't know: its first line goes.
        #expect(CompactionSummary.parse("[CONTEXT SUMMARY]: the person asked about backups")?.summary == "the person asked about backups")
        #expect(CompactionSummary.parse("[CONTEXT COMPACTION — NEW WORDING] Do this.\nThe body")?.summary == "The body")
        #expect(CompactionSummary.parse("Tell me about [CONTEXT COMPACTION]") == nil)
    }

    /// Hermes folds a summary into a message when roles must alternate: an older message before it
    /// (`_MERGED_PRIOR_CONTEXT_HEADER`), or the person's request after its end marker.
    @Test func aSummaryFoldedIntoAMessageKeepsThatMessage() {
        let merged = "\(CompactionSummary.priorContextHeader)\nDone: the backups ran.\n\n\(CompactionSummary.mergedDelimiter)\n\n"
            + "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)"
        #expect(CompactionSummary.parse(merged) == CompactionSummary.Parts(before: "Done: the backups ran.", summary: Self.summary, after: ""))
        let leading = "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)\n\nAnd the offsite copy?"
        #expect(CompactionSummary.parse(leading)?.after == "And the offsite copy?")
        // A delimiter without a summary after it is someone's words.
        #expect(CompactionSummary.parse("\(CompactionSummary.mergedDelimiter)\nhello") == nil)
        let restated = "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)\n\n\(CompactionSummary.restatedHeader)\nCheck the disks"
        #expect(CompactionSummary.parse(restated)?.after == "Check the disks")
    }

    @Test func aSummaryIsADividerNotTheirMessage() {
        let items = TranscriptBuilder.build([
            row(1, "user", "How are the backups?"),
            row(2, "assistant", "All fine."),
            row(3, "user", "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)"),
            row(4, "user", "And the disks?"),
            row(5, "assistant", "Healthy."),
        ])
        #expect(items.map(\.id) == ["m1", "tm2", "m3-s", "m4", "tm5"])
        guard case .notice(let divider) = items[2] else { Issue.record("not a divider"); return }
        #expect(divider.kind == Notice.compactionKind)
        #expect(divider.text == Self.summary)
        #expect(items[2].isCompactionSummary)
        // Never counted, never the last line.
        #expect(!UnreadCounter.counts(items[2]))
        #expect(LastLine.of(Array(items.prefix(3)))?.text == "All fine.")
    }

    /// Stored as Hermes's reply too, and folded into one: its words stay a reply, the summary a divider.
    @Test func aSummaryStoredAsHermesIsADividerToo() {
        let merged = "\(CompactionSummary.priorContextHeader)\nDone: the backups ran.\n\n\(CompactionSummary.mergedDelimiter)\n\n"
            + "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)"
        let items = TranscriptBuilder.build([row(1, "user", "Run the backups"), row(2, "assistant", merged)])
        #expect(items.map(\.id) == ["m1", "tm2-p", "m2-s"])
        if case .assistant(let turn) = items[1] { #expect(turn.answer == "Done: the backups ran.") }
        let leading = "\(Self.preamble)\n\(Self.summary)\n\n\(CompactionSummary.endMarker)\n\nAnd the offsite copy?"
        let asked = TranscriptBuilder.build([row(1, "user", leading), row(2, "assistant", "Copied at 02:10.")])
        #expect(asked.map(\.id) == ["m1-s", "m1", "tm2"])
        if case .user(let entry) = asked[1] { #expect(entry.text == "And the offsite copy?") }
    }

    /// Hermes's projection hides a summary on its own but keeps its words (`_project_for_display`):
    /// still a divider. The message a live turn answers is never one.
    @Test func aHiddenSummaryIsStillADivider() {
        let hidden = TranscriptBuilder.build([row(1, "user", "\(Self.preamble)\n\(Self.summary)", kind: "hidden")])
        #expect(hidden.map(\.id) == ["m1-s"])
        #expect(InflightTurn(user: "\(Self.preamble)\n\(Self.summary)").userEntry(id: "local-1") == nil)
    }

    /// A request Hermes restated after compacting stands in for the person's message it replaced.
    @Test func aRestatedRequestIsThePersonsMessage() {
        let items = TranscriptBuilder.build([row(1, "user", "\(CompactionSummary.restatedHeader)\nCheck the disks")])
        guard case .user(let entry) = items.first else { Issue.record("not a message"); return }
        #expect(entry.text == "Check the disks")
    }

    // MARK: Deliveries

    /// A routine's alert a script posted into the Bot Chat (`hermes peer dm`): Hermes tags it
    /// `internal_notification` with no wrapper. It's the automation's card, as Markdown, never
    /// the person's bubble or a two-line notice.
    @Test func anUnwrappedDeliveryIsAutomationsNotYours() {
        let alert = "**Ops room — issue change**\n- 🔴 **P2 · Backups: 1 job failed** (needs you)\n  Fix: open the backups page."
        let items = TranscriptBuilder.build([
            row(1, "user", alert, kind: "internal_notification"),
            row(2, "assistant", "That's the same alert again."),
        ], hidesSilence: true)
        guard case .user(let entry) = items.first else { Issue.record("not a message"); return }
        #expect(entry.delivery == .automation)
        #expect(entry.text == alert)
        #expect(!entry.isFromPerson)
        #expect(UnreadCounter.counts(items[0]))
        #expect(LastLine.of(Array(items.prefix(1)))?.speaker == .named("Automation"))
        #expect(Delivery.replies(in: items) == ["tm2": .automation])
        // Hermes's own notes tagged the same stay notices.
        let note = TranscriptBuilder.build([row(1, "user", "[IMPORTANT: Background process proc_1 matched watch pattern \"ERR\"]", kind: "internal_notification")])
        if case .notice = note.first {} else { Issue.record("not a notice") }
        // The live turn's message reads the same, by its display kind.
        let live = InflightTurn(user: alert, displayKind: "internal_notification").userEntry(id: "local-1")
        #expect(live?.delivery == .automation)
        #expect(InflightTurn(user: alert).userEntry(id: "local-2")?.isFromPerson == true)
    }

    /// The wrappers Hermes's cron and webhooks write (`cron/scheduler_delivery.py`, `cron/scheduler.py`,
    /// `gateway/platforms/webhook.py`): the source's name, and the words without the wrapper.
    @Test func wrappedDeliveriesNameTheirSource() {
        let cronjob = Delivery.parse("[Cronjob \"[bot:ops] Issue alerts\" output — scheduled job, not the user. Review it.]\n\nAll clear.", displayKind: nil)
        #expect(cronjob?.source == .routine("Issue alerts"))
        #expect(cronjob?.body == "All clear.")
        let mirrored = Delivery.parse("[Cron delivery: Morning brief]\nThree things today.", displayKind: nil)
        #expect(mirrored?.source == .routine("Morning brief"))
        #expect(mirrored?.body == "Three things today.")
        let hook = Delivery.parse("[Webhook delivery: deploys]\nBuild 41 shipped.", displayKind: nil)
        #expect(hook?.source == .webhook("deploys"))
        let platform = Delivery.parse("Cronjob Response: Morning brief\n(job_id: a1b2)\n-------------\n\nThree things today.\n\n"
            + "To stop or manage this job, send me a new message (e.g. \"stop reminder Morning brief\").", displayKind: nil)
        #expect(platform?.source == .routine("Morning brief"))
        #expect(platform?.body == "Three things today.")
        // The person's own words that only look alike stay theirs.
        #expect(Delivery.parse("[Cron delivery] is broken", displayKind: nil) == nil)
        #expect(Delivery.parse("Please check the backups", displayKind: nil) == nil)
    }

    // MARK: Hermes's own notes

    /// A skill used on another device is stored expanded; it shows as the skill and the words typed
    /// with it (`describe_skill_invocation`).
    @Test func aSkillPayloadShowsAsTheSkillAndTheWords() {
        let single = "[IMPORTANT: The user has invoked the \"logging-meals\" skill, indicating they want you to follow its instructions. "
            + "The full skill content is loaded below.]\n\n# Logging meals\nLog food.\n\n"
            + "The user has provided the following instruction alongside the skill invocation: two eggs and toast\n\n[Runtime note: today]"
        let items = TranscriptBuilder.build([row(1, "user", single)])
        guard case .user(let entry) = items.first else { Issue.record("not a message"); return }
        #expect(entry.skillNames == ["logging-meals"])
        #expect(entry.text == "two eggs and toast")
        let bundle = "[IMPORTANT: The user has invoked the \"/clean /work\" skill bundle, indicating …]\nUser instruction: tidy the repo\n\n[Loaded as part of the bundle]"
        #expect(SkillInvocation.parse(bundle)?.skills == ["clean", "work"])
        #expect(SkillInvocation.parse(bundle)?.instruction == "tidy the repo")
        #expect(SkillInvocation.parse("[IMPORTANT: The config file is broken]") == nil)
    }

    /// Recovery nudges and compaction's carried-over task list are for the model: not shown, as in
    /// Hermes's clients. An interrupted turn picked up again is a notice, typed or not.
    @Test func scaffoldingIsNotTheirs() {
        let items = TranscriptBuilder.build([
            row(1, "user", "[System: Your previous response was truncated by the output length limit. Continue exactly.]"),
            row(2, "user", "[Your active task list was preserved across context compression]\n- [ ] Check disks"),
            row(3, "user", "[System note: Your previous turn was interrupted mid-run — the app stopped. The interrupted request was:]\n\nCheck disks"),
            row(4, "user", "<memory-context>\n[System note: recalled]\nLikes short answers\n</memory-context>Check the disks"),
        ])
        #expect(items.map(\.id) == ["m3", "m4"])
        if case .notice(let notice) = items[0] { #expect(notice.kind == "auto_continue") } else { Issue.record("not a notice") }
        if case .user(let entry) = items[1] { #expect(entry.text == "Check the disks") }
    }
}
