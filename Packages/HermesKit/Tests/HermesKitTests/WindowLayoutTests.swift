import Testing
@testable import HermesKit

@Suite("Window layout")
struct WindowLayoutTests {
    private func layout(at width: Double) -> WindowLayout {
        var layout = WindowLayout()
        layout.resize(to: width)
        return layout
    }

    @Test func anUnmeasuredWindowCountsAsWide() {
        let layout = WindowLayout()
        #expect(!layout.isNarrow)
        #expect(!layout.inspectorOverlays)
        #expect(layout.docksSidebar)
    }

    @Test func theSidebarStepsAsideBelowSevenHundred() {
        #expect(layout(at: 700).docksSidebar)
        #expect(!layout(at: 700).isNarrow)
        #expect(layout(at: 699).isNarrow)
        #expect(!layout(at: 699).docksSidebar)
        #expect(!layout(at: 480).showsSidebar)
    }

    @Test func theInspectorOpensOverTheChatBelowEightFortyPoints() {
        #expect(layout(at: 839).inspectorOverlays)
        #expect(!layout(at: 840).inspectorOverlays)
        #expect(layout(at: 480).inspectorOverlays)
    }

    @Test func theButtonShowsTheSidebarOverANarrowWindow() {
        var layout = layout(at: 600)
        layout.toggleSidebar()
        #expect(layout.showsSidebarOver)
        #expect(layout.showsSidebar)
        #expect(!layout.docksSidebar)
        layout.toggleSidebar()
        #expect(!layout.showsSidebarOver)
    }

    @Test func pickingAChatPutsTheSidebarAway() {
        var layout = layout(at: 600)
        layout.toggleSidebar()
        layout.closeSidebarOver()
        #expect(!layout.showsSidebarOver)
    }

    @Test func growingBackPastTheCutoffDocksTheSidebar() {
        var layout = layout(at: 1000)
        layout.resize(to: 600)
        #expect(!layout.docksSidebar)
        layout.toggleSidebar()
        layout.resize(to: 701)
        // The sidebar over the chat goes; the one beside it comes back.
        #expect(!layout.showsSidebarOver)
        #expect(layout.docksSidebar)
    }

    @Test func aSidebarThePersonHidStaysHidden() {
        var layout = layout(at: 1000)
        layout.toggleSidebar()
        #expect(!layout.docksSidebar)
        layout.resize(to: 600)
        layout.resize(to: 1000)
        #expect(!layout.docksSidebar)
        #expect(!layout.showsSidebar)
        layout.toggleSidebar()
        #expect(layout.docksSidebar)
    }

    @Test func theSystemButtonCountsAsThePersonsChoice() {
        var layout = layout(at: 1000)
        layout.sidebarChanged(shown: false)
        #expect(layout.personHidSidebar)
        layout.resize(to: 600)
        layout.resize(to: 1000)
        #expect(!layout.docksSidebar)
        layout.sidebarChanged(shown: true)
        #expect(layout.docksSidebar)
    }

    @Test func aNarrowWindowIgnoresTheSplitViewsOwnReports() {
        var layout = layout(at: 600)
        // The split view hiding its sidebar as the window narrows is not the person's choice.
        layout.sidebarChanged(shown: false)
        layout.resize(to: 1000)
        #expect(layout.docksSidebar)
    }

    @Test func aReportThatMatchesChangesNothing() {
        var layout = layout(at: 1000)
        layout.sidebarChanged(shown: true)
        #expect(!layout.personHidSidebar)
    }

    @Test func theInspectorBesideTheChatCollapsesTheSidebarUnderFourteenHundred() {
        var layout = layout(at: 1000)
        layout.inspectorChanged(open: true)
        #expect(layout.inspectorHidSidebar)
        #expect(!layout.docksSidebar)
        layout.inspectorChanged(open: false)
        #expect(layout.docksSidebar)
    }

    @Test func aWideWindowKeepsTheSidebarBesideTheInspector() {
        var layout = layout(at: 1440)
        layout.inspectorChanged(open: true)
        #expect(layout.docksSidebar)
    }

    @Test func closingTheInspectorLeavesASidebarThePersonHidHidden() {
        var layout = layout(at: 1000)
        layout.toggleSidebar()
        layout.inspectorChanged(open: true)
        #expect(!layout.inspectorHidSidebar)
        layout.inspectorChanged(open: false)
        #expect(!layout.docksSidebar)
    }

    @Test func theInspectorOverTheChatLeavesTheSidebarBeside() {
        var layout = layout(at: 760)
        layout.inspectorChanged(open: true)
        #expect(!layout.inspectorHidSidebar)
        #expect(layout.docksSidebar)
    }

    @Test func narrowingWithTheInspectorOpenKeepsTheSidebarAwayUntilItCloses() {
        var layout = layout(at: 1000)
        layout.inspectorChanged(open: true)
        layout.resize(to: 760)
        #expect(layout.inspectorOverlays)
        #expect(!layout.docksSidebar)
        layout.inspectorChanged(open: false)
        #expect(layout.docksSidebar)
    }

    @Test func showingTheSidebarBesideTheInspectorKeepsItThere() {
        var layout = layout(at: 1000)
        layout.inspectorChanged(open: true)
        layout.toggleSidebar()
        #expect(layout.docksSidebar)
        #expect(!layout.personHidSidebar)
    }

    @Test func narrowingUnderFourteenHundredWithTheInspectorBesideCollapsesTheSidebar() {
        var layout = layout(at: 1440)
        layout.inspectorChanged(open: true)
        #expect(layout.docksSidebar)
        layout.resize(to: 1000)
        #expect(!layout.docksSidebar)
        layout.inspectorChanged(open: false)
        #expect(layout.docksSidebar)
    }

    @Test func theInspectorMovingBesideTheChatCollapsesTheSidebar() {
        var layout = layout(at: 600)
        layout.inspectorChanged(open: true)
        layout.resize(to: 900)
        #expect(!layout.inspectorOverlays)
        #expect(!layout.docksSidebar)
    }

    @Test func aSidebarShownBesideTheInspectorStaysThroughAResize() {
        var layout = layout(at: 1000)
        layout.inspectorChanged(open: true)
        layout.toggleSidebar()
        layout.resize(to: 990)
        #expect(layout.docksSidebar)
    }

    @Test func theInspectorOverTheChatPutsTheSidebarOverItAway() {
        var layout = layout(at: 600)
        layout.toggleSidebar()
        layout.inspectorChanged(open: true)
        #expect(!layout.showsSidebarOver)
    }
}
