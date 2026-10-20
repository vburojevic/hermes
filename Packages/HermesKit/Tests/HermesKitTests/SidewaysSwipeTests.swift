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
        // To the right (the drawer's edge swipe): not a reply.
        #expect(!SidewaysSwipe.begins(velocity: CGPoint(x: 900, y: 120), translation: CGPoint(x: 12, y: 2), direction: .left))
        #expect(!SidewaysSwipe.begins(velocity: .zero, translation: CGPoint(x: 16, y: 4), direction: .left))
    }
}
