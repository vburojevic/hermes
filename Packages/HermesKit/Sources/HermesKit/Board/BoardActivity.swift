import Foundation

/// A card's event in plain words (`kanbanEventRow`): "Hermes picked it up", "Asked for review",
/// "Checks passed". `who` is the Bot's display name for the event's profile, or the card's
/// assignee. Events with nothing to say to a person read nil and are left out.
public struct BoardActivityLine: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case plain, good, attention, bad
    }

    public var text: String
    public var symbol: String
    public var tone: Tone

    public init(text: String, symbol: String, tone: Tone = .plain) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    public static func line(for event: BoardEvent, who: String, columnTitle: (String) -> String) -> BoardActivityLine? {
        let payload = event.payload
        switch event.kind {
        case "created": return .init(text: String(localized: "Added to the board"), symbol: "plus.circle")
        case "imported": return .init(text: String(localized: "Brought in from another board"), symbol: "square.and.arrow.down")
        case "edited": return .init(text: String(localized: "Edited"), symbol: "pencil")
        case "specified": return .init(text: String(localized: "Hermes wrote it up"), symbol: "text.badge.star")
        case "decomposed": return .init(text: String(localized: "Split into cards"), symbol: "square.split.2x1")
        case "assigned":
            if let to = payload?["assignee"]?.stringValue, !to.isEmpty {
                return .init(text: String(localized: "Given to \(to)"), symbol: "person.crop.circle")
            }
            return .init(text: String(localized: "Given to nobody"), symbol: "person.crop.circle.badge.xmark")
        case "reprioritized": return .init(text: String(localized: "Priority changed"), symbol: "arrow.up.arrow.down")
        case "linked": return .init(text: String(localized: "Now waits for another card"), symbol: "link")
        case "unlinked": return .init(text: String(localized: "No longer waits for another card"), symbol: "link")
        case "dependency_wait": return .init(text: String(localized: "Waiting for the cards before it"), symbol: "hourglass")
        case "promoted", "promoted_manual": return .init(text: String(localized: "Ready to start"), symbol: "play.circle")
        case "scheduled": return .init(text: String(localized: "Scheduled"), symbol: "clock")
        case "claimed": return .init(text: String(localized: "\(who) picked it up"), symbol: "figure.walk")
        case "commented":
            let author = payload?["author"]?.stringValue ?? ""
            let fromPerson = ["dashboard", "app", "you", "user", ""].contains(author.lowercased())
            return .init(text: fromPerson ? String(localized: "You commented") : String(localized: "\(author) commented"), symbol: "text.bubble")
        case "attached": return .init(text: String(localized: "File attached"), symbol: "paperclip")
        case "attachment_removed": return .init(text: String(localized: "File removed"), symbol: "paperclip")
        case "blocked":
            switch payload?["kind"]?.stringValue {
            case "needs_input", nil: return .init(text: String(localized: "\(who) needs you"), symbol: "hand.raised", tone: .attention)
            case "capability": return .init(text: String(localized: "\(who) can't go on without you"), symbol: "hand.raised", tone: .attention)
            default: return .init(text: String(localized: "Blocked"), symbol: "pause.circle", tone: .attention)
            }
        case "block_loop_detected": return .init(text: String(localized: "Kept getting stuck, back to Triage"), symbol: "arrow.uturn.backward", tone: .attention)
        case "unblocked": return .init(text: String(localized: "Back to Ready"), symbol: "play.circle")
        case "review_requested": return .init(text: String(localized: "Asked for review"), symbol: "eye")
        case "review_reopened": return .init(text: String(localized: "Reopened"), symbol: "arrow.uturn.backward")
        case "changes_requested": return .init(text: String(localized: "Changes asked for"), symbol: "arrow.uturn.backward", tone: .attention)
        case "pr_acceptance":
            if payload?["ok"]?.boolValue == true { return .init(text: String(localized: "Checks passed"), symbol: "checkmark.seal", tone: .good) }
            return .init(text: String(localized: "Checks didn't pass"), symbol: "xmark.seal", tone: .bad)
        case "completed": return .init(text: String(localized: "Done"), symbol: "checkmark.circle", tone: .good)
        case "completion_blocked_empty_result", "completion_blocked_hallucination", "suspected_hallucinated_references":
            return .init(text: String(localized: "Finishing was refused: the result didn't hold up"), symbol: "exclamationmark.triangle", tone: .bad)
        case "reclaimed": return .init(text: String(localized: "Stopped, back to Ready"), symbol: "stop.circle")
        case "stale": return .init(text: String(localized: "\(who) stopped answering"), symbol: "exclamationmark.triangle", tone: .attention)
        case "crashed": return .init(text: String(localized: "The run crashed"), symbol: "exclamationmark.octagon", tone: .bad)
        case "timed_out": return .init(text: String(localized: "The run ran out of time"), symbol: "timer", tone: .bad)
        case "gave_up":
            let tries = payload?["failures"]?.doubleValue.map { Int($0) } ?? 0
            return .init(text: tries > 0 ? String(localized: "Stopped after \(tries) tries") : String(localized: "Stopped trying"), symbol: "xmark.octagon", tone: .bad)
        case "archived": return .init(text: String(localized: "Archived"), symbol: "archivebox")
        case "descendant_invalidated": return .init(text: String(localized: "Reopened because a card before it changed"), symbol: "arrow.uturn.backward")
        case "status":
            guard let to = payload?["status"]?.stringValue else { return nil }
            return .init(text: String(localized: "Moved to \(columnTitle(to))"), symbol: "arrow.right.circle")
        default:
            return nil
        }
    }
}
