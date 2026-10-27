import Testing
@testable import HermesKit

@Suite("Sidebar selection")
struct SidebarSelectionTests {
    @Test func routeFollowsTheSelection() {
        #expect(DetailRoute(selection: nil, mode: .bots, hasBotMode: true) == .botsHome)
        #expect(DetailRoute(selection: .bot("default"), mode: .bots, hasBotMode: true) == .chat)
        // A Bot picked before the Bots have loaded is its chat, never the grid.
        #expect(DetailRoute(selection: .bot("default"), mode: .bots, hasBotMode: false) == .chat)
        #expect(DetailRoute(selection: .session("s1"), mode: .bots, hasBotMode: true) == .chat)
        #expect(DetailRoute(selection: .group("r1"), mode: .bots, hasBotMode: true) == .group("r1"))
        #expect(DetailRoute(selection: .tasks, mode: .bots, hasBotMode: true) == .tasks)
        #expect(DetailRoute(selection: .skills, mode: .chats, hasBotMode: true) == .skills)
        #expect(DetailRoute(selection: .project("p"), mode: .chats, hasBotMode: true) == .project("p"))
        #expect(DetailRoute(selection: .board("p"), mode: .chats, hasBotMode: true) == .board("p"))
        #expect(DetailRoute(selection: .allProjects, mode: .chats, hasBotMode: false) == .allProjects)
    }

    @Test func nothingPickedIsTheGridOnlyInBotsMode() {
        #expect(DetailRoute(selection: nil, mode: .chats, hasBotMode: true) == .chat)
        // Without Bot Mode there is no grid to show: the new-chat draft.
        #expect(DetailRoute(selection: nil, mode: .bots, hasBotMode: false) == .chat)
    }

    @Test func pickingTheSelectedRowShowsItAgain() {
        var pass = DetailPass()
        let changed = pass.pick(.bot("ada"), current: nil)
        #expect(changed)
        #expect(pass.count == 0)
        let again = pass.pick(.bot("ada"), current: .bot("ada"))
        #expect(!again)
        #expect(pass.count == 1)
        // All Bots while the grid shows.
        let allBots = pass.pick(nil, current: nil)
        #expect(!allBots)
        #expect(pass.count == 2)
        let away = pass.pick(nil, current: .bot("ada"))
        #expect(away)
        #expect(pass.count == 2)
    }

    @Test func pickingTheSelectedProjectRowShowsItAgain() {
        var pass = DetailPass()
        let project = pass.pick(.project("p"), current: .project("p"))
        #expect(!project)
        #expect(pass.count == 1)
        let board = pass.pick(.board("p"), current: .board("p"))
        #expect(!board)
        #expect(pass.count == 2)
        let allProjects = pass.pick(.allProjects, current: .allProjects)
        #expect(!allProjects)
        #expect(pass.count == 3)
        // The project's Board from its home is another screen.
        let toBoard = pass.pick(.board("p"), current: .project("p"))
        #expect(toBoard)
        #expect(pass.count == 3)
    }

    @Test func aLaunchSelectionSettlesOnce() {
        var pass = DetailPass()
        pass.open(.bot("default"))
        pass.settle(current: .bot("default"))
        #expect(pass.count == 1)
        pass.settle(current: .bot("default"))
        #expect(pass.count == 1)
    }

    @Test func aLaunchSelectionTheWindowLeftDoesNotSettle() {
        var pass = DetailPass()
        pass.open(.session("s1"))
        pass.settle(current: .session("s2"))
        #expect(pass.count == 0)

        // A pick before the gateway answers: the person's choice already redrew the detail.
        pass.open(.bot("default"))
        let changed = pass.pick(.bot("ada"), current: .bot("default"))
        #expect(changed)
        pass.settle(current: .bot("ada"))
        #expect(pass.count == 0)
    }

    @Test func aWindowThatOpenedOnNothingSettlesToo() {
        var pass = DetailPass()
        pass.settle(current: nil)
        #expect(pass.count == 0)
        pass.open(nil)
        pass.settle(current: nil)
        #expect(pass.count == 1)
    }

    @Test func storedValuesRoundTrip() {
        let items: [SidebarItem] = [.session("a:b"), .tasks, .skills, .bot("ops"), .group("r"), .project("p"), .board("p"), .allProjects]
        for item in items {
            #expect(SidebarItem(storedValue: item.storedValue) == item)
        }
        #expect(SidebarItem(storedValue: "bot") == nil)
        #expect(SidebarItem(storedValue: "nonsense") == nil)
    }
}
