import Foundation
import Testing
@testable import HermesKit

@Suite("Transcript folding")
struct TranscriptTests {
    private func decode(_ json: String) throws -> [SessionMessage] {
        struct Envelope: Decodable { var data: [SessionMessage] }
        return try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).data
    }

    @Test func foldsToolCallsIntoOneTurn() throws {
        let messages = try decode("""
        {"object":"list","session_id":"s","data":[
         {"id":1,"session_id":"s","role":"user","content":"search then summarize","tool_call_id":null,"tool_calls":null,"tool_name":null,"timestamp":1760200000.1,"reasoning":null,"display_kind":null},
         {"id":2,"session_id":"s","role":"assistant","content":"Let me search for that:","tool_calls":[{"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\\"query\\": \\"hermes agent\\"}"}}],"timestamp":1760200001.2,"finish_reason":"tool_calls","reasoning":"I should search first."},
         {"id":3,"session_id":"s","role":"tool","content":"results","tool_call_id":"call_1","tool_name":"web_search","timestamp":1760200002.3},
         {"id":4,"session_id":"s","role":"assistant","content":"Here is the summary.","tool_calls":null,"timestamp":1760200003.4,"finish_reason":"stop","reasoning":null}],
         "pagination":{"limit":500,"offset":0,"order":"latest","returned":4}}
        """)
        let items = TranscriptBuilder.build(messages)
        #expect(items.count == 2)
        guard case .user(let user) = items[0], case .assistant(let turn) = items[1] else {
            Issue.record("unexpected items \(items)")
            return
        }
        #expect(user.text == "search then summarize")
        #expect(turn.answer == "Here is the summary.")
        #expect(turn.steps.count == 3)
        guard case .reasoning(_, let reasoning) = turn.steps[0],
              case .narration(_, let narration) = turn.steps[1],
              case .tool(let tool) = turn.steps[2] else {
            Issue.record("unexpected steps \(turn.steps)")
            return
        }
        #expect(reasoning == "I should search first.")
        #expect(narration == "Let me search for that:")
        #expect(tool.name == "web_search")
        #expect(tool.preview == "hermes agent")
        #expect(tool.result == "results")
        #expect(tool.status == .succeeded)
        #expect(abs((tool.duration ?? 0) - 1.1) < 0.001)
    }

    @Test func userImagesAndAttachedContext() throws {
        let messages = try decode("""
        {"data":[{"id":1,"role":"user","content":"What is this?\\n[screenshot]\\n[screenshot]\\n--- Attached Context ---\\nsecret"}]}
        """)
        guard case .user(let user) = TranscriptBuilder.build(messages).first else {
            Issue.record("expected user")
            return
        }
        #expect(user.text == "What is this?")
        #expect(user.imagePlaceholderCount == 2)
    }

    @Test func multimodalContentParts() throws {
        let messages = try decode("""
        {"data":[{"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"https://x/y.png"}},{"type":"input_image","image_url":"data:image/png;base64,AAA"}]}]}
        """)
        guard case .user(let user) = TranscriptBuilder.build(messages).first else {
            Issue.record("expected user")
            return
        }
        #expect(user.text == "look")
        #expect(user.inlineImageURLs == ["https://x/y.png", "data:image/png;base64,AAA"])
    }

    @Test func hiddenRowsAndNotices() throws {
        let messages = try decode("""
        {"data":[
         {"id":1,"role":"user","content":"internal","display_kind":"hidden"},
         {"id":2,"role":"assistant","content":"Switched to grok","display_kind":"model_switch"},
         {"id":3,"role":"user","content":"hi"},
         {"id":4,"role":"assistant","content":"secret","display_kind":"hidden","tool_calls":[{"id":"c","function":{"name":"memory","arguments":"not json"}}]},
         {"id":5,"role":"tool","content":"{\\"error\\": \\"denied\\"}","tool_call_id":"c","tool_name":"memory"},
         {"id":6,"role":"assistant","content":"Hello!"}
        ]}
        """)
        let items = TranscriptBuilder.build(messages)
        #expect(items.count == 3)
        guard case .notice(let notice) = items[0], case .assistant(let turn) = items[2] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(notice.text == "Switched to grok")
        #expect(turn.answer == "Hello!")
        guard case .tool(let tool) = turn.steps.first else {
            Issue.record("expected tool")
            return
        }
        #expect(tool.status == .failed)
        #expect(tool.arguments == nil)
    }

    /// Hermes' one-shot `hermes chat` stores the background-process wake as a plain user row.
    @Test func untaggedProcessCompletionIsANotice() throws {
        let messages = try decode("""
        {"data":[
         {"id":1,"role":"assistant","content":"I cleared it."},
         {"id":2,"role":"user","content":"[IMPORTANT: Background process proc_1 completed normally (exit code 0).\\nCommand: hermes -p news chat\\nOutput\\nok]","display_kind":null},
         {"id":3,"role":"assistant","content":"@news confirmed the change."},
         {"id":4,"role":"user","content":"[IMPORTANT: Background process proc_2 matched watch pattern \\"ERROR\\".]"}
        ]}
        """)
        let items = TranscriptBuilder.build(messages)
        #expect(items.count == 4)
        // A watch pattern's match is Hermes's too, never the person's message (Desktop's
        // `PROCESS_NOTIFICATION_RE` takes every such row).
        guard case .notice(let notice) = items[1], case .assistant(let turn) = items[2], case .notice(let watch) = items[3] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(notice.kind == "process_complete")
        #expect(notice.text == "News got the message")
        #expect(turn.answer == "@news confirmed the change.")
        #expect(watch.work == [.process(FinishedProcess(id: "proc_2", command: "", outcome: .matched(pattern: "ERROR"), output: ""))])
    }

    /// Steer: a `steer` row stays in the reply it landed in, read after the steps before it, and
    /// shows the person's words.
    @Test func steerRowsStayInTheirTurn() throws {
        let messages = try decode("""
        {"data":[
         {"id":1,"role":"user","content":"Check the disks"},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"terminal","arguments":"{}"}}]},
         {"id":3,"role":"tool","content":"ok","tool_call_id":"c1","tool_name":"terminal"},
         {"id":4,"role":"user","content":"[OUT-OF-BAND USER MESSAGE — a direct message]\\nOnly the NAS, please\\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer","display_content":"Only the NAS, please"},
         {"id":5,"role":"assistant","content":"","tool_calls":[{"id":"c2","function":{"name":"terminal","arguments":"{}"}}]},
         {"id":6,"role":"tool","content":"ok","tool_call_id":"c2","tool_name":"terminal"},
         {"id":7,"role":"user","content":"[OUT-OF-BAND USER MESSAGE — x]\\nAnd the router\\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer"},
         {"id":8,"role":"assistant","content":"The NAS is fine."}
        ]}
        """)
        let items = TranscriptBuilder.build(messages)
        #expect(items.count == 2)
        guard case .assistant(let turn) = items[1] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(turn.steps.count == 2)
        #expect(turn.answer == "The NAS is fine.")
        #expect(turn.steers.map(\.text) == ["Only the NAS, please", "And the router"])
        #expect(turn.steers.map(\.afterStep) == [1, 2])
        // A steer with no reply open (another client's history) is still the person's message.
        let bare = TranscriptBuilder.build(try decode("""
        {"data":[{"id":1,"role":"user","content":"[OUT-OF-BAND USER MESSAGE — x]\\nHi\\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer"}]}
        """))
        guard case .user(let entry)? = bare.first else {
            Issue.record("unexpected \(bare)")
            return
        }
        #expect(entry.isSteer && entry.text == "Hi")
    }

    /// What the gateway did with a mid-turn message, and the message it holds for the next turn.
    @Test func followUpStatuses() {
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"queued","text":"x"}"#)) == .queued)
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"redirected"}"#)) == .redirected)
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"steered"}"#)) == .steered)
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"rejected"}"#)) == .rejected)
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"streaming"}"#)) == .streaming)
        #expect(FollowUpStatus(result: JSONValue.parse(#"{"status":"weird"}"#)) == nil)
        #expect(FollowUpStatus(result: nil) == nil)
        #expect(GatewayQueue.queuedPrompt(in: JSONValue.parse(#"{"running":true,"queued":{"user":"Then check the NAS"}}"#)!) == "Then check the NAS")
        #expect(GatewayQueue.queuedPrompt(in: JSONValue.parse(#"{"running":true}"#)!) == nil)
        #expect(GatewayQueue.busyMode(in: JSONValue.parse(#"{"value":"steer"}"#)!) == "steer")
    }

    /// A cached transcript reads back exactly as it was fetched.
    @Test func messagesRoundTripThroughTheCache() throws {
        let messages = try decode("""
        {"data":[
         {"id":1,"role":"user","content":"Check the disks","timestamp":1760000000.5},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"terminal","arguments":"{\\"command\\":\\"df -h\\"}"}}],"reasoning":"Look first."},
         {"id":3,"role":"tool","content":"ok","tool_call_id":"c1","tool_name":"terminal"},
         {"id":4,"role":"user","content":[{"type":"text","text":"and this"},{"type":"image_url","image_url":{"url":"https://x/y.png"}}]},
         {"id":5,"role":"user","content":"[OUT-OF-BAND]","display_kind":"steer","display_content":"Only the NAS"}
        ]}
        """)
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([SessionMessage].self, from: data)
        #expect(decoded == messages)
    }

    /// Pages from the newest end meet the rows already held without losing or repeating any.
    @Test func pagesMerge() {
        func rows(_ ids: ClosedRange<Int>) -> [SessionMessage] {
            ids.map { SessionMessage(id: $0, role: "user", content: .text("\($0)")) }
        }
        // The newest page overlaps what's held (rows arrived since): earlier rows stay once.
        let page = SessionTranscript(sessionID: "s", messages: rows(6...12), hasEarlier: true)
        #expect(page.appending(toEarlier: rows(1...8)).compactMap(\.id) == Array(1...12))
        // An earlier page overlapping the rows held (offset counted after new rows came).
        #expect(SessionTranscript.merge(earlier: rows(3...7), before: rows(6...12)).compactMap(\.id) == Array(3...12))
    }

    /// The owner's chat (2026-10-17): the Bot wrote a file, read it back and wrote it again with a
    /// few lines changed. Folded, that's one card for the file, its last content; opened, the second
    /// write shows only what it changed.
    @Test func aFileWrittenTwiceShowsOnceFolded() {
        func content(_ third: String) -> String {
            (1...12).map { $0 == 3 ? third : "line \($0)" }.joined(separator: "\n")
        }
        func write(_ id: String, _ text: String) -> AssistantStep {
            .tool(ToolActivity(id: id, name: "write_file",
                               arguments: .object(["path": .string("/tmp/brief.md"), "content": .string(text)]),
                               result: #"{"bytes_written": 90}"#, status: .succeeded))
        }
        let read = AssistantStep.tool(ToolActivity(id: "r", name: "read_file", arguments: .object(["path": .string("/tmp/brief.md")]),
                                                   result: "{}", status: .succeeded))
        var turn = AssistantTurn(id: "t", steps: [write("a", content("first draft")), read, write("b", content("second draft"))])
        turn.relateRewrites()

        let folded = turn.foldedAttachments
        #expect(folded.count == 1)
        #expect(folded.first?.displayDiff?.hasPrefix("--- /dev/null") == true)
        #expect(folded.first?.displayDiff?.contains("+second draft") == true)
        #expect(folded.first?.displayDiff?.contains("first draft") == false)

        guard case .tool(let second) = turn.steps[2], let diff = second.displayDiff else {
            Issue.record("no diff for the second write")
            return
        }
        #expect(diff.contains("-first draft") && diff.contains("+second draft"))
        #expect(!diff.contains("line 12")) // only the change and three lines around it
        guard case .tool(let first) = turn.steps[0] else { return }
        #expect(first.displayDiff?.hasPrefix("--- /dev/null") == true)
    }

    /// Two different files, and a patch: each keeps its card.
    @Test func differentFilesKeepTheirCards() {
        var turn = AssistantTurn(id: "t", steps: [
            .tool(ToolActivity(id: "a", name: "write_file", arguments: .object(["path": .string("/tmp/a.md"), "content": .string("a")]),
                               result: "{}", status: .succeeded)),
            .tool(ToolActivity(id: "b", name: "write_file", arguments: .object(["path": .string("/tmp/b.md"), "content": .string("b")]),
                               result: "{}", status: .succeeded)),
            .tool(ToolActivity(id: "c", name: "patch", arguments: .object(["path": .string("/tmp/a.md"), "old_string": .string("a"), "new_string": .string("A")]),
                               result: "{}", status: .succeeded)),
        ])
        turn.relateRewrites()
        #expect(turn.foldedAttachments.map(\.id) == ["a", "b", "c"])
    }

    /// A routine delivered while a turn waited on a tool (the mock's Daily digest, 2026-10-20): the
    /// delivery and its reply were stored between a call and its result. The turn stays whole, every
    /// step once, and the delivery follows it.
    @Test func aDeliveryInTheMiddleOfATurnFollowsIt() throws {
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id":1,"role":"user","content":"page risks","timestamp":1760000000},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"web_extract","arguments":"{\"url\":\"https://a.example\"}"}},{"id":"c2","function":{"name":"web_extract","arguments":"{\"url\":\"https://b.example\"}"}}],"timestamp":1760000001},
         {"id":3,"role":"tool","content":"page a","tool_call_id":"c1","tool_name":"web_extract","timestamp":1760000002},
         {"id":4,"role":"user","content":"[Cronjob \"[bot:researcher] Daily digest\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\nDigest #27: two new papers.","display_kind":"internal_notification","timestamp":1760000003},
         {"id":5,"role":"assistant","content":"📰 Two new papers look worth a read.","timestamp":1760000005},
         {"id":6,"role":"tool","content":"page b","tool_call_id":"c2","tool_name":"web_extract","timestamp":1760000006},
         {"id":7,"role":"assistant","content":"","tool_calls":[{"id":"c3","function":{"name":"web_extract","arguments":"{\"url\":\"https://c.example\"}"}}],"timestamp":1760000007},
         {"id":8,"role":"tool","content":"page c","tool_call_id":"c3","tool_name":"web_extract","timestamp":1760000008},
         {"id":9,"role":"assistant","content":"The focaccia recipe wants an overnight rest.","timestamp":1760000009}]
        """#.utf8))
        let items = TranscriptBuilder.build(rows, hidesSilence: true)
        #expect(items.count == 4)
        guard items.count == 4, case .user(let ask) = items[0], case .assistant(let turn) = items[1],
              case .user(let delivery) = items[2], case .assistant(let reply) = items[3] else {
            Issue.record("unexpected items \(items)")
            return
        }
        #expect(ask.text == "page risks")
        let calls = turn.steps.compactMap { step -> String? in if case .tool(let tool) = step { tool.callID } else { nil } }
        #expect(calls == ["c1", "c2", "c3"])
        #expect(turn.steps.allSatisfy { if case .tool(let tool) = $0 { tool.result != nil } else { true } })
        #expect(turn.answer == "The focaccia recipe wants an overnight rest.")
        #expect(delivery.routineName == "Daily digest")
        #expect(reply.answer == "📰 Two new papers look worth a read.")
        #expect(reply.steps.isEmpty)
        // Nothing moves where no turn was waiting on a tool.
        #expect(TranscriptBuilder.keepingTurnsWhole(Array(rows.prefix(2)) + [rows[2]]) == Array(rows.prefix(3)))
    }

    /// The owner's chat (2026-10-19): two files and a failing check, a steer read after it, then a
    /// third file. Folded, the third file's card goes after the steer, where it was written.
    @Test func filesChangedAfterASteerFoldAfterIt() throws {
        func write(_ id: String, _ path: String) -> AssistantStep {
            .tool(ToolActivity(id: id, name: "write_file", arguments: .object(["path": .string(path), "content": .string("import SwiftUI")]),
                               result: "{}", status: .succeeded))
        }
        let check = AssistantStep.tool(ToolActivity(id: "check", name: "terminal", arguments: .object(["command": .string("swiftc -typecheck")]),
                                                    result: #"{"output": "error", "exit_code": 1}"#, status: .succeeded))
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id":1,"role":"user","content":"Write an example code in swift","timestamp":1760000000},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"w1","function":{"name":"write_file","arguments":"{\"path\":\"/w/Widgets.swift\",\"content\":\"a\"}"}},{"id":"w2","function":{"name":"write_file","arguments":"{\"path\":\"/w/main.swift\",\"content\":\"b\"}"}}],"timestamp":1760000010},
         {"id":3,"role":"tool","content":"{}","tool_call_id":"w1","tool_name":"write_file","timestamp":1760000011},
         {"id":4,"role":"tool","content":"{}","tool_call_id":"w2","tool_name":"write_file","timestamp":1760000011},
         {"id":5,"role":"assistant","content":"","tool_calls":[{"id":"t1","function":{"name":"terminal","arguments":"{\"command\":\"swiftc\"}"}}],"timestamp":1760000020},
         {"id":6,"role":"tool","content":"{\"output\":\"error\",\"exit_code\":1}","tool_call_id":"t1","tool_name":"terminal","timestamp":1760000030},
         {"id":7,"role":"user","content":"[OUT-OF-BAND USER MESSAGE]\nMan just a simple one example like 20 lines\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer","display_content":"Man just a simple one example like 20 lines","timestamp":1760000031},
         {"id":8,"role":"assistant","content":"","tool_calls":[{"id":"w3","function":{"name":"write_file","arguments":"{\"path\":\"/w/Simple.swift\",\"content\":\"c\"}"}}],"timestamp":1760000031},
         {"id":9,"role":"tool","content":"{}","tool_call_id":"w3","tool_name":"write_file","timestamp":1760000040},
         {"id":10,"role":"assistant","content":"Here's the short version.","timestamp":1760000050}]
        """#.utf8))
        guard case .assistant(let stored)? = TranscriptBuilder.build(rows).last else {
            Issue.record("no reply")
            return
        }
        #expect(stored.steers.map(\.text) == ["Man just a simple one example like 20 lines"])
        #expect(stored.foldedAttachmentGroups.map { $0.map(\.filePath) } == [["/w/Widgets.swift", "/w/main.swift"], ["/w/Simple.swift"]])

        // A turn without steers keeps every card in its one group.
        let plain = AssistantTurn(id: "t", steps: [write("a", "/w/a.swift"), check, write("b", "/w/b.swift")])
        #expect(plain.foldedAttachmentGroups.map { $0.map(\.id) } == [["a", "b"]])
    }

    /// A chat that shows its transcript catches up with a short page: what arrived lands after the
    /// 150 rows held, and rows Hermes removed since (an undo, a rewind) go, as with a full page.
    @Test func aShortPageCatchesUpTheRowsHeld() {
        func rows(_ ids: ClosedRange<Int>) -> [SessionMessage] {
            ids.map { SessionMessage(id: $0, role: "user", content: .text("\($0)")) }
        }
        let held = rows(1...150)
        let arrived = SessionTranscript(sessionID: "s", messages: rows(129...152), hasEarlier: true)
        #expect(arrived.messages.count == SessionTranscript.catchUpPage)
        #expect(arrived.appending(toEarlier: held).compactMap(\.id) == Array(1...152))
        // The last ten rows were undone: the page ends earlier, and they don't come back.
        let undone = SessionTranscript(sessionID: "s", messages: rows(117...140), hasEarlier: true)
        #expect(undone.appending(toEarlier: held).compactMap(\.id) == Array(1...140))
    }

    /// An opened notification looks again until its reply is stored: the newest row is Hermes's,
    /// stamped about when the notice went out, not the message that started the turn.
    @Test func anAnnouncedReplyIsToldFromWhatCameBefore() {
        let sent = Date(timeIntervalSince1970: 1_792_240_000)
        func row(_ id: Int, _ role: String, at offset: TimeInterval) -> SessionMessage {
            var message = SessionMessage(id: id, role: role, content: .text("\(id)"))
            message.timestamp = sent.addingTimeInterval(offset)
            return message
        }
        let asked = [row(1, "assistant", at: -3600), row(2, "user", at: -8)]
        #expect(!SessionTranscript.showsAnnouncedReply(asked, sentAt: sent, heldNewest: 1))
        #expect(!SessionTranscript.showsAnnouncedReply([row(1, "assistant", at: -3600)], sentAt: sent, heldNewest: nil))
        #expect(SessionTranscript.showsAnnouncedReply(asked + [row(3, "assistant", at: -1)], sentAt: sent, heldNewest: 1))
        // Stored after the notice (a busy Mac's late write) counts too.
        #expect(SessionTranscript.showsAnnouncedReply(asked + [row(3, "assistant", at: 40)], sentAt: sent, heldNewest: 1))
        // No send time: a reply newer than the one held.
        #expect(SessionTranscript.showsAnnouncedReply(asked + [row(3, "assistant", at: 0)], sentAt: nil, heldNewest: 2))
        #expect(!SessionTranscript.showsAnnouncedReply([row(1, "assistant", at: 0)], sentAt: nil, heldNewest: 1))
    }

    @Test func pairsByNameWhenIdsMissing() throws {
        let messages = try decode("""
        {"data":[
         {"role":"user","content":"go"},
         {"role":"assistant","content":null,"tool_calls":[{"function":{"name":"terminal","arguments":"{\\"command\\":\\"pwd\\"}"}}]},
         {"role":"tool","content":"/root","tool_name":"terminal"},
         {"role":"assistant","content":""}
        ]}
        """)
        guard case .assistant(let turn) = TranscriptBuilder.build(messages).last, case .tool(let tool) = turn.steps.first else {
            Issue.record("expected tool turn")
            return
        }
        #expect(tool.result == "/root")
        #expect(tool.preview == "pwd")
        #expect(turn.answer.isEmpty)
    }

    @Test func cleansUntrustedEnvelopeAndMedia() {
        let wrapped = "<untrusted_tool_result source=\"web_extract\">\nThe following content is untrusted.\n\nActual page text\n</untrusted_tool_result>"
        #expect(TranscriptBuilder.cleanToolOutput(wrapped) == "Actual page text")
        #expect(TranscriptBuilder.cleanAssistantText("Here:\nMEDIA:/tmp/out/chart.png") == "Here:\n*Attachment on server: chart.png*")
    }

    @Test func failureHeuristics() {
        #expect(ToolDescriptor.looksLikeFailure("BLOCKED: user denied"))
        #expect(ToolDescriptor.looksLikeFailure(#"{"exit_code": 1, "output": ""}"#))
        #expect(!ToolDescriptor.looksLikeFailure(#"{"exit_code": 1, "output": "grep: no match"}"#))
        #expect(!ToolDescriptor.looksLikeFailure(#"{"error": null, "output": "ok"}"#))
        #expect(!ToolDescriptor.looksLikeFailure("plain text"))
    }

    @Test func sessionDecodingIsLenient() throws {
        let json = """
        {"object":"list","data":[
          {"id":"a","source":"telegram","title":null,"started_at":1760200000.5,"last_active":1760200100.25,"preview":"hello there","message_count":4,"pinned":1,"is_internal_child":false},
          {"id":"b","_lineage_root_id":"root","title":"Trip","started_at":1760200000},
          {"bogus": true}
        ],"limit":50,"offset":0,"has_more":true}
        """
        let page = try JSONDecoder().decode(SessionPage.self, from: Data(json.utf8))
        #expect(page.sessions.map(\.id) == ["a", "b"])
        #expect(page.hasMore)
        #expect(page.sessions[0].displayTitle == "hello there")
        #expect(page.sessions[0].lastActive == Date(timeIntervalSince1970: 1760200100.25))
        #expect(page.sessions[1].stableID == "root")
        #expect(page.sessions[1].displayTitle == "Trip")
    }

    @Test func jobDatesFromPythonIsoformat() throws {
        let json = """
        {"jobs":[{"id":"j1","name":"Morning brief","prompt":"Summarize news","schedule":{"kind":"interval","display":"every 1d at 09:00"},"enabled":true,"state":"scheduled","next_run_at":"2026-10-13T09:00:00.123456+02:00","last_run_at":"2026-10-12T09:00:01","last_status":"ok","repeat":{"times":null,"completed":3}}]}
        """
        let job = try JSONDecoder().decode(JobsEnvelope.self, from: Data(json.utf8)).jobs[0]
        #expect(job.scheduleDisplay == "every 1d at 09:00")
        #expect(job.nextRunAt == HermesDate.fromISO("2026-10-13T07:00:00.123Z"))
        #expect(job.lastRunAt == HermesDate.fromISO("2026-10-12T09:00:01Z"))
        #expect(job.repeatCompleted == 3)
        #expect(!job.isPaused)
    }
}
