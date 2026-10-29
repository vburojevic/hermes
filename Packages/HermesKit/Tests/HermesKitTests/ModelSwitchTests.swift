import Foundation
import Testing
@testable import HermesKit

/// Hermes's model-switch lines as v0.22.5 sends them over `/api/ws` (`ModelSwitch`, #88).
private enum Line {
    static let restored = "✅ Primary model restored: claude-opus-5-5 via anthropic; fallback gpt-6-sol via openai-codex is no longer active."
    static let fallback = "⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (provider server error); using gpt-6-sol via openai-codex."
    static let fallbackNote = "Model fallback: claude-opus-5-5 via anthropic unavailable (provider server error); using gpt-6-sol via openai-codex."
    static let otherFallback = "⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (provider server error); using kimi-k3 via openrouter."
    static let otherFallbackNote = "Model fallback: claude-opus-5-5 via anthropic unavailable (provider server error); using kimi-k3 via openrouter."
}

@Suite("Model switches in a chat")
struct ModelSwitchChatTests {
    /// What one turn showed: its notes, and every status line its header had.
    struct Shown: Equatable {
        var notes: [String] = []
        var statuses: [String] = []
    }

    /// Runs a chat's turns through the decoder, one chat's `ModelSwitchNotes` and a `LiveTurn`
    /// each, as `ConversationModel` does for a Bot Chat.
    private func chat(_ turns: [[(String, String)]]) -> [Shown] {
        var notes = ModelSwitchNotes()
        var seq = 0
        return turns.map { events in
            var live = LiveTurn(id: "t", sessionID: "s")
            var shown = Shown()
            for (type, payload) in events {
                seq += 1
                let data = try! JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
                for item in notes.filter(GatewayTurnDecoder.decode(GatewayEvent(type: type, sessionID: "s", seq: seq, payload: data))) {
                    live.apply(item)
                    if let status = live.status, shown.statuses.last != status { shown.statuses.append(status) }
                }
            }
            shown.notes = live.snapshot.warning?.components(separatedBy: "\n\n") ?? []
            return shown
        }
    }

    private static func status(_ text: String) -> (String, String) {
        ("status.update", String(data: try! JSONEncoder().encode(JSONValue.object(["kind": .string("lifecycle"), "text": .string(text)])), encoding: .utf8)!)
    }

    private static let start = ("message.start", "{}")
    private static let words = ("message.delta", #"{"text":"Here you go."}"#)
    private static let done = ("message.complete", #"{"text":"Here you go.","status":"complete"}"#)
    private static let restored = status(Line.restored)
    private static let fallback = status(Line.fallback)

    @Test func aRestoreAloneShowsNothing() {
        #expect(chat([[Self.start, Self.restored, Self.words, Self.done]]) == [Shown()])
    }

    @Test func aFallbackShowsOnceAndItsRestoreNever() {
        #expect(chat([
            [Self.start, Self.words, Self.fallback, Self.done],
            [Self.start, Self.restored, Self.words, Self.done],
        ]) == [Shown(notes: [Line.fallbackNote]), Shown()])
    }

    @Test func repeatedRestoresShowNothing() {
        let turn = [Self.start, Self.restored, Self.words, Self.done]
        #expect(chat([turn, turn, turn]) == [Shown(), Shown(), Shown()])
    }

    /// The report in #88: a primary that keeps failing is restored and falls back on every turn.
    @Test func theSameFallbackOnThreeTurnsShowsOnce() {
        let again = [Self.start, Self.restored, Self.words, Self.fallback, Self.done]
        // A rate-limit cooldown adds a countdown: the same switch, however long it says.
        let counting = [Self.start, Self.restored, Self.words,
                        Self.status(Line.fallback + " Primary retry eligible in ~58 s; recovery is not guaranteed."), Self.done]
        #expect(chat([[Self.start, Self.words, Self.fallback, Self.done], again, counting])
            == [Shown(notes: [Line.fallbackNote]), Shown(), Shown()])
    }

    @Test func aTurnThatEndsOnThePrimaryLetsTheNextFallbackShow() {
        #expect(chat([
            [Self.start, Self.words, Self.fallback, Self.done],
            [Self.start, Self.restored, Self.words, Self.done],
            [Self.start, Self.words, Self.fallback, Self.done],
        ]) == [Shown(notes: [Line.fallbackNote]), Shown(), Shown(notes: [Line.fallbackNote])])
    }

    @Test func aDifferentFallbackShowsANewNote() {
        #expect(chat([
            [Self.start, Self.words, Self.fallback, Self.done],
            [Self.start, Self.restored, Self.words, Self.status(Line.otherFallback), Self.done],
            [Self.start, Self.restored, Self.words, Self.status(Line.otherFallback), Self.done],
        ]) == [Shown(notes: [Line.fallbackNote]), Shown(notes: [Line.otherFallbackNote]), Shown()])
    }

    /// A turn that fails on the fallback too: Hermes flushes what it tried, the switch in both forms.
    @Test func bothFormsOfOneSwitchShowOneNote() {
        let failed = ("message.complete", #"{"text":"","status":"error","error":"The model provider returned 529: overloaded."}"#)
        #expect(chat([[Self.start, Self.restored, Self.fallback, Self.status("↻ Switched to fallback: gpt-6-sol (openai-codex)"), failed]])
            == [Shown(notes: [Line.fallbackNote])])
    }

    /// A turn that fails doesn't end on the primary: the same switch after it stays quiet.
    @Test func aFailedTurnDoesNotResetTheSwitch() {
        let failed = ("message.complete", #"{"text":"","status":"error","error":"The model provider returned 529: overloaded."}"#)
        #expect(chat([
            [Self.start, Self.words, Self.fallback, Self.done],
            [Self.start, Self.restored, failed],
            [Self.start, Self.words, Self.fallback, Self.done],
        ]).map(\.notes) == [[Line.fallbackNote], [], []])
    }
}

