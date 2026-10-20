import Foundation
import Testing
@testable import HermesKit

/// The risk note under a step says what Hermes's scanner found, not more (`docs/chat.md` §2 Tools).
@Suite("Tool output risk")
struct ToolRiskTests {
    private func risk(_ findings: [String], risk: String? = "high", redacted: Bool = false, tool: String? = "web_extract") -> ToolRisk {
        ToolRisk(risk: risk, findings: findings, redacted: redacted, tool: tool)
    }

    private func decode(_ payload: String) -> [TurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: "tool.output_risk", sessionID: "s", seq: 1, payload: JSONValue.parse(payload)!)).map(\.event)
    }

    @Test func charactersOrdinaryTextCarriesEarnNoNote() {
        // Hermes's INVISIBLE_CHARS that ordinary pages carry, and the soft hyphen.
        for code in ["200B", "200C", "200D", "2060", "FEFF", "00AD", "2062", "2063", "2064"] {
            #expect(ToolRisk.concern(of: "invisible_unicode_U+\(code)") == .ordinary, "U+\(code)")
        }
        #expect(risk(["invisible_unicode_U+200B"]).isQuiet, "one zero-width space is not a warning")
        #expect(risk(["invisible_unicode_U+200B", "invisible_unicode_U+FEFF"]).isQuiet)
    }

    @Test func charactersThatReorderOrHideTextAreHiddenCharacters() {
        for code in ["202A", "202B", "202C", "202D", "202E", "2066", "2067", "2068", "2069", "E0001", "E0041", "E007F"] {
            #expect(ToolRisk.concern(of: "invisible_unicode_U+\(code)") == .hiddenCharacters, "U+\(code)")
        }
        let found = risk(["invisible_unicode_U+200B", "invisible_unicode_U+202E"])
        #expect(found.concern == .hiddenCharacters)
        #expect(!found.isQuiet)
        #expect(found.shownFindings == ["Right-to-left override (U+202E)"], "the zero-width space isn't listed")
        #expect(ToolRisk.label("invisible_unicode_U+E0041") == "Tag character (U+E0041)")
    }

    @Test func instructionShapedFindingsKeepTheInstructionsNote() {
        let found = risk(["invisible_unicode_U+200B", "prompt_injection"])
        #expect(found.concern == .instructions)
        #expect(found.shownFindings == ["prompt_injection"])
        // Every pattern in Hermes's tools/threat_patterns.py that reads as instructions or commands.
        for id in ["prompt_injection", "sys_prompt_override", "disregard_rules", "bypass_restrictions", "html_comment_injection",
                   "translate_execute", "deception_hide", "role_hijack", "role_pretend", "leak_system_prompt", "remove_filters",
                   "fake_update", "identity_override", "c2_node_registration", "c2_heartbeat", "c2_task_pull", "c2_network_connect",
                   "forced_action", "anti_forensic_oneliner", "anti_forensic_disk", "env_var_unset_agent", "known_c2_framework",
                   "c2_explicit", "c2_explicit_long", "exfil_curl", "exfil_wget", "read_secrets", "send_to_url", "context_exfil",
                   "ssh_backdoor", "ssh_access", "hermes_env", "agent_config_mod", "hermes_config_mod"] {
            #expect(ToolRisk.concern(of: id) == .instructions, "\(id)")
        }
    }

    @Test func hiddenTextSecretsAndUnknownIds() {
        #expect(risk(["hidden_div"]).concern == .hiddenText)
        #expect(risk(["hardcoded_secret"]).concern == .secret)
        #expect(risk([], risk: "secrets").concern == .secret)
        #expect(risk(["some_new_pattern"]).concern == .unknown, "an id the app doesn't know is shown, not hidden")
        #expect(!risk([]).isQuiet, "a flag without findings still shows")
        #expect(!risk(["invisible_unicode_U+200B"], redacted: true).isQuiet, "whatever Hermes hid from the model is said")
    }

    @Test func pagesAndOtherResults() {
        #expect(risk([], tool: "web_extract").isPage)
        #expect(risk([], tool: "browser_snapshot").isPage)
        #expect(risk([], tool: nil).isPage)
        #expect(!risk([], tool: "mcp_github_get_issue").isPage)
    }

    @Test func theDecoderDropsQuietFindings() {
        #expect(decode(#"{"tool_id":"call_1","name":"web_extract","risk":"high","findings":["invisible_unicode_U+200B"],"redacted":false}"#).isEmpty)
        let events = decode(#"{"tool_id":"call_2","name":"web_extract","risk":"high","findings":["invisible_unicode_U+202E"],"redacted":false}"#)
        guard case .toolRisk(let id, let name, let found)? = events.first else {
            Issue.record("no risk event: \(events)")
            return
        }
        #expect(id == "call_2")
        #expect(name == "web_extract")
        #expect(found.tool == "web_extract")
        #expect(found.concern == .hiddenCharacters)
    }
}
