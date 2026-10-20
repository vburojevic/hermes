import Foundation
import Testing
@testable import HermesKit

@Suite("Inline diffs from Hermes")
struct InlineDiffTests {
    /// What `tool.complete` carries for a new file: agent/display.py's terminal rendering.
    static let rendered = [
        "  ┊ review diff",
        "\u{1B}[38;2;218;165;32ma/swift-widgets/Simple.swift → b/swift-widgets/Simple.swift\u{1B}[0m",
        "\u{1B}[38;2;139;134;130m@@ -0,0 +1,3 @@\u{1B}[0m",
        "\u{1B}[38;2;255;255;255;48;2;20;90;20m+import SwiftUI\u{1B}[0m",
        "\u{1B}[38;2;255;255;255;48;2;20;90;20m+\u{1B}[0m",
        "\u{1B}[38;2;255;255;255;48;2;120;20;20m-struct Old {}\u{1B}[0m",
        "\u{1B}[38;2;255;255;255;48;2;20;90;20m+struct MessageView: View {}\u{1B}[0m",
    ].joined(separator: "\n")

    @Test func hermesTerminalRenderingBecomesAUnifiedDiff() throws {
        let diff = try #require(InlineDiff.unified(Self.rendered))
        #expect(diff == [
            "--- a/swift-widgets/Simple.swift",
            "+++ b/swift-widgets/Simple.swift",
            "@@ -0,0 +1,3 @@",
            "+import SwiftUI",
            "+",
            "-struct Old {}",
            "+struct MessageView: View {}",
        ].joined(separator: "\n"))
        // The card's counts and the Inspector's changed files read it as they read any diff.
        var tool = ToolActivity(id: "t", name: "write_file", status: .succeeded)
        tool.diff = diff
        let counts = TurnFileEdits.counts(tool)
        #expect(counts.added == 3)
        #expect(counts.removed == 1)
    }

    @Test func plainDiffsPassThroughAndEmptyOnesAreDropped() {
        let plain = "--- a/x.swift\n+++ b/x.swift\n@@ -1 +1 @@\n-old\n+new"
        #expect(InlineDiff.unified(plain) == plain)
        #expect(InlineDiff.unified("  ┊ review diff\n\u{1B}[38;2;1;2;3mnothing changed\u{1B}[0m") == nil)
    }

    @Test func liveToolsCarryTheCleanDiff() throws {
        let event = GatewayEvent(type: "tool.complete", sessionID: "s", seq: 4, payload: .object([
            "tool_id": .string("c1"), "name": .string("write_file"), "inline_diff": .string(Self.rendered),
        ]))
        let details = GatewayTurnDecoder.decode(event).compactMap { item -> String? in
            if case .toolDetails(_, _, let diff, _) = item.event { diff } else { nil }
        }
        #expect(details.first?.hasPrefix("--- a/swift-widgets/Simple.swift") == true)
        #expect(details.first?.contains("\u{1B}") == false)
    }
}
