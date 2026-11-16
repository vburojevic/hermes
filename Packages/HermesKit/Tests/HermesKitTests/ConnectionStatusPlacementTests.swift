import Testing
@testable import HermesKit

@Suite("Connection status placement")
struct ConnectionStatusPlacementTests {
    @Test func belowTheAccessibilitySizesItIsTheSubtitle() {
        let placement = ConnectionStatusPlacement(isAccessibilitySize: false, isSearching: false)
        #expect(placement == .subtitle)
        #expect(placement.showsSubtitle)
        #expect(!placement.showsRow)
        // A search leaves the subtitle as it was.
        #expect(ConnectionStatusPlacement(isAccessibilitySize: false, isSearching: true) == .subtitle)
    }

    @Test func atTheAccessibilitySizesItIsTheFirstRow() {
        let placement = ConnectionStatusPlacement(isAccessibilitySize: true, isSearching: false)
        #expect(placement == .row)
        #expect(placement.showsRow)
        // Never both: the subtitle would show the line cut off.
        #expect(!placement.showsSubtitle)
    }

    @Test func aSearchHidesTheRow() {
        let placement = ConnectionStatusPlacement(isAccessibilitySize: true, isSearching: true)
        #expect(placement == .hidden)
        #expect(!placement.showsRow)
        #expect(!placement.showsSubtitle)
    }
}
