import Foundation
import Testing
@testable import HermesKit

/// A send whose answer was lost is settled by evidence keyed to the message, never by its words
/// and never by absence (`LostPrompt`).
@Suite("A send whose answer was lost")
struct LostPromptTests {
    private let sentAt = Date(timeIntervalSince1970: 1_760_000_000)
    private var key: LostPrompt { LostPrompt(knownNewestID: 40, sentAt: sentAt) }

    private func row(_ id: Int, _ role: String = "user", text: String = "hi", at offset: TimeInterval = 2, kind: String? = nil) -> SessionMessage {
        SessionMessage(id: id, role: role, content: .text(text), timestamp: sentAt.addingTimeInterval(offset), displayKind: kind)
    }

    /// Hermes still building the chat's agent: idle, nothing stored. Not a reason to send again.
    @Test func idleWithNothingStoredIsNothingYet() {
        #expect(key.finding(running: false, turnStartedAt: nil, messages: [row(40, "assistant")]) == .nothingYet)
        #expect(key.finding(running: false, turnStartedAt: nil, messages: nil) == .nothingYet)
    }

    @Test func aTurnStartedAfterTheSendIsThisMessagesTurn() {
        #expect(key.finding(running: true, turnStartedAt: sentAt.addingTimeInterval(10), messages: []) == .taken)
        // The gateway's clock a little behind the device's.
        #expect(key.finding(running: true, turnStartedAt: sentAt.addingTimeInterval(-5), messages: []) == .taken)
        #expect(key.finding(running: true, turnStartedAt: nil, messages: []) == .taken)
    }

    /// A turn that started well before the send is an older one: it says nothing about this message.
    @Test func anOlderTurnStillRunningIsNoEvidence() {
        #expect(key.finding(running: true, turnStartedAt: sentAt.addingTimeInterval(-90), messages: []) == .nothingYet)
    }

    /// Stored in another form than the composer held (a mention's note, a file reference): still it.
    @Test func aRowAfterTheNewestOneHeldIsThisMessageWhateverItsWords() {
        let stored = row(41, text: "@ops what changed?\n\n[Note: @ops = agent profile \"ops\"]")
        #expect(key.finding(running: false, turnStartedAt: nil, messages: [row(40, "assistant"), stored]) == .stored)
    }

    @Test func rowsFromBeforeTheSendAreNotIt() {
        // The same words sent earlier ("ok", then "ok"): its id is one the chat already had.
        #expect(!key.wasStored(in: [row(39, text: "ok"), row(40, "assistant")]))
        // A newer id with a time long before the send (another device, earlier).
        #expect(!key.wasStored(in: [row(41, at: -600)]))
    }

    @Test func rowsHermesAddsItselfAreNotIt() {
        #expect(!key.wasStored(in: [row(41, kind: "hidden"), row(42, kind: "failed_turn"), row(43, kind: "internal_notification")]))
        #expect(!key.wasStored(in: [row(41, "assistant")]))
    }

    /// A chat with no rows yet: only a row stamped around the send counts.
    @Test func aNewChatCountsARowFromAroundTheSend() {
        let fresh = LostPrompt(knownNewestID: nil, sentAt: sentAt)
        #expect(fresh.wasStored(in: [row(1)]))
        #expect(!fresh.wasStored(in: [SessionMessage(id: 1, role: "user", content: .text("hi"))]))
    }
}
