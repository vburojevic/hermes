import Foundation
import Testing
@testable import HermesKit

@Suite("A sideways swipe on a row")
struct SidewaysSwipeTests {
    @Test func verticalDragsStayTheScrollViews() {
        // A flick up or down, fast or slow, and one that slants but mostly goes down.
        let drags: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: -1800), CGPoint(x: 0, y: -14)),
            (CGPoint(x: 40, y: 300), CGPoint(x: 3, y: 12)),
            (CGPoint(x: -500, y: 900), CGPoint(x: -8, y: 12)),
        ]
        for (velocity, translation) in drags {
            #expect(!SidewaysSwipe.begins(velocity: velocity, translation: translation, direction: .either))
            #expect(!SidewaysSwipe.begins(velocity: velocity, translation: translation, direction: .left))
        }
    }

    @Test func sidewaysDragsBeginEitherWay() {
        #expect(SidewaysSwipe.begins(velocity: CGPoint(x: 900, y: 120), translation: CGPoint(x: 12, y: 2), direction: .either))
        #expect(SidewaysSwipe.begins(velocity: CGPoint(x: -900, y: 120), translation: CGPoint(x: -12, y: 2), direction: .either))
        // Slow: the distance decides.
        #expect(SidewaysSwipe.begins(velocity: .zero, translation: CGPoint(x: -16, y: 4), direction: .either))
    }

    @Test func replyBeginsOnlyToTheLeft() {
        #expect(SidewaysSwipe.begins(velocity: CGPoint(x: -900, y: 120), translation: CGPoint(x: -12, y: 2), direction: .left))
        #expect(SidewaysSwipe.begins(velocity: .zero, translation: CGPoint(x: -16, y: 4), direction: .left))
        // To the right (the back swipe): not a reply.
        #expect(!SidewaysSwipe.begins(velocity: CGPoint(x: 900, y: 120), translation: CGPoint(x: 12, y: 2), direction: .left))
        #expect(!SidewaysSwipe.begins(velocity: .zero, translation: CGPoint(x: 16, y: 4), direction: .left))
    }

    @Test func aRowCountsTheMoveThatBeganItsSwipe() {
        // A 120-point swipe on an iPad lane row whose first touch sample is 60 points along: the
        // pan begins there and its translation starts again, so it saw only the other 60.
        let swipe = RowSwipe(count: 2, rowWidth: 640)
        let touchDown = CGPoint(x: 700, y: 481)
        let travel = SidewaysSwipe.travel(from: touchDown, to: CGPoint(x: 580, y: 481))
        #expect(travel == -120)
        #expect(swipe.release(offset: swipe.offset(translation: travel, from: 0)) == .open)
        #expect(swipe.release(offset: swipe.offset(translation: -60, from: 0)) == .close)
        // Up or down on the way doesn't count.
        #expect(SidewaysSwipe.travel(from: touchDown, to: CGPoint(x: 690, y: 470)) == -10)
    }
}

/// Measured on the chat list's own swipe on iOS 27 (a 402-point iPhone row, Mute and Archive).
@Suite("A row's swipe actions outside a list")
struct RowSwipeTests {
    let swipe = RowSwipe(count: 2, rowWidth: 402)

    @Test func twoButtonsOpenAHundredAndFiftyPoints() {
        #expect(swipe.openWidth == 150)
        #expect(RowSwipe(count: 1, rowWidth: 402).openWidth == 80)
        #expect(RowSwipe(count: 0, rowWidth: 402).openWidth == 0)
    }

    @Test func theRowFollowsTheFingerUpToTheFullSwipeMark() {
        #expect(swipe.fullSwipeDistance > 209 && swipe.fullSwipeDistance < 211)
        #expect(swipe.offset(translation: -120, from: 0) == -120)
        #expect(swipe.offset(translation: -40, from: -150) == -190)
        // Never right of shut.
        #expect(swipe.offset(translation: 60, from: 0) == 0)
        #expect(swipe.offset(translation: 400, from: -150) == 0)
        // Past the mark it resists.
        let past = swipe.offset(translation: -310, from: 0)
        #expect(-past > swipe.fullSwipeDistance && -past < swipe.fullSwipeDistance + 20)
    }

    @Test func aNarrowRowNeedsTheFirstButtonToWidenFirst() {
        let narrow = RowSwipe(count: 2, rowWidth: 300)
        #expect(narrow.fullSwipeDistance == 210)
        let wide = RowSwipe(count: 2, rowWidth: 1000)
        #expect(wide.fullSwipeDistance == 520)
    }

    @Test func aLetGoDecidesByWhereTheRowIs() {
        #expect(swipe.release(offset: -72) == .close)
        #expect(swipe.release(offset: -75) == .open)
        #expect(swipe.release(offset: -180) == .open)
        #expect(swipe.release(offset: -215) == .full)
        #expect(swipe.release(offset: 0) == .close)
        #expect(RowSwipe(count: 0, rowWidth: 402).release(offset: -300) == .close)
    }

    @Test func buttonsPopInAsTheRowUncoversThem() {
        #expect(!swipe.shows(0, at: -59))
        #expect(swipe.shows(0, at: -60))
        #expect(!swipe.shows(1, at: -129))
        #expect(swipe.shows(1, at: -130))
        // Past the full-swipe mark only the first shows.
        #expect(swipe.shows(0, at: -215))
        #expect(!swipe.shows(1, at: -215))
        #expect(!swipe.shows(2, at: -150))
    }

    @Test func buttonsWaitInTheirPlacesThenTheFirstWidens() {
        #expect(swipe.slot(0, at: -100) == RowSwipe.Slot(inset: 10, width: 60))
        #expect(swipe.slot(1, at: -100) == RowSwipe.Slot(inset: 80, width: 60))
        #expect(swipe.slot(0, at: -150) == RowSwipe.Slot(inset: 10, width: 60))
        #expect(swipe.slot(0, at: -180) == RowSwipe.Slot(inset: 10, width: 90))
        #expect(swipe.slot(1, at: -180) == RowSwipe.Slot(inset: 110, width: 60))
        // Full: the first fills the space, 10 points in from each side.
        #expect(swipe.slot(0, at: -220) == RowSwipe.Slot(inset: 10, width: 200))
    }

    @Test func theOthersFadePastTheOpenButtons() {
        #expect(swipe.opacity(1, at: -150) == 1)
        #expect(swipe.opacity(0, at: -200) == 1)
        let justPast = swipe.opacity(1, at: -162)
        #expect(justPast > 0.45 && justPast < 0.5)
        let nearFull = swipe.opacity(1, at: -209)
        #expect(nearFull > 0.29 && nearFull < 0.32)
    }
}

