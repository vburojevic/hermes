import Foundation
import Testing
@testable import HermesKit

/// A reply the app stopped hearing recovers by itself (`docs/chat.md` §2): "Lost track of this
/// reply" showed in normal use, after a phone was away while its reply ended (Hermes reaps the
/// session 20 s after its socket left, and the re-attach to a new runtime replays nothing), after a
/// gateway restart, and after a relaunch mid-reply.
@Suite("A reply the app lost track of recovers by itself")
struct TurnRecoveryTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// The turn's rows as Hermes stores them: the message, a call and its result, a second call
    /// (cut off when `whole` is false), then the reply.
    private func rows(whole: Bool) -> [SessionMessage] {
        var rows = [
            SessionMessage(id: 8, role: "user", content: .text("Log breakfast"), timestamp: at(-900)),
            SessionMessage(id: 9, role: "assistant", content: .text("Logged."), timestamp: at(-880)),
            SessionMessage(id: 10, role: "user", content: .text("Find the release notes and sum them up"), timestamp: at(-120)),
            SessionMessage(id: 11, role: "assistant", content: .text("Looking for them."),
                           toolCalls: [ToolCall(id: "c1", name: "web_search", arguments: #"{"query": "release notes"}"#)], timestamp: at(-110)),
            SessionMessage(id: 12, role: "tool", content: .text(#"{"results": []}"#), toolCallID: "c1", toolName: "web_search", timestamp: at(-100)),
            SessionMessage(id: 13, role: "assistant", content: .text(""),
                           toolCalls: [ToolCall(id: "c2", name: "web_extract", arguments: #"{"urls": ["https://example.com"]}"#)], timestamp: at(-90)),
        ]
        if whole {
            rows.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-60)))
            rows.append(SessionMessage(id: 15, role: "assistant", content: .text("Three fixes and a new importer."), timestamp: at(-50)))
        }
        return rows
    }

    /// The turn as this device heard it before the socket went: the narration, the first call to its
    /// end, the second still running. Its end never came.
    private func unheard() -> LiveTurn {
        var live = LiveTurn(id: "live-1", sessionID: "rt", startedAt: at(-120))
        live.apply(SequencedTurnEvent(seq: 1, event: .commentary("Looking for them.", alreadyStreamed: false)), now: at(-110))
        live.apply(SequencedTurnEvent(seq: 2, event: .toolStarted(id: "c1", name: "web_search", preview: nil, at: nil)), now: at(-110))
        live.apply(SequencedTurnEvent(seq: 3, event: .toolFinished(id: "c1", name: "web_search", failed: false, duration: 10, resultPreview: nil, at: nil)), now: at(-100))
        live.apply(SequencedTurnEvent(seq: 4, event: .toolStarted(id: "c2", name: "web_extract", preview: nil, at: nil)), now: at(-90))
        live.settleUnheard(now: now)
        return live
    }

    private func steps(_ turn: AssistantTurn?) -> [String: ToolActivity.Status] {
        Dictionary(uniqueKeysWithValues: (turn?.steps ?? []).compactMap { step -> (String, ToolActivity.Status)? in
            if case .tool(let tool) = step { (tool.callID ?? tool.id, tool.status) } else { nil }
        })
    }

    // MARK: The looks

    /// The chat can't be read: the app looks again after 1, 2, 4, 8 and 15 s, about 30 s in all,
    /// before the turn says it lost track, and why. Until then nothing says "Lost track".
    @Test func lostTrackOnlyAfterTheBackoff() {
        var recovery = TurnRecovery()
        var waits: [TimeInterval] = []
        var step = recovery.next(after: .unreachable)
        while case .wait(let seconds) = step {
            waits.append(seconds)
            step = recovery.next(after: .unreachable)
        }
        #expect(waits == [1, 2, 4, 8, 15])
        #expect(waits.reduce(0, +) == 30)
        #expect(step == .lost(.unreachable))
        #expect(recovery.looks == 6)
    }

    /// A backend that freezes instead of answering takes a minute a read: the looks still end a minute
    /// after the unheard end, the last wait cut to what's left, and the turn doesn't show as working
    /// for many minutes. Each read gets what's left as its timeout.
    @Test func theLooksEndAMinuteAfterTheUnheardEnd() {
        var recovery = TurnRecovery()
        #expect(recovery.next(after: .unreachable, elapsed: 20) == .wait(1))
        #expect(recovery.next(after: .unreachable, elapsed: 57) == .wait(2))
        #expect(recovery.next(after: .unreachable, elapsed: 59) == .wait(1))
        #expect(recovery.next(after: .unreachable, elapsed: 61) == .lost(.unreachable))
        var partway = TurnRecovery()
        #expect(partway.next(after: .partway, elapsed: 3) == .wait(1))
        #expect(partway.next(after: .unreachable, elapsed: 70) == .settle)
        #expect(TurnRecovery.timeout(elapsed: 10) == 50)
        #expect(TurnRecovery.timeout(elapsed: 59.5) == 2)
        #expect(TurnRecovery.deadline == 60)
    }

    /// The stored chat still stops partway once the looks are spent, and nothing runs: the turn
    /// ended there, and settles as Hermes stored it, "Stopped", with no tap.
    @Test func partwayRowsSettleAsStoppedAfterTheBackoff() throws {
        var recovery = TurnRecovery()
        var step = recovery.next(after: .partway)
        var looks = 1
        while case .wait = step {
            step = recovery.next(after: looks == 5 ? .unreachable : .partway)
            looks += 1
        }
        // A last look that couldn't read the chat doesn't undo what the others read.
        #expect(step == .settle)
        #expect(looks == 6)

        let live = unheard()
        let messages = rows(whole: false)
        let placed = TurnPlacement.place([.assistant(live.heldTurn)], userRowID: nil, after: 9,
                                         in: TranscriptBuilder.build(messages), messages: messages)
        let held = try #require(placed.last.flatMap { if case .assistant(let turn) = $0 { turn } else { nil } })
        #expect(held.isWorking && !held.lostTrack)
        let settled = held.endedPartway(cutOff: live.cutOff, messages: messages, now: now)
        #expect(settled.id == "live-1" && settled.state == .stopped && !settled.isWorking)
        #expect(steps(settled) == ["c1": .succeeded, "c2": .failed])
    }

    /// What ends the looks at once: the turn running (followed live), stored whole (its rows take
    /// over), or the chat gone (said plainly, with Reload).
    @Test func runningStoredOrGoneEndTheLooksAtOnce() {
        for first in [TurnRecovery.Look.partway, .unreachable] {
            var recovery = TurnRecovery()
            #expect(recovery.next(after: first) == .wait(1))
            var stored = recovery
            var running = recovery
            var gone = recovery
            #expect(stored.next(after: .stored) == .handOver)
            #expect(running.next(after: .running) == .follow)
            #expect(gone.next(after: .gone) == .lost(.gone))
        }
        var recovery = TurnRecovery()
        #expect(recovery.next(after: .gone) == .lost(.gone))
    }

    /// A read Hermes answers 404 for the chat means it's gone, whichever client read it: the API
    /// server's, or the backend a Bot Chat is read from (that one said "couldn't reach" instead). A
    /// route an older Hermes lacks, a refusal or no network is a read that failed.
    @Test func aChatHermesNoLongerHasIsGoneOverEitherClient() {
        #expect(TurnRecovery.look(after: HermesError.notFound(message: "Session not found")) == .gone)
        #expect(TurnRecovery.look(after: BackendClient.Failure.http(404, "Session not found")) == .gone)
        #expect(TurnRecovery.look(after: BackendClient.Failure.http(404, nil)) == .gone)
        #expect(TurnRecovery.look(after: BackendClient.Failure.http(404, "No such API endpoint")) == .unreachable)
        #expect(TurnRecovery.look(after: BackendClient.Failure.http(502, "Bad Gateway")) == .unreachable)
        #expect(TurnRecovery.look(after: URLError(.notConnectedToInternet)) == .unreachable)
        #expect(TurnRecovery.look(after: HermesError.unauthorized) == .unreachable)
    }

    /// A turn whose end went unheard is reading its stored rows when the stuck-turn check asks the
    /// gateway: nothing runs, but the turn isn't stuck, so it isn't settled from under its reads (that
    /// dropped the turn and its message while a busy Hermes answered 502).
    @Test func theStuckTurnCheckLeavesATurnBeingRecovered() {
        #expect(StuckTurn.outcome(running: false, recovering: true) == .askAgain)
        #expect(StuckTurn.outcome(running: nil, recovering: true) == .askAgain)
        #expect(StuckTurn.outcome(running: true, recovering: true) == .follow)
        #expect(StuckTurn.outcome(running: false) == .settle)
    }

    // MARK: Back from the background: a new runtime replays nothing

    /// The phone was away while the reply ended; Hermes reaped the session, so the re-attach got a
    /// new runtime and no replay. The turn on screen asks the stored chat how it ended, keeps
    /// working meanwhile, and its stored rows take over when they hold it whole.
    @Test func aNewRuntimeAsksTheStoredChatHowTheTurnEnded() throws {
        #expect(TurnRecovery.afterReattach(working: true, promptTaken: true) == .recover)
        #expect(TurnRecovery.afterReattach(working: true, promptTaken: false) == .wait)
        #expect(TurnRecovery.afterReattach(working: false, promptTaken: true) == .idle)

        let live = unheard()
        #expect(live.isFinished && live.endedUnheard)
        #expect(live.heldTurn.isWorking && !live.heldTurn.lostTrack)
        #expect(steps(live.heldTurn) == ["c1": .succeeded, "c2": .running])
        let messages = rows(whole: true)
        #expect(TranscriptBuilder.holdsTurn(messages, after: 9))
        var recovery = TurnRecovery()
        #expect(recovery.next(after: .stored) == .handOver)
    }

    // MARK: A relaunch mid-reply

    /// After a relaunch the stored rows stop mid-work in the person's own turn. When the gateway says
    /// nothing runs there, it's the turn a restart cut off, and it settles as "Stopped" rather than
    /// working for 20 minutes; a row stored after that turns it back into a turn going on.
    @Test func aRelaunchSettlesAStoredTurnNothingRuns() {
        let messages = rows(whole: false)
        #expect(TranscriptBuilder.endsOwnMidTurn(messages, now: now))
        var built = TranscriptBuilder.build(messages)
        #expect(TranscriptBuilder.settleMidTurn(&built, messages: messages, endedAt: 13))
        guard case .assistant(let settled)? = built.last else {
            Issue.record("no turn")
            return
        }
        #expect(settled.state == .stopped)
        #expect(steps(settled) == ["c1": .succeeded, "c2": .failed])

        // Another row came: it was going on after all.
        var more = messages
        more.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-5)))
        var rebuilt = TranscriptBuilder.build(more)
        #expect(!TranscriptBuilder.settleMidTurn(&rebuilt, messages: more, endedAt: 13))
        #expect(TranscriptBuilder.markMidTurn(&rebuilt, messages: more, now: now))

        // Without a settle, the rows alone still show it working (what the app shows until the
        // gateway answers).
        var plain = TranscriptBuilder.build(messages)
        #expect(!TranscriptBuilder.settleMidTurn(&plain, messages: messages, endedAt: nil))
        #expect(TranscriptBuilder.markMidTurn(&plain, messages: messages, now: now))
    }

    /// Another Bot's message, or a routine's output, is answered in a one-shot `hermes chat` the
    /// gateway knows nothing of: its stored mid-turn keeps showing as a turn going on elsewhere.
    @Test func aTurnAnsweringAnotherBotIsNotSettledByTheGateway() {
        var messages = rows(whole: false)
        messages[2] = SessionMessage(id: 10, role: "user",
                                     content: .text("Message from 🤖 Ada (@ada): Can you check the release notes?"),
                                     timestamp: at(-120))
        #expect(TranscriptBuilder.endsMidTurn(messages, now: now))
        #expect(!TranscriptBuilder.endsOwnMidTurn(messages, now: now))
        // A stale one isn't mid-turn at all.
        #expect(!TranscriptBuilder.endsOwnMidTurn(rows(whole: false), now: at(TranscriptBuilder.midTurnStaleAfter)))
    }

    // MARK: The Bots list follows the chat

    /// A Bot's row showed a turn that died mid-work (a gateway restart, a reap while the socket was
    /// down) as working until its last row was 20 minutes old. Settled at its last stored row, it
    /// stops; a row stored after that one is the turn going on, and it shows again.
    @Test func aSettledTurnStopsShowingAsWorkingInTheBotsList() {
        let partway = rows(whole: false)
        #expect(ElsewhereTurn.of(partway, now: now) == ElsewhereTurn(runningTool: "web_extract"))
        #expect(ElsewhereTurn.of(partway, now: now, settledAt: 13) == nil)
        // Settled at an earlier row: these rows go further, so the turn went on.
        #expect(ElsewhereTurn.of(partway, now: now, settledAt: 12) == ElsewhereTurn(runningTool: "web_extract"))
        var more = partway
        more.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-5)))
        #expect(ElsewhereTurn.of(more, now: now, settledAt: 13) == ElsewhereTurn(runningTool: nil))
        // The chat's own view keys on the same row.
        var items = TranscriptBuilder.build(partway)
        #expect(TranscriptBuilder.settleMidTurn(&items, messages: partway, endedAt: TranscriptBuilder.lastTurnRowID(partway)))
    }

    /// Where no chat follows the turn, the roster's look gives the chat's verdict: Hermes running the
    /// chat follows it, rows no longer stopping mid-work in the person's turn take over, and rows
    /// still partway with nothing running are partway. Without an answer on whether it runs, the
    /// rows alone can't say it died.
    @Test func theRostersLookMatchesTheChats() {
        let partway = rows(whole: false)
        #expect(TurnRecovery.look(running: true, stored: partway, now: now) == .running)
        #expect(TurnRecovery.look(running: true, stored: nil, now: now) == .running)
        #expect(TurnRecovery.look(running: false, stored: partway, now: now) == .partway)
        #expect(TurnRecovery.look(running: nil, stored: partway, now: now) == .unreachable)
        #expect(TurnRecovery.look(running: false, stored: nil, now: now) == .unreachable)
        #expect(TurnRecovery.look(running: false, stored: rows(whole: true), now: now) == .stored)
        // A turn waiting on the person (an approval) still runs: it never settles while it waits.
        #expect(ActiveSession(sessionKey: "chat", status: "waiting").holdsTurn)
        #expect(ActiveSession(sessionKey: "chat", status: "working").holdsTurn)
        #expect(!ActiveSession(sessionKey: "chat", status: "idle").holdsTurn)
        // Answering another Bot runs in a one-shot `hermes chat` the gateway doesn't list: not the
        // gateway's to settle, so its rows take over (`ElsewhereTurn` keeps it working).
        var answering = partway
        answering[2] = SessionMessage(id: 10, role: "user", content: .text("Message from 🤖 Ada (@ada): Can you check the release notes?"),
                                      timestamp: at(-120))
        #expect(TurnRecovery.look(running: false, stored: answering, now: now) == .stored)
        #expect(ElsewhereTurn.of(answering, now: now) == ElsewhereTurn(answering: "Ada", runningTool: "web_extract"))
    }

    /// The Bots list keeps only where it lost track of a turn; where one settled is the chat's own
    /// `KeptTurn`. Lost: nothing shows it working, nothing says "Stopped", the roster keeps looking.
    /// Settled (the chat's mark): nothing shows it working and no more looks. A row stored after
    /// either is the turn going on.
    @Test func theBotsListLosesATurnWhereTheChatWouldSettleIt() {
        let partway = rows(whole: false)
        var book = BotTurnBook()
        #expect(book.shown("ada", rows: partway, settledAt: nil, now: now) == ElsewhereTurn(runningTool: "web_extract"))
        #expect(BotTurnBook.needsLook(partway, settledAt: nil, now: now))

        let lost = book.lose("ada", rows: partway, now: now)
        #expect(lost)
        #expect(book.shown("ada", rows: partway, settledAt: nil, now: now) == nil)
        #expect(BotTurnBook.needsLook(partway, settledAt: nil, now: now))
        book.found("ada")
        #expect(book.shown("ada", rows: partway, settledAt: nil, now: now) == ElsewhereTurn(runningTool: "web_extract"))

        // Settled at row 13 (the chat's `KeptTurn.stoppedAt`): hidden, no more looks; a row after it shows again.
        #expect(BotTurnBook.stoppedRow(partway, now: now) == 13)
        #expect(book.shown("ada", rows: partway, settledAt: 13, now: now) == nil)
        #expect(!BotTurnBook.needsLook(partway, settledAt: 13, now: now))
        var more = partway
        more.append(SessionMessage(id: 14, role: "tool", content: .text(#"{"content": "notes"}"#), toolCallID: "c2", toolName: "web_extract", timestamp: at(-5)))
        #expect(book.shown("ada", rows: more, settledAt: 13, now: now) == ElsewhereTurn(runningTool: nil))
        #expect(BotTurnBook.needsLook(more, settledAt: 13, now: now))

        // A turn stored whole is never marked, so it never reads "Stopped".
        let lostWhole = book.lose("grace", rows: rows(whole: true), now: now)
        #expect(!lostWhole && BotTurnBook.stoppedRow(rows(whole: true), now: now) == nil)
    }

    /// A Bot Chat's turn the roster lost track of, then the app relaunched, then the turn settled. The
    /// lost mark lives in memory, so the relaunch forgets it and looks again; the settle is the chat's
    /// kept mark, so it outlives the next relaunch, and the chat and the Bots list read the same one.
    @Test func aLostTurnRelaunchedThenSettled() throws {
        let suite = "turn-recovery-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "bot-gateway-ada"
        let partway = rows(whole: false)

        var book = BotTurnBook()
        _ = book.lose("ada", rows: partway, now: now)
        #expect(book.shown("ada", rows: partway, settledAt: KeptTurns(defaults: defaults).turn(for: key).stoppedAt, now: now) == nil)
        #expect(KeptTurns(defaults: defaults).turn(for: key).stoppedAt == nil) // lost is never "Stopped"

        // Relaunch: a new roster, the same device.
        book = BotTurnBook()
        let kept = KeptTurns(defaults: defaults)
        #expect(book.shown("ada", rows: partway, settledAt: kept.turn(for: key).stoppedAt, now: now) == ElsewhereTurn(runningTool: "web_extract"))
        #expect(BotTurnBook.needsLook(partway, settledAt: kept.turn(for: key).stoppedAt, now: now))

        // Two looks find nothing running: settled where the rows stop, in the chat's record.
        var turn = kept.turn(for: key)
        turn.stoppedAt = BotTurnBook.stoppedRow(partway, now: now)
        kept.set(turn, for: key)

        // Another relaunch: the Bots list and the chat both read it settled.
        let again = KeptTurns(defaults: defaults).turn(for: key)
        #expect(again.stoppedAt == 13)
        #expect(BotTurnBook().shown("ada", rows: partway, settledAt: again.stoppedAt, now: now) == nil)
        #expect(!BotTurnBook.needsLook(partway, settledAt: again.stoppedAt, now: now))
        var items = TranscriptBuilder.build(partway)
        #expect(TranscriptBuilder.settleMidTurn(&items, messages: partway, endedAt: again.stoppedAt))
        guard case .assistant(let stopped)? = items.last else {
            Issue.record("no turn")
            return
        }
        #expect(stopped.state == .stopped)
    }

    /// The Bot's own turn died with nothing running: two looks a second apart that both find the rows
    /// partway settle it, so its row stops showing as working seconds after the roster can look, not
    /// after the chat's half-minute backoff (or 20 minutes). Still running, it's followed at once;
    /// stored whole on the second look, the rows take over; a look that can't read anything doesn't
    /// count toward settling.
    @Test func aDeadTurnStopsShowingWithinSeconds() {
        let partway = rows(whole: false)
        let dead = TurnRecovery.look(running: false, stored: partway, now: now)
        var recovery = TurnRecovery.forBotsList()
        #expect(recovery.next(after: dead) == .wait(1))
        #expect(recovery.next(after: dead, elapsed: 1.2) == .settle)

        var running = TurnRecovery.forBotsList()
        #expect(running.next(after: TurnRecovery.look(running: true, stored: partway, now: now)) == .follow)

        var stored = TurnRecovery.forBotsList()
        #expect(stored.next(after: dead) == .wait(1))
        #expect(stored.next(after: TurnRecovery.look(running: false, stored: rows(whole: true), now: now), elapsed: 1.5) == .handOver)

        // The socket still down: unanswered looks wait on the backoff, and the next partway one settles.
        var offline = TurnRecovery.forBotsList()
        #expect(offline.next(after: dead) == .wait(1))
        #expect(offline.next(after: .unreachable, elapsed: 1.2) == .wait(2))
        #expect(offline.next(after: dead, elapsed: 3.5) == .settle)

        // The chat keeps its whole backoff: two partway looks only wait longer.
        var chat = TurnRecovery()
        #expect(chat.next(after: dead) == .wait(1))
        #expect(chat.next(after: dead, elapsed: 1.2) == .wait(2))
    }
}
