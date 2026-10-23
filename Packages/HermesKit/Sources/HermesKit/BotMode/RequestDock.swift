import Foundation
import HermesPush

/// When a waiting request steps aside for the compact dock above the composer (`needsYouDock`),
/// and what the dock can offer for it without opening the card (`docs/quick-actions.md` §1).
public enum RequestDock {
    /// The card steps aside for the dock while the person types on a phone-width screen.
    public static func docks(composerFocused: Bool, isWide: Bool) -> Bool {
        composerFocused && !isWide
    }

    /// A request that arrives while the keyboard is up over an empty composer gets the full card:
    /// the keyboard steps aside. Mid-typing, it docks and the typing carries on.
    public static func keyboardStepsAside(forArrivalWith composerFocused: Bool, draftIsEmpty: Bool, isWide: Bool) -> Bool {
        docks(composerFocused: composerFocused, isWide: isWide) && draftIsEmpty
    }

    /// The question's lines before the rest is one tap away, in the card.
    public static let questionLines = 4

    /// Hermes caps a question at four choices (`tools/clarify_tool.py` `MAX_CHOICES`).
    static let maxChips = 4
    /// A pick longer than this is read in the card, not answered from a chip.
    static let chipLength = 40

    /// One pick the dock offers as a chip: its label, and what's sent when it's tapped.
    public struct Chip: Sendable, Hashable, Identifiable {
        public var label: String
        public var answer: String
        public var id: String { answer }
    }

    /// The question one tap on a chip answers: a single question with a single pick. A form of
    /// several questions or picks opens the card.
    public static func chips(for request: HermesRequest) -> [Chip] {
        guard let question = singleQuestion(request), !question.multiSelect, !question.choices.isEmpty,
              question.choices.count <= maxChips else { return [] }
        let chips = question.choices.map { Chip(label: choiceParts($0).label, answer: $0) }
        guard chips.allSatisfy({ !$0.label.isEmpty && $0.label.count <= chipLength && !$0.label.contains(where: \.isNewline) }) else { return [] }
        return chips
    }

    /// The question a message from the composer answers: one question that takes words. Hermes
    /// offers "Other" under every single pick and asks open questions in words; picks of several
    /// are a list, so they're answered in the card.
    public static func typedQuestion(for request: HermesRequest) -> HermesRequest.Question? {
        guard let question = singleQuestion(request), !question.multiSelect else { return nil }
        return question
    }

    /// The answer to `request` (by its id) from `text` typed in the composer, the shape the card
    /// sends: `{answers: {qid: text}}`. `nil` when it doesn't take words or nothing was typed.
    public static func typedAnswer(_ text: String, to request: HermesRequest) -> JSONValue? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let question = typedQuestion(for: request) else { return nil }
        return .object(["answers": .object([question.id: .string(said)])])
    }

    /// The answer a chip sends.
    public static func pickedAnswer(_ chip: Chip, to request: HermesRequest) -> JSONValue? {
        guard let question = singleQuestion(request), question.choices.contains(chip.answer) else { return nil }
        return .object(["answers": .object([question.id: .string(chip.answer)])])
    }

    /// Deny and Allow in the dock only for a command shown whole there: short, not flagged and
    /// not a card fill. Anything else is read on its card first.
    public static func answersHere(_ approval: ApprovalRequest) -> Bool {
        guard !approval.smartDenied, !approval.isPaymentFill else { return false }
        return VisibleText.fitsAtAGlance(approval.isMemorySave ? approval.memoryText : approval.summary, limit: 44)
    }

    /// "Staging — Safe to reset" → label and detail, as the card shows a pick.
    public static func choiceParts(_ choice: String) -> (label: String, detail: String?) {
        for separator in [" — ", " – ", ": ", "\n"] {
            if let range = choice.range(of: separator) {
                return (String(choice[..<range.lowerBound]), String(choice[range.upperBound...]))
            }
        }
        return (choice, nil)
    }

    private static func singleQuestion(_ request: HermesRequest) -> HermesRequest.Question? {
        guard case .clarify(let questions) = request.kind, questions.count == 1 else { return nil }
        return questions[0]
    }
}

/// Everything waiting on the person in one chat, approvals first, the way the dock steps through
/// them ("1 of 3").
public enum WaitingItem: Sendable, Hashable, Identifiable {
    case approval(ApprovalRequest)
    case request(HermesRequest)

    public var id: String {
        switch self {
        case .approval(let approval): "a:" + approval.id
        case .request(let request): "r:" + request.id
        }
    }

    public static func all(approvals: [ApprovalRequest], requests: [HermesRequest]) -> [WaitingItem] {
        approvals.map(WaitingItem.approval) + requests.map(WaitingItem.request)
    }

    /// The item the dock shows: the one the person stepped to while it still waits, else the first.
    public static func shown(_ items: [WaitingItem], selected: String?) -> (item: WaitingItem, index: Int)? {
        if let selected, let index = items.firstIndex(where: { $0.id == selected }) { return (items[index], index) }
        return items.first.map { ($0, 0) }
    }
}
