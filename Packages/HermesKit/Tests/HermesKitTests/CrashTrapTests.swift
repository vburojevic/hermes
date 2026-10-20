import Foundation
@testable import HermesKit
import HermesMarkdown
import Testing

/// Numbers and texts from the gateway or the model that used to stop the app: a trapping
/// `Int(_:)`, a backwards range (security scan F1, F3, F4, F14, F20–F23, F26, F29, F33).
@Suite("Crash traps")
struct CrashTrapTests {
    private func json(_ text: String) throws -> JSONValue {
        try #require(JSONValue.parse(Data(text.utf8)))
    }

    @Test func numbersConvertWithoutATrap() throws {
        #expect(JSONValue.number(12.7).truncatedIntValue == 12)
        #expect(JSONValue.string("42").truncatedIntValue == 42)
        for wild in [JSONValue.number(1e300), .number(-1e19), .string("nan"), .string("inf"), .string("-inf"), .number(0x1p63)] {
            #expect(wild.truncatedIntValue == nil, "\(wild)")
        }
        #expect(JSONValue.number(-0x1p63).truncatedIntValue == Int.min)
        #expect(Int(saturating: 1e300) == .max && Int(saturating: -1e300) == .min && Int(saturating: .nan) == 0)
        #expect(Int64(checking: 1e300) == nil && Int64(checking: 1024) == 1024)
        #expect(BackgroundProcess.durationText(1e300).isEmpty == false)
    }

    @Test func aTodoIDOfAnySizeReadsAsAPlan() throws {
        let items = PlanItem.list(from: try json(#"[{"id": 1e300, "content": "x"}, {"id": 7, "content": "y"}]"#))
        #expect(items?.count == 2)
        #expect(items?.last?.id == "7")
    }

    @Test func aBoardCardWithWildCountsStillLoads() throws {
        let file = BoardChangedFile(json: try json(#"{"path": "a.swift", "additions": "nan", "deletions": 1e300}"#))
        #expect(file?.path == "a.swift")
        #expect(file?.added == nil && file?.removed == nil)
    }

    @Test func widgetNumbersAndRangesStayInBounds() throws {
        let quantity = try JSONDecoder().decode(WidgetQuantity.self, from: Data(#"{"value": 1e300, "format": "bytes"}"#.utf8))
        #expect(WidgetFormatter().string(quantity) == WidgetFormatter.unknown)
        let fine = try JSONDecoder().decode(WidgetQuantity.self, from: Data(#"{"value": 2048, "format": "bytes"}"#.utf8))
        #expect(WidgetFormatter().string(fine) != WidgetFormatter.unknown)

        let control = try JSONDecoder().decode(ControlWidget.Control.self, from: Data(
            #"{"id": "b", "kind": "slider", "label": "Level", "value": 5, "min": 10, "max": 0, "step": -1}"#.utf8))
        #expect(control.sliderRange == 0...10)
        #expect(control.step(default: 1) == 1)
        #expect(WidgetRange.ordered(3, 3) == 3...4)
        let negative = WidgetRange.padded([-5, -5])
        #expect(negative.lowerBound < -5 && negative.upperBound > -5)
        #expect(WidgetRange.padded([100, 200]) == 98...202)
    }

    @Test func previewActionNumbersAreHeldToWhatAPageCanUse() throws {
        let scroll = try #require(PreviewAction(params: try json(#"{"action": "scroll", "amount": "1e300", "max": "nan"}"#)))
        #expect(scroll.amount == nil || scroll.amount == 10_000_000)
        #expect(scroll.max == nil)
        let elements = try #require(PreviewAction(params: try json(#"{"action": "elements", "amount": -5e8, "max": 9000}"#)))
        #expect(elements.amount == -10_000_000 && elements.max == 500)
    }

    /// Talk reads a reply as it streams: an answer that parses to fewer blocks, or starts over
    /// after a tool call, mustn't stop the app.
    @Test func aShrinkingAnswerDoesntStopTalk() {
        var stream = SpokenStream()
        _ = stream.update("First paragraph here. Still going.\n\nSecond one. And more.", isFinished: false)
        _ = stream.update("", isFinished: false)
        let restarted = stream.update("A new answer starts. Here it goes on", isFinished: false)
        #expect(restarted.map(\.text).contains { $0.hasPrefix("A new answer starts") })
        var growing = SpokenStream()
        _ = growing.update("Intro.\n\nMore.\n\n[1]:", isFinished: false)
        _ = growing.update("Intro.\n\nMore.\n\n[1]: https://example.com", isFinished: true)
    }

    @Test func aPatchWhoseOldTextCarriesTheArrowStillReads() {
        let detail = "entry matching: x' becomes: y\nspan 'x' becomes: y' becomes: NEW (rest of the entry is kept)"
        let text = MemoryPendingParser.text(for: .update, detail: detail, entry: "x' becomes: y and more")
        #expect(!text.isEmpty)
        let batch = MemoryPendingParser.batch(id: "a1", store: nil, detail: "- patch span ' -> 'old' -> 'new' (rest of the entry is kept)", entry: nil, background: false)
        #expect(!batch.text.isEmpty)
    }
}
