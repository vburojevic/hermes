import Testing
@testable import HermesKit

/// Reading back through a long chat holds a few rows around the screen (`docs/chat.md` §4).
@Suite("Reading back holds a few rows around the screen")
struct TranscriptScrollTests {
    @Test("Rows below the screen stay until there are more than a few past it")
    func dropBelow() {
        // On screen through row 50: four rows past it stay, and up to three more may wait.
        #expect(TranscriptWindow.lastAfterDropBelow(lastVisible: 50, end: 58) == nil)
        #expect(TranscriptWindow.lastAfterDropBelow(lastVisible: 50, end: 59) == 54)
        #expect(TranscriptWindow.lastAfterDropBelow(lastVisible: 50, end: 80) == 54)
    }

    @Test("Rows above the screen stay until there are more than a few before it")
    func dropAbove() {
        #expect(TranscriptWindow.firstAfterDropAbove(firstVisible: 20, first: 13) == nil)
        #expect(TranscriptWindow.firstAfterDropAbove(firstVisible: 20, first: 12) == 16)
        #expect(TranscriptWindow.firstAfterDropAbove(firstVisible: 20, first: 0) == 16)
    }

    @Test("Dropping never takes a row on screen or the ones kept past it")
    func keepsTheScreen() {
        for visible in 0..<40 {
            for edge in 0..<80 {
                if let last = TranscriptWindow.lastAfterDropBelow(lastVisible: visible, end: edge) {
                    #expect(last == visible + TranscriptWindow.keptBeyond)
                    #expect(last < edge)
                }
                if let first = TranscriptWindow.firstAfterDropAbove(firstVisible: visible, first: edge) {
                    #expect(first == visible - TranscriptWindow.keptBeyond)
                    #expect(first > edge)
                }
            }
        }
    }

    @Test("Back down, a few screens of rows come back, and none past the end")
    func showLater() {
        #expect(TranscriptWindow.lastAfterShowLater(last: 30, count: 100) == 40)
        #expect(TranscriptWindow.lastAfterShowLater(last: 95, count: 100) == 99)
        #expect(TranscriptWindow.lastAfterShowLater(last: 99, count: 100) == nil)
    }

    @Test("Rows coming back above cover a page of reading")
    func bringBack() {
        #expect(TranscriptWindow.bringBackSteps * TranscriptWindow.fillStep >= TranscriptWindow.readingPage)
        #expect((TranscriptWindow.bringBackSteps - 1) * TranscriptWindow.fillStep < TranscriptWindow.readingPage)
    }
}
