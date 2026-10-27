import Foundation
import Testing
@testable import HermesKit

/// A reply's recovery lasts across launches (`docs/chat.md` §2): a turn settled as "Stopped" stays
/// settled after the next relaunch, and a chat over the API server alone asks the run it started
/// how it stands rather than showing its stored rows as working for 20 minutes.
@Suite("A settled reply stays settled, and an API-server chat asks its run")
struct KeptTurnTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "kept-turn-\(UUID().uuidString)"))
    }

    /// A turn a gateway restart cut off: the message, a call and its result, then a call stored
    /// without its result.
    private var cutOff: [SessionMessage] {
        [
            SessionMessage(id: 10, role: "user", content: .text("Find the release notes and sum them up"), timestamp: at(-120)),
            SessionMessage(id: 11, role: "assistant", content: .text("Looking for them."),
                           toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query": "release notes"}"#)], timestamp: at(-110)),
            SessionMessage(id: 12, role: "tool", content: .text(#"{"results": []}"#), toolCallID: "c1", toolName: "web_search", timestamp: at(-100)),
            SessionMessage(id: 13, role: "assistant", content: .text(""),
                           toolCalls: [ToolCall(id: "c2", name: "web_extract", arguments: #"{"urls": ["https://example.com"]}"#)], timestamp: at(-90)),
        ]
    }

    private func status(_ value: String, session: String = "s1") throws -> RunStatus {
        try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id": "run_1", "status": "\#(value)", "session_id": "\#(session)"}"#.utf8))
    }

    // MARK: #65: settled stays settled

    /// The settle is kept on the device: the next launch reads it back and the stored turn shows as
    /// stopped at once, with no look at the gateway first (it showed working for about 30 s, with
    /// Steer offered meanwhile).
    @Test func aSettledTurnStaysSettledAfterARelaunch() throws {
        let store = try defaults()
        KeptTurns(defaults: store).set(KeptTurn(stoppedAt: 13), for: "gw-chat")

        // The next launch: a new store over the same defaults, the rows as Hermes stored them.
        let kept = KeptTurns(defaults: store).turn(for: "gw-chat").stillStopped(in: cutOff)
        #expect(kept.stoppedAt == 13)
        var built = TranscriptBuilder.build(cutOff)
        #expect(TranscriptBuilder.settleMidTurn(&built, messages: cutOff, endedAt: kept.stoppedAt))
        #expect(!TranscriptBuilder.markMidTurn(&built, messages: cutOff, now: now))
        guard case .assistant(let turn)? = built.last else {
            Issue.record("no turn")
            return
        }
        #expect(turn.state == .stopped)
        #expect(!turn.isWorking)

        // Another chat's mark is its own.
        #expect(KeptTurns(defaults: store).turn(for: "gw-other").isEmpty)
    }

    /// A row stored after the mark: the turn went on after all (or a later turn came). The mark goes,
    /// so it never settles a turn it wasn't set for; an older copy of the rows keeps it.
    @Test func aRowStoredAfterTheMarkClearsIt() {
        var more = cutOff
        more.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-5)))
        #expect(KeptTurn(stoppedAt: 13).stillStopped(in: more).stoppedAt == nil)
        #expect(KeptTurn(runID: "run_1", stoppedAt: 13).stillStopped(in: more) == KeptTurn(runID: "run_1"))
        #expect(KeptTurn(stoppedAt: 13).stillStopped(in: Array(cutOff.dropLast())).stoppedAt == 13)
    }

    /// A turn heard ending without finishing (a restart interrupted its run, Stop, a failure) while its
    /// stored rows stop partway: the mark is set then, so even the first relaunch shows it ended.
    @Test func aTurnThatEndedPartwayIsMarkedAsItEnds() {
        let restarted = AssistantTurn.State.failed("The gateway restarted before this run settled.")
        #expect(TranscriptBuilder.stoppedMark(endedAs: restarted, messages: cutOff, now: now) == 13)
        #expect(TranscriptBuilder.stoppedMark(endedAs: .stopped, messages: cutOff, now: now) == 13)
        // Finished, its reply stored a moment late: not stopped.
        #expect(TranscriptBuilder.stoppedMark(endedAs: .complete, messages: cutOff, now: now) == nil)
        // Stored whole: nothing to mark.
        var whole = cutOff
        whole.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-60)))
        whole.append(SessionMessage(id: 15, role: "assistant", content: .text("Three fixes."), timestamp: at(-50)))
        #expect(TranscriptBuilder.stoppedMark(endedAs: .stopped, messages: whole, now: now) == nil)
    }

    /// Only what's needed is kept, and nothing at all once there's nothing to keep.
    @Test func anEmptyTurnLeavesNothingBehind() throws {
        let store = try defaults()
        let turns = KeptTurns(defaults: store)
        turns.set(KeptTurn(runID: "run_1"), for: "chat")
        #expect(turns.turn(for: "chat") == KeptTurn(runID: "run_1"))
        turns.set(KeptTurn(), for: "chat")
        #expect(store.object(forKey: KeptTurns.key("chat")) == nil)

        // A removed gateway takes its chats' with it, its Bot Chats' too, and no other's.
        let gateway = UUID(), other = UUID()
        turns.set(KeptTurn(stoppedAt: 3), for: "\(gateway.uuidString)-chat")
        turns.set(KeptTurn(stoppedAt: 4), for: "bot-\(gateway.uuidString)-ops")
        turns.set(KeptTurn(stoppedAt: 5), for: "\(other.uuidString)-chat")
        turns.removeAll(gateway: gateway)
        #expect(turns.turn(for: "\(gateway.uuidString)-chat").isEmpty)
        #expect(turns.turn(for: "bot-\(gateway.uuidString)-ops").isEmpty)
        #expect(turns.turn(for: "\(other.uuidString)-chat").stoppedAt == 5)
    }

    // MARK: #67: an API-server chat asks its run

    @Test("A run that still runs carries on live", arguments: ["running", "queued", "waiting_for_approval"])
    func follows(value: String) throws {
        #expect(UnheardRun.next(status: .success(try status(value)), sessionID: "s1") == .follow)
    }

    @Test("A run that ended without finishing settles as stopped at once", arguments: ["interrupted", "cancelled", "failed"])
    func settles(value: String) throws {
        #expect(UnheardRun.next(status: .success(try status(value)), sessionID: "s1") == .settle)
    }

    /// Finished, its reply may land a moment late; gone (no status kept, as before Hermes kept them
    /// over a restart), nothing runs for it. Either way the stored chat says how it ended.
    @Test func aFinishedOrForgottenRunIsReadFromTheStoredChat() throws {
        #expect(UnheardRun.next(status: .success(try status("completed")), sessionID: "s1") == .readStored)
        #expect(UnheardRun.next(status: .failure(HermesError.notFound(message: "Run not found: run_1")), sessionID: "s1") == .readStored)
        // A status that names another chat isn't this chat's turn.
        #expect(UnheardRun.next(status: .success(try status("running", session: "s2")), sessionID: "s1") == .readStored)
    }

    /// Its run couldn't be asked for the whole minute: the stored turn says so, with Reload, instead of
    /// working on for 20 minutes; a row stored after it ends that.
    @Test func aRunThatCouldNotBeAskedSaysSo() {
        var built = TranscriptBuilder.build(cutOff)
        #expect(TranscriptBuilder.loseMidTurn(&built, messages: cutOff, at: (13, .unreachable)))
        #expect(!TranscriptBuilder.markMidTurn(&built, messages: cutOff, now: now))
        guard case .assistant(let turn)? = built.last else {
            Issue.record("no turn")
            return
        }
        #expect(turn.lostReason == .unreachable)
        #expect(!turn.isWorking)

        var more = cutOff
        more.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-5)))
        var rebuilt = TranscriptBuilder.build(more)
        #expect(!TranscriptBuilder.loseMidTurn(&rebuilt, messages: more, at: (13, .unreachable)))
        #expect(!TranscriptBuilder.loseMidTurn(&rebuilt, messages: more, at: nil))
    }

    @Test func aStatusThatCouldNotBeReadIsAskedAgain() {
        #expect(UnheardRun.next(status: .failure(URLError(.notConnectedToInternet)), sessionID: "s1") == .askAgain)
        #expect(UnheardRun.next(status: .failure(URLError(.timedOut)), sessionID: "s1") == .askAgain)
    }
}
