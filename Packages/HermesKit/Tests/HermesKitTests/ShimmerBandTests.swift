import Foundation
import Testing
@testable import HermesKit

@Suite("The shimmer's band")
struct ShimmerBandTests {
    @Test func itIsFullStrengthOnlyAtItsMiddle() {
        #expect(ShimmerBand.strength(at: 0.5) == 1)
        #expect(ShimmerBand.strength(at: 0) == 0)
        #expect(ShimmerBand.strength(at: 1) == 0)
        #expect(ShimmerBand.strength(at: 0.25) == ShimmerBand.strength(at: 0.75))
    }

    @Test func itsEdgesEaseOutRatherThanRampStraight() {
        // A straight ramp is 0.25 strong an eighth of the way in; eased, much less shows there,
        // so the band has no edge.
        #expect(ShimmerBand.strength(at: 0.125) < 0.2)
        // And it eases into its middle too: no crease at the peak.
        #expect(ShimmerBand.strength(at: 0.375) > 0.8)
    }

    @Test func itsStopsRunEdgeToEdgeAndRiseThenFall() {
        let stops = ShimmerBand.stops
        #expect(stops.first == .init(location: 0, strength: 0))
        #expect(stops.last == .init(location: 1, strength: 0))
        #expect(stops.map(\.location) == stops.map(\.location).sorted())
        let middle = stops.count / 2
        #expect(stops[middle].strength == 1)
        #expect(zip(stops[..<middle], stops[1...middle]).allSatisfy { $0.strength < $1.strength })
        #expect(zip(stops[middle...], stops[(middle + 1)...]).allSatisfy { $0.strength > $1.strength })
    }

    @Test func itIsAThirdOfTheWordsWithinLimits() {
        // "Thinking…" in a chat: never so thin it can't be seen.
        #expect(ShimmerBand.width(over: 68) == 32)
        // A sidebar row.
        #expect(ShimmerBand.width(over: 200) == 60)
        // A row across an iPhone or a wide Mac window: never a wash over half the line.
        #expect(ShimmerBand.width(over: 330) == 80)
        #expect(ShimmerBand.width(over: 900) == 80)
    }

    @Test func itPassesFromWhollyBeforeTheWordsToWhollyPastThem() {
        let travel = ShimmerBand.travel(over: 200)
        #expect(travel.from == -30)
        #expect(travel.to == 230)
    }

    @Test func itCrossesAtASteadyPaceThenRests() {
        let width = 200.0
        let (from, to) = ShimmerBand.travel(over: width)
        #expect(ShimmerBand.middle(at: 0, over: width) == from)
        #expect(abs(ShimmerBand.middle(at: ShimmerBand.pass / 2, over: width) - (from + to) / 2) < 1e-9)
        #expect(ShimmerBand.middle(at: ShimmerBand.pass, over: width) == to)
        // Equal times, equal distances: the same pace over the first word as the last.
        let quarter = ShimmerBand.pass / 4
        let first = ShimmerBand.middle(at: quarter, over: width) - ShimmerBand.middle(at: 0, over: width)
        let last = ShimmerBand.middle(at: ShimmerBand.pass, over: width) - ShimmerBand.middle(at: 3 * quarter, over: width)
        #expect(abs(first - last) < 1e-9)
        // Then it rests past the words until the period starts again.
        #expect(ShimmerBand.middle(at: ShimmerBand.period - 0.01, over: width) == to)
        #expect(ShimmerBand.pass < ShimmerBand.period)
    }

    @Test func everyShimmerIsOnOneClock() {
        let width = 120.0
        let now = 812_345.678
        let next = ShimmerBand.middle(at: now + ShimmerBand.period, over: width)
        #expect(abs(ShimmerBand.middle(at: now, over: width) - next) < 1e-6)
        // A clock before its zero still lands inside the period.
        let (from, to) = ShimmerBand.travel(over: width)
        let early = ShimmerBand.middle(at: -0.4, over: width)
        #expect(early >= from && early <= to)
    }
}
