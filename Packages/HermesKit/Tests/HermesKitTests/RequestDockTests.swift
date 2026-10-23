import Foundation
import Testing
@testable import HermesKit

@Suite("The dock for what's waiting while you type")
struct RequestDockTests {
    private func clarify(_ questions: [HermesRequest.Question], id: String = "srq-1") -> HermesRequest {
        HermesRequest(id: id, method: "clarify", kind: .clarify(questions))
    }

    private let dose = HermesRequest.Question(
        id: "dose", question: "Omega-3 1000 mg: how many capsules a day, and when? The label says one or two with a meal.",
        choices: ["1 with breakfast (Recommended)", "1 with dinner", "2 with dinner"]
    )

    @Test func aQuestionOverAnEmptyComposerGetsTheFullCard() {
        // Keyboard up after sending, nothing typed: the keyboard steps aside for the card.
        #expect(RequestDock.keyboardStepsAside(forArrivalWith: true, draftIsEmpty: true, isWide: false))
        // Mid-typing: the question docks and the typing carries on.
        #expect(!RequestDock.keyboardStepsAside(forArrivalWith: true, draftIsEmpty: false, isWide: false))
        #expect(RequestDock.docks(composerFocused: true, isWide: false))
        // Keyboard down, or a wide screen where the card never docks: nothing to move.
        #expect(!RequestDock.keyboardStepsAside(forArrivalWith: false, draftIsEmpty: true, isWide: false))
        #expect(!RequestDock.keyboardStepsAside(forArrivalWith: true, draftIsEmpty: true, isWide: true))
        #expect(!RequestDock.docks(composerFocused: true, isWide: true))
    }

    @Test func aSinglePickIsAnsweredFromChips() {
        let request = clarify([dose])
        let chips = RequestDock.chips(for: request)
        #expect(chips.map(\.label) == ["1 with breakfast (Recommended)", "1 with dinner", "2 with dinner"])
        // The chip sends the pick as Hermes offered it, by the question's id.
        #expect(RequestDock.pickedAnswer(chips[1], to: request) == .object(["answers": .object(["dose": .string("1 with dinner")])]))
    }

    @Test func aPickWithDetailShowsItsLabel() {
        let request = clarify([.init(id: "db", question: "Which database first?", choices: ["Staging — Safe to reset", "Production — Takes a backup first"])])
        let chips = RequestDock.chips(for: request)
        #expect(chips.map(\.label) == ["Staging", "Production"])
        #expect(chips.map(\.answer) == ["Staging — Safe to reset", "Production — Takes a backup first"])
    }

    @Test func picksTooLongOrSeveralOpenTheCard() {
        let long = clarify([.init(id: "swap", question: "Swap keywords?", choices: [
            "Yes, research and draft the swap, then note which keywords changed and why", "Leave keywords as they are",
        ])])
        #expect(RequestDock.chips(for: long).isEmpty)
        let multi = clarify([.init(id: "notes", question: "Which changes?", choices: ["A", "B"], multiSelect: true)])
        #expect(RequestDock.chips(for: multi).isEmpty)
        let steps = clarify([dose, .init(id: "budget", question: "Budget?")])
        #expect(RequestDock.chips(for: steps).isEmpty)
        let open = clarify([.init(id: "skip", question: "Which topics should the digest skip?")])
        #expect(RequestDock.chips(for: open).isEmpty)
        let secret = HermesRequest(id: "srq-2", method: "secret", kind: .secret(envVar: "API_KEY", prompt: nil))
        #expect(RequestDock.chips(for: secret).isEmpty)
    }

    @Test func wordsFromTheComposerAnswerAQuestionThatTakesThem() {
        // A single pick takes words too (Hermes's "Other" row), and an open question only words.
        let request = clarify([dose])
        #expect(RequestDock.typedAnswer("  2, one at lunch  ", to: request) == .object(["answers": .object(["dose": .string("2, one at lunch")])]))
        let open = clarify([.init(id: "skip", question: "Which topics?")])
        #expect(RequestDock.typedAnswer("sports", to: open) == .object(["answers": .object(["skip": .string("sports")])]))
        #expect(RequestDock.typedAnswer("   ", to: open) == nil)
    }

    @Test func listsFormsAndOtherRequestsAreNotAnsweredInWords() {
        let multi = clarify([.init(id: "notes", question: "Which changes?", choices: ["A", "B"], multiSelect: true)])
        #expect(RequestDock.typedAnswer("A", to: multi) == nil)
        #expect(RequestDock.typedAnswer("A", to: clarify([dose, .init(id: "b", question: "B?")])) == nil)
        // A password never comes from the composer.
        let sudo = HermesRequest(id: "srq-3", method: "sudo", kind: .sudo(command: "sudo true"))
        #expect(RequestDock.typedAnswer("hunter2", to: sudo) == nil)
    }

    @Test func allowOnlyBesideAWholeUnflaggedCommand() {
        let short = ApprovalRequest(requestID: "r1", command: "rm -rf ./build", description: "Recursive delete", choices: [.once, .deny])
        #expect(RequestDock.answersHere(short))
        var flagged = short
        flagged.smartDenied = true
        #expect(!RequestDock.answersHere(flagged))
        let long = ApprovalRequest(requestID: "r2", command: "rm -rf ./build && make release && make archive && open ./dist",
                                   description: nil, choices: [.once, .deny])
        #expect(!RequestDock.answersHere(long))
        let twoLines = ApprovalRequest(requestID: "r3", command: "cd /tmp\nrm -rf x", description: nil, choices: [.once, .deny])
        #expect(!RequestDock.answersHere(twoLines))
    }

    @Test func severalWaitingStepThroughInOrder() {
        let approval = ApprovalRequest(requestID: "r1", command: "ls", description: nil, choices: [.once, .deny])
        let items = WaitingItem.all(approvals: [approval], requests: [clarify([dose], id: "srq-a"), clarify([dose], id: "srq-b")])
        #expect(items.map(\.id) == ["a:r1", "r:srq-a", "r:srq-b"])
        #expect(WaitingItem.shown(items, selected: nil)?.index == 0)
        #expect(WaitingItem.shown(items, selected: "r:srq-b")?.index == 2)
        // The one stepped to was answered: back to the first still waiting.
        #expect(WaitingItem.shown(items, selected: "r:gone")?.index == 0)
        #expect(WaitingItem.shown([], selected: nil) == nil)
    }
}
