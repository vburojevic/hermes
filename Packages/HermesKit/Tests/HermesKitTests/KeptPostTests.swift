import Foundation
import Testing
@testable import HermesKit

/// A group chat's messages on their way, kept on the device across a relaunch (`KeptPost`).
@Suite("Group chat posts kept on the device")
struct KeptPostTests {
    @Test func aPostKeptAcrossARelaunchGoesAgainUnderItsOwnID() throws {
        let posts = [KeptPost(eventID: "e-1", text: "hello room"), KeptPost(eventID: "e-2", text: "and again")]
        let data = try #require(KeptPost.encode(posts))
        #expect(KeptPost.decode(data) == posts)
        #expect(KeptPost.decode(Data("not json".utf8)) == [])
    }
}
