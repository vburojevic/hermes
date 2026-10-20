import Foundation
@testable import HermesKit
import Testing

@Suite("Preview file access")
struct PreviewFileAccessTests {
    @Test func aPageReadsItsOwnFolderAndNothingElse() {
        var access = PreviewFileAccess()
        #expect(!access.allows("/Users/u/site/index.html"))
        access.allowFolder(ofFile: "/Users/u/site/index.html")
        #expect(access.allows("/Users/u/site/index.html"))
        #expect(access.allows("/Users/u/site/assets/app.css"))
        #expect(!access.allows("/Users/u/site"))
        #expect(!access.allows("/Users/u/.ssh/id_ed25519"))
        #expect(!access.allows("/Users/u/site/../.ssh/id_ed25519"))
        #expect(!access.allows("/Users/u/site/./x"))
        #expect(!access.allows("/Users/u/site/.git/config"))
        #expect(!access.allows("/Users/u/site/sub/.env"))
        #expect(!access.allows("/Users/u/other/index.html"))
        #expect(!access.allows("/Users/u/sitex/index.html"))
    }

    @Test func aFileInHomeStillCantReachHiddenFolders() {
        var access = PreviewFileAccess()
        access.allowFolder(ofFile: "/Users/u/report.html")
        #expect(access.allows("/Users/u/chart.png"))
        #expect(!access.allows("/Users/u/.hermes/config.yaml"))
        #expect(!access.allows("/Users/u/.aws/credentials"))
    }

    /// The gateway follows symlinks: a link inside the folder can't lead outside it.
    @Test func whereAPathReallyLeadsMustStayInside() {
        var access = PreviewFileAccess()
        var answer: Bool
        access.allowFolder(ofFile: "/Users/u/src/evil/index.html")
        // Nothing but the opened file can be served before its real place is known.
        answer = access.allows("/Users/u/src/evil/app.js", resolvedTo: "/Users/u/src/evil/app.js")
        #expect(!answer)
        answer = access.allows("/Users/u/src/evil/index.html", resolvedTo: "/Volumes/Data/src/evil/index.html")
        #expect(answer)
        answer = access.allows("/Users/u/src/evil/app.js", resolvedTo: "/Volumes/Data/src/evil/app.js")
        #expect(answer)
        answer = access.allows("/Users/u/src/evil/lib/x.js", resolvedTo: "/Volumes/Data/src/evil/vendor/x.js")
        #expect(answer)
        // s3 -> ../../../.ssh, up -> ../.., k -> .git/config
        #expect(access.allows("/Users/u/src/evil/s3/id_ed25519"))
        answer = access.allows("/Users/u/src/evil/s3/id_ed25519", resolvedTo: "/Users/u/.ssh/id_ed25519")
        #expect(!answer)
        answer = access.allows("/Users/u/src/evil/up/Documents/taxes.pdf", resolvedTo: "/Users/u/Documents/taxes.pdf")
        #expect(!answer)
        answer = access.allows("/Users/u/src/evil/k", resolvedTo: "/Volumes/Data/src/evil/.git/config")
        #expect(!answer)
        answer = access.allows("/Users/u/src/evil/x.js", resolvedTo: "/Volumes/Data/src/evilx/x.js")
        #expect(!answer)
    }

    @Test func aFileAtTheTopOpensNothingElse() {
        var access = PreviewFileAccess()
        access.allowFolder(ofFile: "/index.html")
        #expect(!access.allows("/index.html"))
        #expect(!access.allows("/Users/u/notes.txt"))
    }

    @Test func aFileInsideAHiddenFolderReadsItsSiblings() {
        var access = PreviewFileAccess()
        access.allowFolder(ofFile: "/Users/u/.hermes/artifacts/page.html")
        #expect(access.allows("/Users/u/.hermes/artifacts/style.css"))
        #expect(!access.allows("/Users/u/.hermes/.env"))
    }
}
