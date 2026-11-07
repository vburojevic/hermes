import Testing
@testable import HermesKit

/// A chat follows the model picked for it on another device (#104, `docs/sessions-and-models.md` §4).
@Suite("A chat's model follows other devices")
struct ChatModelFollowTests {
    private let sonnet = ModelSelection(provider: "openrouter", model: "anthropic/claude-sonnet-4.6")
    private let opus = ModelSelection(provider: "anthropic", model: "claude-opus-5-5")
    private let gpt = ModelSelection(provider: "openai-codex", model: "gpt-6-sol")
    private let options = ModelOptions(providers: [
        ModelProvider(slug: "openrouter", name: "OpenRouter", isCurrent: true, models: ["anthropic/claude-sonnet-4.6", "claude-opus-5-5"]),
        ModelProvider(slug: "anthropic", name: "Anthropic", isCurrent: false, models: ["claude-opus-5-5"]),
        ModelProvider(slug: "openai-codex", name: "OpenAI Codex", isCurrent: false, models: ["gpt-6-sol"]),
    ], model: "anthropic/claude-sonnet-4.6", provider: "openrouter")

    private func report(_ selection: ModelSelection) -> ChatModelFollow.Report {
        .init(model: selection.model, provider: selection.provider)
    }

    @Test("Another device changed the model: the chat takes it")
    func anotherDevice() {
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        #expect(follow.reported(report(sonnet), current: sonnet, options: options) == nil)
        #expect(follow.reported(report(opus), current: sonnet, options: options) == opus)
    }

    @Test("A chat opened on a device whose last pick differs takes the session's model")
    func opened() {
        var follow = ChatModelFollow()
        #expect(follow.reported(report(opus), current: sonnet, options: options) == opus)
    }

    @Test("This device changed it: Hermes reporting that pick changes nothing")
    func thisDevice() {
        var follow = ChatModelFollow()
        #expect(follow.reported(report(sonnet), current: sonnet, options: options) == nil)
        follow.picked()
        follow.sent(opus)
        #expect(follow.reported(report(opus), current: opus, options: options) == nil)
    }

    @Test("Both changed it: the pick made here wins for this device's next turn")
    func both() {
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        follow.picked()
        #expect(follow.reported(report(opus), current: gpt, options: options) == nil)
        follow.sent(gpt)
        // The other device's pick, reported again, isn't news any more.
        #expect(follow.reported(report(opus), current: gpt, options: options) == nil)
        // A later change there is.
        #expect(follow.reported(report(sonnet), current: gpt, options: options) == sonnet)
    }

    @Test("Hermes reports nothing: the chat keeps its model")
    func nothing() {
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        #expect(follow.reported(.init(model: ""), current: sonnet, options: options) == nil)
        #expect(follow.reported(.init(model: "  ", provider: "  "), current: sonnet, options: options) == nil)
        #expect(follow.reported(.init(model: "hermes-agent"), current: sonnet, options: options) == nil)
    }

    @Test("A fallback turn isn't mistaken for a switch")
    func fallback() {
        var follow = ChatModelFollow()
        follow.sent(opus)
        follow.fellBack(to: ModelSwitch.Model(name: "gpt-6-sol", provider: "openai-codex"))
        #expect(follow.reported(report(gpt), current: opus, options: options) == nil)
        // The next turn restores the primary.
        #expect(follow.reported(report(opus), current: opus, options: options) == nil)
    }

    @Test("A report while a turn runs is ignored: it may name a fallback mid-switch")
    func running() {
        var follow = ChatModelFollow()
        follow.sent(opus)
        #expect(follow.reported(report(gpt), current: opus, options: options, turnRunning: true) == nil)
        #expect(follow.reported(report(gpt), current: opus, options: options) == gpt)
    }

    @Test("A row that stays on the session's first model isn't news after this device sends others")
    func staleRow() {
        var follow = ChatModelFollow()
        let row = ChatModelFollow.Report(model: "anthropic/claude-sonnet-4.6", source: .row)
        #expect(follow.reported(row, current: sonnet, options: options) == nil)
        follow.picked()
        follow.sent(opus)
        #expect(follow.reported(report(opus), current: opus, options: options) == nil)
        #expect(follow.reported(row, current: opus, options: options) == nil)
        // The row moving is news.
        #expect(follow.reported(.init(model: "gpt-6-sol", source: .row), current: opus, options: options) == gpt)
    }

    @Test("A row's first model is only where it stands: a launch doesn't take a stale one")
    func rowBaseline() {
        var follow = ChatModelFollow()
        #expect(follow.reported(.init(model: "gpt-6-sol", source: .row), current: sonnet, options: options) == nil)
        // The socket's info is the live agent's model, and counts at once.
        #expect(follow.reported(report(opus), current: sonnet, options: options) == opus)
    }

    @Test("Before the gateway's models are known a moved row can't be read: it counts once they are")
    func optionsLater() {
        var follow = ChatModelFollow()
        #expect(follow.reported(.init(model: "anthropic/claude-sonnet-4.6", source: .row), current: nil, options: nil) == nil)
        let moved = ChatModelFollow.Report(model: "gpt-6-sol", source: .row)
        #expect(follow.reported(moved, current: sonnet, options: nil) == nil)
        #expect(follow.reported(moved, current: sonnet, options: options) == gpt)
    }

    @Test("A row names no provider: the chat's own provider when it lists the model, else the first")
    func rowProvider() {
        let first = ChatModelFollow.Report(model: "anthropic/claude-sonnet-4.6", source: .row)
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        _ = follow.reported(first, current: sonnet, options: options)
        #expect(follow.reported(.init(model: "claude-opus-5-5", source: .row), current: sonnet, options: options)
            == ModelSelection(provider: "openrouter", model: "claude-opus-5-5"))

        var other = ChatModelFollow()
        other.sent(sonnet)
        _ = other.reported(first, current: sonnet, options: options)
        #expect(other.reported(.init(model: "gpt-6-sol", source: .row), current: sonnet, options: options) == gpt)

        var unknown = ChatModelFollow()
        unknown.sent(sonnet)
        _ = unknown.reported(first, current: sonnet, options: options)
        #expect(unknown.reported(.init(model: "mystery-1", source: .row), current: sonnet, options: options) == nil)
    }

    @Test("The gateway's default model is the same as no pick")
    func gatewayDefault() {
        var follow = ChatModelFollow()
        follow.sent(nil)
        #expect(follow.reported(report(sonnet), current: nil, options: options) == nil)
        #expect(follow.reported(report(opus), current: nil, options: options) == opus)
    }

    @Test("Another device switching back to this device's earlier pick is followed too")
    func switchedBack() {
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        #expect(follow.reported(report(opus), current: sonnet, options: options) == opus)
        #expect(follow.reported(report(sonnet), current: opus, options: options) == sonnet)
    }

    @Test("Picking the gateway's default and sending lets the chat follow other devices again")
    func defaultPicked() {
        var follow = ChatModelFollow()
        follow.sent(sonnet)
        follow.picked()
        follow.sent(nil)
        #expect(follow.reported(report(opus), current: nil, options: options) == opus)
    }
}
