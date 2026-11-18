import Testing
@testable import HermesKit

/// Sending turns the page unless Keep chat at bottom when sending is on (`docs/chat.md` §4).
@Suite("Send scroll")
struct SendScrollPolicyTests {
    @Test func theSettingStartsOff() {
        #expect(SendScroll.keepsAtBottomByDefault == false)
    }

    @Test func offTurnsThePageToTheMessage() {
        #expect(SendScroll.onSend(keepsAtBottom: false, messageShown: true) == .turnPage)
    }

    @Test func onKeepsTheChatAtItsEnd() {
        #expect(SendScroll.onSend(keepsAtBottom: true, messageShown: true) == .followEnd)
    }

    @Test func withNoMessageToHoldTheChatGoesToItsEnd() {
        #expect(SendScroll.onSend(keepsAtBottom: false, messageShown: false) == .followEnd)
        #expect(SendScroll.onSend(keepsAtBottom: true, messageShown: false) == .followEnd)
    }
}
