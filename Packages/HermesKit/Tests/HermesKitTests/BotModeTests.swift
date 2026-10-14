import Foundation
import Testing
@testable import HermesKit

@Suite("Backend gateway frames")
struct GatewayFrameTests {
    @Test func classifiesEventsRequestsAndResponses() {
        let event = GatewayFrame.parse(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"ab12cd34","seq":7,"payload":{"text":"Hi"}}}"#)
        #expect(event == .event(GatewayEvent(type: "message.delta", sessionID: "ab12cd34", seq: 7, payload: .object(["text": .string("Hi")]))))

        guard case .request(let request)? = GatewayFrame.parse(#"{"jsonrpc":"2.0","id":"srq-1a2b","method":"approval","params":{"session_id":"ab12cd34","command":"rm -rf build"}}"#) else {
            Issue.record("expected a server request")
            return
        }
        #expect(request.id == "srq-1a2b")
        #expect(request.method == "approval")
        #expect(request.sessionID == "ab12cd34")

        guard case .response(let id, let result, let error)? = GatewayFrame.parse(#"{"jsonrpc":"2.0","id":"r3","result":{"ok":true}}"#) else {
            Issue.record("expected a response")
            return
        }
        #expect(id == "r3")
        #expect(result?["ok"]?.boolValue == true)
        #expect(error == nil)
    }

    @Test func numericIDsAndErrors() {
        guard case .response(let id, _, let error)? = GatewayFrame.parse(#"{"jsonrpc":"2.0","id":12,"error":{"code":4064,"message":"unknown profile"}}"#) else {
            Issue.record("expected an error response")
            return
        }
        #expect(id == "12")
        #expect(error?.code == 4064)
        #expect(error?.errorDescription == "That bot doesn't exist on this Hermes backend.")
        #expect(GatewayRPCError(code: 4001, message: "session not found").isSessionNotFound)
    }

    @Test func ignoresNonObjects() {
        #expect(GatewayFrame.parse("[1,2]") == nil)
        #expect(GatewayFrame.parse("not json") == nil)
        #expect(GatewayFrame.parse(#"{"jsonrpc":"2.0"}"#) == nil)
    }
}

@Suite("Backend sign-in")
struct BackendClientTests {
    @Test func readsTheInjectedSessionToken() {
        let html = #"<html><head><script>window.__HERMES_SESSION_TOKEN__="tok-\"abc\"-123";window.__HERMES_DASHBOARD_EMBEDDED_CHAT__=true;</script></head></html>"#
        #expect(BackendClient.sessionToken(inHTML: html) == #"tok-"abc"-123"#)
        #expect(BackendClient.sessionToken(inHTML: #"window.__HERMES_SESSION_TOKEN__ = "plain";"#) == "plain")
        #expect(BackendClient.sessionToken(inHTML: #"window.__HERMES_SESSION_TOKEN__="";"#) == nil)
        #expect(BackendClient.sessionToken(inHTML: "<html>login</html>") == nil)
    }

