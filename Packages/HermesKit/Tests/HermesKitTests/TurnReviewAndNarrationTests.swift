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
        let died = AssistantTurn(id: "t", steps: [.narration(id: "n", text: Self.narration)], state: .failed(LiveTurn.lostTrack))
        #expect(died.reading(stepsOpen: false)?.isInterim == true)
    }
}
