import Foundation
import Testing
@testable import HermesKit

@Suite("A turn sent from another device")
struct InflightTurnTests {
    let started = Date(timeIntervalSince1970: 1_792_000_000)

    private func snapshot(_ inflight: [String: JSONValue]?, running: Bool = true) -> JSONValue {
        var object: [String: JSONValue] = ["session_id": .string("sid-1"), "running": .bool(running)]
        if let inflight {
            object["inflight"] = .object(inflight)
            object["turn_started_at"] = .number(started.timeIntervalSince1970)
        }
        return .object(object)
    }

    private func user(_ text: String, at offset: TimeInterval?) -> TranscriptItem {
        .user(UserEntry(id: "m\(text.count)", text: text, timestamp: offset.map { started.addingTimeInterval($0) }))
    }

    @Test func readsWhatResumeReports() throws {
        let turn = try #require(InflightTurn(snapshot: snapshot(["user": .string(" Plan the trip \n"), "assistant": .string("Sure"), "streaming": .bool(true)])))
        #expect(turn.user == "Plan the trip")
        #expect(turn.assistant == "Sure")
        #expect(turn.startedAt == started)
        #expect(turn.userEntry(id: "local-1")?.text == "Plan the trip")
        #expect(InflightTurn(snapshot: snapshot(nil)) == nil)
    }

    @Test func aHiddenSendHasNoBubble() throws {
        let turn = try #require(InflightTurn(snapshot: snapshot(["user": .string("Refresh the widget"), "display_kind": .string("hidden")])))
        #expect(turn.userEntry(id: "local-1") == nil)
        #expect(InflightTurn(snapshot: snapshot(["user": .string(""), "assistant": .string("Working")]))?.userEntry(id: "x") == nil)
    }

    @Test func anotherBotsMessageReadsAsItsOwn() throws {
        let turn = try #require(InflightTurn(snapshot: snapshot(["user": .string("Message from 🤖 Research Buddy (@researcher): Found 3 papers.")])))
        let entry = try #require(turn.userEntry(id: "local-1"))
        #expect(entry.sender?.handle == "researcher")
        #expect(entry.text == "Found 3 papers.")
    }

    @Test func storedAtSendIsNotShownTwice() {
        let turn = InflightTurn(user: "Plan the trip", startedAt: started)
        #expect(turn.isStored(in: [user("Earlier", at: -600), .assistant(AssistantTurn(id: "a1", state: .complete)), user("Plan the trip", at: 0.2)]))
    }

    @Test func turnIsolationStoresItLater() {
        // The chat ends with the last finished turn: this message isn't there yet.
        let turn = InflightTurn(user: "Plan the trip", startedAt: started)
        #expect(!turn.isStored(in: [user("Earlier", at: -600), .assistant(AssistantTurn(id: "a1", state: .complete))]))
    }

    @Test func theSameWordsEarlierAreAnotherMessage() {
        // "ok" was answered ten minutes ago; this "ok" is a new message.
        let turn = InflightTurn(user: "ok", startedAt: started)
        #expect(!turn.isStored(in: [user("ok", at: -600), .assistant(AssistantTurn(id: "a1", state: .complete))]))
        // Without times, a reply after it says it was answered.
        let untimed = InflightTurn(user: "ok")
        #expect(!untimed.isStored(in: [user("ok", at: nil), .assistant(AssistantTurn(id: "a1", state: .complete))]))
        #expect(untimed.isStored(in: [user("ok", at: nil)]))
    }
}
