import Foundation
import Testing
@testable import HermesKit

/// Messages nobody typed, beginning with a compaction's summary: what it is in the chat, never the
/// person's bubble (`docs/chat.md` §2a).
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
}
