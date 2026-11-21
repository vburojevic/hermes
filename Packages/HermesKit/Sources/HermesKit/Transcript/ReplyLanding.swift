import Foundation

/// The part of a reply its last element is in, where VoiceOver lands reading back onto the reply
/// after an earlier page came in (`docs/chat.md` §1): the last note under the reply, else its
/// actions, else its text, else its work line. Each case mirrors what `AssistantTurnView` draws,
/// from the bottom up.
public enum ReplyLanding: Sendable, Equatable {
    /// The work line: a turn with steps and no words, or one the app lost track of.
    case header
    /// The reply's text, where a reply has words but no actions (a widget's card included).
    case reply
    /// The line saying why it failed.
    case failure
    /// The actions row (More), whatever the reply's last block is: code, a table or an image too.
    case actions
    case usage, learned, memory, review, cards, context
}

extension AssistantTurn {
    /// Where VoiceOver lands on this turn (`ReplyLanding`). The view's own state comes in: whether
    /// the steps are open, the token use shows, Board cards show (the chat has a Board) and the
    /// reply is the latest on its branch, which is where the context notice shows.
    public func landing(stepsOpen: Bool, showsUsage: Bool, showsCards: Bool, isLatestOnBranch: Bool) -> ReplyLanding? {
        let finished = !isWorking
        if isLatestOnBranch, finished, let percent = usage?.contextPercent, percent >= 80 { return .context }
        if finished, showsCards, !addedCards.isEmpty { return .cards }
        if finished, review != nil { return .review }
        if finished, !memoryChanges.isEmpty { return .memory }
        if finished, !createdSkills.isEmpty { return .learned }
        // A turn the app lost track of ends on its line, which says so, whatever it said before.
        if lostTrack { return .header }
        switch state {
        case .complete:
            if usage != nil, showsUsage { return .usage }
            if !copyableText.isEmpty { return .actions }
        case .stopped:
            if !copyableText.isEmpty { return .actions }
        case .streaming, .waitingForApproval:
            break
        case .failed:
            return .failure
        }
        if reading(stepsOpen: stepsOpen) != nil { return .reply }
        return showsWork ? .header : nil
    }

    /// The turn draws its work line: steps, a plan, a turn working on no words yet, or one lost.
    public var showsWork: Bool {
        !steps.isEmpty || !plan.isEmpty || (isWorking && answer.isEmpty) || lostTrack
    }
}
