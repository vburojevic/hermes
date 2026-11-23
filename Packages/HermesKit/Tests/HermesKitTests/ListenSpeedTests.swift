import Foundation
import Testing
@testable import HermesKit

@Suite("Listen speed")
struct ListenSpeedTests {
    private let english = Locale(identifier: "en_US")

    @Test func stepsRunFromOneToTwoInQuarters() {
        #expect(ListenSpeed.steps == [1, 1.25, 1.5, 1.75, 2])
    }

    @Test func aTapMovesToTheNextStepAndTwoWrapsToOne() {
        #expect(ListenSpeed.next(after: 1) == 1.25)
        #expect(ListenSpeed.next(after: 1.25) == 1.5)
        #expect(ListenSpeed.next(after: 1.5) == 1.75)
        #expect(ListenSpeed.next(after: 1.75) == 2)
        #expect(ListenSpeed.next(after: 2) == 1)
    }

    @Test func aTapFromBetweenStepsMovesOnFromTheNearestOne() {
        #expect(ListenSpeed.next(after: 1.3) == 1.5)
        #expect(ListenSpeed.next(after: 3) == 1)
        #expect(ListenSpeed.next(after: .nan) == 1.25)
    }

    @Test func labelsAreExact() {
        let labels = ListenSpeed.steps.map { ListenSpeed.label($0, locale: english) }
        #expect(labels == ["1×", "1.25×", "1.5×", "1.75×", "2×"])
        #expect(ListenSpeed.label(0.75, locale: english) == "0.75×")
    }

    @Test func labelsFollowTheLocalesDecimalMark() {
        #expect(ListenSpeed.label(1.25, locale: Locale(identifier: "de_DE")) == "1,25×")
    }

    @Test func storedSpeedsSnapToTheNearestStep() {
        #expect(ListenSpeed.snapped(1.1) == 1)
        #expect(ListenSpeed.snapped(1.3) == 1.25)
        #expect(ListenSpeed.snapped(1.4) == 1.5)
        #expect(ListenSpeed.snapped(1.8) == 1.75)
        // A tie goes to the slower step.
        #expect(ListenSpeed.snapped(1.125) == 1)
        for step in ListenSpeed.steps {
            #expect(ListenSpeed.snapped(step) == step)
        }
    }

    @Test func storedSpeedsOutsideTheRangeAreClamped() {
        #expect(ListenSpeed.snapped(0.5) == 1)
        #expect(ListenSpeed.snapped(0) == 1)
        #expect(ListenSpeed.snapped(3) == 2)
        #expect(ListenSpeed.snapped(.infinity) == 2)
        #expect(ListenSpeed.snapped(-.infinity) == 1)
    }

    @Test func nothingStoredOrNotANumberIsOne() {
        #expect(ListenSpeed.snapped(nil) == 1)
        #expect(ListenSpeed.snapped(.nan) == 1)
    }

    @Test func theLongestLabelIsAsLongAsEveryStepsLabel() {
        let longest = ListenSpeed.longestLabel(locale: english)
        #expect(longest.count == 5)
        for step in ListenSpeed.steps {
            #expect(ListenSpeed.label(step, locale: english).count <= longest.count)
        }
        #expect(ListenSpeed.longestLabel(locale: Locale(identifier: "de_DE")) == "1,25×")
    }
}
