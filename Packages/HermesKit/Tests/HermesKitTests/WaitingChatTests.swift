import Foundation
import Testing
@testable import HermesKit

@Suite("A new chat's first message waiting on the device")
struct WaitingChatTests {
    let sent = Date(timeIntervalSince1970: 1_792_000_000)

    private func chat() -> WaitingChat {
        WaitingChat(title: "Plan the trip\nto Split", sentAt: sent, key: "waiting-1", requestedID: "api_1792000000_0a1b2c3d")
    }

    @Test func untilHermesMakesItItsKeptUnderItsOwnKey() {
        var waiting = chat()
        #expect(WaitingChat.isKey(waiting.key))
        #expect(waiting.outboxKey == "waiting-1")
        #expect(waiting.rowKey == "waiting-1")
        waiting.created("20261023_101500_abc123")
        #expect(waiting.outboxKey == "20261023_101500_abc123")
        #expect(waiting.rowKey == "20261023_101500_abc123")
        #expect(!WaitingChat.isKey(waiting.rowKey))
    }

    @Test func aMessageThatNeverLeftGoesAgainAsANewChat() {
        var waiting = chat()
        #expect(waiting.resume == .send)
        // Made over the socket, never stored: it goes again as a new chat, asking for the same id.
        waiting.created("20261023_101500_abc123")
        #expect(waiting.resume == .send)
        let resent = waiting.resent
        #expect(resent.sessionID == nil)
        #expect(resent.key == waiting.key)
        #expect(resent.requestedID == "api_1792000000_0a1b2c3d")
        #expect(resent.outboxKey == "waiting-1")
    }

    @Test func aMessageThatLeftIsLookedForAndNeverSentAgainByItself() {
        var waiting = chat()
        waiting.left(in: "20261023_101500_abc123")
        #expect(waiting.mayHaveArrived)
        #expect(waiting.resume == .lookFor(sessionID: "20261023_101500_abc123"))
        #expect(waiting.resent == waiting)
    }

    @Test func itsRowShowsUntilTheListHasTheChat() {
        var older = WaitingChat(title: "First", sentAt: sent, key: "waiting-a")
        let newer = WaitingChat(title: "Second", sentAt: sent.addingTimeInterval(5), key: "waiting-b")
        #expect(WaitingChat.rows([older, newer], listed: []).map(\.id) == ["waiting-b", "waiting-a"])
        #expect(WaitingChat.rows([older, newer], listed: []).first?.title == "Second")
        older.created("api_1_00000000")
        // Filed in the list under the chat Hermes made (`adopt`): that row stands for it.
        #expect(WaitingChat.rows([older, newer], listed: ["api_1_00000000"]).map(\.id) == ["waiting-b"])
    }

    @Test func aChatHermesListsAfterItsMessageWentOutHasArrived() {
        var left = chat()
        left.left(in: "20261023_101500_abc123")
        var made = WaitingChat(title: "Other", sentAt: sent, key: "waiting-2")
        // An API server chat is listed as soon as it's made, before its message goes.
        made.created("api_1792000000_ffffffff")
        let listed: Set<String> = ["20261023_101500_abc123", "api_1792000000_ffffffff"]
        #expect(WaitingChat.remaining([left, made], gatewayListed: listed) == [made])
        #expect(WaitingChat.remaining([left, made], gatewayListed: []) == [left, made])
    }

    @Test func keptAcrossALaunch() throws {
        var waiting = WaitingChat(title: "Plan", sentAt: sent, model: ModelSelection(provider: "nous", model: "Hermes-4-70B"),
                                  effort: .high, projectID: "p1", key: "waiting-1", requestedID: "api_1_00000000")
        waiting.left(in: "api_1_00000000")
        let decoded = try JSONDecoder().decode(WaitingChat.self, from: JSONEncoder().encode(waiting))
        #expect(decoded == waiting)
        #expect(decoded.resume == .lookFor(sessionID: "api_1_00000000"))
    }

    @Test func itsIdIsShapedLikeHermessOwn() {
        let id = WaitingChat.newSessionID(at: sent)
        #expect(id.wholeMatch(of: /api_1792000000_[0-9a-f]{8}/) != nil)
        #expect(WaitingChat.newSessionID(at: sent) != id)
    }

    @Test func itsTitleIsTheMessagesFirstWords() {
        #expect(chat().title == "Plan the trip to Split")
        let long = WaitingChat(title: String(repeating: "word ", count: 30), sentAt: sent)
        #expect(long.title.count == 60)
        #expect(long.title.hasSuffix("…"))
    }
}
