import Foundation
import Testing
@testable import HermesKit

@Suite("A row's least height")
struct RowHeightTests {
    @Test func proseLinesWrapAndBlankLinesCountNothing() {
        let short = TranscriptItem.user(UserEntry(id: "u", text: "Hi there"))
        #expect(short.leastHeight == CGFloat(40 + 18))
        // 230 characters wrap twice at 110; the blank line between paragraphs adds nothing.
        let long = String(repeating: "a", count: 230)
        let item = TranscriptItem.assistant(AssistantTurn(id: "t", answer: "\(long)\n\nDone."))
        #expect(item.leastHeight == CGFloat(40 + 18 * (3 + 1)))
    }

    @Test func codeLinesNeverWrapAndFencesTakeNoRoom() {
        let code = (0..<80).map { "let value\($0) = " + String(repeating: "x", count: 200) }.joined(separator: "\n")
        let item = TranscriptItem.assistant(AssistantTurn(id: "t", answer: "Here it is:\n```swift\n\(code)\n```"))
        #expect(item.leastHeight == CGFloat(40 + 18 * (1 + 80)))
    }

    @Test func rowsWithoutTextAreTheirFloor() {
        let notice = TranscriptItem.notice(Notice(id: "n", kind: "info", text: "Model changed"))
        #expect(notice.leastHeight == CGFloat(40))
        #expect(TranscriptItem.assistant(AssistantTurn(id: "t")).leastHeight == CGFloat(40))
    }
}
