import Testing
@testable import HermesKit

@Suite("Composer paste")
struct PastePlanTests {
    @Test func copiedFilesAttachAsFiles() {
        // The Finder leaves each file's name and icon alongside its address.
        #expect(PastePlan.plan(hasFiles: true, hasImages: true, text: "Report.pdf") == .files)
    }

    @Test func aPictureAttachesEvenWithItsAddress() {
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: nil) == .images)
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: "") == .images)
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: "https://example.com/cat.png") == .images)
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: "/Users/ada/Desktop/Screenshot.png\n") == .images)
    }

    @Test func textWinsOverAPictureOfIt() {
        // Pages, Numbers and Excel copy a picture of the selection with its text.
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: "Q3 revenue grew 12%") == .text)
        #expect(PastePlan.plan(hasFiles: false, hasImages: true, text: "42") == .text)
    }

    @Test func plainTextAndNothing() {
        #expect(PastePlan.plan(hasFiles: false, hasImages: false, text: "https://example.com") == .text)
        #expect(PastePlan.plan(hasFiles: false, hasImages: false, text: "  ") == .text)
        #expect(PastePlan.plan(hasFiles: false, hasImages: false, text: nil) == .system)
        #expect(PastePlan.plan(hasFiles: false, hasImages: false, text: "") == .system)
    }
}
