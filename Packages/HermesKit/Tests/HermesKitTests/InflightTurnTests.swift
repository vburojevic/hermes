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

/// A turn Hermes started by itself reads, while it runs, as the stored chat will read it
/// (`docs/chat.md` §2a, the message a live turn answers): never as the person's bubble.
@Suite("A turn Hermes started by itself")
struct InflightNoticeTests {
    let started = Date(timeIntervalSince1970: 1_792_000_000)

    /// Hermes's own delivery runner for `message_agent` (`tools/bot_mode_dm.py`, `_delivery_command`).
    static let delivery = #"/opt/hermes/venv/bin/python /opt/hermes/hermes-agent/tools/bot_mode_dm.py --run-delivery --author '{"id":"bot:me","name":"Hermes","is_bot":true}' query-file /tmp/dm-ab12.json --profile-home /opt/hermes/profiles/writer /opt/hermes/bin/hermes -p writer chat --in /tmp -c 'Bot Chat'"#

    static func completion(_ id: String, command: String = delivery, exit: Int = 0) -> String {
        """
        [IMPORTANT: Background process \(id) completed normally (exit code \(exit)).
        Command: \(command)
        Output:
        {"outcome": "@writer answered.", "reply": "Draft is in notes.md.", "status": "settled", "delivery_id": "dm_ab12"}]
        """
    }

    private func notice(_ turn: InflightTurn) -> Notice? {
        if case .notice(let notice) = turn.reading(id: "live") { notice } else { nil }
    }

    private func stored(_ text: String, kind: String?, at offset: TimeInterval = 0.3) -> SessionMessage {
        SessionMessage(id: Int(offset * 10) + 1_000, role: "user", content: .text(text), timestamp: started.addingTimeInterval(offset), displayKind: kind)
    }

