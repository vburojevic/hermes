import Foundation
import Testing
@testable import HermesKit

@Suite("A stored turn still going elsewhere")
struct MidTurnTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// A Bot's one-shot `hermes chat` writes the turn row by row: no events reach the app.
    private func rows(through stage: Int) -> [SessionMessage] {
        var rows = [
            SessionMessage(id: 1, role: "user", content: .text("Message from 🤖 cofounder: please resume."), timestamp: at(-240)),
            SessionMessage(id: 2, role: "assistant", content: .text("The earlier test archive died with the session, so I'm running it again."),
                           toolCalls: [ToolCall(id: "c1", name: "terminal", arguments: #"{"command": "xcodebuild archive"}"#)], timestamp: at(-230)),
        ]
        if stage >= 2 {
            rows.append(SessionMessage(id: 3, role: "tool", content: .text(#"{"output": "ARCHIVE SUCCEEDED", "exit_code": 0}"#),
                                       toolCallID: "c1", toolName: "terminal", timestamp: at(-30)))
        }
        if stage >= 3 {
            rows.append(SessionMessage(id: 4, role: "assistant", content: .text("The archive is signed; 1.20.7 is ready."), timestamp: at(-10)))
        }
        return rows
    }

    @Test func aTurnWhoseRowsStopMidWorkIsStillGoing() {
        #expect(TranscriptBuilder.endsMidTurn(rows(through: 1), now: now))
        #expect(TranscriptBuilder.endsMidTurn(rows(through: 2), now: now))
        #expect(!TranscriptBuilder.endsMidTurn(rows(through: 3), now: now))
        // Twenty minutes without a row: it died, it isn't working.
        #expect(!TranscriptBuilder.endsMidTurn(rows(through: 1), now: at(30 * 60)))
    }

    /// A hidden nudge or a steer stored after a tool call doesn't end the turn: the builder skips
    /// one and reads the other inside the turn, so the turn kept flipping between done and working.
    @Test func aHiddenNudgeOrASteerDoesntEndTheTurn() {
        let nudge = SessionMessage(id: 5, role: "user", content: .text("[continue]"), timestamp: at(-20), displayKind: "hidden")
        let steer = SessionMessage(id: 6, role: "user", content: .text("Use the release config"), timestamp: at(-15), displayKind: "steer")
        #expect(TranscriptBuilder.endsMidTurn(rows(through: 2) + [nudge], now: now))
        #expect(TranscriptBuilder.endsMidTurn(rows(through: 2) + [steer], now: now))
        // A new message from the person does end it.
        let ask = SessionMessage(id: 7, role: "user", content: .text("How's it going?"), timestamp: at(-5))
        #expect(!TranscriptBuilder.endsMidTurn(rows(through: 2) + [ask], now: now))
    }

    /// Hermes stores another Bot's message as the receiving Bot's one-shot turn starts; until its
    /// first step lands, that message is the chat's last row, and the Bot is already on it.
    @Test func aBotsMessageWithNothingAfterItIsBeingAnswered() {
        let incoming = SessionMessage(id: 9, role: "user", content: .text("Message from 🤖 CORE (@hermes): Two infra items for you."), timestamp: at(-20))
        let earlier = SessionMessage(id: 8, role: "assistant", content: .text("Done."), timestamp: at(-3600))
        #expect(TranscriptBuilder.awaitsReply([earlier, incoming], now: now))
        #expect(TranscriptBuilder.runsElsewhere([earlier, incoming], now: now))
        // Its first step, then its reply.
        #expect(TranscriptBuilder.runsElsewhere(rows(through: 1), now: now))
        #expect(!TranscriptBuilder.runsElsewhere(rows(through: 3), now: now))
        // Ten minutes with nothing after it: that turn died (Hermes stopped the delivery).
        #expect(TranscriptBuilder.awaitsReply([earlier, incoming], now: at(9 * 60)))
        #expect(!TranscriptBuilder.awaitsReply([earlier, incoming], now: at(11 * 60)))
        // The person's own message, or a routine's delivered as a dashboard turn, runs where the app hears it.
        let mine = SessionMessage(id: 10, role: "user", content: .text("Message from me: hi"), timestamp: at(-10))
        #expect(!TranscriptBuilder.awaitsReply([earlier, mine], now: now))
        let routine = SessionMessage(id: 11, role: "user", content: .text("[Cronjob \"brief\" output — scheduled job, not the user.]\n\nAll quiet."),
                                     timestamp: at(-10), displayKind: "internal_notification")
        #expect(!TranscriptBuilder.awaitsReply([earlier, routine], now: now))
    }

    /// The open chat shows a working turn under the Bot's message, and the row says who it answers
    /// or what it runs.
    @Test func whatTheRowAndTheChatShow() {
        let incoming = SessionMessage(id: 9, role: "user", content: .text("Message from 🤖 CORE (@hermes): Two infra items for you."), timestamp: at(-20))
        var items = TranscriptBuilder.build([incoming])
        #expect(TranscriptBuilder.markMidTurn(&items, messages: [incoming], now: now))
        guard case .assistant(let turn)? = items.last else {
            Issue.record("no working turn")
            return
        }
        #expect(turn.isWorking && turn.steps.isEmpty && turn.startedAt == at(-20))
        #expect(ElsewhereTurn.of([incoming], now: now) == ElsewhereTurn(answering: "CORE"))
        // Its first step stored: it still answers CORE, running that call.
        let step = SessionMessage(id: 10, role: "assistant", content: .text(""),
                                  toolCalls: [ToolCall(id: "c2", name: "terminal", arguments: "{}")], timestamp: at(-5))
        #expect(ElsewhereTurn.of([incoming, step], now: now) == ElsewhereTurn(answering: "CORE", runningTool: "terminal"))
        #expect(ElsewhereTurn.of(rows(through: 1), now: now) == ElsewhereTurn(runningTool: "terminal"))
        #expect(ElsewhereTurn.of(rows(through: 2), now: now) == ElsewhereTurn(runningTool: nil))
        #expect(ElsewhereTurn.of(rows(through: 3), now: now) == nil)
    }

    @Test func itShowsWorkingWithItsOpenCallRunning() {
        var items = TranscriptBuilder.build(rows(through: 1))
        #expect(TranscriptBuilder.markMidTurn(&items, messages: rows(through: 1), now: now))
        guard case .assistant(let turn)? = items.last else {
            Issue.record("no turn")
            return
        }
        #expect(turn.isWorking && turn.finishedAt == nil && turn.answer.isEmpty)
        #expect(turn.steps.contains { if case .narration(_, let text) = $0 { text.hasPrefix("The earlier test archive") } else { false } })
        #expect(turn.steps.contains { if case .tool(let tool) = $0 { tool.status == .running } else { false } })
        // A turn that ended stays as it was.
        var done = TranscriptBuilder.build(rows(through: 3))
        #expect(!TranscriptBuilder.markMidTurn(&done, messages: rows(through: 3), now: now))
        if case .assistant(let finished)? = done.last { #expect(!finished.isWorking) }
    }

    /// A device that opens the chat while the turn runs carries the stored part on live: one turn,
    /// its open call finished by the live event, the reply streaming after its narration.
    @Test func joiningARunningTurnCarriesItsStoredStepsOn() {
        var items = TranscriptBuilder.build(rows(through: 1))
        _ = TranscriptBuilder.markMidTurn(&items, messages: rows(through: 1), now: now)
        guard case .assistant(let stored)? = items.last else {
            Issue.record("no turn")
            return
        }
        var live = LiveTurn(continuing: stored, sessionID: "s1", startedAt: at(-235))
        #expect(live.turn.id == stored.id && live.turn.startedAt == at(-235) && !live.isFinished)
        live.apply(SequencedTurnEvent(seq: 9, event: .toolFinished(id: "c1", name: "terminal", failed: false, duration: 200, resultPreview: "ARCHIVE SUCCEEDED", at: now)))
        live.apply(SequencedTurnEvent(seq: 10, event: .textDelta("The archive is signed.")))
        let tools = live.snapshot.steps.compactMap { step -> ToolActivity? in if case .tool(let tool) = step { tool } else { nil } }
        #expect(tools.count == 1 && tools.first?.status == .succeeded)
        #expect(live.snapshot.answer == "The archive is signed.")
    }
}

/// A chat whose history came after a message went out (a busy Mac answers slowly): the history
/// goes in above that message, and the message never shows twice.
@Suite("History under a turn in flight")
struct HistoryUnderTurnTests {
    let sent = Date(timeIntervalSince1970: 1_792_306_880)

    private func row(_ id: Int, _ role: String, _ text: String, at seconds: TimeInterval) -> SessionMessage {
        SessionMessage(id: id, role: role, content: .text(text), timestamp: sent.addingTimeInterval(seconds))
    }

    private var earlier: [SessionMessage] {
        [row(124, "user", "Plan my week", at: -86_000), row(125, "assistant", "Here's the plan.", at: -85_990)]
    }

    @Test func notStoredYetKeepsEverything() {
        #expect(TranscriptBuilder.history(earlier, before: "What can i eat today?", sentAt: sent) == earlier)
    }

    @Test func cutsAtTheStoredMessageAndWhatFollows() {
        let stored = earlier + [row(126, "user", "What can i eat today?", at: 82), row(127, "assistant", "Fish is fine.", at: 118)]
        #expect(TranscriptBuilder.history(stored, before: "What can i eat today?", sentAt: sent) == earlier)
    }

    @Test func findsItsWordsAfterAnAttachmentAndThroughAClockAhead() {
        // Stored a minute "before" it was sent (the Mac's clock ahead), after a file Hermes put first.
        let stored = earlier + [row(126, "user", "[Attached PDF: sheet.pdf]\nWhat does this allow?", at: -60)]
        #expect(TranscriptBuilder.history(stored, before: "What does this allow?", sentAt: sent) == earlier)
    }

    @Test func theSameWordsLongAgoAreHistory() {
        let stored = [row(10, "user", "hi", at: -7200), row(11, "assistant", "Hello!", at: -7190)]
        #expect(TranscriptBuilder.history(stored, before: "hi", sentAt: sent) == stored)
    }

    /// The owner's chat (2026-10-19): a steer stored partway through the turn is a user row after
    /// the send too, but the turn starts at its message, not at the steer.
    @Test func aSteerIsNotWhereTheTurnStarts() {
        var steer = row(129, "user", "[OUT-OF-BAND USER MESSAGE]\nMan just a simple one example\n[/OUT-OF-BAND USER MESSAGE]", at: 220)
        steer.displayKind = "steer"
        let stored = earlier + [row(126, "user", "Write an example code in swift", at: 1), row(127, "assistant", "", at: 48),
                                row(128, "tool", "{}", at: 150), steer, row(130, "assistant", "Here's the short version.", at: 290)]
        #expect(TranscriptBuilder.history(stored, before: "Write an example code in swift", sentAt: sent) == earlier)
    }
}

@Suite("A turn handing over to its stored rows")
struct TurnHandoverTests {
    let sent = Date(timeIntervalSince1970: 1_792_441_598)

    private func row(_ id: Int, _ role: String, _ text: String = "", at seconds: TimeInterval, kind: String? = nil, calls: Bool = false) -> SessionMessage {
        var message = SessionMessage(id: id, role: role, content: .text(text),
                                     toolCalls: calls ? [ToolCall(id: "c\(id)", name: "write_file", arguments: "{}")] : [],
                                     timestamp: sent.addingTimeInterval(seconds))
        message.displayKind = kind
        return message
    }

    private var earlier: [SessionMessage] {
        [row(114201, "user", "weather tomorrow?", at: -229), row(114215, "assistant", "Tomorrow in Brooklyn is dry and sunny.", at: -149)]
    }

    /// The owner's chat (2026-10-19) as Hermes stored it: the message, two files and a check, a
    /// steer, a third file, the answer.
    private var turn: [SessionMessage] {
        [row(114216, "user", "Write an example code in swift", at: 0.4),
         row(114217, "assistant", at: 48, calls: true), row(114218, "tool", "{}", at: 156), row(114219, "tool", "{}", at: 156),
         row(114220, "assistant", at: 176, calls: true), row(114221, "tool", "{}", at: 196),
         row(114222, "user", "[OUT-OF-BAND USER MESSAGE]\nMan just a simple one example like 20 lines\n[/OUT-OF-BAND USER MESSAGE]", at: 221, kind: "steer"),
         row(114223, "assistant", at: 221, calls: true), row(114224, "tool", "{}", at: 278),
         row(114226, "assistant", "Here's the short version. It compiles.", at: 290)]
    }

    @Test func aTurnEndsAfterTheRowsFromBeforeIt() {
        #expect(TranscriptBuilder.newestBeforeTurn(earlier, ask: "Write an example code in swift", sentAt: sent) == 114215)
        #expect(TranscriptBuilder.holdsTurn(earlier + turn, after: 114215))
    }

    /// A reload brought the stored turn in while the reply still showed live. Its own rows aren't
    /// its history: the newest of them as the start, the stored chat never seemed to hold the turn,
    /// and the live copy stayed under the stored one.
    @Test func theTurnsOwnRowsAreNeverItsHistory() {
        let held = earlier + turn
        let before = TranscriptBuilder.newestBeforeTurn(held, ask: "Write an example code in swift", sentAt: sent)
        #expect(before == 114215)
        #expect(TranscriptBuilder.holdsTurn(held, after: before))
        #expect(!TranscriptBuilder.holdsTurn(held, after: held.last?.id)) // what the newest row as the start said
    }

    /// A turn this device joined partway, stored up to its steer: it starts at its message.
    @Test func aJoinedTurnStartsAtItsMessageNotItsSteer() {
        let partway = earlier + Array(turn.prefix(8))
        #expect(TranscriptBuilder.newestBeforeTurn(partway, ask: nil, sentAt: nil) == 114215)
        // A chat with nothing running: the newest row.
        #expect(TranscriptBuilder.newestBeforeTurn(earlier + turn, ask: nil, sentAt: nil) == 114226)
    }
}
