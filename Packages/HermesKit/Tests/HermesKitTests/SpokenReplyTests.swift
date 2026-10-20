import Foundation
import HermesMarkdown
import Testing
@testable import HermesKit

@Suite("Which reply Talk reads")
struct SpokenReplyTests {
    @Test func readsSentencesAsTheyComplete() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: ["a"])
        #expect(tracker.update(turnID: "b", answer: "The NAS is at", isFinished: false).isEmpty)
        let first = tracker.update(turnID: "b", answer: "The NAS is at 61%. Snapshots older", isFinished: false)
        #expect(first.map(\.text) == ["The NAS is at 61%."])
        let rest = tracker.update(turnID: "b", answer: "The NAS is at 61%. Snapshots older than 30 days take 148 GB.", isFinished: true)
        #expect(rest.map(\.text) == ["Snapshots older than 30 days take 148 GB."])
        #expect(tracker.isDone)
        #expect(tracker.update(turnID: "b", answer: "The NAS is at 61%. More.", isFinished: true).isEmpty)
    }

    @Test func aReplyThatWasAlreadyThereIsNeverReadAgain() {
        // A message queued behind a finishing turn: the newest turn is still the previous reply.
        var tracker = SpokenReplyTracker(earlierTurnIDs: ["a"])
        #expect(tracker.update(turnID: "a", answer: "The previous answer.", isFinished: true).isEmpty)
        #expect(!tracker.isDone)
        #expect(tracker.update(turnID: "b", answer: "The new answer.", isFinished: true).map(\.text) == ["The new answer."])
    }

    @Test func aLaterTurnNeverTakesOver() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: [])
        _ = tracker.update(turnID: "b", answer: "Checking. Still", isFinished: false)
        #expect(tracker.trackedTurnID == "b")
        #expect(tracker.update(turnID: "c", answer: "Another reply.", isFinished: true).isEmpty)
        #expect(tracker.isDone)
    }

    @Test func aFailedTurnReadsItsError() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: [])
        let said = tracker.update(turnID: "b", answer: "", isFinished: true, failure: "The model is overloaded. Try again in a minute.")
        #expect(said.map(\.text) == ["The model is overloaded. Try again in a minute."])
    }

    @Test func codeIsDescribedOnceItsClosed() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: [])
        #expect(tracker.update(turnID: "b", answer: "Run this:\n\n```sh\ndf -h", isFinished: false).map(\.text) == ["Run this:"])
        let next = tracker.update(turnID: "b", answer: "Run this:\n\n```sh\ndf -h\n```\n\nThen tell me", isFinished: false)
        #expect(next.map(\.text) == ["I put the shell code in the chat."])
        #expect(tracker.update(turnID: "b", answer: "Run this:\n\n```sh\ndf -h\n```\n\nThen tell me.", isFinished: true).map(\.text) == ["Then tell me."])
    }
}

@Suite("Calls fold into their card")
struct CallFoldingTests {
    private let start = Date(timeIntervalSince1970: 1_792_000_000)

    private func user(_ id: String, at offset: TimeInterval) -> TranscriptItem {
        .user(UserEntry(id: id, text: id, timestamp: start.addingTimeInterval(offset)))
    }

    private func reply(_ id: String, at offset: TimeInterval) -> TranscriptItem {
        .assistant(AssistantTurn(id: id, answer: id, startedAt: start.addingTimeInterval(offset)))
    }

    @Test func theCallsTurnsFoldAndTheCardFollowsTheLast() {
        let call = UUID()
        let items = [user("before", at: -60), reply("r0", at: -55), user("u1", at: 1), reply("r1", at: 3), user("u2", at: 20), reply("r2", at: 25), user("after", at: 400)]
        let folds = CallFolding.folds(items, spans: [.init(id: call, start: start, end: start.addingTimeInterval(120))])
        #expect(Set(folds.rows.keys) == ["u1", "r1", "u2", "r2"])
        #expect(folds.cardAfter == ["r2": call])
    }

    @Test func noCallsNoFolds() {
        #expect(CallFolding.folds([user("u", at: 0)], spans: []) == CallFolding.Folds())
    }
}

@Suite("A reply read across settling")
struct SettledReplyTests {
    @Test func theStoredRowOfTheLiveTurnIsReadOn() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: ["t1"])
        #expect(tracker.update(turnID: "live-A", answer: "", isFinished: false).isEmpty)
        // The turn finished and was stored as t2 before the follower saw it finish.
        let said = tracker.update(turnID: "t2", answer: "Done. Freed 14 GB.", isFinished: true, settled: true)
        #expect(said.map(\.text) == ["Done.", "Freed 14 GB."])
        #expect(tracker.isDone)
    }

    @Test func aDifferentTurnStillEndsReading() {
        var tracker = SpokenReplyTracker(earlierTurnIDs: [])
        _ = tracker.update(turnID: "live-A", answer: "Checking. Still", isFinished: false)
        // Live while another turn appears: not a settled row.
        #expect(tracker.update(turnID: "live-B", answer: "Other.", isFinished: true).isEmpty)
        #expect(tracker.isDone)
    }
}
