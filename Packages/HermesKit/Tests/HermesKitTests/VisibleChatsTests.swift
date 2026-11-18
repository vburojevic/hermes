import Foundation
import HermesPush
import Testing
@testable import HermesKit

/// A chat open in any visible window counts as seen: each gateway hears its own open chat, and a
/// notice for it doesn't banner (`docs/notifications.md` §1.2, §1.6).
@Suite("Visible chats")
struct VisibleChatsTests {
    let home = UUID()
    let work = UUID()
    let first = UUID()
    let second = UUID()

    /// Two windows: `first` on home with `homeChat` open, `second` on work with `workChat` open.
    func twoWindows(homeChat: [String] = ["s-home", "k-home"], workChat: [String] = ["s-work", "k-work"],
                    hiding hidden: UUID? = nil, isActive: Bool = true) -> VisibleChats {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        if let hidden { windows.setVisible(false, window: hidden) }
        let open = [home: homeChat, work: workChat]
        return VisibleChats(isActive: isActive, gateways: windows.visibleGateways) { open[$0] ?? [] }
    }

    func reply(_ chat: String, roomID: String? = nil) -> PushNotice {
        PushNotice(kind: .reply, id: "n-\(chat)", thread: chat, sessionID: chat, roomID: roomID)
    }

    @Test func twoGatewaysEachWithAChatOpenBothCount() {
        let visible = twoWindows()
        #expect(visible.isShowing(reply("s-home"), on: home))
        #expect(visible.isShowing(reply("s-work"), on: work))
        // A chat a notice names by its stable key counts too.
        #expect(visible.isShowing(reply("k-work"), on: work))
    }

    @Test func presenceNamesEachGatewaysOwnChat() {
        let visible = twoWindows()
        #expect(visible.ids(on: home).first == "s-home")
        #expect(visible.ids(on: work).first == "s-work")
        #expect(visible.ids(on: UUID()).isEmpty)
    }

    @Test func aChatOpenOnTheOtherGatewayDoesNotCount() {
        // Session ids can repeat across gateways: the notice's own gateway decides.
        let visible = twoWindows(homeChat: ["same"], workChat: ["other"])
        #expect(!visible.isShowing(reply("same"), on: work))
        #expect(!visible.isShowing(reply("s-elsewhere"), on: home))
    }

    @Test func aGroupChatCountsByItsRoom() {
        let visible = twoWindows(workChat: ["room-7"])
        let message = PushNotice(kind: .message, id: "m", thread: "room-7", roomID: "room-7")
        #expect(visible.isShowing(message, on: work))
        #expect(visible.gateway(showing: message, on: work) == work)
        #expect(!visible.isShowing(PushNotice(kind: .message, id: "m", roomID: "room-8"), on: work))
    }

    @Test func aHiddenWindowsChatDoesNotCount() {
        let visible = twoWindows(hiding: second)
        #expect(!visible.isShowing(reply("s-work"), on: work))
        #expect(visible.ids(on: work).isEmpty)
        #expect(visible.isShowing(reply("s-home"), on: home))
    }

    @Test func withTheAppInactiveNothingCounts() {
        let visible = twoWindows(isActive: false)
        #expect(visible == .none)
        #expect(!visible.isShowing(reply("s-home"), on: home))
        #expect(visible.ids(on: home).isEmpty)
    }

    @Test func aNoticeFromAnUnknownGatewayMatchesAnyChatOnScreen() {
        let visible = twoWindows()
        #expect(visible.gateway(showing: reply("s-work"), on: nil) == work)
        #expect(!visible.isShowing(reply("s-elsewhere"), on: nil))
    }

    @Test func aNoticeThatNamesNoChatIsNeverShowing() {
        let visible = twoWindows(homeChat: ["s-home"])
        #expect(!visible.isShowing(PushNotice(kind: .reply, id: "x"), on: home))
    }
}
