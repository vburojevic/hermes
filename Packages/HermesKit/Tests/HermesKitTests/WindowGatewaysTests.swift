import Foundation
import Testing
@testable import HermesKit

/// Each window keeps its own gateway; every gateway a visible window shows stays connected; the
/// last-used one follows the latest switch or activation (`docs/connecting-and-voice.md` §8).
@Suite("Window gateways")
struct WindowGatewaysTests {
    let home = UUID()
    let work = UUID()
    let first = UUID()
    let second = UUID()

    @Test func twoWindowsOnTwoGatewaysKeepBoth() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: nil)
        windows.show(work, in: second)
        #expect(windows.gateway(in: first) == home)
        #expect(windows.gateway(in: second) == work)
        #expect(windows.keptConnected == [home, work])
    }

    @Test func switchingOneWindowLeavesTheOther() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: home)
        windows.show(work, in: second)
        #expect(windows.gateway(in: first) == home)
        #expect(windows.gateway(in: second) == work)
    }

    @Test func switchingMovesTheWindowsClaim() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.show(work, in: first)
        #expect(windows.keptConnected == [work])
    }

    @Test func closingAWindowStopsItsGatewayUnlessAnotherShowsIt() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        windows.close(second)
        #expect(windows.keptConnected == [home])
        #expect(!windows.isOpen(second))
        #expect(windows.gateway(in: second) == nil)

        windows.open(second, showing: home)
        windows.close(second)
        #expect(windows.keptConnected == [home])
    }

    @Test func aHiddenWindowsGatewayStopsUntilItShowsAgain() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        windows.setVisible(false, window: second)
        #expect(windows.keptConnected == [home])
        windows.setVisible(true, window: second)
        #expect(windows.keptConnected == [home, work])
    }

    @Test func theLastUsedGatewayKeepsConnectedWithEveryWindowMinimized() {
        // The menu bar extra and Talk show the last-used gateway with no window in sight.
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.setVisible(false, window: first)
        #expect(windows.keptConnected == [home])

        windows.open(second, showing: work)
        windows.activate(second)
        windows.setVisible(false, window: second)
        #expect(windows.keptConnected == [work])
    }

    @Test func withNoWindowTheLastUsedGatewayKeepsConnected() {
        let windows = WindowGateways(lastUsed: home)
        #expect(windows.keptConnected == [home])
        #expect(WindowGateways().keptConnected.isEmpty)
    }

    @Test func aNewWindowShowsTheLastUsedGateway() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.show(work, in: first)
        windows.open(second, showing: nil)
        #expect(windows.gateway(in: second) == work)
    }

    @Test func lastUsedFollowsTheLatestSwitchOrActivation() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        #expect(windows.lastUsed == home) // opening isn't using
        windows.activate(second)
        #expect(windows.lastUsed == work)
        windows.activate(first)
        #expect(windows.lastUsed == home)
        windows.show(work, in: first)
        #expect(windows.lastUsed == work)
        // A window that isn't open changes nothing.
        windows.activate(UUID())
        #expect(windows.lastUsed == work)
    }

    @Test func anAppWideSwitchChangesTheMostRecentlyActiveWindow() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: home)
        windows.activate(second)
        windows.activate(first)
        #expect(windows.mostRecentWindow == first)
        windows.show(work)
        #expect(windows.gateway(in: first) == work)
        #expect(windows.gateway(in: second) == home)
        #expect(windows.lastUsed == work)
    }

    @Test func anAppWideSwitchWithNoWindowSetsTheLastUsedGateway() {
        var windows = WindowGateways(lastUsed: home)
        windows.show(work)
        #expect(windows.lastUsed == work)
        #expect(windows.keptConnected == [work])
    }

    @Test func anAppWideSwitchBeforeAnyWindowOpensShowsInTheFirstOne() {
        // A notification tapped at launch, before the restored windows open.
        var windows = WindowGateways(lastUsed: home)
        windows.show(work)
        windows.open(first, showing: home)
        windows.open(second, showing: home)
        #expect(windows.gateway(in: first) == work)
        #expect(windows.gateway(in: second) == home)
    }

    @Test func closingTheActiveWindowMakesTheNextOneMostRecent() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        windows.activate(first)
        windows.activate(second)
        windows.close(second)
        #expect(windows.mostRecentWindow == first)
    }

    @Test func aRemovedGatewayFallsBack() {
        var windows = WindowGateways(lastUsed: work)
        windows.open(first, showing: home)
        windows.open(second, showing: work)
        windows.remove(gateway: work, fallback: home)
        #expect(windows.gateway(in: second) == home)
        #expect(windows.gateway(in: first) == home)
        #expect(windows.lastUsed == home)
        #expect(windows.keptConnected == [home])

        windows.remove(gateway: home, fallback: nil)
        #expect(windows.gateway(in: first) == nil)
        #expect(windows.lastUsed == nil)
        #expect(windows.keptConnected.isEmpty)
    }

    @Test func aGatewayRestoredAfterTheWindowOpenedReplacesTheLastUsed() {
        // On the Mac, a window's saved state arrives after it appears on the last-used gateway.
        var windows = WindowGateways(lastUsed: work)
        windows.open(first, showing: work)
        windows.open(second, showing: work)
        windows.activate(first)
        windows.restore(home, in: first)
        windows.restore(work, in: second)
        #expect(windows.gateway(in: first) == home)
        #expect(windows.gateway(in: second) == work)
        #expect(windows.lastUsed == home) // the window in front
        #expect(windows.keptConnected == [home, work])
    }

    @Test func aLateRestoreLeavesAWindowThatWasSwitched() {
        var windows = WindowGateways(lastUsed: home)
        windows.open(first, showing: home)
        windows.show(work, in: first)
        windows.restore(home, in: first)
        #expect(windows.gateway(in: first) == work)

        // A notification tapped at launch picked the first window's gateway.
        var launching = WindowGateways(lastUsed: home)
        launching.show(work)
        launching.open(second, showing: home)
        launching.restore(home, in: second)
        #expect(launching.gateway(in: second) == work)
    }

    @Test func aWindowRestoresItsGatewayOrFallsBackToTheLastUsed() {
        let gateways = [home, work]
        #expect(WindowGateways.restored(work, among: gateways, lastUsed: home) == work)
        // Removed since the window last showed it.
        #expect(WindowGateways.restored(UUID(), among: gateways, lastUsed: home) == home)
        #expect(WindowGateways.restored(nil, among: gateways, lastUsed: home) == home)
        #expect(WindowGateways.restored(nil, among: [UUID](), lastUsed: nil) == nil)
    }
}
