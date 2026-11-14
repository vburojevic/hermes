import Foundation
import Testing
@testable import HermesKit

/// How large a file may go to Hermes, and under what name (`docs/composer.md` §2).
@Suite("Files going to Hermes")
struct FileUploadTests {
    /// A Hermes before 0.23.1 closes its socket on a frame over 16 MiB, and a file goes whole in one
    /// frame as base64: a file it can't take is refused before it leaves, never sent into a closed socket.
    @Test func anOlderHermesTakesWhatFitsInOneFrame() {
        #expect(FileUpload.limit(hermesVersion: "0.22.4") == FileUpload.olderHermesLimit)
        #expect(FileUpload.limit(hermesVersion: "0.23.0") == FileUpload.olderHermesLimit)
        let largestFrame = 4 * ((FileUpload.olderHermesLimit + 2) / 3)
        #expect(largestFrame + 4096 < 16 * 1024 * 1024)
    }

    @Test func hermes0231AndLaterTakesTheAppsWholeLimit() {
        #expect(FileUpload.limit(hermesVersion: "0.23.1") == FileUpload.appLimit)
        #expect(FileUpload.limit(hermesVersion: "v0.24.0") == FileUpload.appLimit)
        #expect(FileUpload.limit(hermesVersion: "0.23.1rc3") == FileUpload.appLimit)
        #expect(FileUpload.limit(hermesVersion: "1.0") == FileUpload.appLimit)
    }

    /// Not known yet, or not a version: taken to be older, so nothing can close the socket.
    @Test func anUnknownVersionIsTakenToBeOlder() {
        #expect(FileUpload.limit(hermesVersion: nil) == FileUpload.olderHermesLimit)
        #expect(FileUpload.limit(hermesVersion: "dev") == FileUpload.olderHermesLimit)
        #expect(FileUpload.limit(hermesVersion: "") == FileUpload.olderHermesLimit)
    }

    @Test func aFolderGoesAsAZipNamedForIt() {
        #expect(FileUpload.uploadName("Trip.pages", isFolder: true) == "Trip.pages.zip")
        #expect(FileUpload.uploadName("Sample Invoice.pdf", isFolder: false) == "Sample Invoice.pdf")
    }

    @Test func onlyAKnownSizeOverTheLimitIsTooLarge() {
        #expect(FileUpload.isOver(FileUpload.appLimit + 1, limit: FileUpload.appLimit))
        #expect(!FileUpload.isOver(FileUpload.appLimit, limit: FileUpload.appLimit))
        #expect(!FileUpload.isOver(nil, limit: FileUpload.appLimit))
        #expect(!FileUpload.isOver(Int.max, limit: nil))
    }
}
