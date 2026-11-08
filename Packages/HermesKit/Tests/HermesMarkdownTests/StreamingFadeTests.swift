import Testing
@testable import HermesMarkdown

@Suite("Streaming fade")
struct StreamingFadeTests {
    @Test func whileWordsArriveTheEdgeSitsOnTheNewestGlyph() {
        let shown = StreamingFade.shown(count: 40, restedSteps: 0)
        #expect(shown == 40)
        // The newest glyph is faint, the one `length` behind it whole.
        #expect(StreamingFade.opacity(at: 39, shown: shown) == 1 / StreamingFade.length)
        #expect(StreamingFade.opacity(at: 40 - StreamingFade.length, shown: shown) == 1)
        #expect(StreamingFade.opacity(at: 0, shown: shown) == 1)
    }

    @Test func atRestTheFadeFinishesInItsSteps() {
        let count = 40
        var last = StreamingFade.shown(count: count, restedSteps: 0)
        for step in 1...StreamingFade.restSteps {
            let shown = StreamingFade.shown(count: count, restedSteps: step)
            #expect(shown > last)
            last = shown
        }
        // Every glyph is whole once the last step is in, and later steps change nothing.
        #expect(StreamingFade.opacity(at: Double(count - 1), shown: last) == 1)
        #expect(StreamingFade.shown(count: count, restedSteps: StreamingFade.restSteps + 2) == last)
    }

    @Test func nothingIsDrawnPastTheEdge() {
        #expect(StreamingFade.opacity(at: 40, shown: 40) == 0)
        #expect(StreamingFade.opacity(at: 55, shown: 40) == 0)
        #expect(StreamingFade.shown(count: -3, restedSteps: -1) == 0)
    }

    @Test func wordsAfterARestFadeInWithoutDimmingWhatWasDrawn() {
        // 120 glyphs rest until the fade is done, then 4 more arrive.
        var pause = StreamingFade.Pause.none
        for step in 1...StreamingFade.restSteps { pause = pause.rested(count: 120, step: step) }
        let rested = StreamingFade.Edge(count: 120, pause: pause)
        let resumed = StreamingFade.Edge(count: 124, pause: pause)
        #expect(rested.opacity(at: 115) == 1)
        #expect(rested.opacity(at: 119) == 1)
        #expect(resumed.opacity(at: 115) == 1)
        #expect(resumed.opacity(at: 119) == 1)
        // The new words fade in from the new edge.
        #expect(resumed.opacity(at: 123) == 1 / StreamingFade.length)
        #expect(resumed.isWhole(before: 120))
        #expect(!resumed.isWhole(before: 121))
    }

    @Test func noGlyphEverDims() {
        // Streaming, a short rest, more words, a full rest, more words, and a pause cut short
        // before its first step: no glyph that is on screen ever gets fainter.
        var pause = StreamingFade.Pause.none
        var frames: [(count: Int, edge: StreamingFade.Edge)] = []
        func draw(_ count: Int) { frames.append((count, StreamingFade.Edge(count: count, pause: pause))) }
        for count in stride(from: 10, through: 60, by: 10) { draw(count) }
        pause = pause.rested(count: 60, step: 1)
        draw(60)
        for count in [62, 70, 90] { draw(count) }
        for step in 1...StreamingFade.restSteps {
            pause = pause.rested(count: 90, step: step)
            draw(90)
        }
        for count in [91, 95, 120, 140] { draw(count) }
        for (before, after) in zip(frames, frames.dropFirst()) {
            for index in 0..<before.count {
                let glyph = Double(index)
                #expect(after.edge.opacity(at: glyph) >= before.edge.opacity(at: glyph), "glyph \(index)")
            }
        }
        // Everything the last full rest drew stays whole.
        #expect(frames.last?.edge.isWhole(before: 90) == true)
    }

    @Test func aBlockFadesInOverItsStepsAndStaysWhole() {
        #expect(StreamingFade.appearOpacity(step: 0) == 0)
        var last = 0.0
        for step in 1...StreamingFade.appearSteps {
            let opacity = StreamingFade.appearOpacity(step: step)
            #expect(opacity > last)
            last = opacity
        }
        #expect(last == 1)
        #expect(StreamingFade.appearOpacity(step: StreamingFade.appearSteps + 2) == 1)
        #expect(StreamingFade.appearOpacity(step: -1) == 0)
    }

    @Test func aBlockDrawnUnderReduceMotionStaysWholeOnceItIsTurnedOff() {
        // Under Reduce Motion a block starts whole, whatever step it had reached, so its opacity
        // is 1 when Reduce Motion goes off mid-reply and it has no steps left to fade in again.
        for step in [0, 1, StreamingFade.appearSteps] {
            let start = StreamingFade.appearStart(from: step, reduceMotion: true)
            #expect(start == StreamingFade.appearSteps)
            #expect(StreamingFade.appearOpacity(step: start) == 1)
        }
    }

    @Test func aBlockShownAgainCarriesOnFromWhereItWas() {
        #expect(StreamingFade.appearStart(from: 0, reduceMotion: false) == 0)
        #expect(StreamingFade.appearStart(from: 2, reduceMotion: false) == 2)
        // One that had faded in has nothing left to go, so it never dims back.
        #expect(StreamingFade.appearStart(from: StreamingFade.appearSteps, reduceMotion: false) == StreamingFade.appearSteps)
        #expect(StreamingFade.appearStart(from: StreamingFade.appearSteps + 2, reduceMotion: false) == StreamingFade.appearSteps)
        #expect(StreamingFade.appearStart(from: -1, reduceMotion: false) == 0)
    }
}
