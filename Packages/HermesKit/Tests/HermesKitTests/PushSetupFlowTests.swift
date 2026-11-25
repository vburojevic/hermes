import HermesPush
import Testing

/// The Set Up Push sheet offers the plugin's install only after a check said the plugin is missing
/// (`docs/setup.md` §4.13).
@Suite("Push setup sheet")
struct PushSetupFlowTests {
    /// Feeds the checks in order, as the sheet sees them, and collects the page after each.
    private func pages(_ checks: [PushSetupFlow.Check], hasRoster: Bool = true) -> [PushSetupFlow.Page] {
        var flow = PushSetupFlow()
        return checks.map { check in
            flow.saw(check)
            return flow.page(check, hasRoster: hasRoster, isDone: false)
        }
    }

    @Test func aGatewayWithoutThePluginOpensOnTheReview() {
        #expect(pages([.missing]) == [.review])
    }

    @Test func aStoppedGatewayWaitsForItsCheck() {
        #expect(pages([.other]) == [.waiting])
    }

    @Test func aStoppedGatewayWithThePluginNeverShowsTheReview() {
        // Stopped, then checking, then on.
        #expect(pages([.other, .other, .other]) == [.waiting, .waiting, .waiting])
        var flow = PushSetupFlow()
        flow.saw(.other)
        #expect(flow.page(.other, hasRoster: true, isDone: true) == .done)
    }

    @Test func theReviewStaysThroughALaterCheck() {
        #expect(pages([.missing, .other, .other]) == [.review, .review, .review])
        #expect(pages([.other, .missing, .other]) == [.waiting, .review, .review])
    }

    @Test func aCheckThatEndsWithoutPushClosesTheSheet() {
        // Stopped, then offline, not registered or failed: the row says why, with Check Again.
        #expect(pages([.other, .ended]) == [.waiting, .close])
        #expect(pages([.other, .other, .ended]) == [.waiting, .waiting, .close])
    }

    @Test func theStateItOpensWithDoesntCloseIt() {
        // Opened on a gateway already offline, it waits for its own check.
        #expect(pages([.ended]) == [.waiting])
        #expect(pages([.ended, .other, .ended]) == [.waiting, .waiting, .close])
    }

    @Test func theReviewStaysWhenALaterCheckFails() {
        // The install restarts the gateway: offline for a moment is no reason to close.
        #expect(pages([.missing, .ended, .other]) == [.review, .review, .review])
    }

    @Test func withoutBotModeItShowsTheCommands() {
        #expect(pages([.needsBotMode]) == [.needsBotMode])
        #expect(pages([.missing], hasRoster: false) == [.needsBotMode])
        #expect(pages([.other], hasRoster: false) == [.needsBotMode])
    }
}