@Suite("Model switch lines")
struct ModelSwitchLineTests {
    private let opus = ModelSwitch.Model(name: "claude-opus-5-5", provider: "anthropic")
    private let sol = ModelSwitch.Model(name: "gpt-6-sol", provider: "openai-codex")

    @Test func readsHermesWords() {
        #expect(ModelSwitch(line: Line.fallback) == .fallback(.init(primary: opus, fallback: sol, reason: "provider server error")))
        #expect(ModelSwitch(line: Line.restored) == .restored(primary: opus, fallback: sol))
        #expect(ModelSwitch(line: "↻ Switched to fallback: gpt-6-sol (openai-codex)") == .fallback(.init(primary: nil, fallback: sol, reason: nil)))
        // Dotted model names, and the countdown a rate limit adds, which the note leaves out.
        let dotted = ModelSwitch(line: "⚠ Model fallback: gpt-5.1 via openai unavailable (rate limit); using claude-sonnet-4.6 via openrouter. Primary retry eligible in ~42 s; recovery is not guaranteed.")
        let route = ModelSwitch.Route(primary: .init(name: "gpt-5.1", provider: "openai"),
                                      fallback: .init(name: "claude-sonnet-4.6", provider: "openrouter"), reason: "rate limit")
        #expect(dotted == .fallback(route))
        #expect(route.note == "Model fallback: gpt-5.1 via openai unavailable (rate limit); using claude-sonnet-4.6 via openrouter.")
        #expect(ModelSwitch.Route(primary: nil, fallback: sol, reason: nil).note == "Switched to fallback: gpt-6-sol (openai-codex)")
        // Other lines Hermes sends about fallbacks stay what they were.
        #expect(ModelSwitch(line: "⚠️ Max retries (3) exhausted — trying fallback...") == nil)
        #expect(ModelSwitch(line: "⚠️ Model returning empty responses — switching to fallback provider...") == nil)
    }

    @Test func decodesThemAsSwitches() {
        func decode(_ text: String) -> [TurnEvent] {
            GatewayTurnDecoder.decode(GatewayEvent(type: "status.update", sessionID: "s", seq: 1,
                                                   payload: .object(["kind": .string("lifecycle"), "text": .string(text)]))).map(\.event)
        }
        #expect(decode(Line.restored) == [.modelSwitch(.restored(primary: opus, fallback: sol))])
        #expect(decode(Line.fallback) == [.modelSwitch(.fallback(.init(primary: opus, fallback: sol, reason: "provider server error")))])
        #expect(decode("⚠️ Max retries (3) exhausted — trying fallback...") == [.warning("Max retries (3) exhausted — trying fallback...")])
    }
}
