import Testing
@testable import HermesKit

@Suite("Composer field and draft while an input method composes")
struct ComposerFieldSyncTests {
    // The issue's steps: 你好世界 in the field, the caret after 你好, "dajia" being composed.
    private let draft = "你好世界"
    private let composingField = "你好dajia世界"

    @Test func aRedrawWhileComposingLeavesTheWordAlone() {
        #expect(ComposerFieldSync.redraw(draft: draft, field: composingField, synced: draft, composing: true) == .nothing)
    }

    @Test func aRedrawWithNothingComposedPutsAChangedDraftBack() {
        // Sent, Edit and Resend, dictated words: the field takes what the draft says.
        #expect(ComposerFieldSync.redraw(draft: "", field: draft, synced: draft, composing: false) == .applyDraft)
        #expect(ComposerFieldSync.redraw(draft: draft, field: draft, synced: draft, composing: false) == .nothing)
        // Before the field and the draft first agree (a field just made).
        #expect(ComposerFieldSync.redraw(draft: draft, field: "", synced: nil, composing: false) == .applyDraft)
    }

    @Test func aDraftChangedWhileComposingWaitsForTheWord() {
        // Sent from the button, cleared, or a reference inserted while "dajia" is still marked.
        #expect(ComposerFieldSync.redraw(draft: "", field: composingField, synced: draft, composing: true) == .waitForWord)
        #expect(ComposerFieldSync.redraw(draft: "", field: composingField, synced: nil, composing: true) == .waitForWord)
        // Already what the field shows: nothing to wait for.
        #expect(ComposerFieldSync.redraw(draft: composingField, field: composingField, synced: draft, composing: true) == .nothing)
    }

    @Test func choosingTheWordCatchesTheDraftUp() {
        #expect(ComposerFieldSync.fieldChanged(draft: draft, field: "你好大家世界", synced: draft, composing: false, draftWaiting: false) == .takeField)
        // Typing that leaves the draft as it was.
        #expect(ComposerFieldSync.fieldChanged(draft: draft, field: draft, synced: draft, composing: false, draftWaiting: false) == .nothing)
        // A field that reports each marked letter (UITextView) keeps the draft in step as it goes.
        #expect(ComposerFieldSync.fieldChanged(draft: draft, field: composingField, synced: draft, composing: true, draftWaiting: false) == .takeField)
    }

    @Test func aDraftThatWaitedIsAppliedOnceTheWordIsChosenOrCancelled() {
        // Still composing: it keeps waiting.
        #expect(ComposerFieldSync.fieldChanged(draft: "", field: "你好da世界", synced: draft, composing: true, draftWaiting: true) == .waitForWord)
        // Chosen: the draft from elsewhere goes in.
        #expect(ComposerFieldSync.fieldChanged(draft: "", field: "你好大家世界", synced: draft, composing: false, draftWaiting: true) == .applyDraft)
        // Cancelled, and the field already shows the draft that waited.
        #expect(ComposerFieldSync.fieldChanged(draft: draft, field: draft, synced: "你好", composing: false, draftWaiting: true) == .nothing)
        // The draft went back to what the field started from meanwhile: the chosen word stays.
        #expect(ComposerFieldSync.fieldChanged(draft: draft, field: "你好大家世界", synced: draft, composing: false, draftWaiting: true) == .takeField)
    }
}
