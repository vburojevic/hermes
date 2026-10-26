import Foundation
import Testing
@testable import HermesKit

/// Every reason Hermes gives for refusing a message (4090), in the words and with the action the
/// app takes (`docs/chat.md` §4d). The messages are Hermes's own (hermes-agent
/// `tui_gateway/methods_prompt.py`, `session_lifecycle.py`, `hermes_cli/active_sessions.py`).
@Suite("Hermes refusing a message")
struct SendRefusalTests {
    private func refusal(_ reason: String?, _ message: String) -> GatewayRPCError {
        GatewayRPCError(code: 4090, message: message, data: reason.map { .object(["reason": .string($0)]) })
    }

    private let capText = "as many chats at once"

    @Test func theGatewayRunningATurnWaitsForItAndIsNeverTheChatLimit() throws {
        let error = refusal("SESSION_OWNER_BUSY", "The gateway is running a turn in this chat and a rewind or attachment cannot join its queue. Nothing was sent. Send it again when the current turn ends.")
        let refused = try #require(SendRefusal(error))
        #expect(refused.reason == .ownerBusy(imageRemoved: false))
        #expect(refused.action == .waitsForChat)
        #expect(refused.holder == .gatewayTurn)
        #expect(!refused.offersRetry)
        #expect(error.errorDescription?.contains(capText) == false)
        #expect(error.errorDescription == "The gateway is running a turn in this chat. Your message sends when that turn ends.")
    }

    @Test func aPhotoHermesTookOffSaysSo() throws {
        let refused = try #require(SendRefusal(refusal("SESSION_OWNER_BUSY", "The gateway is running a turn in this chat and an image cannot join its queue, so it was removed from this message. Nothing was sent. Send it again when the current turn ends.")))
        #expect(refused.reason == .ownerBusy(imageRemoved: true))
        #expect(refused.line.contains("with its photo"))
    }

    @Test func anUnconfirmedMessageIsCheckedForAndNeverRetried() throws {
        let error = refusal("SESSION_OWNER_UNCONFIRMED", "The gateway is running a turn in this chat and did not confirm your message in time. It may already be queued there: check the chat before sending it again.")
        let refused = try #require(SendRefusal(error))
        #expect(refused.reason == .ownerUnconfirmed)
        #expect(refused.action == .checkTheChat)
        #expect(!refused.offersRetry)
        #expect(error.errorDescription?.contains(capText) == false)
        #expect(error.errorDescription?.contains("check the chat before sending it again") == true)
    }

    @Test func anUnconfirmedSendMayHaveArrivedSoItIsLookedForNotSentAgain() {
        let unconfirmed = refusal("SESSION_OWNER_UNCONFIRMED", "The gateway is running a turn in this chat and did not confirm your message in time. It may already be queued there: check the chat before sending it again.")
        #expect(SendFailure.overSocket(unconfirmed) == .mayHaveArrived)
        // Refused outright: nothing was sent, so nothing can run twice.
        #expect(SendFailure.overSocket(refusal("SESSION_OWNER_BUSY", "The gateway is running a turn in this chat and the gateway refused it. Nothing was sent. Send it again when the current turn ends.")) == .refused)
        #expect(SendFailure.overSocket(refusal(nil, "Hermes could not safely reserve this session. Try again.")) == .refused)
    }

    @Test func theRealChatLimitSaysHowManyAndWaits() throws {
        let error = refusal("MAX_CONCURRENT_SESSIONS", "Hermes is at the active session limit (3/3). Held by: 2 desktop, 1 cli, oldest 4m ago. Try again when another session finishes.")
        let refused = try #require(SendRefusal(error))
        #expect(refused.reason == .atLimit(active: 3, limit: 3))
        #expect(refused.action == .waitsForChat)
        #expect(refused.holder == .chatLimit(active: 3, limit: 3))
        #expect(refused.line == "Hermes is running as many chats at once as it's set to allow (3 of 3). Your message sends when one finishes.")
    }

    @Test func noReasonShowsHermessOwnWordsNeverTheLimit() throws {
        let error = refusal(nil, "Hermes could not safely reserve this session. Try again.")
        let refused = try #require(SendRefusal(error))
        #expect(refused.reason == .other)
        #expect(refused.action == .tryAgain)
        #expect(refused.offersRetry)
        #expect(error.errorDescription == "Hermes could not safely reserve this session. Try again.")
    }

    @Test func aReasonTheAppDoesntKnowShowsHermessOwnWords() {
        let error = refusal("SOMETHING_NEW", "Hermes has a new reason.\nDetails: for logs.")
        #expect(SendRefusal(error)?.reason == .other)
        #expect(error.errorDescription == "Hermes has a new reason.")
    }

    @Test func anUnreadableRegistryShowsHermessFirstLine() throws {
        let refused = try #require(SendRefusal(refusal("SESSION_COORDINATION_UNAVAILABLE", "Hermes could not read the active-session registry at /x/active_sessions.json, so it cannot prove this session has no other live owner. Fix or remove that file and try again.")))
        #expect(refused.reason == .coordinationUnavailable)
        #expect(refused.action == .tryAgain)
        #expect(refused.line.hasPrefix("Hermes could not read the active-session registry"))
    }

    @Test func aChatAnotherProcessHoldsWaitsAndKnowsTheProcess() throws {
        let refused = try #require(SendRefusal(refusal("SESSION_NOT_OWNED", "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session 20261025_x opened by cli 0m ago.")))
        guard case .chatHeld(let hold?) = refused.reason else {
            Issue.record("not a held chat: \(refused.reason)")
            return
        }
        #expect(hold.surface == "cli")
        #expect(refused.action == .waitsForChat)
        #expect(refused.holder == nil) // told from the chat's stored rows
    }

    @Test func workOnlyTheGatewaySettlesWaitsForThePersonNotForever() throws {
        let refused = try #require(SendRefusal(refusal("SESSION_NOT_OWNED", "Session 20261025_x has outcome-unknown work in the gateway's durable queue. Resume it through the gateway (hermes chat --resume, Desktop or the TUI) to resolve it; nothing was run here.")))
        #expect(refused.reason == .gatewayWorkUnresolved)
        #expect(refused.action == .settleOnGateway)
        #expect(!refused.offersRetry)
        #expect(!refused.line.contains("outcome-unknown"))
    }

    @Test func otherRefusalsAreNotA4090() {
        #expect(SendRefusal(GatewayRPCError(code: 4009, message: "session busy")) == nil)
        #expect(SendRefusal(GatewayRPCError(code: 4010, message: "agent does not support steer")) == nil)
    }
}
