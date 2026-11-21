import Foundation
import Testing
@testable import HermesKit

/// Where VoiceOver lands on a reply when an earlier page comes in above it (`docs/chat.md` §1).
struct ReplyLandingTests {
    private func landing(_ turn: AssistantTurn, showsUsage: Bool = false) -> ReplyLanding? {
        turn.landing(stepsOpen: false, showsUsage: showsUsage, showsCards: false, isLatestOnBranch: false)
    }

    @Test func aFinishedReplyWithWordsLandsOnItsActions() {
        #expect(landing(AssistantTurn(id: "a", answer: "Done, the tests pass.")) == .actions)
    }

    @Test func aReplyEndingInCodeLandsOnItsActionsToo() {
        let turn = AssistantTurn(id: "a", answer: "Here it is:\n\n```swift\nprint(\"hi\")\n```")
        #expect(landing(turn) == .actions)
    }

    @Test func aStoppedReplyWithWordsLandsOnItsActions() {
        #expect(landing(AssistantTurn(id: "a", answer: "Half of it", state: .stopped)) == .actions)
    }

    @Test func aReplyThatIsOnlyAWidgetLandsOnItsText() {
        // A directive with no alt leaves the reply nothing to copy, so it has no actions: it lands
        // on the widget, which ends its text.
        let turn = AssistantTurn(id: "a", answer: #"::widget{id="w_today01"}"#)
        #expect(turn.copyableText.isEmpty)
        #expect(landing(turn) == .reply)
    }

    @Test func aWidgetWithWordsLandsOnItsActions() {
        let turn = AssistantTurn(id: "a", answer: #"::widget{id="w_today01", alt="Today: stretch."}"#)
        #expect(landing(turn) == .actions)
    }

    @Test func aTurnTheAppLostTrackOfLandsOnItsLine() {
        let turn = AssistantTurn(id: "a", answer: "I started on it", state: .failed(LostTurn.unreachable.line))
        #expect(turn.lostTrack)
        #expect(landing(turn) == .header)
        let gone = AssistantTurn(id: "b", state: .failed(LostTurn.gone.line))
        #expect(landing(gone) == .header)
    }

    @Test func aFailedTurnLandsOnWhyItFailed() {
        #expect(landing(AssistantTurn(id: "a", answer: "Partly", state: .failed("The model refused."))) == .failure)
    }

    @Test func shownUsageIsTheLastThingAReplyDraws() {
        var turn = AssistantTurn(id: "a", answer: "Done.")
        turn.usage = TokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12)
        #expect(landing(turn, showsUsage: true) == .usage)
        #expect(landing(turn, showsUsage: false) == .actions)
    }

    @Test func aTurnWithStepsAndNoWordsLandsOnItsWorkLine() {
        let turn = AssistantTurn(id: "a", steps: [.reasoning(id: "r", text: "Looking at the tests")], state: .stopped)
        #expect(turn.showsWork)
        #expect(landing(turn) == .header)
    }

    @Test func aNoteUnderTheReplyComesLast() {
        var turn = AssistantTurn(id: "a", answer: "Done.")
        turn.review = "Checked twice."
        #expect(landing(turn) == .review)
    }
}
