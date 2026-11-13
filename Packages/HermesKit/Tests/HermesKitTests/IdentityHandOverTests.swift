import Foundation
import Testing
@testable import HermesKit

/// The stored rows of a turn that ended take over the identities of the rows shown while it ran
/// (`docs/chat.md` §4), also when a message came in while it ran.
@Suite("Identity hand-over")
struct IdentityHandOverTests {
    private static let base = Date(timeIntervalSince1970: 1_760_600_000)

    private static func you(_ id: String) -> TranscriptItem {
        .user(UserEntry(id: id, text: "Check the release", timestamp: base))
    }

    private static func ada(_ id: String) -> TranscriptItem {
        .user(UserEntry(id: id, text: "Shipped it", timestamp: base, sender: AgentSender(name: "Ada", handle: "ada")))
    }

    private static func reply(_ id: String) -> TranscriptItem {
        .assistant(AssistantTurn(id: id, answer: "Done.", state: .complete, startedAt: base))
    }

    private static let shown = [you("live-ask"), reply("live-reply")]

    @Test func replyStoredAboveAMessageThatCameInWhileItRanKeepsItsKey() {
        // On screen: the older reply, the ask, Ada's message (in while the reply ran), the reply.
        let stored = [Self.reply("m0"), Self.you("m1"), Self.reply("m2"), Self.ada("m3")]
        let matches = IdentityHandOver.matches(shown: Self.shown, in: stored,
                                               existing: ["m0", "live-ask", "m3", "live-reply"], before: ["m0"])
        #expect(matches == ["m1": "live-ask", "m2": "live-reply"])
    }

    @Test func deliveredReplyNeverTakesTheTurnsKey() {
        // A routine's post came in as an assistant row while the reply ran.
        let existing: Set<String> = ["m0", "live-ask", "m3", "live-reply"]
        let below = [Self.reply("m0"), Self.you("m1"), Self.reply("m2"), Self.reply("m3")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: below, existing: existing, before: ["m0"])
            == ["m1": "live-ask", "m2": "live-reply"])
        // Not stored yet, the reply takes nothing; the ask still keeps its key.
        let unstored = [Self.reply("m0"), Self.you("m1"), Self.reply("m3")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: unstored, existing: existing, before: ["m0"])
            == ["m1": "live-ask"])
    }

    @Test func olderReplyNeverTakesASilentReplysKey() {
        // A silent reply is dropped from the stored rows; one with no ask on screen (a Bot's turn)
        // would otherwise hand its key to the reply before it, past a message that came in too.
        let shown = [Self.reply("live-reply")]
        #expect(IdentityHandOver.matches(shown: shown, in: [Self.reply("m0")],
                                         existing: ["m0", "live-reply"], before: ["m0"]).isEmpty)
        #expect(IdentityHandOver.matches(shown: shown, in: [Self.reply("m0"), Self.ada("m3")],
                                         existing: ["m0", "m3", "live-reply"], before: ["m0"]).isEmpty)
    }

    @Test func personsMessageKeepsItsKeyAndStopsTheReply() {
        let existing: Set<String> = ["m0", "live-ask", "live-reply"]
        let stored = [Self.reply("m0"), Self.you("m1")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: stored, existing: existing, before: ["m0"])
            == ["m1": "live-ask"])
        // A message of the person's that came in while the reply ran (sent from another device):
        // the reply never matches across it.
        let later = [Self.reply("m0"), Self.you("m1"), Self.reply("m2"), Self.you("m3")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: later,
                                         existing: existing.union(["m3"]), before: ["m0"]).isEmpty)
    }

    @Test func turnStoredLastHandsOverAsBefore() {
        let stored = [Self.reply("m0"), Self.you("m1"), Self.reply("m2")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: stored,
                                         existing: ["m0", "live-ask", "live-reply"], before: ["m0"])
            == ["m1": "live-ask", "m2": "live-reply"])
        // A row whose stored copy kept its id hands nothing over.
        let same = [Self.reply("m0"), Self.you("live-ask"), Self.reply("m2")]
        #expect(IdentityHandOver.matches(shown: Self.shown, in: same,
                                         existing: ["m0", "live-ask", "live-reply"], before: ["m0"])
            == ["m2": "live-reply"])
    }

    @Test func noticeAHermesTurnAnsweredKeepsItsKey() {
        // Hermes started the turn for a finished process: its line, then the reply.
        let notice = { (id: String) in TranscriptItem.notice(Notice(id: id, kind: "process_complete", text: "Ada replied")) }
        let shown = [notice("live-notice"), Self.reply("live-reply")]
        let stored = [Self.reply("m0"), notice("m1"), Self.reply("m2")]
        #expect(IdentityHandOver.matches(shown: shown, in: stored,
                                         existing: ["m0", "live-notice", "live-reply"], before: ["m0"])
            == ["m1": "live-notice", "m2": "live-reply"])
        // The person's message stops it: an older notice never takes the line's key.
        let older = [notice("m0"), Self.you("m1")]
        #expect(IdentityHandOver.matches(shown: [notice("live-notice")], in: older,
                                         existing: ["m0", "live-notice"], before: ["m0"]).isEmpty)
    }
}