    @Test func statusDecoding() throws {
        let status = BackendStatus(json: try #require(JSONValue.parse(#"{"version":"0.21.6","auth_required":true,"auth_providers":["basic",{"name":"oidc"}],"install_id":"i-1"}"#)))
        #expect(status.version == "0.21.6")
        #expect(status.authRequired)
        #expect(status.authProviders == ["basic", "oidc"])
        #expect(status.supportsPassword)
    }
}

@Suite("Bot roster")
struct BotProfileTests {
    private func profile(_ json: String) throws -> BotProfile {
        BotProfile(json: try #require(JSONValue.parse(json)))
    }

    @Test func decodesARosterRow() throws {
        let now = Date().timeIntervalSince1970
        let bot = try profile("""
        {"name":"researcher","is_default":false,"model":"hermes-4","provider":"nous",
         "description":"Research Buddy — digs through papers","display_name":"",
         "previous_names":["scholar"],
         "last_session":{"id":"s1","title":"Notes","preview":"**Done** with the `summary`","last_active":\(now - 30)},
         "canonical_session":{"id":"c1","resolved_id":"c2","title":"Bot Chat","last_active":\(now - 600)},
         "ui_meta":{"hermes-bots":{"title":"Research Buddy","shape":"hexagon","color":"#22c55e","custom":true,"chat":"stale","created":1760000000000}},
         "ui_meta_revisions":{"hermes-bots":4},"has_avatar":false}
        """)
        #expect(bot.title == "Research Buddy")
        #expect(bot.handle == "researcher")
        #expect(bot.mentionTag == "research-buddy")
        #expect(bot.role == "digs through papers")
        #expect(bot.canonicalSession?.resolvedID == "c2")
        #expect(bot.meta.raw["chat"] == nil)
        #expect(bot.meta.shape == "hexagon")
        #expect(bot.metaRevision == 4)
        #expect(bot.activitySession?.id == "s1")
        #expect(bot.isActive())
        // The row previews its Bot Chat, which is empty here, not the newer "Notes" session.
        #expect(bot.preview == nil)
        #expect(bot.meta.created == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func primaryProfileIsHermes() throws {
        let bot = try profile(#"{"name":"default","is_default":true,"display_name":""}"#)
        #expect(bot.title == "Hermes")
        #expect(bot.handle == "hermes")
        #expect(bot.mentionTag == "hermes")
        #expect(bot.canonicalSession == nil)
        #expect(!bot.isActive())
    }

    @Test func titleFallsBackToTheProfileName() throws {
        #expect(try profile(#"{"name":"code_reviewer"}"#).title == "Code Reviewer")
        #expect(try profile(#"{"name":"ops","display_name":"Ops Desk"}"#).title == "Ops Desk")
    }

    @Test func agentMessagesPreviewWithTheSender() throws {
        let bot = try profile(#"{"name":"writer","last_session":{"id":"s","preview":"Message from 🤖 Research Buddy (@researcher): Here are the papers."}}"#)
        #expect(bot.preview == "Research Buddy: Here are the papers.")
    }

    @Test func agentMessagesReadAsMessagingABot() throws {
        #expect(ToolDescriptor.describe("message_agent").doneTitle == "Messaged a Bot")
        let arguments = JSONValue.parse(#"{"target":"researcher","message":"Could you dig into speculative decoding?"}"#)
        #expect(ToolDescriptor.argumentPreview(name: "message_agent", arguments: arguments) == "Could you dig into speculative decoding?")
    }

    @Test func previewsFlattenMarkdownLists() throws {
        #expect(BotMentions.stripMarkdown("Your **digest** is in:\n\n- **One**: first\n- Two\n1. Three") == "Your digest is in: One: first Two Three")
        #expect(BotMentions.stripMarkdown("Your **digest** is in:   - **One**: first") == "Your digest is in: One: first")
        #expect(BotMentions.stripMarkdown("## Heading\n> quoted [link](https://x.dev)") == "Heading quoted link")
        #expect(BotMentions.stripMarkdown("Mac mini - home server") == "Mac mini - home server")
    }

    @Test func workerHeartbeatCountsAsActive() throws {
        let beat = Date().timeIntervalSince1970 - 120
        let bot = try profile(#"{"name":"w","worker_session":{"id":"w1","last_active":\#(beat)}}"#)
        #expect(bot.isActive())
        #expect(!bot.isActive(now: Date().addingTimeInterval(60)))
    }
}

@Suite("Bot mentions")
struct BotMentionTests {
    private let roster: [BotProfile] = [
        BotProfile(json: JSONValue.parse(#"{"name":"default","is_default":true}"#)!),
        BotProfile(json: JSONValue.parse(#"{"name":"researcher","previous_names":["scholar"],"ui_meta":{"hermes-bots":{"title":"Research Buddy"}}}"#)!),
        BotProfile(json: JSONValue.parse(#"{"name":"writer","display_name":"Ada"}"#)!),
        BotProfile(json: JSONValue.parse(#"{"name":"editor","display_name":"Ada"}"#)!),
    ]

    @Test func slugs() {
        #expect(BotMentions.slug("Research Buddy") == "research-buddy")
        #expect(BotMentions.slug("  Café  Crème! ") == "cafe-creme")
    }

    @Test func resolvesHandlesFriendlyNamesAndOldNames() {
        let resolved = BotMentions.resolve("Ask @research-buddy, @hermes and @scholar", roster: roster, excluding: nil)
        #expect(resolved.map(\.bot.name) == ["researcher", "default"])
        #expect(resolved.map(\.token) == ["research-buddy", "hermes"])
    }

    @Test func ambiguousFormsAndTheActiveBotAreIgnored() {
        #expect(BotMentions.resolve("@ada please", roster: roster, excluding: nil).isEmpty)
        #expect(BotMentions.resolve("@writer and @researcher", roster: roster, excluding: "writer").map(\.bot.name) == ["researcher"])
    }

    @Test func codeIsNotAMention() {
        #expect(BotMentions.resolve("run `@researcher` now\n```\n@writer\n```", roster: roster, excluding: nil).isEmpty)
        #expect(BotMentions.resolve("mail me@writer.com", roster: roster, excluding: nil).isEmpty)
    }

    @Test func promptNoteRoundTrips() {
        let text = "Can @researchbuddy help?"
        let prompt = BotMentions.prompt(for: text, roster: roster, activeBot: "default")
        #expect(prompt.hasPrefix(text))
        #expect(prompt.contains(#"@researchbuddy = agent profile "researcher" ("Research Buddy") (message_agent target: "researcher")"#))
        #expect(prompt.hasSuffix("say so.]"))
        #expect(BotMentions.stripNote(prompt) == text)
        #expect(BotMentions.prompt(for: "no mentions", roster: roster, activeBot: nil) == "no mentions")
    }

    @Test func agentMessageForms() {
        let modern = BotMentions.parseAgentMessage("Message from 🤖 Research Buddy (@researcher): Found 3 papers.\nMore.")
        #expect(modern == BotMentions.AgentMessage(senderName: "Research Buddy", senderHandle: "researcher", body: "Found 3 papers.\nMore."))
        let legacy = BotMentions.parseAgentMessage("Message from agent 'writer': draft ready")
        #expect(legacy?.senderHandle == "writer")
        #expect(legacy?.body == "draft ready")
        #expect(BotMentions.parseAgentMessage("Hello there") == nil)
    }
}

@Suite("Bot routines")
struct BotRoutineTests {
    @Test func parsesTaggedJobs() throws {
        let json = try #require(JSONValue.parse("""
        {"job_id":"j1","name":"[bot:researcher] Morning digest","prompt_preview":"Summarise arXiv","schedule":"0 8 * * *",
         "deliver":"bot-chat","enabled":true,"state":"scheduled","next_run_at":"2026-10-13T08:00:00+00:00","last_status":"ok"}
        """))
        let routine = try #require(BotRoutine(json: json))
        #expect(routine.id == "j1")
        #expect(routine.taggedBot == "researcher")
        #expect(routine.title == "Morning digest")
        #expect(routine.deliversToBotChat)
        #expect(!routine.isPaused)
        #expect(!routine.hasFailed)
        #expect(routine.nextRunAt == ISO8601DateFormatter().date(from: "2026-10-13T08:00:00Z"))
    }

    @Test func untaggedAndFailingJobs() throws {
        let json = try #require(JSONValue.parse(#"{"id":"j2","name":"","enabled":false,"last_status":"error","last_error":"boom"}"#))
        let routine = try #require(BotRoutine(json: json))
        #expect(routine.taggedBot == nil)
        #expect(routine.title == "Untitled routine")
        #expect(routine.isPaused)
        #expect(routine.hasFailed)
        #expect(routine.issue == "boom")
        #expect(routine.deliver == "local")
    }
}

@Suite("Backend turn events")
struct GatewayTurnDecoderTests {
    private func decode(_ type: String, _ payload: String, seq: Int? = 1) -> [TurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: seq, payload: JSONValue.parse(payload)!)).map(\.event)
    }

    @Test func streamingAndTools() {
        #expect(decode("message.delta", #"{"text":"Hel"}"#) == [.textDelta("Hel")])
        #expect(decode("message.interim", #"{"text":"Checking","already_streamed":true}"#) == [.commentary("Checking", alreadyStreamed: true)])
        #expect(decode("reasoning.delta", #"{"text":"think"}"#) == [.reasoning("think", replacing: false)])
        #expect(decode("reasoning.available", #"{"text":"all of it"}"#) == [.reasoning("all of it", replacing: true)])
        #expect(decode("tool.start", #"{"tool_id":"call_1","name":"terminal","context":"ls -la","args":{"command":"ls -la"}}"#)
            == [.toolStarted(id: "call_1", name: "terminal", preview: "ls -la", at: nil)])
        #expect(decode("tool.complete", #"{"tool_id":"call_1","name":"terminal","duration_s":1.5,"summary":"2 files","result":{"output":"a b"}}"#)
            == [.toolFinished(id: "call_1", name: "terminal", failed: false, duration: 1.5, resultPreview: "2 files", at: nil)])
        #expect(decode("tool.start", #"{"tool_id":"x","name":"_internal"}"#).isEmpty)
    }

    @Test func completionStates() {
        guard case .completed(let output, let usage, _)? = decode("message.complete", #"{"text":"Done.","status":"complete","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5}}"#).last else {
            Issue.record("expected completion")
            return
        }
        #expect(output == "Done.")
        #expect(usage?.totalTokens == 5)
        #expect(decode("message.complete", #"{"text":"partial","status":"interrupted"}"#) == [.finalText("partial"), .cancelled])
        #expect(decode("message.complete", #"{"text":"","status":"error","error":"quota"}"#) == [.finalText(""), .failed("quota")])
    }

    @Test func sessionSignals() {
        #expect(decode("session.info", #"{"running":false}"#) == [.settled])
        #expect(decode("session.info", #"{"running":true}"#).isEmpty)
        #expect(decode("session.title", #"{"title":"Trip plan"}"#) == [.titleChanged("Trip plan")])
        #expect(decode("request.cancel", #"{"id":"srq-1","method":"approval","reason":"interrupted"}"#) == [.approvalResolved(requestID: nil)])
        #expect(decode("request.cancel", #"{"id":"srq-2","method":"clarify"}"#).isEmpty)
        #expect(decode("status.update", #"{"kind":"compacting","text":"Compacting context…"}"#) == [.status("Compacting context…")])
        #expect(decode("status.update", #"{"kind":"heartbeat","text":"♥"}"#).isEmpty)
        // Lasting diagnostics are notes on the turn, not the live status line.
        #expect(decode("status.update", #"{"kind":"lifecycle","text":"⚠ Compression model gpt-6-sol context is 272,000 tokens.\n  To make this permanent, edit config.yaml"}"#)
            == [.warning("Compression model gpt-6-sol context is 272,000 tokens.\n  To make this permanent, edit config.yaml")])
        #expect(decode("status.update", #"{"kind":"lifecycle","text":"⚠️ Tool guardrail halted terminal: loop"}"#) == [.warning("Tool guardrail halted terminal: loop")])
        #expect(decode("status.update", #"{"kind":"warn","text":"Memory provider unavailable"}"#) == [.warning("Memory provider unavailable")])
        // The gateway re-tags lifecycle text that mentions compression as `compacting`.
        #expect(decode("status.update", #"{"kind":"compacting","text":"⚠ Configured auxiliary compression provider 'openai-codex' is unavailable, so older messages in long chats will be cut without a summary."}"#)
            == [.warning("Configured auxiliary compression provider 'openai-codex' is unavailable, so older messages in long chats will be cut without a summary.")])
        #expect(decode("status.update", #"{"kind":"compacting","text":"Compacting context…"}"#) == [.status("Compacting context…")])
        #expect(decode("status.update", #"{"kind":"lifecycle","text":"⚠ Rate limited — waiting 5s"}"#) == [.status("⚠ Rate limited — waiting 5s")])
        #expect(decode("status.update", #"{"kind":"lifecycle","text":"↻ Stream interrupted — using delivered content as final response"}"#)
            == [.status("↻ Stream interrupted — using delivered content as final response")])
        #expect(decode("thinking.delta", #"{"text":"(◕‿◕) pondering"}"#).isEmpty)
        #expect(decode("thinking.delta", #"{"text":"⏳ Still waiting on the provider (40s)"}"#) == [.status("⏳ Still waiting on the provider (40s)")])
        #expect(GatewayTurnDecoder.decode(GatewayEvent(type: "message.delta", sessionID: "s", seq: 9, payload: .object(["text": .string("x")]))).first?.seq == 9)
    }

    @Test func approvalRequestsCarryTheirRPCID() throws {
        let request = GatewayServerRequest(id: "srq-9", method: "approval", params: try #require(JSONValue.parse(
            #"{"session_id":"s","request_id":"ap-1","command":"rm -rf build","description":"Delete build","choices":["once","session","deny"]}"#
        )))
        let approval = try #require(GatewayTurnDecoder.approval(from: request))
        #expect(approval.gatewayRequestID == "srq-9")
        #expect(approval.requestID == "ap-1")
        #expect(approval.choices == [.once, .session, .deny])
        #expect(GatewayTurnDecoder.approval(from: GatewayServerRequest(id: "srq-1", method: "clarify", params: .object([:]))) == nil)
    }
}

@Suite("Bot Chat transcripts")
struct BotChatTranscriptTests {
    @Test func agentMessagesAndMentionNotes() throws {
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id":1,"role":"user","content":"Message from 🤖 Research Buddy (@researcher): Found it.","timestamp":1760000000},
         {"id":2,"role":"user","content":"Ask @ada\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: @ada = agent profile \"writer\". If …]","timestamp":1760000001}]
        """#.utf8))
        let items = TranscriptBuilder.build(rows)
        guard case .user(let dm) = items[0], case .user(let mine) = items[1] else {
            Issue.record("unexpected items \(items)")
            return
        }
        #expect(dm.sender == AgentSender(name: "Research Buddy", handle: "researcher"))
        #expect(dm.text == "Found it.")
        #expect(mine.sender == nil)
        #expect(mine.text == "Ask @ada")
    }

    @Test func silenceMarkersFollowHermes() {
        for text in ["[SILENT]", " silent ", "NO_REPLY", "*NO_REPLY*", ".SILENT", "no reply", "[静默]"] {
            #expect(BotMentions.isSilenceMarker(text), "\(text)")
        }
        for text in ["", "[SILENT is mentioned here", "[SILENT] is mentioned here, but this is a real answer.", "Silent retry succeeded"] {
            #expect(!BotMentions.isSilenceMarker(text), "\(text)")
        }
    }

    @Test func silentRepliesVanishFromBotChats() throws {
        let rows = try JSONDecoder().decode([SessionMessage].self, from: Data(#"""
        [{"id":1,"role":"user","content":"What's new?","timestamp":1760000000},
         {"id":2,"role":"assistant","content":"Nothing yet.","timestamp":1760000001},
         {"id":3,"role":"user","content":"Your run finished.","display_kind":"internal_notification","timestamp":1760000002},
         {"id":4,"role":"assistant","content":"[SILENT]","timestamp":1760000003},
         {"id":5,"role":"user","content":"Still there?","timestamp":1760000004},
         {"id":6,"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"terminal","arguments":"{\"command\":\"ls\"}"}}],"timestamp":1760000005},
         {"id":7,"role":"tool","content":"ok","tool_call_id":"c1","tool_name":"terminal","timestamp":1760000006},
         {"id":8,"role":"assistant","content":"NO_REPLY","timestamp":1760000007}]
        """#.utf8))
        let bot = TranscriptBuilder.build(rows, hidesSilence: true)
        #expect(bot.count == 4)  // question, answer, "Still there?", and the turn that only ran a tool
        guard case .assistant(let toolTurn) = bot.last else {
            Issue.record("unexpected items \(bot)")
            return
        }
        #expect(toolTurn.answer.isEmpty)
        #expect(toolTurn.steps.count == 1)
        // Plain chats keep the marker, like Hermes.
        #expect(TranscriptBuilder.build(rows).count == 6)
    }

    @Test func silentRepliesAreNotPreviews() throws {
        let bot = BotProfile(json: JSONValue.parse(#"{"name":"default","last_session":{"id":"s","preview":"[SILENT]"}}"#)!)
        #expect(bot.preview == nil)
        // The row previews its Bot Chat, even when a routine ran later (Desktop, #88200).
        let studio = BotProfile(json: JSONValue.parse(#"{"name":"studio","canonical_session":{"id":"c","preview":"Mostly. Both jobs work again.","last_active":100},"last_session":{"id":"cron","preview":"[IMPORTANT: The user has invoked the \"growth\" skill, indicat...","last_active":200}}"#)!)
        #expect(studio.preview == "Mostly. Both jobs work again.")
        #expect(studio.lastActive == Date(timeIntervalSince1970: 200))
        // Hermes' control frames read as what they are, or give way to the role line.
        func preview(_ text: String) -> String? {
            BotProfile(json: .object(["name": .string("x"), "description": .string("Helper"),
                                      "canonical_session": .object(["id": .string("c"), "preview": .string(text)])])).preview
        }
        #expect(preview("[IMPORTANT: The user has invoked the \"work\" skill, indicating...") == "Used the work skill")
        #expect(preview("[IMPORTANT: Background process proc_1 completed normally (exit...") == "Background process finished")
        #expect(preview("[OUT-OF-BAND USER MESSAGE — a direct message from the user, delivered once...") == "Steered the reply")
        #expect(preview("[IMPORTANT: Something internal happened...") == nil)
    }

    @Test func routineDeliveries() throws {
        let text = "[Cronjob \"[bot:researcher] Morning digest\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n**3** new papers"
        let delivery = try #require(BotMentions.parseRoutineDelivery(text))
        #expect(delivery.name == "Morning digest")
        #expect(delivery.output == "**3** new papers")
        let preview = try #require(BotMentions.parseRoutineDelivery("[Cronjob \"Backups\" output — scheduled job, not..."))
        #expect(preview.name == "Backups")
        #expect(preview.output.isEmpty)
        let bot = BotProfile(json: JSONValue.parse(#"{"name":"r","last_session":{"id":"s","preview":"[Cronjob \"[bot:r] Backups\" output — scheduled job, not..."}}"#)!)
        #expect(bot.preview == "⏰ Backups")
        #expect(BotMentions.parseRoutineDelivery("Hello") == nil)
    }
}

@Suite("Live turns from the backend")
struct BackendLiveTurnTests {
    @Test func pairsParallelToolsByID() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(SequencedTurnEvent(seq: 1, event: .toolStarted(id: "a", name: "web_search", preview: "one", at: nil)))
        live.apply(SequencedTurnEvent(seq: 2, event: .toolStarted(id: "b", name: "web_search", preview: "two", at: nil)))
        live.apply(SequencedTurnEvent(seq: 3, event: .toolFinished(id: "b", name: "web_search", failed: true, duration: 2, resultPreview: "err", at: nil)))
        let tools = live.turn.steps.compactMap { step -> ToolActivity? in
            if case .tool(let tool) = step { tool } else { nil }
        }
        #expect(tools.map(\.status) == [.running, .failed])
        #expect(tools[1].result == "err")
    }

    @Test func reasoningAppendsThenReplaces() {
        var live = LiveTurn(id: "t", sessionID: "s")
        live.apply(SequencedTurnEvent(seq: nil, event: .reasoning("Let me ", replacing: false)))
        live.apply(SequencedTurnEvent(seq: nil, event: .reasoning("think", replacing: false)))
        #expect(live.turn.reasoningText == "Let me think")
        live.apply(SequencedTurnEvent(seq: nil, event: .reasoning("Let me think it through.", replacing: true)))
        #expect(live.turn.reasoningText == "Let me think it through.")
        #expect(live.turn.steps.count == 1)
    }
}
