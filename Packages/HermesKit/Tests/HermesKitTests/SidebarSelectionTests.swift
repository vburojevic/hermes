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

    @Test func pickingTheSelectedProjectFromSearchShowsItAgain() {
        // The window opened on the project, then the person searched for it and clicked its
        // result: the same pick as its sidebar row (`docs/search.md` §2).
        var pass = DetailPass()
        pass.open(.project("p"))
        pass.settle(current: .project("p"))
        #expect(pass.count == 1)
        let fromSearch = pass.pick(.project("p"), current: .project("p"))
        #expect(!fromSearch)
        #expect(pass.count == 2)
        let again = pass.pick(.project("p"), current: .project("p"))
        #expect(!again)
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

@Suite("Compact navigation")
struct CompactNavigationTests {
    @Test func aNewSelectionOpensItsScreen() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false)
        #expect(navigation.pushes == 1)
        navigation.selectionChanged(to: .bot("ada"), keepsPlace: false)
        #expect(navigation.pushes == 2)
    }

    @Test func aSelectionThatKeepsItsPlaceStaysOnTheList() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .bot("ada"), keepsPlace: true)
        navigation.selectionChanged(to: nil, keepsPlace: true)
        #expect(navigation.pushes == 0)
    }

    @Test func aClearedSelectionStaysWhereItIs() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: nil, keepsPlace: false)
        #expect(navigation.pushes == 0)
    }

    @Test func askingByNameAlwaysOpens() {
        var navigation = CompactNavigation()
        // New Chat and All Bots select nothing; a row picked again keeps its selection.
        navigation.show()
        navigation.show()
        #expect(navigation.pushes == 2)
    }

    @Test func aScreenThatWentAwayGoesBackToTheList() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false)
        // The open chat is deleted: its selection clears, which alone moves nothing.
        navigation.selectionChanged(to: nil, keepsPlace: false)
        navigation.dismiss()
        #expect(navigation.pushes == 1)
        #expect(navigation.pops == 1)
    }

    @Test func aChatOpenedFromAProjectGoesBackToIt() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .project("p1"), keepsPlace: false)
        #expect(navigation.parentProject == nil)
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        #expect(navigation.parentProject == "p1")
        // It pushes over the project's home on a compact width; Back selects the project.
        let route = DetailRoute(selection: .session("s1"), mode: .chats, hasBotMode: true, parentProject: navigation.parentProject)
        #expect(route == .projectChat("p1"))
        #expect(route.backSelection == .project("p1"))
        // The window is already back on the project's home: selecting it pushes nothing more.
        let pushes = navigation.pushes
        navigation.selectionChanged(to: route.backSelection, keepsPlace: true)
        #expect(navigation.parentProject == nil)
        #expect(navigation.pushes == pushes)
        // A second Back is the list's own: the project has nothing to go back to.
        #expect(DetailRoute(selection: .project("p1"), mode: .chats, hasBotMode: true).backSelection == nil)
    }

    @Test func backToAProjectsHomeKeepsTheHomeOnShow() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .project("p1"), keepsPlace: false)
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        #expect(navigation.homeUnderList == nil)
        // Back from the chat: the home stays on screen, though the split view says the list.
        navigation.selectionChanged(to: .project("p1"), keepsPlace: true)
        navigation.poppedToProject("p1")
        #expect(navigation.homeUnderList == "p1")
        // Another chat, the Board or a new chat opened from that home push over it.
        navigation.selectionChanged(to: .session("s2"), keepsPlace: false, fromProject: "p1")
        #expect(navigation.homeUnderList == "p1")
        navigation.selectionChanged(to: .board("p1"), keepsPlace: false)
        #expect(navigation.homeUnderList == "p1")
        navigation.selectionChanged(to: nil, keepsPlace: false, fromProject: "p1")
        navigation.show()
        #expect(navigation.homeUnderList == "p1")
    }

    @Test func aPushAnywhereElseEndsTheHomeUnderTheList() {
        // A row picked in the list, even the project already selected.
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .project("p1"), keepsPlace: false)
        navigation.poppedToProject("p1")
        navigation.show()
        #expect(navigation.homeUnderList == nil)
        // A chat opened from the list, a notification, search or a link.
        navigation.poppedToProject("p1")
        navigation.selectionChanged(to: .session("s9"), keepsPlace: false)
        #expect(navigation.homeUnderList == nil)
        // Another project, or another project's Board.
        navigation.poppedToProject("p1")
        navigation.selectionChanged(to: .board("p2"), keepsPlace: false)
        #expect(navigation.homeUnderList == nil)
        // The screen on show went away: back to the list.
        navigation.poppedToProject("p1")
        navigation.dismiss()
        #expect(navigation.homeUnderList == nil)
        // Renaming what is on show pushes nothing and keeps it.
        navigation.poppedToProject("p1")
        navigation.selectionChanged(to: .project("p1"), keepsPlace: true)
        #expect(navigation.homeUnderList == "p1")
    }

    @Test func aChatOpenedAnyOtherWayGoesBackToTheList() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        // The same chat, or another, picked in the list, a notification, search or a link.
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false)
        #expect(navigation.parentProject == nil)
        let route = DetailRoute(selection: .session("s1"), mode: .chats, hasBotMode: true, parentProject: navigation.parentProject)
        #expect(route == .chat)
        #expect(route.backSelection == nil)
    }

    @Test func aChatStartedInAProjectGoesBackToItOnceSent() {
        var navigation = CompactNavigation()
        // Talk on a project's home opens a new chat's draft from the project.
        navigation.selectionChanged(to: nil, keepsPlace: false, fromProject: "p1")
        #expect(DetailRoute(selection: nil, mode: .chats, hasBotMode: true, parentProject: navigation.parentProject) == .projectChat("p1"))
        // Sent, the draft is filed under its chat, which keeps its place and its project.
        navigation.selectionChanged(to: .session("s1"), keepsPlace: true)
        #expect(navigation.parentProject == "p1")
        // The project home's own composer: its chat opens from the project as it's filed.
        navigation.selectionChanged(to: .project("p2"), keepsPlace: false)
        navigation.selectionChanged(to: .session("s2"), keepsPlace: true, fromProject: "p2")
        #expect(navigation.parentProject == "p2")
    }

    @Test func aChatThatWentAwayLeavesItsProject() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        // Archived or deleted while on screen: the selection clears and the window goes back.
        navigation.selectionChanged(to: nil, keepsPlace: false)
        navigation.dismiss()
        #expect(navigation.parentProject == nil)
        #expect(navigation.pops == 1)
    }

    @Test func onlyChatsComeFromAProject() {
        var navigation = CompactNavigation()
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        // Switching to Bots brings back that mode's selection under its list.
        navigation.selectionChanged(to: .bot("ada"), keepsPlace: true)
        #expect(navigation.parentProject == nil)
        navigation.selectionChanged(to: .board("p1"), keepsPlace: false, fromProject: "p1")
        #expect(navigation.parentProject == nil)
        // A cleared selection that keeps its place (the other mode had none) has no project.
        navigation.selectionChanged(to: .session("s1"), keepsPlace: false, fromProject: "p1")
        navigation.selectionChanged(to: nil, keepsPlace: true)
        #expect(navigation.parentProject == nil)
    }

    @Test func wideWindowsShowAProjectsChatInPlace() {
        // The parent is passed only on a compact width; without it the chat is the detail.
        #expect(DetailRoute(selection: .session("s1"), mode: .chats, hasBotMode: true) == .chat)
        // Bots mode with nothing picked stays on the Bots' home.
        #expect(DetailRoute(selection: nil, mode: .bots, hasBotMode: true, parentProject: "p1") == .botsHome)
        #expect(DetailRoute(selection: .bot("ada"), mode: .bots, hasBotMode: true, parentProject: "p1") == .chat)
        #expect(DetailRoute(selection: .board("p1"), mode: .chats, hasBotMode: true).backSelection == .project("p1"))
    }

    @Test func theScreenStartsOnScreen() {
        // Wide windows never push: the detail is always there.
        #expect(CompactNavigation().showsDetail)
    }
}
