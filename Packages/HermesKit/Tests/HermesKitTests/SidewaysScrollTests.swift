import Foundation
import Testing
@testable import HermesKit

@Suite("A sideways scroll on a message on the Mac")
struct SidewaysScrollTests {
    @Test func trackpadSwipeLeftFollowsThenReleases() {
        var scroll = SidewaysScroll()
        // The first events are too small to decide.
        #expect(scroll.scroll(.began, delta: CGPoint(x: -1, y: 0)) == .pass)
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -2, y: 0.5)) == .pass)
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -6, y: 0)) == .follow(-9))
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -60, y: 2)) == .follow(-69))
        #expect(scroll.scroll(.ended, delta: .zero) == .release(-69))
        #expect(scroll.isIdle)
        // Its glide is the message's too, until the next scroll begins.
        #expect(scroll.scroll(.momentum, delta: CGPoint(x: -30, y: 2)) == .absorb)
        #expect(scroll.scroll(.began, delta: CGPoint(x: 0, y: -6)) == .pass)
        #expect(scroll.scroll(.ended, delta: .zero) == .pass)
        #expect(scroll.scroll(.momentum, delta: CGPoint(x: 0, y: -30)) == .pass)
    }

    @Test func glideAfterAScrollElsewhereStaysTheChats() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.began, delta: CGPoint(x: -20, y: 0)) == .follow(-20))
        #expect(scroll.scroll(.ended, delta: .zero) == .release(-20))
        // The next flick starts over another row: its glide moves the chat.
        scroll.beganElsewhere()
        #expect(scroll.scroll(.momentum, delta: CGPoint(x: 0, y: -40)) == .pass)
    }

    @Test func verticalScrollStaysTheChats() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.began, delta: CGPoint(x: 0, y: -3)) == .pass)
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -1, y: -8)) == .pass)
        // Once it's the chat's, a turn sideways stays the chat's.
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -80, y: 0)) == .pass)
        #expect(scroll.scroll(.ended, delta: .zero) == .pass)
        #expect(scroll.isIdle)
        // The chat's glide stays the chat's.
        #expect(scroll.scroll(.momentum, delta: CGPoint(x: 0, y: -40)) == .pass)
    }

    @Test func scrollToTheRightIsntAReply() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.began, delta: CGPoint(x: 12, y: 0)) == .pass)
        #expect(scroll.scroll(.changed, delta: CGPoint(x: 40, y: 0)) == .pass)
        #expect(scroll.scroll(.ended, delta: .zero) == .pass)
    }

    @Test func cancelledSwipeReleasesWithoutReplying() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.began, delta: CGPoint(x: -20, y: 0)) == .follow(-20))
        #expect(scroll.scroll(.cancelled, delta: .zero) == .release(0))
    }

    @Test func scrollThatBeganElsewhereIsIgnored() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.changed, delta: CGPoint(x: -40, y: 0)) == .pass)
        #expect(scroll.scroll(.ended, delta: .zero) == .pass)
    }

    @Test func wheelStepsSidewaysEndWhenTheyStop() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.step, delta: CGPoint(x: -30, y: 0)) == .follow(-30))
        #expect(!scroll.isIdle)
        #expect(scroll.scroll(.step, delta: CGPoint(x: -40, y: 0)) == .follow(-70))
        #expect(scroll.idle() == .release(-70))
        #expect(scroll.isIdle)
    }

    @Test func verticalWheelStepsStayTheChats() {
        var scroll = SidewaysScroll()
        #expect(scroll.scroll(.step, delta: CGPoint(x: 0, y: -30)) == .pass)
        #expect(scroll.scroll(.step, delta: CGPoint(x: -30, y: 0)) == .pass)
        #expect(scroll.idle() == .pass)
        #expect(scroll.isIdle)
    }
}
