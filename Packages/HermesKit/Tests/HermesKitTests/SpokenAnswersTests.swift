import Foundation
import Testing
@testable import HermesKit

@Suite("Answering by voice")
struct SpokenAnswersTests {
    private let build = ApprovalRequest(requestID: "r1", command: "make release", description: "Run the release build", choices: [.once, .session, .always, .deny])
    private let delete = ApprovalRequest(requestID: "r2", command: "rm -rf ./build && make release", description: "recursive delete", choices: [.once, .session, .always, .deny])

    @Test func theThreeAnswers() {
        #expect(SpokenAnswers.approval("Allow once.", for: build, shownFor: 3) == .allow(.once))
        #expect(SpokenAnswers.approval("allow in this chat", for: build, shownFor: 3) == .allow(.session))
        #expect(SpokenAnswers.approval("Deny", for: build, shownFor: 3) == .deny)
        #expect(SpokenAnswers.approval("yes, go ahead", for: build, shownFor: 3) == .allow(.once))
    }

    @Test func aNoCanBeSaidAnyWayAtAnyTime() {
        #expect(SpokenAnswers.approval("no", for: build, shownFor: 0.2) == .deny)
        #expect(SpokenAnswers.approval("don't do that", for: build, shownFor: 0.2) == .deny)
        #expect(SpokenAnswers.approval("Cancel it.", for: delete, shownFor: 0.2) == .deny)
    }

    @Test func aYesInTheFirstTwoSecondsIsRefused() {
        #expect(SpokenAnswers.approval("allow once", for: build, shownFor: 1.9) == .tooSoon)
        #expect(SpokenAnswers.approval("allow once", for: build, shownFor: 2.0) == .allow(.once))
    }

    @Test func alwaysFlaggedAndIrreversibleNeedATap() {
        #expect(SpokenAnswers.approval("always allow", for: build, shownFor: 5) == .needsTap(.always))
        var flagged = build
        flagged.smartDenied = true
        #expect(SpokenAnswers.approval("allow once", for: flagged, shownFor: 5) == .needsTap(.flagged))
        #expect(SpokenAnswers.approval("allow once", for: delete, shownFor: 5) == .needsTap(.irreversible))
    }

    @Test func allowInThisChatFallsBackWhenTheChatChoiceIsntOffered() {
        let onceOnly = ApprovalRequest(requestID: "r3", command: "ls", description: nil, choices: [.once, .deny])
        #expect(SpokenAnswers.approval("allow in this chat", for: onceOnly, shownFor: 5) == .allow(.once))
    }

    @Test func otherWordsArentAnAnswer() {
        #expect(SpokenAnswers.approval("what does that command do", for: build, shownFor: 5) == .notUnderstood)
        #expect(SpokenAnswers.approval("", for: build, shownFor: 5) == .notUnderstood)
        // A yes buried in a sentence isn't a yes.
        #expect(SpokenAnswers.approval("yes I think the build is broken anyway", for: build, shownFor: 5) == .notUnderstood)
    }

    @Test func whatCantBeTakenBack() {
        #expect(SpokenAnswers.isIrreversible(delete))
        #expect(SpokenAnswers.isIrreversible(ApprovalRequest(requestID: nil, command: "psql -c 'DROP TABLE users'", description: "SQL DROP", choices: [.once])))
        #expect(SpokenAnswers.isIrreversible(ApprovalRequest(requestID: nil, command: "stripe charges create --amount 900", description: nil, choices: [.once])))
        #expect(SpokenAnswers.isIrreversible(ApprovalRequest(requestID: nil, command: "git push --force origin main", description: nil, choices: [.once])))
        #expect(!SpokenAnswers.isIrreversible(build))
        #expect(!SpokenAnswers.isIrreversible(ApprovalRequest(requestID: nil, command: "df -h /volume1", description: nil, choices: [.once])))
    }

    @Test func clarifyChoicesBySayingThem() {
        let options = ["Keep the weekly ones", "Delete everything", "Only last month"]
        #expect(SpokenAnswers.choice("the second one", among: options) == 1)
        #expect(SpokenAnswers.choice("number one", among: options) == 0)
        #expect(SpokenAnswers.choice("The first.", among: options) == 0)
        #expect(SpokenAnswers.choice("the last one", among: options) == 2)
        #expect(SpokenAnswers.choice("third", among: options) == 2)
        #expect(SpokenAnswers.choice("delete everything", among: options) == 1)
        #expect(SpokenAnswers.choice("hmm let's say only last month please", among: options) == 2)
        #expect(SpokenAnswers.choice("fifth", among: options) == nil)
        #expect(SpokenAnswers.choice("something else entirely", among: options) == nil)
    }

    @Test func noiseIsNotATurn() {
        #expect(!SpokenAnswers.hasWords("."))
        #expect(!SpokenAnswers.hasWords(" … "))
        #expect(SpokenAnswers.hasWords("Stop."))
        #expect(SpokenAnswers.hasWords("42"))
    }

    @Test func captionTailsStartOnAWord() {
        #expect(SpokenAnswers.tail("Short line.", limit: 90) == "Short line.")
        let tail = SpokenAnswers.tail("Here’s the full picture of moving the app to Swift 6, step by step", limit: 40)
        #expect(tail.hasPrefix("…"))
        #expect(tail.count <= 40)
        #expect(tail == "…moving the app to Swift 6, step by step")
    }
}
