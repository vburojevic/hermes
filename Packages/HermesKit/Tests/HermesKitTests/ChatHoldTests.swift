import Foundation
import Testing
@testable import HermesKit

@Suite("A chat another Hermes process holds")
struct ChatHoldTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    /// Word for word what Hermes refused Cofounder's Bot Chat with on 2026-10-21, while that Bot
    /// answered Engineer in its one-shot `hermes chat`.
    static let refusal = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
        + "Details: session 20261015_134058_36b40b opened by cli 0m ago."

    private func decode(_ type: String, _ payload: String) -> [TurnEvent] {
        GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: 1, payload: JSONValue.parse(payload)!)).map(\.event)
    }

    @Test func readsHermesSentence() throws {
        let hold = try #require(ChatHold(refusal: Self.refusal))
        #expect(hold.sentence == "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.")
        #expect(hold.sessionID == "20261015_134058_36b40b")
        #expect(hold.surface == "cli")
        #expect(hold.age == 0)
        // `format_age` past an hour, and a hold with no start time (no age at all).
        let base = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session s1 opened by "
        #expect(ChatHold(refusal: base + "desktop 45m ago.")?.age == 2700)
        #expect(ChatHold(refusal: base + "cli 2h ago.")?.age == 7200)
        #expect(ChatHold(refusal: base + "tui 1h5m ago.")?.age == 3900)
        let ageless = try #require(ChatHold(refusal: base + "another surface."))
        #expect(ageless.surface == "another surface" && ageless.age == nil)
        // Its first line alone still reads as a hold; anything else isn't one.
        #expect(ChatHold(refusal: "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.")?.surface == nil)
        #expect(ChatHold(refusal: "Hermes is running as many chats at once as it's set to allow.") == nil)
        #expect(ChatHold(refusal: "") == nil)
    }

    /// Refused once taken, Hermes sends a bare `error` event with the sentence: a hold, not a
    /// failed turn (that was the card that told Vedran to use another window).
    @Test func aRefusedTurnIsAHoldNotAFailure() throws {
        let payload = String(data: try JSONSerialization.data(withJSONObject: ["message": Self.refusal]), encoding: .utf8)!
        #expect(decode("error", payload) == [.held(ChatHold(refusal: Self.refusal)!)])
        #expect(decode("error", #"{"message": "Rate limited"}"#) == [.failed("Rate limited")])
        // A turn that gets that far anyway ends with Hermes's words.
        var live = LiveTurn(id: "t", sessionID: "s", startedAt: now)
        live.apply(SequencedTurnEvent(seq: 1, event: .held(ChatHold(refusal: Self.refusal)!)))
        #expect(live.turn.state == .failed(ChatHold(refusal: Self.refusal)!.sentence))
    }

    @Test func saysWhatHoldsTheChat() throws {
        let cli = try #require(ChatHold(refusal: Self.refusal))
        #expect(cli.holder(of: ElsewhereTurn(answering: "Engineer"), inBotChat: true) == .answeringBot("Engineer"))
        #expect(cli.holder(of: ElsewhereTurn(routine: "control-room-issue-alerts"), inBotChat: true) == .routine("control-room-issue-alerts"))
        #expect(cli.holder(of: ElsewhereTurn(runningTool: "terminal"), inBotChat: true) == .working)
        // Nothing stored yet: a Bot Chat's `hermes chat` that only just took it is a Bot's turn starting.
        #expect(cli.holder(of: nil, inBotChat: true) == .working)
        #expect(cli.holder(of: nil, inBotChat: true).isHermesWork)
        // Held for long with nothing running, another window, or a normal chat: Hermes's own words.
        var old = cli
        old.age = 45 * 60
        #expect(old.holder(of: nil, inBotChat: true) == .elsewhere(cli.sentence))
        var window = cli
        window.surface = "desktop"
        #expect(window.holder(of: nil, inBotChat: true) == .elsewhere(cli.sentence))
        #expect(cli.holder(of: nil, inBotChat: false) == .elsewhere(cli.sentence))
        #expect(!cli.holder(of: nil, inBotChat: false).isHermesWork)
    }

    /// The real 11:54 one: a routine's output stored without a display kind, its follow-up running
    /// in a one-shot `hermes chat`, and the Bot's reply two minutes later.
    @Test func aRoutinesFollowUpRunsElsewhere() {
        let delivery = SessionMessage(id: 7205, role: "user", content: .text(#"[Cronjob "[bot:cofounder] control-room-issue-alerts" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]"# + "\n\n**Control room — issue change**"),
                                      timestamp: now.addingTimeInterval(-60))
        let reply = SessionMessage(id: 7206, role: "assistant", content: .text("This is the new Hermes TestFlight feedback."), timestamp: now)
        #expect(TranscriptBuilder.awaitsReply([delivery], now: now))
        #expect(ElsewhereTurn.of([delivery], now: now) == ElsewhereTurn(routine: "control-room-issue-alerts"))
        #expect(ElsewhereTurn.of([delivery, reply], now: now) == nil)
        // Its first step stored: still the routine's, with the call it runs.
        let step = SessionMessage(id: 7207, role: "assistant", content: .text(""),
                                  toolCalls: [ToolCall(id: "c9", name: "terminal", arguments: "{}")], timestamp: now.addingTimeInterval(-30))
        #expect(ElsewhereTurn.of([delivery, step], now: now) == ElsewhereTurn(routine: "control-room-issue-alerts", runningTool: "terminal"))
        var items = TranscriptBuilder.build([delivery])
        #expect(TranscriptBuilder.markMidTurn(&items, messages: [delivery], now: now))
        // One delivered as a dashboard turn (`internal_notification`) runs where the app hears it.
        var notice = delivery
        notice.displayKind = "internal_notification"
        #expect(!TranscriptBuilder.awaitsReply([notice], now: now))
    }
}
