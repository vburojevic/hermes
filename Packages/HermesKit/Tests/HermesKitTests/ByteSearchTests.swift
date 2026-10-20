import Foundation
import Testing
@testable import HermesKit

@Suite("Byte search")
struct ByteSearchTests {
    @Test func findsMarkersAnywhere() {
        #expect("Done.\n::widget{id=\"w_1\"}".containsBytes("::widget{"))
        #expect("Ünïcode first ✓ then ```widget".containsBytes("```widget"))
        #expect(!String(repeating: "Compiling module, ünïcode ✓ ", count: 400).containsBytes("```"))
        #expect(!"``".containsBytes("```"))
        // A substring is searched within its own bounds.
        let text = "abc ``` def"
        #expect(!text[..<text.firstIndex(of: "`")!].containsBytes("```"))
    }

    @Test func countsWithoutOverlaps() {
        #expect("".countBytes("```") == 0)
        #expect("```swift\nlet a = 1\n```".countBytes("```") == 2)
        // As `components(separatedBy:)` reads it: four backticks are one fence and a backtick.
        #expect("````".countBytes("```") == 1)
        #expect("``````".countBytes("```") == 2)
        #expect("ü```ü```ü```".countBytes("```") == 3)
    }

    @Test func agreesWithComponents() {
        for text in ["", "a**b", "**a** and **b", "*** ** *", "日本**語**", "****"] {
            #expect(text.countBytes("**") == text.components(separatedBy: "**").count - 1, "\(text)")
        }
    }
}
