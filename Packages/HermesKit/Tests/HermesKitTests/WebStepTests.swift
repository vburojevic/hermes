import Foundation
import HermesPush
import Testing
@testable import HermesKit

@Suite("Steps in a chat")
struct WebStepTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func signInSaysTheSiteAndTheSourceNeverTheLogin() throws {
        let step = try #require(WebStep.describe(name: "browser_vault", arguments: try json(#"{"action": "fill", "handle": "op:k3v9github"}"#),
                                                 result: #"{"success": true, "filled_fields": 1, "backend": "onepassword", "kind": "login", "origin": "https://github.com", "next": "Submit."}"#,
                                                 isRunning: false))
        #expect(step.title == "Signed in to github.com")
        #expect(step.preview == "Your login from 1Password · Hermes never saw the password")
        #expect(step.failure == nil)
    }

    @Test func codesSayWhereTheyCameFrom() throws {
        let fromKey = WebStep.describe(name: "browser_vault", arguments: try json(#"{"action": "enter_code", "handle": "vault_1"}"#),
                                       result: #"{"success": true, "filled_fields": 1, "origin": "https://accounts.example.com", "source": "local"}"#, isRunning: false)
        #expect(fromKey?.title == "Entered the 2FA code")
        #expect(fromKey?.preview == "From your authenticator key")
        let fromYou = WebStep.describe(name: "browser_vault", arguments: try json(#"{"action": "enter_code"}"#),
                                       result: #"{"success": true, "filled_fields": 1, "source": "user"}"#, isRunning: false)
        #expect(fromYou?.preview == "From you")
    }

    @Test func refusalsReadInWords() throws {
        let args = try json(#"{"action": "fill", "handle": "op:k3v9github"}"#)
        let mismatch = WebStep.describe(name: "browser_vault", arguments: args, result: """
        {"success": false, "error_type": "origin_mismatch", "error": "Refused: current page origin (https://gist.github.com) does not match the vault item's bound origin(s) (https://github.com). Vault fills only run on the exact origin(s) the credential was saved for."}
        """, isRunning: false)
        #expect(mismatch?.failure == "Your login is for github.com, not this page.")
        let locked = WebStep.describe(name: "browser_vault", arguments: args,
                                      result: #"{"success": false, "error_type": "unlock_cancelled", "error": "The user declined to unlock 1Password."}"#, isRunning: false)
        #expect(locked?.failure == "1Password is locked.")
        let declined = WebStep.describe(name: "browser_vault", arguments: try json(#"{"action": "fill", "handle": "vault_9f2b4d6e8a0c"}"#),
                                        result: #"{"success": false, "error_type": "payment_declined", "error": "The user did not confirm filling this payment card."}"#, isRunning: false)
        #expect(declined?.declined == true)
        #expect(declined?.failure == "Not filled.")
        let device = WebStep.describe(name: "browser_vault", arguments: try json(#"{"action": "enter_code"}"#),
                                      result: #"{"success": false, "error_type": "no_code_field", "error": "No one-time-code field…"}"#, isRunning: false)
        #expect(device?.failure == "Finish signing in on your device.")
        let control = WebStep.describe(name: "browser_vault", arguments: args,
                                       result: #"{"success": false, "error_type": "human_has_control", "error": "x"}"#, isRunning: false)
        #expect(control?.failure == "You're in control of the browser; Hermes is waiting.")
    }

    @Test func navigationShowsTheAddressNotTheQuery() throws {
        let step = WebStep.describe(name: "browser_navigate", arguments: try json(#"{"url": "https://www.vercel.com/login?next=/dashboard"}"#),
                                    result: #"{"success": true}"#, isRunning: false)
        #expect(step?.title == "Opened vercel.com")
        #expect(step?.preview == "www.vercel.com/login")
        #expect(step?.previewIsAddress == true)
    }

    @Test func typingNeverShowsTheText() throws {
        let step = WebStep.describe(name: "browser_type", arguments: try json(#"{"ref": "@e3", "text": "sam@example.com"}"#), result: nil, isRunning: true)
        #expect(step?.preview == nil)
        #expect(step?.title == "Typing into the page")
        #expect(WebStep.hidesArguments("browser_type"))
    }

    @Test func browserUseStepsTakeTheScriptsComment() throws {
        let step = WebStep.describe(name: "browser_exec", arguments: try json(##"{"code": "# open the deploy log\npage.goto('https://vercel.com')"}"##), result: nil, isRunning: true)
        #expect(step?.title == "Open the deploy log")
    }

    @Test func otherToolsAreLeftAlone() {
        #expect(WebStep.describe(name: "terminal", arguments: nil, result: nil, isRunning: false) == nil)
    }

    // MARK: Card fills

    @Test func readsHermesCardFillCommand() throws {
        let fill = try #require(PaymentFill(command: "Fill payment card 'Personal Visa' on https://www.amazon.com"))
        #expect(fill.label == "Personal Visa")
        #expect(fill.origin == "https://www.amazon.com")
        #expect(fill.site == "amazon.com")
        // A name with quotes and " on " in it still splits at the last separator.
        let tricky = try #require(PaymentFill(command: "Fill payment card 'Work card' on site' on https://shop.example.com"))
        #expect(tricky.label == "Work card' on site")
        #expect(tricky.origin == "https://shop.example.com")
        #expect(PaymentFill(command: "rm -rf /") == nil)
        #expect(PaymentFill.isPaymentFill("Fill payment card 'x"))
    }

    @Test func aCardFillNeverOffersAlwaysOrTheBanner() throws {
        let request = try JSONDecoder().decode(ApprovalRequest.self, from: Data("""
        {"request_id": "r1", "command": "Fill payment card 'Personal Visa' on https://www.amazon.com",
         "description": "The agent wants to enter your saved card details into this checkout page.",
         "pattern_key": "mcp_elicitation", "allow_permanent": true}
        """.utf8))
        #expect(request.isPaymentFill)
        #expect(request.paymentFill?.label == "Personal Visa")
    }
}
