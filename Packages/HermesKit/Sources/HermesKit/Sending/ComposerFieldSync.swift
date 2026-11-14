import Foundation

/// Keeps the composer's field and the chat's draft in step while an input method composes a word
/// (`docs/composer.md` §5). Pinyin, Kana, Korean and the accent popup hold the word being composed
/// in the field as marked text until it's chosen, and the Mac's text view only reports the field
/// changed once it is. Until then the field is ahead of the draft, and putting the draft back
/// would throw the word away and move the caret.
public enum ComposerFieldSync: Equatable, Sendable {
    /// The field already shows the draft, or is ahead of it only by the word being composed.
    case nothing
    /// The draft changed from elsewhere (sent, cleared, a reference or dictated words): the field
    /// takes it.
    case applyDraft
    /// The person changed the field: the draft takes it.
    case takeField
    /// An input method is composing a word: the field is left alone until it's chosen or
    /// cancelled, when the draft that changed meanwhile is applied.
    case waitForWord

    /// The composer redrew. `synced` is the draft the field and the draft last agreed on, nil
    /// before they first have.
    public static func redraw<Draft: Equatable>(draft: Draft, field: Draft, synced: Draft?, composing: Bool) -> Self {
        if field == draft { return .nothing }
        guard composing else { return .applyDraft }
        // Unchanged since they last agreed: the field is only ahead by the marked word.
        return draft == synced ? .nothing : .waitForWord
    }

    /// The field changed under the person's hands, or its word was chosen or cancelled.
    /// `draftWaiting` says a draft from elsewhere arrived while a word was being composed.
    public static func fieldChanged<Draft: Equatable>(draft: Draft, field: Draft, synced: Draft?, composing: Bool, draftWaiting: Bool) -> Self {
        guard draftWaiting else { return field == draft ? .nothing : .takeField }
        if composing { return .waitForWord }
        if field == draft { return .nothing }
        // The draft that arrived meanwhile wins unless it went back to what the field started from.
        return draft == synced ? .takeField : .applyDraft
    }
}
