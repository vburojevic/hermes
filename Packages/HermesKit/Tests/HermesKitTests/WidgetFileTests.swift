@testable import HermesKit
import Testing

/// `hermes-file:` addresses: the path a widget's picture loads and Open shows (docs/widgets.md §9).
@Suite("Widget files")
struct WidgetFileTests {
    private let folder = "/Users/studio/Code/site"

    @Test func aRelativePathJoinsOntoTheFolder() {
        #expect(WidgetFile.resolve("hermes-file:diagrams/flow.png", in: folder) == "/Users/studio/Code/site/diagrams/flow.png")
        #expect(WidgetFile.resolve("hermes-file:flow.png", in: folder + "/") == "/Users/studio/Code/site/flow.png")
        #expect(WidgetFile.resolve("hermes-file:./diagrams/flow.png", in: folder) == "/Users/studio/Code/site/diagrams/flow.png")
    }

    @Test func aRelativePathWithNoFolderResolvesToNothing() {
        #expect(WidgetFile.resolve("hermes-file:flow.png", in: nil) == nil)
        #expect(WidgetFile.resolve("hermes-file:flow.png", in: "") == nil)
    }

    @Test func absoluteAndHomePathsStayAsOpenKeepsThem() {
        #expect(WidgetFile.resolve("hermes-file:/srv/charts/week.png", in: folder) == "/srv/charts/week.png")
        #expect(WidgetFile.resolve("hermes-file:~/charts/week.png", in: folder) == "~/charts/week.png")
        #expect(WidgetFile.resolve("hermes-file:~/charts/week.png", in: nil) == "~/charts/week.png")
    }

    @Test func aStepAboveIsRefused() {
        #expect(WidgetFile.path("hermes-file:../secrets.png") == nil)
        #expect(WidgetFile.path("hermes-file:diagrams/../../flow.png") == nil)
        #expect(WidgetFile.path("hermes-file:/srv/../etc/flow.png") == nil)
        #expect(WidgetFile.path("hermes-file:%2e%2e/flow.png") == nil)
        #expect(WidgetFile.resolve("hermes-file:diagrams/..", in: folder) == nil)
        // Two dots inside a name are only a name.
        #expect(WidgetFile.path("hermes-file:v1..2/flow.png") == "v1..2/flow.png")
    }

    @Test func thePathIsPercentDecoded() {
        #expect(WidgetFile.path("hermes-file:Launch%20Flow/step%201.png") == "Launch Flow/step 1.png")
        #expect(WidgetFile.resolve("hermes-file:caf%C3%A9.png", in: folder) == "/Users/studio/Code/site/café.png")
    }

    @Test func aFragmentIsDropped() {
        #expect(WidgetFile.path("hermes-file:src/Sync.swift#L42") == "src/Sync.swift")
        #expect(WidgetFile.path("hermes-file:src/Sync.swift#L42-L60") == "src/Sync.swift")
        // An encoded # is part of the name.
        #expect(WidgetFile.path("hermes-file:notes%23draft.png") == "notes#draft.png")
        #expect(WidgetFile.path("hermes-file:#L1") == nil)
    }

    @Test func onlyHermesFileAddressesNameAFile() {
        #expect(WidgetFile.path("https://example.com/flow.png") == nil)
        #expect(WidgetFile.path("hermes-file:") == nil)
        #expect(WidgetFile.path("HERMES-FILE:flow.png") == "flow.png")
        #expect(WidgetFile.resolve("file:///etc/flow.png", in: folder) == nil)
    }
}
