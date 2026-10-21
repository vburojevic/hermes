import Foundation
import Testing
@testable import HermesKit

@Suite("Cards for requests settled elsewhere")
struct RequestSyncTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aCardStillListedStays() {
        let ended = RequestSync.ended(shown: [.init(id: "srq-a")], open: ["srq-a"], now: now)
        #expect(ended.isEmpty)
    }

    @Test func aCardNoLongerListedWasAnsweredElsewhere() {
        // The iPhone answered the question; the Mac's card goes, and says so.
        let ended = RequestSync.ended(shown: [.init(id: "srq-a"), .init(id: "srq-b")], open: ["srq-b"], now: now)
        #expect(ended.map(\.id) == ["srq-a"])
        #expect(ended.map(\.ending) == [.answeredElsewhere])
    }

    @Test func pastItsDeadlineItTimedOut() {
        // Asleep through the deadline: Hermes stopped waiting, nobody answered.
        let card = RequestSync.Card(id: "srq-a", deadline: now.addingTimeInterval(-1))
        #expect(RequestSync.ended(shown: [card], open: [], now: now).map(\.ending) == [.timedOut])
        let early = RequestSync.Card(id: "srq-a", deadline: now.addingTimeInterval(60))
        #expect(RequestSync.ended(shown: [early], open: [], now: now).map(\.ending) == [.answeredElsewhere])
    }

    @Test func anAnswerStillOnItsWayFromHereIsNotTakenForAnother() {
        let ended = RequestSync.ended(shown: [.init(id: "srq-a")], open: [], answeredHere: ["srq-a"], now: now)
        #expect(ended.isEmpty)
    }

    @Test func openIDsReadTheSnapshot() {
        let value: JSONValue = .array([
            .object(["id": .string("srq-a"), "method": .string("clarify")]),
            .object(["method": .string("approval")]),
        ])
        #expect(RequestSync.openIDs(value) == ["srq-a"])
        #expect(RequestSync.openIDs(.array([])) == [])
        // No list at all (an older Hermes) is not "nothing open".
        #expect(RequestSync.openIDs(nil) == nil)
    }
}
