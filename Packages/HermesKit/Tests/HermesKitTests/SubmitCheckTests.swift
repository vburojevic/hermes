import Foundation
import Testing
@testable import HermesKit

@Suite("Did an unanswered send arrive")
struct SubmitCheckTests {
    let sent = Date(timeIntervalSince1970: 1_792_000_000)

    private func user(_ id: Int, _ text: String, at offset: TimeInterval) -> SessionMessage {
        SessionMessage(id: id, role: "user", content: .text(text), timestamp: sent.addingTimeInterval(offset))
    }

    @Test func storedAfterWhatTheChatKnewArrived() {
        let messages = [user(40, "ok", at: -300), SessionMessage(id: 41, role: "assistant", content: .text("Done.")), user(42, "ok", at: 1)]
        #expect(SubmitCheck.arrived("ok", sentAt: sent, knownNewestID: 41, in: messages))
    }

    @Test func anEarlierIdenticalMessageIsNotIt() {
        // "ok" was sent and answered a minute ago; this "ok" never got there.
        let messages = [user(40, "ok", at: -60), SessionMessage(id: 41, role: "assistant", content: .text("Done."))]
        #expect(!SubmitCheck.arrived("ok", sentAt: sent, knownNewestID: 41, in: messages))
    }

    @Test func aNewChatGoesByTimeAlone() {
        #expect(SubmitCheck.arrived("Plan the trip", sentAt: sent, knownNewestID: nil, in: [user(1, "Plan the trip", at: -3)]))
        #expect(!SubmitCheck.arrived("Plan the trip", sentAt: sent, knownNewestID: nil, in: [user(1, "Plan the trip", at: -600)]))
    }

    @Test func somethingElseSentSinceLeavesItOpen() {
        // Stored in another form (an attachment's text), or sent from another device: not "never got there".
        let messages = [user(40, "ok", at: -60), user(42, "[image] Look at this", at: 1)]
        #expect(!SubmitCheck.arrived("Look at this", sentAt: sent, knownNewestID: 41, in: messages))
        #expect(SubmitCheck.anySent(since: sent, knownNewestID: 41, in: messages))
        #expect(!SubmitCheck.anySent(since: sent, knownNewestID: 42, in: messages))
    }

    @Test func wordsMatterNotTheirSpacing() {
        let messages = [user(42, "Check the NAS\nthen the router ", at: 2)]
        #expect(SubmitCheck.arrived("Check the NAS then the router", sentAt: sent, knownNewestID: 41, in: messages))
        #expect(!SubmitCheck.arrived("Check the NAS", sentAt: sent, knownNewestID: 41, in: messages))
        #expect(!SubmitCheck.arrived("Check the NAS then the router", sentAt: sent, knownNewestID: 41,
                                     in: [SessionMessage(id: 42, role: "assistant", content: .text("Check the NAS then the router"))]))
    }
}
