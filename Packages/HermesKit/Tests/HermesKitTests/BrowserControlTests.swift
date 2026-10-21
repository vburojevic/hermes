import Foundation
import Testing
@testable import HermesKit

@Suite("Browsing in the app")
struct BrowserControlTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func readsCommandsAndCancelsOnEitherTransport() throws {
        // The controller socket's `{method, params}` (`gateway/browser_control_broker.py`).
        let frame = BrowserControlFrame(json: try json("""
        {"method": "browser.controller.command", "params": {"command_id": "c1", "action": "browser_click",
         "arguments": {"ref": "@e5"}, "controller_id": "hermes-app-x", "browser_profile_id": "hermes-app", "tool_call_id": "t1"}}
        """))
        guard case .command(let command) = frame else { Issue.record("not a command"); return }
        #expect(command.action == "browser_click")
        #expect(command.string("ref") == "@e5")
        #expect(command.toolCallID == "t1")
        // The backend socket wraps the same frame as an event's type and payload.
        let cancel = BrowserControlFrame(method: "browser.controller.cancel", params: try json(#"{"command_id": "c1", "tool_call_id": "t1"}"#))
        #expect(cancel == .cancel(commandID: "c1", toolCallID: "t1"))
        #expect(BrowserControlFrame(method: "browser.controller.command", params: try json(#"{"action": "x"}"#)) == .other)
    }

    @Test func resultsAnswerWithTheCommandsID() {
        let ok = BrowserCommandResult.success("c1", #"{"success": true}"#)
        #expect(ok.params["ok"] == .bool(true))
        #expect(ok.params["result"] == .string(#"{"success": true}"#))
        #expect(ok.params["error"] == nil)
        let failed = BrowserCommandResult.failure("c2", "unknown action")
        #expect(failed.params["error"] == .string("unknown action"))
        #expect(failed.frame["method"] == .string("browser.controller.result"))
    }

    @Test func theTicketRidesInTheProtocolsNotTheURL() throws {
        let ticket = try #require(BrowserControlTicket(json: try json("""
        {"protocol_version": 1, "ticket": "abc123", "ticket_expires_in_seconds": 30, "ws_path": "/v1/browser-control/ws",
         "scope": {"capabilities": ["browser_click", "browser_navigate"]}}
        """)))
        #expect(ticket.protocols == ["hermes-browser-control-v1", "hermes-browser-control-ticket.abc123"])
        #expect(ticket.capabilities == ["browser_click", "browser_navigate"])
        let client = HermesClient(baseURL: URL(string: "https://studio.example.com:8642")!, apiKey: "k")
        #expect(client.browserControlSocketURL(path: ticket.socketPath)?.absoluteString == "wss://studio.example.com:8642/v1/browser-control/ws")
        let local = HermesClient(baseURL: URL(string: "http://127.0.0.1:8642")!, apiKey: "k")
        #expect(local.browserControlSocketURL(path: "/v1/browser-control/ws")?.absoluteString == "ws://127.0.0.1:8642/v1/browser-control/ws")
    }

    @Test func neverAsksForDeveloperCapabilities() {
        #expect(!BrowserControl.capabilities.contains("browser_cdp"))
        #expect(!BrowserControl.capabilities.contains("browser_evaluate"))
    }

    @Test func refusalsSayWhatWouldFixThem() {
        #expect(BrowserControlRefusal.from(status: 404, code: "browser_control_disabled", message: nil) == .turnedOff)
        #expect(BrowserControlRefusal.from(status: 404, code: nil, message: "Not Found") == .needsNewerHermes)
        #expect(BrowserControlRefusal.from(status: 403, code: "browser_control_auth_required", message: nil) == .needsAPIKey)
        #expect(BrowserControlRefusal.from(status: 403, code: "browser_control_session_forbidden", message: nil) == .unknownSession)
        let identity = GatewayRPCError(code: 4403, message: "browser.controller.register requires an authenticated non-internal identity")
        #expect(BrowserControlRefusal.from(rpc: identity) == .needsSignIn)
        #expect(BrowserControlRefusal.from(rpc: GatewayRPCError(code: 4403, message: "browser.extension_control.enabled is not set")) == .turnedOff)
        #expect(BrowserControlRefusal.from(rpc: GatewayRPCError(code: -32601, message: "unknown method")) == .needsNewerHermes)
        // `_handle_browser_control_register`'s other answers.
        #expect(BrowserControlRefusal.from(status: 400, code: "browser_control_protocol_unsupported", message: nil) == .needsNewerHermes)
        #expect(BrowserControlRefusal.from(status: 401, code: "gateway_auth_failed", message: nil) == .keyRefused)
        #expect(BrowserControlRefusal.from(rpc: GatewayRPCError(code: 4403, message: "unsupported browser-control protocol version; expected 1")) == .needsNewerHermes)
    }

    @Test func takeOverAnswersLikeHermessOwnBrowser() throws {
        // The refusal Hermes's browser gives while a person holds its screen, so the model waits.
        let answer = try json(BrowserControl.personHasControl)
        #expect(answer["success"] == .bool(false))
        #expect(answer["code"] == .string("human_has_control"))
        let step = WebStep.describe(name: "browser_click", arguments: nil, result: BrowserControl.personHasControl, isRunning: false)
        #expect(step?.failure == "You're in control of the browser; Hermes is waiting.")
        #expect(step?.declined == true)
        let opened = WebStep.describe(name: "browser_navigate", arguments: .object(["url": .string("https://vercel.com/login")]),
                                      result: BrowserControl.personHasControl, isRunning: false)
        #expect(opened?.title == "Didn't open vercel.com")
        #expect(opened?.declined == true)
    }

    @Test func unfinishedCommandsReadInWords() {
        // `tools/registry.py` wraps the broker's exception for the model.
        let timeout = #"{"error": "[TOOL_ERROR] Tool execution failed: ControllerTimeout: controller did not complete command 'ab12' within 30.0s"}"#
        let step = WebStep.describe(name: "browser_snapshot", arguments: nil, result: timeout, isRunning: false)
        #expect(step?.title == "Didn't read the page")
        #expect(step?.failure == "This app's browser didn't answer in 30 seconds.")
        let unavailable = #"{"error": "[TOOL_ERROR] Tool execution failed: ControllerUnavailable: bound browser controller cannot execute browser_navigate"}"#
        let opened = WebStep.describe(name: "browser_navigate", arguments: .object(["url": .string("https://vercel.com")]), result: unavailable, isRunning: false)
        #expect(opened?.failure == "This app's browser wasn't connected, so Hermes couldn't use it.")
        // Hermes's own browser keeps the usual step for the other tools.
        #expect(WebStep.describe(name: "browser_click", arguments: nil, result: #"{"success": true}"#, isRunning: false) == nil)
        #expect(WebStep.describe(name: "browser_click", arguments: nil, result: #"{"success": false, "error": "Element not found"}"#, isRunning: false) == nil)
    }

    @Test func setupSaysWhenInThisAppCantConnect() {
        var facts = GatewaySetupFacts(gatewayName: "Studio Mac", gatewayOnline: true, botMode: .online)
        facts.config = .object(["browser": .object(["extension_control": .object(["enabled": .bool(true)])])])
        #expect(GatewaySetup.browser(facts).detail == "In this app")
        facts.inAppBrowserRefusal = .needsSignIn
        let status = GatewaySetup.browser(facts)
        #expect(status.state == .limited)
        #expect(status.fallback?.contains("its own browser") == true)
        // Only a chat Hermes hasn't stored yet stays Ready: its next turn registers again.
        for refusal in [BrowserControlRefusal.turnedOff, .keyRefused, .needsAPIKey, .needsNewerHermes, .other("no")] {
            facts.inAppBrowserRefusal = refusal
            #expect(GatewaySetup.browser(facts).state == .limited)
        }
        facts.inAppBrowserRefusal = .unknownSession
        #expect(GatewaySetup.browser(facts).state == .ready)
    }
}
