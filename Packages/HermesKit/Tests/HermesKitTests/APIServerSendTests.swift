import Foundation
import Testing
@testable import HermesKit

/// Sending over the API server (`docs/chat.md` §4c): its bare refusals in words, and a run Hermes
/// queued behind another.
@Suite("Sending over the API server")
struct APIServerSendTests {
    @Test func storeRefusalsWithOnlyTheirReasonAreWords() {
        let refused = HermesError.server(status: 409, code: "permission_denied", message: "permission_denied")
        #expect(refused.errorDescription?.contains("permission_denied") == false)
        #expect(HermesError.server(status: 409, code: "queue_full", message: "queue_full").errorDescription?.contains("waiting") == true)
        // A message of its own stays Hermes's.
        #expect(HermesError.server(status: 409, code: "run_not_active", message: "Run is not active").errorDescription == "Run is not active")
    }

    @Test func aRunHermesQueuedSaysSo() throws {
        let queued = try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id": "r", "status": "queued"}"#.utf8))
        #expect(queued.isQueued)
        let running = try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id": "r", "status": "running"}"#.utf8))
        #expect(!running.isQueued)
    }
}
