import Foundation

/// The draft a row shows after "Draft:" (`docs/inbox.md` §2): a chat's or a Bot Chat's unsent words,
/// unless its chat is open, where they're in the composer. Keys are `UnreadStore`'s.
public enum RowDraft {
    /// The draft as typed, or nil when its chat is open or it's only blanks.
    public static func shown(_ draft: String?, key: String, open: String?) -> String? {
        guard key != open, let draft, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }
}
