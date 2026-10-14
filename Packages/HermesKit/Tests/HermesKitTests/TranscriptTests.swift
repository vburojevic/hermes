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
        guard case .notice(let notice) = items[1], case .assistant(let turn) = items[2], case .user = items[3] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(notice.kind == "process_complete")
        #expect(notice.text == "Background process finished")
        #expect(turn.answer == "@news confirmed the change.")
    }

    /// Steer Now: a `steer` row splits the reply where it landed and shows the person's words.
    @Test func steerRowsSplitTheTurn() throws {
        let messages = try decode("""
        {"data":[
         {"id":1,"role":"user","content":"Check the disks"},
         {"id":2,"role":"assistant","content":"","tool_calls":[{"id":"c1","function":{"name":"terminal","arguments":"{}"}}]},
         {"id":3,"role":"tool","content":"ok","tool_call_id":"c1","tool_name":"terminal"},
         {"id":4,"role":"user","content":"[OUT-OF-BAND USER MESSAGE — a direct message]\\nOnly the NAS, please\\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer","display_content":"Only the NAS, please"},
         {"id":5,"role":"assistant","content":"The NAS is fine."},
         {"id":6,"role":"user","content":"[OUT-OF-BAND USER MESSAGE — x]\\nAnd the router\\n[/OUT-OF-BAND USER MESSAGE]","display_kind":"steer"}
        ]}
        """)
        let items = TranscriptBuilder.build(messages)
        #expect(items.count == 5)
        guard case .assistant(let first) = items[1], case .user(let steer) = items[2], case .assistant(let second) = items[3],
              case .user(let bare) = items[4] else {
            Issue.record("unexpected \(items)")
            return
        }
        #expect(first.steps.count == 1)
        #expect(steer.isSteer && steer.text == "Only the NAS, please")
        #expect(second.answer == "The NAS is fine.")
        #expect(bare.isSteer && bare.text == "And the router")
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
