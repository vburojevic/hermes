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

    @Test func oneReadsWithTheSingularUnit() {
        let votes = { (value: Double) in WidgetQuantity(value: .number(value), unit: "votes", unitOne: "vote") }
        #expect(formatter.string(votes(1)) == "1 vote")
        #expect(formatter.string(votes(2)) == "2 votes")
        #expect(formatter.string(votes(0)) == "0 votes")
        // An older plugin sends only the plural, which reads as before.
        #expect(formatter.string(WidgetQuantity(value: .number(1), unit: "votes")) == "1 votes")
    }

    @Test func aDueDateReadsAsTheDayAndHowFarAway() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9, minute: 41)))
        let british = WidgetFormatter(locale: Locale(identifier: "en_GB"), now: now)
        let due = WidgetQuantity(value: .string("2026-10-20T00:00:00-04:00"), format: .date, fromNow: true)
        #expect(british.string(due) == "Tue 20 Oct, in 4 days")
        #expect(british.string(WidgetQuantity(value: .string("2026-10-12"), format: .date, fromNow: true)) == "Mon 12 Oct, 4 days ago")
        #expect(british.string(WidgetQuantity(value: .string("2026-10-17"), format: .date, fromNow: true)) == "Sat 17 Oct, tomorrow")
        // Without from_now, the day alone, as before.
        #expect(british.string(WidgetQuantity(value: .string("2026-10-20T00:00:00-04:00"), format: .date)) == "Tue 20 Oct")
        // A value the client can't read as a day stays as it came.
        #expect(british.string(WidgetQuantity(value: .string("soon"), format: .date, fromNow: true)) == "soon")
    }

    @Test func aPayloadsNewFieldsDecode() throws {
        let json = #"{"value": 1, "unit": "votes", "unit_one": "vote", "from_now": true, "format": "date"}"#
        let quantity = try JSONDecoder().decode(WidgetQuantity.self, from: Data(json.utf8))
        #expect(quantity.unitOne == "vote" && quantity.fromNow)
        let old = try JSONDecoder().decode(WidgetQuantity.self, from: Data(#"{"value": 1, "unit": "votes"}"#.utf8))
        #expect(old.unitOne == nil && !old.fromNow)
        let source = try JSONDecoder().decode(WidgetSource.self, from: Data(#"{"name": "Apple Health", "symbol": "heart.fill"}"#.utf8))
        #expect(source.symbol == "heart.fill")
    }
}
