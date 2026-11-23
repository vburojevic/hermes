import Foundation
@testable import HermesKit
import Testing

/// A row shows its chat's unsent words after "Draft:" unless that chat is open (`docs/inbox.md` §2).
@Suite("Row draft")
struct RowDraftTests {
    /// What the audit found: words typed in a Bot's chat vanished from its row once another chat
    /// opened, though a regular chat's row kept them. A Bot's row shows them the same way.
    @Test func aBotsDraftShowsOnItsRowOnceItsChatIsLeft() {
        #expect(RowDraft.shown("check the 4-bit KV paper next", key: "bot:researcher", open: "bot:default") == "check the 4-bit KV paper next")
        #expect(RowDraft.shown("check this", key: "bot:researcher", open: nil) == "check this")
        #expect(RowDraft.shown("follow up", key: "chat_a", open: "bot:researcher") == "follow up")
    }

    /// The open chat's draft is in its composer, so its row leaves it out.
    @Test func theOpenChatsDraftStaysInTheComposer() {
        #expect(RowDraft.shown("check this", key: "bot:researcher", open: "bot:researcher") == nil)
        #expect(RowDraft.shown("check this", key: "chat_a", open: "chat_a") == nil)
    }

    /// No draft, or only spaces and new lines, shows the last message instead.
    @Test func blanksAreNoDraft() {
        #expect(RowDraft.shown(nil, key: "bot:ops", open: nil) == nil)
        #expect(RowDraft.shown("", key: "bot:ops", open: nil) == nil)
        #expect(RowDraft.shown("  \n\t", key: "bot:ops", open: nil) == nil)
    }
}
