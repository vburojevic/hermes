import Foundation

/// The stored rows that replace the ones shown while a turn ran (your message, the reply, and
/// around a redirect the work before it and the redirect) keep their on-screen identities, so the
/// rows aren't laid out again and open folds stay open (`docs/chat.md` §4).
public enum IdentityHandOver {
    /// Each stored row in `items` that takes over a row of `shown`, as stored id → on-screen id
    /// (a row whose stored copy kept its id is left out). Matched from the end; a reply never
    /// matches across the person's message, so an older reply never takes a live turn's place (a
    /// turn that stored nothing).
    /// - Parameters:
    ///   - existing: the rows on screen before these stored rows came.
    ///   - before: the rows on screen when the turn started. One of them never takes the turn's
    ///     identity: a silent reply (dropped from the transcript) would otherwise hand its key,
    ///     and its open folds, to the reply before it. A row that came in while the turn ran (a
    ///     delivery, a routine's post) is passed over, wherever its stored copy lands, unless
    ///     it's the person's message.
    public static func matches(shown: [TranscriptItem], in items: [TranscriptItem],
                               existing: Set<String>, before: Set<String>) -> [String: String] {
        let shownIDs = Set(shown.map(\.id))
        var matches: [String: String] = [:]
        var index = items.count - 1
        for row in shown.reversed() {
            var match: Int?
            var probe = index
            while probe >= 0 {
                let stored = items[probe]
                if existing.contains(stored.id), !shownIDs.contains(stored.id) {
                    if before.contains(stored.id) || isPersonsMessage(stored) { break }
                    probe -= 1
                    continue
                }
                if case .assistant = row {
                    if case .assistant = stored { match = probe; break }
                    if isPersonsMessage(stored) { break } // no stored reply (yet): the message still matches
                } else if isPersonsMessage(stored) {
                    match = probe
                    break
                }
                probe -= 1
            }
            guard let match else { continue }
            if items[match].id != row.id { matches[items[match].id] = row.id }
            index = match - 1
        }
        return matches
    }

    private static func isPersonsMessage(_ item: TranscriptItem) -> Bool {
        if case .user(let entry) = item { entry.isFromPerson && !entry.isSteer } else { false }
    }
}
