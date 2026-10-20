import Foundation
import Testing
@testable import HermesKit

@Suite("The room a composer menu has")
struct ComposerMenuRoomTests {
    @Test func plentyOfRoomKeepsTheMenusOwnCap() {
        // A tall window: the composer near the bottom, far below the bar.
        #expect(ComposerMenuRoom.height(ceiling: 100, panelTop: 900, spacing: 8) == ComposerMenuRoom.cap)
    }

    @Test func theKeyboardUpStopsItUnderTheTopBar() {
        // iPhone with the keyboard up: the bar ends at 116, the composer's top is at 420.
        let height = ComposerMenuRoom.height(ceiling: 116, panelTop: 420, spacing: 8)
        #expect(height == 420 - 8 - ComposerMenuRoom.margin - 116)
        #expect(116 + height + ComposerMenuRoom.margin + 8 <= 420)
    }

    @Test func unmeasuredFallsBackToTheCap() {
        #expect(ComposerMenuRoom.height(ceiling: nil, panelTop: 420, spacing: 8) == ComposerMenuRoom.cap)
        #expect(ComposerMenuRoom.height(ceiling: 116, panelTop: nil, spacing: 8) == ComposerMenuRoom.cap)
    }

    @Test func neverGoesOverTheBarEvenWithoutRoom() {
        // Landscape iPhone with the keyboard: barely any room between bar and composer.
        #expect(ComposerMenuRoom.height(ceiling: 60, panelTop: 110, spacing: 8) == 34)
        #expect(ComposerMenuRoom.height(ceiling: 60, panelTop: 70, spacing: 8) == 0)
    }
}
