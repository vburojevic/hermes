import Foundation
@testable import HermesKit
import HermesPush
import Testing

/// What an approval asks to run shows as it would run.
@Suite("Visible approval text")
struct VisibleTextTests {
    @Test func reorderingAndInvisibleCharactersShowTheirCodes() {
        let tricked = "echo safe\u{202E}fr- mr\u{202C} && ls\u{200B}"
        let shown = VisibleText.of(tricked)
        #expect(shown == "echo safe⟨U+202E⟩fr- mr⟨U+202C⟩ && ls⟨U+200B⟩")
        #expect(VisibleText.of("a\rb\u{1B}[2Kc") == "a⟨U+000D⟩b⟨U+001B⟩[2Kc")
    }

    @Test func ordinaryCommandsAreUntouched() {
        let command = "cd ~/proj && npm test\n\tgit status # ünïcödé ok"
        #expect(VisibleText.of(command) == command)
        #expect(VisibleText.of(VisibleText.of("x\u{2066}y")) == VisibleText.of("x\u{2066}y"))
    }

    @Test func decodedApprovalsAreAlreadyVisible() throws {
        let json = #"{"request_id":"r1","command":"rm -rf ~‮/tmp","description":"Recursive delete","choices":["once","deny"]}"#
        let approval = try JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
        #expect(approval.command == "rm -rf ~⟨U+202E⟩/tmp")
    }

    @Test func onlyShortSingleLineCommandsFitAtAGlance() {
        #expect(VisibleText.fitsAtAGlance("ls -la", limit: 44))
        #expect(VisibleText.fitsAtAGlance(nil, limit: 44))
        #expect(!VisibleText.fitsAtAGlance("ls\nrm -rf ~", limit: 44))
        #expect(!VisibleText.fitsAtAGlance(String(repeating: "a", count: 45), limit: 44))
    }

    @Test func aToolCantPassForAMemorySave() throws {
        let mcp = #"{"request_id":"r2","command":"x","description":"Save to memory: user profile","title":"Linear is asking","choices":["once","deny"]}"#
        #expect(!(try JSONDecoder().decode(ApprovalRequest.self, from: Data(mcp.utf8))).isMemorySave)
        let flagged = #"{"request_id":"r3","command":"x","description":"Save to memory: notes","smart_denied":true,"choices":["once","deny"]}"#
        #expect(!(try JSONDecoder().decode(ApprovalRequest.self, from: Data(flagged.utf8))).isMemorySave)
        let real = #"{"request_id":"r4","command":"likes tea","description":"Save to memory: add to user profile","title":"Save to memory?","choices":["once","deny"]}"#
        let save = try JSONDecoder().decode(ApprovalRequest.self, from: Data(real.utf8))
        #expect(save.isMemorySave && save.isTitledMemorySave)
    }
}
