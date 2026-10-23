import Foundation

/// Hermes's background self-review of a reply (`review.summary`, agent/background_review.py). It
/// starts as the turn finishes and usually reports after the turn has ended, sometimes during the
/// next one; it stores no rows and sends no other event. The app shows it as a quiet note on the
/// reply it reviewed (`docs/chat.md` §1, 13), never as a row of its own between a turn and its
/// stored copy.
public enum ReviewNote {
    /// The note's words: Hermes's line without its CLI dressing ("💾 Self-improvement review: ").
    public static func text(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "Self-improvement review:") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    /// The reply the review is of: the turn that just ended (still on screen as it hands over to
    /// its stored rows), else the newest finished reply in the chat. Never a turn still running:
    /// a review landing during the next turn is of the one before it.
    public static func reviewed(in items: [TranscriptItem], live: AssistantTurn?) -> String? {
        if let live, !live.isWorking { return live.id }
        for item in items.reversed() {
            if case .assistant(let turn) = item, !turn.isWorking { return turn.id }
        }
        return nil
    }
}

extension AssistantTurn {
    /// What the turn reads as in the reply's place (`AssistantTurnView`). The reply when there is
    /// one. While Hermes works with the steps folded, what it last said between steps, muted, until
    /// it says more; a turn that died without a reply keeps that, muted. Narration is the turn's
    /// progress, never a grey half-reply left after it finished: a turn that finished with no reply
    /// but what it said along the way reads as those words.
    public func reading(stepsOpen: Bool) -> (text: String, isInterim: Bool)? {
        if !answer.isEmpty { return (answer, false) }
        guard !stepsOpen else { return nil }
        guard let said = steps.last(where: { if case .narration(_, let text) = $0 { !text.isEmpty } else { false } }),
              case .narration(_, let text) = said
        else { return nil }
        return (text, state != .complete)
    }
}
