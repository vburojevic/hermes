import Foundation
import HermesKit

/// The Board's words (`docs/board.md`): card badges, run times, and the gateway's refusals
/// retold in the app's words. A card is never a "task" here: Tasks are scheduled jobs.
enum BoardCopy {
    /// "20 s", "6 min", "2 h", "3 d".
    static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 60 { return String(localized: "\(seconds) s") }
        if seconds < 3600 { return String(localized: "\(seconds / 60) min") }
        if seconds < 86_400 { return String(localized: "\(seconds / 3600) h") }
        return String(localized: "\(seconds / 86_400) d")
    }

    /// "now", "6 min ago", "2 h ago".
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return String(localized: "now") }
        return String(localized: "\(duration(seconds)) ago")
    }

    static func cards(_ count: Int) -> String {
        count == 1 ? String(localized: "1 card") : String(localized: "\(count) cards")
    }

    /// The estimate line under New Card: "About 40k tokens · medium".
    static func estimate(_ estimate: BoardEstimate) -> String {
        let tokens = estimate.tokens >= 1000 ? "\(Int((Double(estimate.tokens) / 1000).rounded()))k" : "\(estimate.tokens)"
        let size: String? = switch estimate.complexity {
        case "S": String(localized: "small")
        case "M": String(localized: "medium")
        case "L": String(localized: "large")
        default: nil
        }
        if let size { return String(localized: "About \(tokens) tokens · \(size)") }
        return String(localized: "About \(tokens) tokens")
    }

    /// A board slug for a project ("hermes-app").
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "board" : trimmed
    }

    // MARK: Badges

    struct Badge: Equatable {
        var title: String
        var symbol: String
        var style: TagLabel.Style
    }

    /// The badge at the top of a card (`kanbanCard` head); nil when the card doesn't need one.
    static func badge(for state: BoardCardState, checks: BoardChecks?, now: Date) -> Badge? {
        switch state {
        case .running(let since):
            let title = since.map { String(localized: "Running · \(duration(now.timeIntervalSince($0)))") } ?? String(localized: "Running")
            return Badge(title: title, symbol: "timer", style: .ink)
        case .stale(let since):
            return Badge(title: String(localized: "No word for \(duration(now.timeIntervalSince(since)))"), symbol: "exclamationmark.triangle.fill", style: .warning)
        case .needsYou:
            return Badge(title: String(localized: "Needs you"), symbol: "hand.raised.fill", style: .warning)
        case .blocked:
            return Badge(title: String(localized: "Blocked"), symbol: "pause.circle.fill", style: .neutral)
        case .waiting(let parents):
            let title = parents == 1 ? String(localized: "After 1 card") : String(localized: "After \(parents) cards")
            return Badge(title: title, symbol: "link", style: .neutral)
        case .review:
            return reviewBadge(checks)
        case .gaveUp(let tries):
            let title = tries == 1 ? String(localized: "Stopped after 1 try") : String(localized: "Stopped after \(tries) tries")
            return Badge(title: title, symbol: "xmark.octagon.fill", style: .danger)
        case .done(let at):
            let title = at.map { String(localized: "Done · \(ago($0, now: now))") } ?? String(localized: "Done")
            return Badge(title: title, symbol: "checkmark", style: .neutral)
        case .idle, .parent:
            return nil
        }
    }

    static func reviewBadge(_ checks: BoardChecks?) -> Badge {
        guard let checks else { return Badge(title: String(localized: "In review"), symbol: "eye", style: .neutral) }
        let pr = checks.prNumber.map { "PR #\($0)" } ?? String(localized: "PR")
        if checks.ok { return Badge(title: String(localized: "\(pr) · checks passed"), symbol: "checkmark.circle.fill", style: .success) }
        if checks.failingCount > 0 {
            let title = checks.failingCount == 1 ? String(localized: "\(pr) · 1 check failed") : String(localized: "\(pr) · \(checks.failingCount) checks failed")
            return Badge(title: title, symbol: "xmark.circle.fill", style: .danger)
        }
        if checks.pendingCount > 0 { return Badge(title: String(localized: "\(pr) · checks running"), symbol: "clock", style: .neutral) }
        return Badge(title: String(localized: "\(pr) · checks unread"), symbol: "questionmark.circle", style: .neutral)
    }

    /// The state in words, for VoiceOver ("Running for 6 minutes", "Needs you").
    static func spoken(_ state: BoardCardState, checks: BoardChecks?, now: Date) -> String? {
        switch state {
        case .running(let since):
            guard let since else { return String(localized: "Running") }
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            return minutes == 1 ? String(localized: "Running for 1 minute") : String(localized: "Running for \(minutes) minutes")
        case .stale(let since):
            let minutes = max(1, Int(now.timeIntervalSince(since) / 60))
            return String(localized: "Running, no word for \(minutes) minutes")
        case .parent(let done, let total):
            return String(localized: "\(done) of \(total) sub-cards done")
        default:
            return badge(for: state, checks: checks, now: now)?.title
        }
    }

    // MARK: Refusals

    static func message(for error: any Error) -> String {
        if case BackendClient.Failure.http(let status, let detail) = error {
            return refusal(detail ?? String(localized: "The gateway answered \(status)."))
        }
        return cardWords(error.localizedDescription)
    }

    /// A gateway refusal in the app's words.
    static func refusal(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("blocked by parent") || lower.contains("unsatisfied parent") {
            return String(localized: "It waits for cards that aren't done yet.")
        }
        if lower.contains("'running' directly") { return String(localized: "Only Hermes starts runs. Move it to Ready instead.") }
        if lower.contains("not valid from current state") { return String(localized: "The board doesn't allow that move.") }
        if lower.contains("not in a claimable state") { return String(localized: "It isn't running any more.") }
        if lower.contains("still running") { return String(localized: "It's running. Stop it first.") }
        if lower.contains("title cannot be empty") || lower.contains("title is required") { return String(localized: "A card needs a title.") }
        if lower.contains("board") && (lower.contains("does not exist") || lower.contains("is archived")) {
            return String(localized: "This board isn't on the gateway any more.")
        }
        return cardWords(text)
    }

    /// Why Approve was refused: the failing required checks, else the gateway's reason.
    static func approvalRefusal(detail: BoardCardDetail?, error: any Error) -> String {
        if let checks = detail?.checks, !checks.ok {
            let failing = checks.checks.filter(\.failed).map(\.name)
            if failing.count == 1 { return String(localized: "Approve waits for the PR's required checks: \(failing[0]) didn't pass.") }
            if !failing.isEmpty { return String(localized: "Approve waits for the PR's required checks: \(failing.formatted(.list(type: .and))) didn't pass.") }
            if checks.pendingCount > 0 { return String(localized: "Approve waits for the PR's required checks to finish.") }
            if let reason = checks.detail { return refusal(reason) }
        }
        if let reason = detail?.refusal {
            // "PR acceptance failure: <what>. <how to recover>": the first sentence is the reason.
            let first = reason.components(separatedBy: ". ").first ?? reason
            return refusal(first.hasSuffix(".") ? first : first + ".")
        }
        return message(for: error)
    }

    /// The gateway's word for a card, replaced.
    static func cardWords(_ text: String) -> String {
        var result = text
        for (word, replacement) in [("Tasks", "Cards"), ("tasks", "cards"), ("Task", "Card"), ("task", "card")] {
            result = result.replacingOccurrences(of: "\\b\(word)\\b", with: replacement, options: .regularExpression)
        }
        return result
    }
}
