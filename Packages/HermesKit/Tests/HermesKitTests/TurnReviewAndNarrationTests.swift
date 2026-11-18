import Foundation
import Testing
@testable import HermesKit

/// What came with the ARGUS turn besides its reply: the self-review that showed as a row of its
/// own between the turn and its stored copy, and the narration left as a grey half-reply.
@Suite("A turn's review and narration")
struct TurnReviewAndNarrationTests {
    private static let narration = "A newer release exists (v1.40.5). I'll check what it adds and upgrade."
    private static let reply = "Yes: 1.40.5 imports blood records from PDF and CSV."

    // MARK: The self-review

    /// Hermes reviews the reply in the background after the turn and says so once
    /// (`review.summary`); it goes on the reply it reviewed, quietly, never as a row of its own.
    @Test func theReviewGoesOnTheReplyItReviewed() {
        #expect(ReviewNote.text("💾 Self-improvement review: Skill 'logging-supplements' patched") == "Skill 'logging-supplements' patched")
        #expect(ReviewNote.text("no issues found") == "no issues found")
        #expect(ReviewNote.text("  ") == nil)
        let built: [TranscriptItem] = [
            .user(UserEntry(id: "m10", text: "Check argus")),
            .assistant(AssistantTurn(id: "tm11", answer: Self.reply)),
        ]
        // The turn just ended, still on screen as it hands over: that one.
        #expect(ReviewNote.reviewed(in: built, live: AssistantTurn(id: "live-1", answer: Self.reply)) == "live-1")
        // Nothing live: the latest reply.
        #expect(ReviewNote.reviewed(in: built, live: nil) == "tm11")
        // It came while the next turn runs: the reply before it, not the one being written.
        let next = LiveTurn(id: "live-2", sessionID: "rt").turn
        #expect(ReviewNote.reviewed(in: built, live: next) == "tm11")
    }

    // MARK: Narration

    /// What Hermes said while it worked is part of the turn's progress: muted in the reply's place
    /// only while it works (or when it died without a reply). A finished turn shows its reply; one
    /// that finished with no reply but its narration shows that, as its words, not a grey half-reply.
    @Test func narrationIsProgressNotAReply() {
        var working = AssistantTurn(id: "t", steps: [.narration(id: "n", text: Self.narration)], state: .streaming)
        #expect(working.reading(stepsOpen: false)?.isInterim == true)
        #expect(working.reading(stepsOpen: true) == nil)
        working.state = .complete
        #expect(working.reading(stepsOpen: false)?.isInterim == false)
        working.answer = Self.reply
        #expect(working.reading(stepsOpen: false)?.text == Self.reply)
        let died = AssistantTurn(id: "t", steps: [.narration(id: "n", text: Self.narration)], state: .failed(LostTurn.unreachable.line))
        #expect(died.reading(stepsOpen: false)?.isInterim == true)
    }

    // MARK: A reply written beside a memory save

    private static let aside = "Your flight leaves at 07:40 on Friday. I've noted that you prefer aisle seats."

    private static func play(_ events: [TurnEvent]) -> AssistantTurn {
        var live = LiveTurn(id: "t", sessionID: "s")
        for (seq, event) in events.enumerated() { live.apply(SequencedTurnEvent(seq: seq + 1, event: event)) }
        return live.snapshot
    }

    /// The model wrote its reply in the message that saved a memory, and its follow-up was empty:
    /// Hermes keeps those words as the reply (`fallback_prior_turn_content`) and `run.completed`
    /// says so. The words show once, as the reply, never also as narration in the thinking section.
    @Test func aReplyBesideAMemorySaveIsTheReply() {
        let turn = Self.play([
            .textDelta(Self.aside),
            .commentary(Self.aside, alreadyStreamed: true),
            .toolStarted(id: nil, name: "memory", preview: "Prefers aisle seats.", at: nil),
            .toolFinished(id: nil, name: "memory", failed: false, duration: 0.6, resultPreview: "Entry added.", at: nil),
            .completed(output: Self.aside, usage: nil, runtime: nil),
        ])
        #expect(turn.answer == Self.aside)
        #expect(!turn.steps.contains { if case .narration = $0 { true } else { false } })
        #expect(turn.reading(stepsOpen: true)?.text == Self.aside)
        // The socket ends the same turn with `message.complete`, read as its final text first.
        let socket = Self.play([
            .textDelta(Self.aside),
            .toolStarted(id: "c1", name: "memory", preview: nil, at: nil),
            .toolFinished(id: "c1", name: "memory", failed: false, duration: 0.6, resultPreview: nil, at: nil),
            .finalText(Self.aside),
            .completed(output: Self.aside, usage: nil, runtime: nil),
        ])
        #expect(socket.answer == Self.aside)
        #expect(socket.steps.count == 1)
    }

    /// Words before a call that does work are narration, even when the reply repeats them.
    @Test func wordsBeforeRealWorkStayNarration() {
        let turn = Self.play([
            .textDelta(Self.narration),
            .toolStarted(id: nil, name: "terminal", preview: "brew upgrade argus", at: nil),
            .toolFinished(id: nil, name: "terminal", failed: false, duration: 1, resultPreview: "ok", at: nil),
            .completed(output: Self.narration, usage: nil, runtime: nil),
        ])
        #expect(turn.steps.first == .narration(id: "t-s0", text: Self.narration))
    }
}