    @Test func aFinishedDeliveryIsItsLineNotABubble() throws {
        let turn = InflightTurn(user: Self.completion("proc_1"), displayKind: "process_complete", startedAt: started)
        #expect(turn.userEntry(id: "live") == nil)
        let notice = try #require(notice(turn))
        #expect(notice.kind == "process_complete")
        guard case .process(let process)? = notice.work.first else { Issue.record("no process"); return }
        #expect(process.id == "proc_1")
        #expect(process.recipient == "writer")
        #expect(process.name() == "Message to Writer")
        #expect(process.status == "Replied")
        #expect(notice.text == "Writer replied")
        // Delivered with no reply yet.
        let quiet = Self.completion("proc_2").replacingOccurrences(of: #""reply": "Draft is in notes.md.", "#, with: "")
        let delivered = try #require(self.notice(InflightTurn(user: quiet, displayKind: "process_complete")))
        guard case .process(let sent)? = delivered.work.first else { Issue.record("no process"); return }
        #expect(sent.status == "Delivered")
    }

    @Test func untaggedAndFooteredCompletionsReadTheSame() throws {
        // A one-shot `hermes chat` sends it untagged; the messaging gateway tags it
        // `internal_notification` and adds its footer.
        let tagged = try #require(notice(InflightTurn(user: Self.completion("proc_1"), displayKind: "process_complete")))
        let untagged = try #require(notice(InflightTurn(user: Self.completion("proc_1"))))
        let footered = try #require(notice(InflightTurn(user: Self.completion("proc_1") + "\n\n" + HermesScaffold.notificationFooter,
                                                        displayKind: "internal_notification")))
        #expect(untagged.kind == "process_complete")
        #expect(footered.kind == "process_complete")
        #expect(untagged.text == tagged.text)
        #expect(footered.text == tagged.text)
        #expect(footered.work.count == 1)
    }

    @Test func aBatchIsOneLine() throws {
        let batch = "[IMPORTANT: 2 background processes completed. Treat these results as one batch and give one consolidated response; preserve failures and actionable results.]\n\n"
            + Self.completion("proc_1") + "\n\n" + Self.completion("proc_2", command: "npm run build", exit: 1)
        let notice = try #require(notice(InflightTurn(user: batch, displayKind: "process_complete")))
        #expect(notice.work.count == 2)
        #expect(!notice.text.hasPrefix("[IMPORTANT"))
    }

    @Test func aHeartbeatIsItsLineOrNothing() throws {
        let beat = "[Background process proc_1 heartbeat #3 — still running after 2m (next in 60s when there is new output; "
            + "you will also be told when it exits).\nCommand: make test\nOutput since last heartbeat:\nok]"
        let line = try #require(notice(InflightTurn(user: beat + "\n\n" + HermesScaffold.notificationFooter, displayKind: "internal_notification")))
        #expect(line.text == "Background process output after 2m: make test")
        // The TUI gateway starts a heartbeat's turn hidden.
        #expect(InflightTurn(user: beat, displayKind: "hidden").reading(id: "live") == .nothing)
    }

    @Test func helpersResultsAreTheirLine() throws {
        let single = "[ASYNC DELEGATION COMPLETE — deleg_2]\nA background subagent you dispatched earlier has finished.\n\nOriginal goal: Find the flaky test\nStatus: completed   API calls: 3   Duration: 40s\n--- RESULT ---\nIt's test_sync."
        let notice = try #require(notice(InflightTurn(user: single, displayKind: "async_delegation_complete")))
        #expect(notice.kind == "async_delegation_complete")
        #expect(notice.text == "Helper finished: Find the flaky test")
        #expect(InflightTurn(user: single).userEntry(id: "live") == nil)
    }

    @Test func scaffoldingShowsNothing() {
        #expect(InflightTurn(user: "[System: The session was compacted; continue.]").reading(id: "live") == .nothing)
    }

    @Test func deliveriesAndThePersonStayMessages() throws {
        let bot = try #require(InflightTurn(user: "Message from 🤖 Research Buddy (@researcher): Found 3 papers.", displayKind: "internal_notification").userEntry(id: "live"))
        #expect(bot.sender?.handle == "researcher")
        let routine = try #require(InflightTurn(user: "[Cronjob \"[bot:ops] Issue alerts\" output — scheduled job, not the user. Review it.]\n\nAll clear.").userEntry(id: "live"))
        #expect(routine.delivery == .routine("Issue alerts"))
        let own = try #require(InflightTurn(user: "Plan the trip").userEntry(id: "live"))
        #expect(own.sender == nil && own.delivery == nil)
        #expect(own.text == "Plan the trip")
    }

    @Test func aStoredNoticeIsFoundOnce() {
        let turn = InflightTurn(user: Self.completion("proc_1"), displayKind: "process_complete", startedAt: started)
        let earlier = SessionMessage(id: 1, role: "user", content: .text("Plan the trip"), timestamp: started.addingTimeInterval(-600))
        let reply = SessionMessage(id: 2, role: "assistant", content: .text("Sure."), timestamp: started.addingTimeInterval(-590))
        // Under turn isolation the chat doesn't have it yet.
        #expect(!turn.isStored(in: TranscriptBuilder.build([earlier, reply])))
        // Stored when sent, it's the chat's last notice.
        #expect(turn.isStored(in: TranscriptBuilder.build([earlier, reply, stored(Self.completion("proc_1"), kind: "process_complete")])))
        // Folded into the finished work stored just before it, it's still found.
        let folded = TranscriptBuilder.build([earlier, reply, stored(Self.completion("proc_0"), kind: "process_complete", at: -1),
                                              stored(Self.completion("proc_1"), kind: "process_complete")])
        #expect(folded.count == 3)
        #expect(turn.isStored(in: folded))
        // Another process's notice isn't this one.
        #expect(!turn.isStored(in: TranscriptBuilder.build([earlier, reply, stored(Self.completion("proc_9"), kind: "process_complete")])))
    }

    @Test func aLiveNoticeFoldsIntoTheStoredLineBeforeIt() throws {
        let rows = TranscriptBuilder.build([stored(Self.completion("proc_0"), kind: "process_complete", at: -1)])
        let live = try #require(notice(InflightTurn(user: Self.completion("proc_1"), displayKind: "process_complete")))
        let shown = TranscriptBuilder.appending([.notice(live)], to: rows)
        #expect(shown.count == 1)
        guard case .notice(let line)? = shown.first, case .notice(let first)? = rows.first else { Issue.record("no line"); return }
        #expect(line.id == first.id)
        #expect(line.work.count == 2)
        // After a reply it stands on its own.
        let answered = rows + [.assistant(AssistantTurn(id: "a1", state: .complete))]
        #expect(TranscriptBuilder.appending([.notice(live)], to: answered).count == 3)
    }
}
