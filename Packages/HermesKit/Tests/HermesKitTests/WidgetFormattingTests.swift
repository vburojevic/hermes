import Foundation
import Testing
@testable import HermesKit

/// How widgets write numbers, times and changes (`docs/widgets.md` §9).
@Suite("Widget formatting")
struct WidgetFormattingTests {
    private let formatter = WidgetFormatter(locale: Locale(identifier: "en_US"))

    @Test func durationsAreShort() {
        #expect(formatter.duration(4) == "4s")
        #expect(formatter.duration(130) == "2m 10s")
        #expect(formatter.duration(5400) == "1h 30m")
        #expect(formatter.duration(12 * 86_400) == "12d")
    }

    @Test func aChangeReadsAsOneStruckRunThenOneAddedRun() {
        let segments = WordDiff.diff("It retries every 5 minutes and stops after an hour.",
                                     "It reconnects as soon as the network is back.")
        let changes = segments.filter { $0.kind != .same }
        #expect(changes.map(\.kind) == [.removed, .added])
        #expect(segments.first?.kind == .same && segments.first?.text == "It ")
    }

    @Test func separateChangesStaySeparate() {
        let segments = WordDiff.diff("Meet at 10:00 in the lobby, bring the slides.",
                                     "Meet at 11:00 in the lobby, bring the printouts.")
        #expect(segments.filter { $0.kind == .removed }.map(\.text) == ["10", "slides"])
        #expect(segments.filter { $0.kind == .added }.map(\.text) == ["11", "printouts"])
    }
}
